#if os(tvOS)
import CryptoKit
import Foundation
import OSLog
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

    static func programsForSnapshot(
        from channels: [GuideChannel],
        favoriteChannelIDs: Set<GuideChannel.ID>,
        after date: Date
    ) -> [Candidate] {
        channels
            .filter { favoriteChannelIDs.contains($0.id) }
            .flatMap { channel in
                channel.programs
                    .filter { $0.end > date }
                    .map { (channel: channel, program: $0) }
            }
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

    static func contentIdentifier(for program: GuideProgram) -> String {
        switch identity(for: program) {
        case let .episode(identifier):
            return "episode:\(identifier)"
        case let .schedule(title, subtitle, start, end):
            return "schedule:\(title)|\(subtitle)|\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)"
        }
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}

struct TopShelfDisplayMetadata: Equatable, Sendable {
    let title: String
    let contextTitle: String
    let summary: String?
    let genre: String?
    let duration: TimeInterval
    let creationDate: Date
    let mediaOptions: [TopShelfSnapshot.MediaOption]
    let namedAttributes: [TopShelfSnapshot.NamedAttribute]
}

enum TopShelfMetadataPolicy {
    static func program(
        channel: GuideChannel,
        program: GuideProgram
    ) -> TopShelfDisplayMetadata {
        metadata(
            title: program.title,
            contextTitle: "On Now · \(channel.name)",
            subtitle: program.subtitle,
            overview: program.overview,
            start: program.start,
            duration: program.duration,
            guideMetadata: program.metadata
        )
    }

    static func recording(
        _ recording: TVRecording,
        matchingProgram: GuideProgram?
    ) -> TopShelfDisplayMetadata {
        metadata(
            title: recording.title,
            contextTitle: "\(recording.state.label) · \(recording.channelName)",
            subtitle: recording.subtitle ?? matchingProgram?.subtitle,
            overview: recording.overview.isEmpty
                ? matchingProgram?.overview ?? ""
                : recording.overview,
            start: recording.start,
            duration: recording.duration,
            guideMetadata: matchingProgram?.metadata ?? .empty,
            preferFirstAiredDate: false
        )
    }

    private static func metadata(
        title: String,
        contextTitle: String,
        subtitle: String?,
        overview: String,
        start: Date,
        duration: TimeInterval,
        guideMetadata: GuideProgramMetadata,
        preferFirstAiredDate: Bool = true
    ) -> TopShelfDisplayMetadata {
        var mediaOptions: [TopShelfSnapshot.MediaOption] = []
        if guideMetadata.isHD {
            mediaOptions.append(.hd)
        }
        if guideMetadata.isSubtitled {
            mediaOptions.append(.closedCaptioning)
        }

        var namedAttributes: [TopShelfSnapshot.NamedAttribute] = []
        if let episode = guideMetadata.episodeDisplayDescription {
            namedAttributes.append(.init(name: "Episode", values: [episode]))
        }
        if let rating = guideMetadata.ratingDisplayDescription {
            namedAttributes.append(.init(name: "Rating", values: [rating]))
        }
        if !guideMetadata.featureLabels.isEmpty {
            namedAttributes.append(
                .init(name: "Features", values: guideMetadata.featureLabels)
            )
        }

        let firstAiredDate = guideMetadata.firstAired.flatMap { timestamp in
            timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
        }
        return TopShelfDisplayMetadata(
            title: title,
            contextTitle: contextTitle,
            summary: summary(subtitle: subtitle, overview: overview),
            genre: guideMetadata.primaryContentLabel,
            duration: duration,
            creationDate: preferFirstAiredDate ? firstAiredDate ?? start : start,
            mediaOptions: mediaOptions,
            namedAttributes: namedAttributes
        )
    }

    private static func summary(subtitle: String?, overview: String) -> String? {
        var seen = Set<String>()
        let values = [subtitle, overview].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let normalized = trimmed
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .lowercased()
            guard seen.insert(normalized).inserted else { return nil }
            return trimmed
        }
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }
}

actor TopShelfSnapshotPublisher {
    static let shared = TopShelfSnapshotPublisher()

    private let logger = Logger(
        subsystem: "de.beutner.TVPlayer",
        category: "TopShelf"
    )

    private struct ThumbnailCandidate: Sendable {
        let recording: TVRecording
        let replacementArtworkFilename: String
        let overlay: RecordingThumbnailOverlay
        let channelLogoFilename: String?
    }

    private struct ThumbnailWork: Sendable {
        let candidate: ThumbnailCandidate
        let configuration: TVHeadendConfiguration
    }

    private var thumbnailGenerationTask: Task<Void, Never>?
    private var thumbnailWorkQueue = RecordingThumbnailWorkQueue<ThumbnailWork>()
    private var nextThumbnailAttempt: [String: Date] = [:]

    func publish(
        channels: [GuideChannel],
        favoriteChannelIDs: Set<GuideChannel.ID>,
        recordings: [TVRecording],
        configuration: TVHeadendConfiguration,
        now: Date,
        guideCoverageEnd: Date? = nil
    ) async {
        do {
            _ = try TopShelfSnapshotStore.prepareCacheDirectory()
        } catch {
            logger.error(
                "Could not prepare the Top Shelf cache: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        // Keep the complete fetched schedule in the shared snapshot. tvOS can
        // defer a background refresh, so a short item-count window can expire
        // even though the app had already downloaded later programmes.
        let favoriteProgramCandidates = TopShelfOnNowPolicy.programsForSnapshot(
            from: channels,
            favoriteChannelIDs: favoriteChannelIDs,
            after: now
        )

        let playableRecordings = recordings
            .filter(\.isPlayable)
            .sorted {
                if $0.state == .recording, $1.state != .recording { return true }
                if $0.state != .recording, $1.state == .recording { return false }
                return $0.start > $1.start
            }
            .prefix(12)
        let artworkClient = TVHeadendClient(configuration: configuration)
        let detailedArtworkIDs = Set(
            channels
                .filter { favoriteChannelIDs.contains($0.id) }
                .flatMap { channel in
                    channel.programs
                        .filter { $0.end > now }
                        .prefix(3)
                        .map { "\(channel.id):\($0.id)" }
                }
        )

        var referencedArtwork = Set<String>()
        var channelArtwork: [GuideChannel.ID: String] = [:]
        var attemptedChannelArtwork = Set<GuideChannel.ID>()
        var onNowItems: [TopShelfSnapshot.Item] = []
        for (channel, program) in favoriteProgramCandidates {
            let metadata = TopShelfMetadataPolicy.program(
                channel: channel,
                program: program
            )
            let filename: String?
            if detailedArtworkIDs.contains("\(channel.id):\(program.id)") {
                filename = await cacheArtwork(
                    urlString: program.metadata.imageURL,
                    identifier: "channel-\(channel.id)-\(program.id)",
                    client: artworkClient
                )
            } else if let cached = channelArtwork[channel.id] {
                filename = cached
            } else if attemptedChannelArtwork.insert(channel.id).inserted {
                filename = await cacheArtwork(
                    urlString: channel.iconURL?.absoluteString,
                    identifier: "channel-\(channel.id)-fallback",
                    client: artworkClient
                )
                channelArtwork[channel.id] = filename
            } else {
                filename = nil
            }
            if let filename { referencedArtwork.insert(filename) }
            onNowItems.append(
                TopShelfSnapshot.Item(
                    id: "channel:\(channel.id)",
                    title: metadata.title,
                    contextTitle: metadata.contextTitle,
                    summary: metadata.summary,
                    genre: metadata.genre,
                    duration: metadata.duration,
                    creationDate: metadata.creationDate,
                    mediaOptions: metadata.mediaOptions,
                    namedAttributes: metadata.namedAttributes,
                    routeURL: AppRoute.playChannel(
                        channel.id,
                        topShelf: TopShelfLaunchContext(
                            programID: program.id,
                            artworkFilename: filename
                        )
                    ).url.absoluteString,
                    displayRouteURL: AppRoute.showChannelDetails(
                        channel.id,
                        programID: program.id
                    ).url.absoluteString,
                    artworkFilename: filename,
                    availabilityDate: program.start,
                    expirationDate: program.end,
                    playbackProgress: nil,
                    contentIdentifier: TopShelfOnNowPolicy.contentIdentifier(for: program)
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
                client: artworkClient
            )
            let metadata = TopShelfMetadataPolicy.recording(
                recording,
                matchingProgram: matchingProgram
            )
            let thumbnailOverlay = RecordingThumbnailOverlayPolicy.overlay(
                for: recording,
                matchingProgram: matchingProgram
            )
            let channel = channels.first {
                $0.id == recording.channelID || $0.name == recording.channelName
            }
            let channelLogoFilename = await cacheArtwork(
                urlString: channel?.iconURL?.absoluteString,
                identifier: channel.map { "channel-\($0.id)-fallback" }
                    ?? "recording-\(recording.id)-channel",
                client: artworkClient
            )
            let cachedFrameFilename = cachedRecordingFrameFilename(
                for: recording,
                channelLogoIdentifier: channelLogoFilename
            )
            let fallbackFilename = cacheRecordingFallback(
                for: recording,
                channel: channel,
                channelLogoFilename: channelLogoFilename,
                overlay: thumbnailOverlay
            )
            let filename = RecordingTopShelfArtworkPolicy.selectedFilename(
                guideArtwork: guideArtworkFilename,
                cachedFrame: cachedFrameFilename,
                channelLogo: channelLogoFilename,
                fallback: fallbackFilename
            )
            referencedArtwork.formUnion(
                RecordingTopShelfArtworkPolicy.referencedFilenames(
                    selected: filename,
                    channelLogo: channelLogoFilename
                )
            )
            if guideArtworkFilename == nil, cachedFrameFilename == nil,
               let filename {
                thumbnailCandidates.append(
                    ThumbnailCandidate(
                        recording: recording,
                        replacementArtworkFilename: filename,
                        overlay: thumbnailOverlay,
                        channelLogoFilename: channelLogoFilename
                    )
                )
            }
            recordingItems.append(
                TopShelfSnapshot.Item(
                    id: "recording:\(recording.id)",
                    title: metadata.title,
                    contextTitle: metadata.contextTitle,
                    summary: metadata.summary,
                    genre: metadata.genre,
                    duration: metadata.duration,
                    creationDate: metadata.creationDate,
                    mediaOptions: metadata.mediaOptions,
                    namedAttributes: metadata.namedAttributes,
                    routeURL: AppRoute.playRecording(recording.id).url.absoluteString,
                    displayRouteURL: AppRoute.showRecordingDetails(
                        recording.id
                    ).url.absoluteString,
                    artworkFilename: filename,
                    expirationDate: nil,
                    playbackProgress: nil
                )
            )
        }

        let snapshot = TopShelfSnapshot(
            version: 2,
            generatedAt: now,
            guideCoverageEnd: guideCoverageEnd,
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
            logger.error(
                "Could not save the Top Shelf snapshot: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func startThumbnailGenerationIfNeeded(
        candidates: [ThumbnailCandidate],
        configuration: TVHeadendConfiguration
    ) {
        for candidate in candidates {
            let work = ThumbnailWork(
                candidate: candidate,
                configuration: configuration
            )
            thumbnailWorkQueue.enqueue(
                work,
                forKey: recordingFrameCacheKey(
                    for: candidate.recording,
                    channelLogoIdentifier: candidate.channelLogoFilename
                )
            )
        }
        guard thumbnailGenerationTask == nil, !thumbnailWorkQueue.isEmpty else { return }
        thumbnailGenerationTask = Task(priority: .utility) { [weak self] in
            await self?.drainThumbnailQueue()
        }
    }

    private func drainThumbnailQueue() async {
        while !Task.isCancelled, let work = thumbnailWorkQueue.popFirst() {
            await generateThumbnail(
                for: work.candidate,
                configuration: work.configuration
            )
        }
        thumbnailGenerationTask = nil
    }

    private func generateThumbnail(
        for candidate: ThumbnailCandidate,
        configuration: TVHeadendConfiguration
    ) async {
        let cacheKey = recordingFrameCacheKey(
            for: candidate.recording,
            channelLogoIdentifier: candidate.channelLogoFilename
        )
        let now = Date()
        guard nextThumbnailAttempt[cacheKey].map({ $0 <= now }) != false else { return }

        guard let data = await RecordingThumbnailGenerator.shared.thumbnailData(
            for: candidate.recording,
            overlay: candidate.overlay,
            channelLogoData: candidate.channelLogoFilename.flatMap {
                TopShelfSnapshotStore.cachedArtworkURL(for: $0)
            }.flatMap {
                try? Data(contentsOf: $0)
            },
            configuration: configuration
        ),
              let filename = storeRecordingFrame(
                data,
                for: candidate.recording,
                channelLogoIdentifier: candidate.channelLogoFilename
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
            candidate.replacementArtworkFilename,
            with: filename,
            for: candidate.recording
        )
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
            return item.replacingArtworkFilename(with: thumbnailFilename)
        }
        guard replaced else { return }

        let updated = TopShelfSnapshot(
            version: snapshot.version,
            generatedAt: snapshot.generatedAt,
            guideCoverageEnd: snapshot.guideCoverageEnd,
            onNow: snapshot.onNow,
            recordings: recordings
        )
        do {
            try TopShelfSnapshotStore.save(updated)
            TVTopShelfContentProvider.topShelfContentDidChange()
        } catch {
            logger.error(
                "Could not update the Top Shelf snapshot: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func cacheArtwork(
        urlString: String?,
        identifier: String,
        client: TVHeadendClient
    ) async -> String? {
        guard let urlString, let url = URL(string: urlString),
              let cacheDirectory = TopShelfSnapshotStore.cacheDirectoryURL()
        else { return nil }

        let digest = SHA256.hash(data: Data(identifier.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let pathExtension = url.pathExtension.lowercased()
        let supportedExtension = ["jpg", "jpeg", "png", "heic"].contains(pathExtension)
            ? pathExtension
            : "jpg"
        let filename = "top-shelf-artwork-\(digest).\(supportedExtension)"
        let destination = cacheDirectory.appending(path: filename)
        if FileManager.default.fileExists(atPath: destination.path) { return filename }

        do {
            let data = try await client.fetchChannelIcon(at: url)
            guard !data.isEmpty else { return nil }
            try data.write(to: destination, options: [.atomic])
            return filename
        } catch {
            return nil
        }
    }

    private func cachedRecordingFrameFilename(
        for recording: TVRecording,
        channelLogoIdentifier: String?
    ) -> String? {
        guard let cacheDirectory = TopShelfSnapshotStore.cacheDirectoryURL() else { return nil }
        let filename = recordingFrameFilename(
            for: recording,
            channelLogoIdentifier: channelLogoIdentifier
        )
        return FileManager.default.fileExists(
            atPath: cacheDirectory.appending(path: filename).path
        ) ? filename : nil
    }

    private func storeRecordingFrame(
        _ data: Data,
        for recording: TVRecording,
        channelLogoIdentifier: String?
    ) -> String? {
        guard !data.isEmpty,
              let cacheDirectory = TopShelfSnapshotStore.cacheDirectoryURL()
        else { return nil }
        let filename = recordingFrameFilename(
            for: recording,
            channelLogoIdentifier: channelLogoIdentifier
        )
        do {
            try data.write(to: cacheDirectory.appending(path: filename), options: [.atomic])
            return filename
        } catch {
            return nil
        }
    }

    private func recordingFrameFilename(
        for recording: TVRecording,
        channelLogoIdentifier: String?
    ) -> String {
        let key = recordingFrameCacheKey(
            for: recording,
            channelLogoIdentifier: channelLogoIdentifier
        )
        return "top-shelf-artwork-\(key).jpg"
    }

    private func recordingFrameCacheKey(
        for recording: TVRecording,
        channelLogoIdentifier: String?
    ) -> String {
        digest(
            RecordingTopShelfArtworkPolicy.frameCacheIdentifier(
                recordingID: recording.id,
                state: recording.state,
                channelLogoIdentifier: channelLogoIdentifier
            )
        )
    }

    private func cacheRecordingFallback(
        for recording: TVRecording,
        channel: GuideChannel?,
        channelLogoFilename: String?,
        overlay: RecordingThumbnailOverlay
    ) -> String? {
        guard let cacheDirectory = TopShelfSnapshotStore.cacheDirectoryURL() else { return nil }
        let identifier = [
            "recording-fallback-v3",
            recording.id,
            recording.title,
            overlay.detail ?? "no-detail",
            recording.channelName,
            recording.state.rawValue,
            channelLogoFilename ?? "no-logo",
        ].joined(separator: "-")
        let filename = "top-shelf-artwork-\(digest(identifier)).jpg"
        let destination = cacheDirectory.appending(path: filename)
        if FileManager.default.fileExists(atPath: destination.path) { return filename }

        let channelLogo = channelLogoFilename
            .flatMap { TopShelfSnapshotStore.cachedArtworkURL(for: $0) }
            .flatMap { UIImage(contentsOfFile: $0.path) }
        guard let data = recordingFallbackData(
            for: recording,
            channel: channel,
            channelLogo: channelLogo,
            overlay: overlay
        ) else { return nil }
        do {
            try data.write(to: destination, options: [.atomic])
            return filename
        } catch {
            return nil
        }
    }

    private func recordingFallbackData(
        for recording: TVRecording,
        channel: GuideChannel?,
        channelLogo: UIImage?,
        overlay: RecordingThumbnailOverlay
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
            RecordingTopShelfArtworkRenderer.drawOverlay(
                overlay,
                channelLogo: channelLogo,
                fallbackMonogram: monogram,
                size: size,
                context: context.cgContext
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
        guard let cacheDirectory = TopShelfSnapshotStore.cacheDirectoryURL(),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
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
