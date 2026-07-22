import Foundation

struct TopShelfSnapshot: Codable, Sendable {
    struct Item: Codable, Sendable, Identifiable {
        private static let topShelfRetirementLeadTime: TimeInterval = 2 * 60

        let id: String
        let title: String
        let routeURL: String
        let artworkFilename: String?
        let availabilityDate: Date?
        let expirationDate: Date?
        let playbackProgress: Double?
        let contentIdentifier: String?

        init(
            id: String,
            title: String,
            routeURL: String,
            artworkFilename: String?,
            availabilityDate: Date? = nil,
            expirationDate: Date?,
            playbackProgress: Double?,
            contentIdentifier: String? = nil
        ) {
            self.id = id
            self.title = title
            self.routeURL = routeURL
            self.artworkFilename = artworkFilename
            self.availabilityDate = availabilityDate
            self.expirationDate = expirationDate
            self.playbackProgress = playbackProgress
            self.contentIdentifier = contentIdentifier
        }

        func isAvailable(at date: Date) -> Bool {
            availabilityDate.map { $0 <= date } != false
                && expirationDate.map { date < $0 } != false
        }

        var topShelfExpirationDate: Date? {
            guard let expirationDate else { return nil }
            let maximumLead = availabilityDate.map {
                max(0, expirationDate.timeIntervalSince($0) * 0.1)
            } ?? Self.topShelfRetirementLeadTime
            return expirationDate.addingTimeInterval(
                -min(Self.topShelfRetirementLeadTime, maximumLead)
            )
        }

        func isPresentableOnTopShelf(at date: Date) -> Bool {
            availabilityDate.map { $0 <= date } != false
                && topShelfExpirationDate.map { date < $0 } != false
        }
    }

    let version: Int
    let generatedAt: Date
    let onNow: [Item]
    let recordings: [Item]

    func availableOnNowItems(at date: Date, limit: Int = 12) -> [Item] {
        guard limit > 0 else { return [] }
        var identifiers = Set<String>()
        var contentIdentifiers = Set<String>()
        var result: [Item] = []

        for item in onNow where item.isPresentableOnTopShelf(at: date) {
            guard !identifiers.contains(item.id) else { continue }
            if let contentIdentifier = item.contentIdentifier,
               contentIdentifiers.contains(contentIdentifier) {
                continue
            }
            identifiers.insert(item.id)
            if let contentIdentifier = item.contentIdentifier {
                contentIdentifiers.insert(contentIdentifier)
            }
            result.append(item)
            if result.count == limit { break }
        }
        return result
    }
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

    static func cachedArtworkURL(
        for filename: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard filename.hasPrefix("top-shelf-artwork-"),
              filename == URL(fileURLWithPath: filename).lastPathComponent
        else { return nil }
        return cacheDirectoryURL(fileManager: fileManager)?.appending(path: filename)
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
