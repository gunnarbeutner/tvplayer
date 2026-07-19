import Foundation

struct PersistedGuideSnapshot: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let serverIdentifier: String
    let serverName: String
    let savedAt: Date
    let channels: [PersistedGuideChannel]

    @MainActor
    init(
        serverIdentifier: String,
        serverName: String,
        savedAt: Date = Date(),
        channels: [GuideChannel]
    ) {
        version = Self.currentVersion
        self.serverIdentifier = serverIdentifier
        self.serverName = serverName
        self.savedAt = savedAt
        self.channels = channels.map(PersistedGuideChannel.init)
    }

    @MainActor
    func restoredChannels(for timeline: GuideTimeline) -> [GuideChannel] {
        channels.map { channel in
            GuideChannel(
                id: channel.id,
                number: channel.number,
                name: channel.name,
                monogram: channel.monogram,
                tint: GuideChannelAppearance.tint(for: channel.id),
                iconURL: channel.iconURL,
                programs: channel.programs.filter {
                    $0.end > timeline.start && $0.start < timeline.end
                }
            )
        }
    }
}

struct PersistedGuideChannel: Codable, Sendable {
    let id: String
    let number: Int
    let name: String
    let monogram: String
    let iconURL: URL?
    let programs: [GuideProgram]

    @MainActor
    init(channel: GuideChannel) {
        id = channel.id
        number = channel.number
        name = channel.name
        monogram = channel.monogram
        iconURL = channel.iconURL
        // Timeline-sized placeholders are regenerated for each guide window
        // rather than surviving into a later launch.
        programs = channel.programs.filter {
            !$0.id.hasPrefix("earlier-") && !$0.id.hasPrefix("unavailable-")
        }
    }
}

actor GuideSnapshotStore {
    static let shared = GuideSnapshotStore()

    private let fileURL: URL

    private static var defaultFileURL: URL {
        let cacheDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return cacheDirectory
            .appendingPathComponent("TVPlayer", isDirectory: true)
            .appendingPathComponent("guide-snapshot-v1.json")
    }

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = Self.defaultFileURL
        }
    }

    /// Used once during app construction so the first SwiftUI frame can be a
    /// real guide instead of a transient connection screen. Subsequent reads
    /// and all writes stay on the actor.
    nonisolated static func loadSynchronously(serverIdentifier: String) -> PersistedGuideSnapshot? {
        decodeSnapshot(at: defaultFileURL, serverIdentifier: serverIdentifier)
    }

    nonisolated static func loadLatestSynchronously() -> PersistedGuideSnapshot? {
        decodeSnapshot(at: defaultFileURL, serverIdentifier: nil)
    }

    func load(serverIdentifier: String) -> PersistedGuideSnapshot? {
        Self.decodeSnapshot(at: fileURL, serverIdentifier: serverIdentifier)
    }

    private nonisolated static func decodeSnapshot(
        at fileURL: URL,
        serverIdentifier: String?
    ) -> PersistedGuideSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(PersistedGuideSnapshot.self, from: data),
              snapshot.version == PersistedGuideSnapshot.currentVersion,
              serverIdentifier.map({ snapshot.serverIdentifier == $0 }) ?? true
        else { return nil }
        return snapshot
    }

    func save(_ snapshot: PersistedGuideSnapshot) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            // This is a performance cache. A write failure must never prevent
            // the freshly loaded guide from being shown.
        }
    }
}
