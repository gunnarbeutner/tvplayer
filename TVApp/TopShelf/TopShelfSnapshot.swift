import Foundation

struct TopShelfSnapshot: Codable, Sendable {
    enum MediaOption: String, Codable, Sendable {
        case hd
        case closedCaptioning
    }

    struct NamedAttribute: Codable, Sendable, Equatable {
        let name: String
        let values: [String]
    }

    struct Item: Codable, Sendable, Identifiable {
        private static let topShelfRetirementLeadTime: TimeInterval = 2 * 60

        let id: String
        let title: String
        let contextTitle: String?
        let summary: String?
        let genre: String?
        let duration: TimeInterval?
        let creationDate: Date?
        let mediaOptions: [MediaOption]?
        let namedAttributes: [NamedAttribute]?
        let routeURL: String
        let displayRouteURL: String?
        let artworkFilename: String?
        let availabilityDate: Date?
        let expirationDate: Date?
        let playbackProgress: Double?
        let contentIdentifier: String?

        init(
            id: String,
            title: String,
            contextTitle: String? = nil,
            summary: String? = nil,
            genre: String? = nil,
            duration: TimeInterval? = nil,
            creationDate: Date? = nil,
            mediaOptions: [MediaOption]? = nil,
            namedAttributes: [NamedAttribute]? = nil,
            routeURL: String,
            displayRouteURL: String? = nil,
            artworkFilename: String?,
            availabilityDate: Date? = nil,
            expirationDate: Date?,
            playbackProgress: Double?,
            contentIdentifier: String? = nil
        ) {
            self.id = id
            self.title = title
            self.contextTitle = contextTitle
            self.summary = summary
            self.genre = genre
            self.duration = duration
            self.creationDate = creationDate
            self.mediaOptions = mediaOptions
            self.namedAttributes = namedAttributes
            self.routeURL = routeURL
            self.displayRouteURL = displayRouteURL
            self.artworkFilename = artworkFilename
            self.availabilityDate = availabilityDate
            self.expirationDate = expirationDate
            self.playbackProgress = playbackProgress
            self.contentIdentifier = contentIdentifier
        }

        func replacingArtworkFilename(with artworkFilename: String?) -> Self {
            Self(
                id: id,
                title: title,
                contextTitle: contextTitle,
                summary: summary,
                genre: genre,
                duration: duration,
                creationDate: creationDate,
                mediaOptions: mediaOptions,
                namedAttributes: namedAttributes,
                routeURL: routeURL,
                displayRouteURL: displayRouteURL,
                artworkFilename: artworkFilename,
                availabilityDate: availabilityDate,
                expirationDate: expirationDate,
                playbackProgress: playbackProgress,
                contentIdentifier: contentIdentifier
            )
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
    /// End of the interval covered by the guide fetch that produced this
    /// snapshot. This is deliberately independent of programme end times:
    /// channels can legitimately have gaps near the edge of the window.
    let guideCoverageEnd: Date?
    let onNow: [Item]
    let recordings: [Item]

    init(
        version: Int,
        generatedAt: Date,
        guideCoverageEnd: Date? = nil,
        onNow: [Item],
        recordings: [Item]
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.guideCoverageEnd = guideCoverageEnd
        self.onNow = onNow
        self.recordings = recordings
    }

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

enum GuideBackgroundRefreshPolicy {
    static let coverageLeadTime: TimeInterval = 30 * 60
    static let minimumDelay: TimeInterval = 15 * 60
    static let retryDelay: TimeInterval = 60 * 60

    static func nextRefreshDate(
        after now: Date,
        guideCoverageEnd: Date?
    ) -> Date {
        guard let guideCoverageEnd else {
            return now.addingTimeInterval(retryDelay)
        }
        return max(
            now.addingTimeInterval(minimumDelay),
            guideCoverageEnd.addingTimeInterval(-coverageLeadTime)
        )
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
    static let snapshotFilename = "top-shelf-v2.json"

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
              snapshot.version == 2
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
