import Foundation

struct TopShelfSnapshot: Codable, Sendable {
    struct Item: Codable, Sendable, Identifiable {
        let id: String
        let title: String
        let routeURL: String
        let artworkFilename: String?
        let expirationDate: Date?
        let playbackProgress: Double?
    }

    let version: Int
    let generatedAt: Date
    let onNow: [Item]
    let recordings: [Item]
}

enum TopShelfSnapshotStore {
    static let appGroupIdentifier = "group.de.beutner.TVPlayer"
    static let snapshotFilename = "top-shelf-v1.json"

    static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    static func load(fileManager: FileManager = .default) -> TopShelfSnapshot? {
        guard let url = containerURL(fileManager: fileManager)?
            .appending(path: snapshotFilename),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(TopShelfSnapshot.self, from: data),
              snapshot.version == 1
        else { return nil }
        return snapshot
    }

    static func save(_ snapshot: TopShelfSnapshot, fileManager: FileManager = .default) throws {
        guard let container = containerURL(fileManager: fileManager) else { return }
        try fileManager.createDirectory(at: container, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(
            to: container.appending(path: snapshotFilename),
            options: [.atomic]
        )
    }
}
