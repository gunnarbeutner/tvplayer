#if os(tvOS)
import CryptoKit
import Foundation
import TVServices

actor TopShelfSnapshotPublisher {
    static let shared = TopShelfSnapshotPublisher()

    func publish(
        channels: [GuideChannel],
        favoriteChannelIDs: Set<GuideChannel.ID>,
        recordings: [TVRecording],
        configuration: TVHeadendConfiguration,
        now: Date
    ) async {
        let favoritePrograms = channels
            .filter { favoriteChannelIDs.contains($0.id) }
            .compactMap { channel -> (GuideChannel, GuideProgram)? in
                guard let program = channel.programs.first(where: { $0.isAiring(at: now) }) else {
                    return nil
                }
                return (channel, program)
            }
            .prefix(12)

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
        for recording in playableRecordings {
            let matchingProgram = channels.lazy.flatMap(\.programs).first { program in
                if let eventID = recording.eventID, program.providerEventID == eventID { return true }
                return program.channelID == recording.channelID
                    && program.start < recording.end
                    && recording.start < program.end
                    && program.title == recording.title
            }
            let filename = await cacheArtwork(
                urlString: matchingProgram?.metadata.imageURL,
                identifier: "recording-\(recording.id)",
                configuration: configuration
            )
            if let filename { referencedArtwork.insert(filename) }
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
        } catch {
            // Top Shelf is opportunistic and must never block guide refreshes.
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
           !configuration.username.isEmpty {
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
