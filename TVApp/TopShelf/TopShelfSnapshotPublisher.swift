#if os(tvOS)
import CryptoKit
import Foundation
import TVServices
import UIKit

enum TopShelfOnNowPolicy {
    typealias Candidate = (channel: GuideChannel, program: GuideProgram)

    private enum Identity: Hashable {
        case episode(String)
        case schedule(title: String, subtitle: String, start: Date, end: Date)
    }

    static func uniquePrograms(
        from candidates: [Candidate],
        limit: Int
    ) -> [Candidate] {
        guard limit > 0 else { return [] }
        var seen = Set<Identity>()
        var result: [Candidate] = []
        result.reserveCapacity(min(limit, candidates.count))

        for candidate in candidates {
            guard seen.insert(identity(for: candidate.program)).inserted else { continue }
            result.append(candidate)
            if result.count == limit { break }
        }
        return result
    }

    private static func identity(for program: GuideProgram) -> Identity {
        if let episodeURI = program.metadata.episodeURI?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !episodeURI.isEmpty {
            return .episode(episodeURI)
        }
        return .schedule(
            title: normalized(program.title),
            subtitle: normalized(program.subtitle ?? ""),
            start: program.start,
            end: program.end
        )
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}

actor TopShelfSnapshotPublisher {
    static let shared = TopShelfSnapshotPublisher()

    private struct ThumbnailCandidate: Sendable {
        let recording: TVRecording
        let fallbackFilename: String
    }

    private var thumbnailGenerationTask: Task<Void, Never>?
    private var nextThumbnailAttempt: [String: Date] = [:]

    func publish(
        channels: [GuideChannel],
        favoriteChannelIDs: Set<GuideChannel.ID>,
        recordings: [TVRecording],
        configuration: TVHeadendConfiguration,
        now: Date
    ) async {
        let favoriteProgramCandidates = channels
            .filter { favoriteChannelIDs.contains($0.id) }
            .compactMap { channel -> TopShelfOnNowPolicy.Candidate? in
                guard let program = channel.programs.first(where: { $0.isAiring(at: now) }) else {
                    return nil
                }
                return (channel: channel, program: program)
            }
        let favoritePrograms = TopShelfOnNowPolicy.uniquePrograms(
            from: favoriteProgramCandidates,
            limit: 12
        )

        let playableRecordings = recordings
            .filter(\.isPlayable)
            .sorted {
                if $0.state == .recording, $1.state != .recording { return true }
                if $0.state != .recording, $1.state == .recording { return false }
                return $0.start > $1.start
            }
            .prefix(12)

        var referencedArtwork = Set<String>()
        var onNowItems: [TopShelfSnapshot.Item] = []
        for (channel, program) in favoritePrograms {
            let filename = await cacheArtwork(
                urlString: program.metadata.imageURL,
                identifier: "channel-\(channel.id)-\(program.id)",
                configuration: configuration
            )
            if let filename { referencedArtwork.insert(filename) }
            onNowItems.append(
                TopShelfSnapshot.Item(
                    id: "channel:\(channel.id)",
                    title: "\(channel.name): \(program.title)",
                    routeURL: AppRoute.playChannel(channel.id).url.absoluteString,
                    artworkFilename: filename,
                    expirationDate: program.end,
                    playbackProgress: nil
                )
            )
        }

        var recordingItems: [TopShelfSnapshot.Item] = []
        var thumbnailCandidates: [ThumbnailCandidate] = []
        for recording in playableRecordings {
            let matchingProgram = channels.lazy.flatMap(\.programs).first { program in
                if let eventID = recording.eventID, program.providerEventID == eventID { return true }
                return program.channelID == recording.channelID
                    && program.start < recording.end
                    && recording.start < program.end
                    && program.title == recording.title
            }
            let guideArtworkFilename = await cacheArtwork(
                urlString: matchingProgram?.metadata.imageURL,
                identifier: "recording-\(recording.id)",
                configuration: configuration
            )
            let channel = channels.first {
                $0.id == recording.channelID || $0.name == recording.channelName
            }
            let cachedFrameFilename = cachedRecordingFrameFilename(for: recording)
            let fallbackFilename = cacheRecordingFallback(
                for: recording,
                channel: channel
            )
            let filename = RecordingTopShelfArtworkPolicy.selectedFilename(
                guideArtwork: guideArtworkFilename,
                cachedFrame: cachedFrameFilename,
                fallback: fallbackFilename
            )
            if let filename { referencedArtwork.insert(filename) }
            if guideArtworkFilename == nil, cachedFrameFilename == nil,
               let fallbackFilename {
                thumbnailCandidates.append(
                    ThumbnailCandidate(
                        recording: recording,
                        fallbackFilename: fallbackFilename
                    )
                )
            }
            recordingItems.append(
                TopShelfSnapshot.Item(
                    id: "recording:\(recording.id)",
                    title: recording.title,
                    routeURL: AppRoute.playRecording(recording.id).url.absoluteString,
                    artworkFilename: filename,
                    expirationDate: nil,
                    playbackProgress: nil
                )
            )
        }

        let snapshot = TopShelfSnapshot(
            version: 1,
            generatedAt: now,
            onNow: onNowItems,
            recordings: recordingItems
        )
        do {
            try TopShelfSnapshotStore.save(snapshot)
            removeUnreferencedArtwork(keeping: referencedArtwork)
            TVTopShelfContentProvider.topShelfContentDidChange()
            startThumbnailGenerationIfNeeded(
                candidates: thumbnailCandidates,
                configuration: configuration
            )
        } catch {
            // Top Shelf is opportunistic and must never block guide refreshes.
        }
    }

    private func startThumbnailGenerationIfNeeded(
        candidates: [ThumbnailCandidate],
        configuration: TVHeadendConfiguration
    ) {
        guard thumbnailGenerationTask == nil, !candidates.isEmpty else { return }
        thumbnailGenerationTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            for candidate in candidates {
                guard !Task.isCancelled else { break }
                await self.generateThumbnail(
                    for: candidate,
                    configuration: configuration
                )
            }
            await self.thumbnailGenerationFinished()
        }
    }

    private func generateThumbnail(
        for candidate: ThumbnailCandidate,
        configuration: TVHeadendConfiguration
    ) async {
        let cacheKey = recordingFrameCacheKey(for: candidate.recording)
        let now = Date()
        guard nextThumbnailAttempt[cacheKey].map({ $0 <= now }) != false else { return }

        guard let data = await RecordingThumbnailGenerator.shared.thumbnailData(
            for: candidate.recording,
            configuration: configuration
        ),
              let filename = storeRecordingFrame(
                data,
                for: candidate.recording
              )
        else {
            let retryDelay: TimeInterval = candidate.recording.state == .recording
                ? 10 * 60
                : 60 * 60
            nextThumbnailAttempt[cacheKey] = now.addingTimeInterval(retryDelay)
            return
        }

        nextThumbnailAttempt[cacheKey] = nil
        replaceFallback(
            candidate.fallbackFilename,
            with: filename,
            for: candidate.recording
        )
    }

    private func thumbnailGenerationFinished() {
        thumbnailGenerationTask = nil
    }

    private func replaceFallback(
        _ fallbackFilename: String,
        with thumbnailFilename: String,
        for recording: TVRecording
    ) {
        guard let snapshot = TopShelfSnapshotStore.load() else { return }
        let itemID = "recording:\(recording.id)"
        var replaced = false
        let recordings = snapshot.recordings.map { item in
            guard item.id == itemID, item.artworkFilename == fallbackFilename else { return item }
            replaced = true
            return TopShelfSnapshot.Item(
                id: item.id,
                title: item.title,
                routeURL: item.routeURL,
                artworkFilename: thumbnailFilename,
                expirationDate: item.expirationDate,
                playbackProgress: item.playbackProgress
            )
        }
        guard replaced else { return }

        let updated = TopShelfSnapshot(
            version: snapshot.version,
            generatedAt: snapshot.generatedAt,
            onNow: snapshot.onNow,
            recordings: recordings
        )
        do {
            try TopShelfSnapshotStore.save(updated)
            TVTopShelfContentProvider.topShelfContentDidChange()
        } catch {
            // The next regular publication can retry the cached frame.
        }
    }

    private func cacheArtwork(
        urlString: String?,
        identifier: String,
        configuration: TVHeadendConfiguration
    ) async -> String? {
        guard let urlString, let url = URL(string: urlString),
              let container = TopShelfSnapshotStore.containerURL()
        else { return nil }

        let digest = SHA256.hash(data: Data(identifier.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let pathExtension = url.pathExtension.lowercased()
        let supportedExtension = ["jpg", "jpeg", "png", "heic"].contains(pathExtension)
            ? pathExtension
            : "jpg"
        let filename = "top-shelf-artwork-\(digest).\(supportedExtension)"
        let destination = container.appending(path: filename)
        if FileManager.default.fileExists(atPath: destination.path) { return filename }

        var request = URLRequest(url: url)
        if let baseURL = configuration.baseURL,
           url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
           url.host?.lowercased() == baseURL.host?.lowercased(),
           configuration.usesAuthentication {
            let credentials = Data("\(configuration.username):\(configuration.password)".utf8)
                .base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  !data.isEmpty
            else { return nil }
            try data.write(to: destination, options: [.atomic])
            return filename
        } catch {
            return nil
        }
    }

    private func cachedRecordingFrameFilename(for recording: TVRecording) -> String? {
        guard let container = TopShelfSnapshotStore.containerURL() else { return nil }
        let filename = recordingFrameFilename(for: recording)
        return FileManager.default.fileExists(
            atPath: container.appending(path: filename).path
        ) ? filename : nil
    }

    private func storeRecordingFrame(_ data: Data, for recording: TVRecording) -> String? {
        guard !data.isEmpty, let container = TopShelfSnapshotStore.containerURL() else { return nil }
        let filename = recordingFrameFilename(for: recording)
        do {
            try data.write(to: container.appending(path: filename), options: [.atomic])
            return filename
        } catch {
            return nil
        }
    }

    private func recordingFrameFilename(for recording: TVRecording) -> String {
        "top-shelf-artwork-\(recordingFrameCacheKey(for: recording)).jpg"
    }

    private func recordingFrameCacheKey(for recording: TVRecording) -> String {
        digest(
            RecordingTopShelfArtworkPolicy.frameCacheIdentifier(
                recordingID: recording.id,
                state: recording.state
            )
        )
    }

    private func cacheRecordingFallback(
        for recording: TVRecording,
        channel: GuideChannel?
    ) -> String? {
        guard let container = TopShelfSnapshotStore.containerURL() else { return nil }
        let identifier = [
            "recording-fallback-v1",
            recording.id,
            recording.title,
            recording.channelName,
            recording.state.rawValue,
        ].joined(separator: "-")
        let filename = "top-shelf-artwork-\(digest(identifier)).jpg"
        let destination = container.appending(path: filename)
        if FileManager.default.fileExists(atPath: destination.path) { return filename }

        guard let data = recordingFallbackData(for: recording, channel: channel) else { return nil }
        do {
            try data.write(to: destination, options: [.atomic])
            return filename
        } catch {
            return nil
        }
    }

    private func recordingFallbackData(
        for recording: TVRecording,
        channel: GuideChannel?
    ) -> Data? {
        let pointSize = TVTopShelfSectionedContent.imageSize(for: .hdtv)
        let size = CGSize(
            width: max(1_216, pointSize.width * 2),
            height: max(684, pointSize.height * 2)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let tint = channel.map { UIColor($0.tint) }
                ?? UIColor(red: 0.0, green: 0.27, blue: 0.62, alpha: 1)
            let colors = [
                tint.withAlphaComponent(0.92).cgColor,
                UIColor(red: 0.035, green: 0.043, blue: 0.059, alpha: 1).cgColor,
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }

            let channelMonogram = channel?.monogram.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let fallbackMonogram = recording.channelName.split(separator: " ").prefix(2)
                    .compactMap(\.first).map(String.init).joined().uppercased()
            let monogram = channelMonogram?.isEmpty == false
                ? channelMonogram ?? fallbackMonogram
                : fallbackMonogram
            let monogramAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 150, weight: .black),
                .foregroundColor: UIColor.white.withAlphaComponent(0.22),
            ]
            (monogram as NSString).draw(
                in: CGRect(x: size.width - 390, y: 70, width: 300, height: 190),
                withAttributes: monogramAttributes
            )

            let badgeText = recording.state == .recording ? "RECORDING" : "RECORDED"
            let badgeAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 30, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let badge = NSMutableAttributedString(
                string: "●",
                attributes: badgeAttributes.merging([.foregroundColor: UIColor.systemRed]) { $1 }
            )
            badge.append(NSAttributedString(string: "  \(badgeText)", attributes: badgeAttributes))
            badge.draw(
                at: CGPoint(x: 72, y: 64),
            )

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 64, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
            ]
            (recording.title as NSString).draw(
                with: CGRect(x: 72, y: 170, width: size.width - 144, height: 180),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: titleAttributes,
                context: nil
            )

            let metadataAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.78),
            ]
            (recording.channelName as NSString).draw(
                at: CGPoint(x: 72, y: size.height - 105),
                withAttributes: metadataAttributes
            )
        }
        return image.jpegData(compressionQuality: 0.86)
    }

    private func digest(_ identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func removeUnreferencedArtwork(keeping filenames: Set<String>) {
        guard let container = TopShelfSnapshotStore.containerURL(),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: container,
                includingPropertiesForKeys: nil
              )
        else { return }
        for url in contents where url.lastPathComponent.hasPrefix("top-shelf-artwork-") {
            if !filenames.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
#endif
