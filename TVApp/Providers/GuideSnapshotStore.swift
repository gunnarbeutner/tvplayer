import Foundation

struct PersistedGuideSnapshot: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let serverIdentifier: String
    /// Lets startup restore the channel ordering before discovery has rebuilt
    /// the active server configuration. Older snapshots fall back to deriving
    /// this from `serverIdentifier` below.
    let channelPreferencesIdentifier: String?
    let serverName: String
    let savedAt: Date
    let channels: [PersistedGuideChannel]

    @MainActor
    init(
        serverIdentifier: String,
        channelPreferencesIdentifier: String? = nil,
        serverName: String,
        savedAt: Date = Date(),
        channels: [GuideChannel]
    ) {
        version = Self.currentVersion
        self.serverIdentifier = serverIdentifier
        self.channelPreferencesIdentifier = channelPreferencesIdentifier
        self.serverName = serverName
        self.savedAt = savedAt
        self.channels = channels.map(PersistedGuideChannel.init)
    }

    /// The guide cache can be restored before mDNS has supplied a
    /// configuration. Use the cache's source identity to restore the matching
    /// favourites during that same synchronous startup pass.
    var startupChannelPreferencesIdentifier: String? {
        if let channelPreferencesIdentifier {
            return channelPreferencesIdentifier
        }
        if serverIdentifier.hasPrefix("profile:") {
            return serverIdentifier
        }

        // Version-1 guide identifiers were encoded as
        // baseURL|username|guideCacheURL|xmltvURL. Reconstruct the older
        // preference key so existing caches also get a stable first frame.
        let components = serverIdentifier.split(
            separator: "|",
            maxSplits: 3,
            omittingEmptySubsequences: false
        )
        guard components.count == 4,
              let baseURL = URL(string: String(components[0]))
        else { return nil }
        return TVHeadendConfiguration(
            baseURL: baseURL,
            username: String(components[1]),
            password: "",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        ).legacyChannelPreferencesIdentifier
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

    private struct StoredSnapshots: Codable {
        var version = 2
        var snapshots: [String: PersistedGuideSnapshot]
    }

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
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if let stored = try? JSONDecoder().decode(StoredSnapshots.self, from: data),
           stored.version == 2 {
            let compatible = stored.snapshots.filter {
                $0.value.version == PersistedGuideSnapshot.currentVersion
            }
            if let serverIdentifier { return compatible[serverIdentifier] }
            return compatible.values.max { $0.savedAt < $1.savedAt }
        }
        guard let legacy = try? JSONDecoder().decode(PersistedGuideSnapshot.self, from: data),
              legacy.version == PersistedGuideSnapshot.currentVersion,
              serverIdentifier.map({ legacy.serverIdentifier == $0 }) ?? true
        else { return nil }
        return legacy
    }

    func save(_ snapshot: PersistedGuideSnapshot) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var snapshots: [String: PersistedGuideSnapshot] = [:]
            if let data = try? Data(contentsOf: fileURL) {
                if let stored = try? JSONDecoder().decode(StoredSnapshots.self, from: data),
                   stored.version == 2 {
                    snapshots = stored.snapshots.filter {
                        $0.value.version == PersistedGuideSnapshot.currentVersion
                    }
                } else if let legacy = try? JSONDecoder().decode(PersistedGuideSnapshot.self, from: data),
                          legacy.version == PersistedGuideSnapshot.currentVersion {
                    snapshots[legacy.serverIdentifier] = legacy
                }
            }
            snapshots[snapshot.serverIdentifier] = snapshot
            try encoder.encode(StoredSnapshots(snapshots: snapshots))
                .write(to: fileURL, options: .atomic)
        } catch {
            // This is a performance cache. A write failure must never prevent
            // the freshly loaded guide from being shown.
        }
    }
}
