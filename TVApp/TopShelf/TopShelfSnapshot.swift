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
    enum StoreError: LocalizedError {
        case appGroupContainerUnavailable

        var errorDescription: String? {
            switch self {
            case .appGroupContainerUnavailable:
                "The Top Shelf App Group container is unavailable."
            }
        }
    }

    static let appGroupIdentifier = "group.de.beutner.TVPlayer"
    static let snapshotFilename = "top-shelf-v1.json"

    static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    static func cacheDirectoryURL(fileManager: FileManager = .default) -> URL? {
        containerURL(fileManager: fileManager).map(cacheDirectoryURL(for:))
    }

    static func cacheDirectoryURL(for containerURL: URL) -> URL {
        containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    }

    static func prepareCacheDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let cacheDirectory = cacheDirectoryURL(fileManager: fileManager) else {
            throw StoreError.appGroupContainerUnavailable
        }
        try fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        return cacheDirectory
    }

    static func load(fileManager: FileManager = .default) -> TopShelfSnapshot? {
        guard let url = cacheDirectoryURL(fileManager: fileManager)?
            .appending(path: snapshotFilename),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(TopShelfSnapshot.self, from: data),
              snapshot.version == 1
        else { return nil }
        return snapshot
    }

    static func save(_ snapshot: TopShelfSnapshot, fileManager: FileManager = .default) throws {
        let cacheDirectory = try prepareCacheDirectory(fileManager: fileManager)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(
            to: cacheDirectory.appending(path: snapshotFilename),
            options: [.atomic]
        )
    }
}
