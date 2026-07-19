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
        // "Earlier programme" is synthesized for a particular timeline and
        // must be regenerated rather than surviving into a later launch.
        programs = channel.programs.filter { !$0.id.hasPrefix("earlier-") }
    }
}

actor GuideSnapshotStore {
    static let shared = GuideSnapshotStore()

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let cacheDirectory = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = cacheDirectory
                .appendingPathComponent("TVPlayer", isDirectory: true)
                .appendingPathComponent("guide-snapshot-v1.json")
        }
    }

    func load(serverIdentifier: String) -> PersistedGuideSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(PersistedGuideSnapshot.self, from: data),
              snapshot.version == PersistedGuideSnapshot.currentVersion,
              snapshot.serverIdentifier == serverIdentifier
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
