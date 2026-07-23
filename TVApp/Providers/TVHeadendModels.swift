import Foundation

struct TVHeadendServerInfo: Decodable, Sendable {
    let name: String?
    let version: String?
    let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case name, capabilities
        case version = "sw_version"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }
}

struct TVHeadendStreamProfile: Decodable, Sendable, Identifiable, Equatable {
    let key: String
    let val: String

    var id: String { key }
    var name: String { val }
}

struct TVHeadendGrid<Element: Decodable & Sendable>: Decodable, Sendable {
    let entries: [Element]
    let total: Int?
}

struct TVPlayerGuideCacheDocument: Decodable, Sendable {
    let version: Int
    let lastRefresh: Double?
    let events: [TVHeadendEPGEvent]
}

struct TVHeadendChannel: Decodable, Sendable {
    let uuid: String
    let number: Double?
    let name: String
    let iconPublicURL: String?
    let icon: String?
    let epggrab: [String]?

    enum CodingKeys: String, CodingKey {
        case uuid, number, name, icon, epggrab
        case iconPublicURL = "icon_public_url"
    }
}

struct TVHeadendEPGEvent: Codable, Sendable {
    let eventID: Int64?
    let channelUUID: String?
    let episodeURI: String?
    let seriesLink: String?
    let title: String?
    let subtitle: String?
    let summary: String?
    let description: String?
    let extraText: String?
    let start: Int64
    let stop: Int64
    let seasonNumber: String?
    let seasonCount: String?
    let episodeNumber: String?
    let episodeCount: String?
    let episodeOnscreen: String?
    let partNumber: String?
    let partCount: String?
    let firstAired: Int64?
    let genres: [Int]
    let categories: [String]
    let ageRating: String?
    let ratingLabel: String?
    let ratingLabelIcon: String?
    let ratingCountry: String?
    let ratingAuthority: String?
    let starRating: String?
    let imageURL: String?
    let isHD: Bool
    let isWidescreen: Bool
    let isSubtitled: Bool
    let isNew: Bool
    let dvrUUID: String?
    let dvrState: String?

    enum CodingKeys: String, CodingKey {
        case title, subtitle, summary, description, extraText, start, stop
        case seasonNumber, seasonCount, episodeNumber, episodeCount, episodeOnscreen
        case partNumber, partCount, firstAired, categories, category
        case genre, ageRating, ratingLabel, ratingLabelIcon, ratingCountry, ratingAuthority
        case starRating, image
        case hd, widescreen, subtitled, new
        case dvrUUID = "dvrUuid"
        case dvrState
        case cat1, cat2, cat3
        case eventID = "eventId"
        case channelUUID = "channelUuid"
        case episodeURI = "episodeUri"
        case seriesLink = "serieslinkUri"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        eventID = values.flexibleInt64(forKey: .eventID)
        channelUUID = values.flexibleString(forKey: .channelUUID)
        episodeURI = values.flexibleString(forKey: .episodeURI)
        seriesLink = values.flexibleString(forKey: .seriesLink)
        title = values.flexibleString(forKey: .title)
        subtitle = values.flexibleString(forKey: .subtitle)
        summary = values.flexibleString(forKey: .summary)
        description = values.flexibleString(forKey: .description)
        extraText = values.flexibleString(forKey: .extraText)
        start = values.flexibleInt64(forKey: .start) ?? 0
        stop = values.flexibleInt64(forKey: .stop) ?? start
        seasonNumber = values.flexibleString(forKey: .seasonNumber)
        seasonCount = values.flexibleString(forKey: .seasonCount)
        episodeNumber = values.flexibleString(forKey: .episodeNumber)
        episodeCount = values.flexibleString(forKey: .episodeCount)
        episodeOnscreen = values.flexibleString(forKey: .episodeOnscreen)
        partNumber = values.flexibleString(forKey: .partNumber)
        partCount = values.flexibleString(forKey: .partCount)
        firstAired = values.flexibleInt64(forKey: .firstAired)
        var decodedGenres = (try? values.decodeIfPresent([Int].self, forKey: .genre)) ?? []
        if decodedGenres.isEmpty, let genre = values.flexibleInt64(forKey: .genre) {
            decodedGenres = [Int(genre)]
        }
        genres = decodedGenres

        var decodedCategories = (try? values.decodeIfPresent([String].self, forKey: .categories)) ?? []
        decodedCategories += (try? values.decodeIfPresent([String].self, forKey: .category)) ?? []
        if let category = values.flexibleString(forKey: .category) {
            decodedCategories.append(category)
        }
        decodedCategories += [CodingKeys.cat1, .cat2, .cat3].compactMap {
            values.flexibleString(forKey: $0)
        }
        categories = Array(Set(decodedCategories)).sorted()

        ageRating = values.flexibleString(forKey: .ageRating)
        ratingLabel = values.flexibleString(forKey: .ratingLabel)
        ratingLabelIcon = values.flexibleString(forKey: .ratingLabelIcon)
        ratingCountry = values.flexibleString(forKey: .ratingCountry)
        ratingAuthority = values.flexibleString(forKey: .ratingAuthority)
        starRating = values.flexibleString(forKey: .starRating)
        imageURL = values.flexibleString(forKey: .image)
        isHD = values.flexibleBool(forKey: .hd)
        isWidescreen = values.flexibleBool(forKey: .widescreen)
        isSubtitled = values.flexibleBool(forKey: .subtitled)
        isNew = values.flexibleBool(forKey: .new)
        dvrUUID = values.flexibleString(forKey: .dvrUUID)
        dvrState = values.flexibleString(forKey: .dvrState)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(eventID, forKey: .eventID)
        try values.encodeIfPresent(channelUUID, forKey: .channelUUID)
        try values.encodeIfPresent(episodeURI, forKey: .episodeURI)
        try values.encodeIfPresent(seriesLink, forKey: .seriesLink)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(subtitle, forKey: .subtitle)
        try values.encodeIfPresent(summary, forKey: .summary)
        try values.encodeIfPresent(description, forKey: .description)
        try values.encodeIfPresent(extraText, forKey: .extraText)
        try values.encode(start, forKey: .start)
        try values.encode(stop, forKey: .stop)
        try values.encodeIfPresent(seasonNumber, forKey: .seasonNumber)
        try values.encodeIfPresent(seasonCount, forKey: .seasonCount)
        try values.encodeIfPresent(episodeNumber, forKey: .episodeNumber)
        try values.encodeIfPresent(episodeCount, forKey: .episodeCount)
        try values.encodeIfPresent(episodeOnscreen, forKey: .episodeOnscreen)
        try values.encodeIfPresent(partNumber, forKey: .partNumber)
        try values.encodeIfPresent(partCount, forKey: .partCount)
        try values.encodeIfPresent(firstAired, forKey: .firstAired)
        if !genres.isEmpty { try values.encode(genres, forKey: .genre) }
        if !categories.isEmpty { try values.encode(categories, forKey: .categories) }
        try values.encodeIfPresent(ageRating, forKey: .ageRating)
        try values.encodeIfPresent(ratingLabel, forKey: .ratingLabel)
        try values.encodeIfPresent(ratingLabelIcon, forKey: .ratingLabelIcon)
        try values.encodeIfPresent(ratingCountry, forKey: .ratingCountry)
        try values.encodeIfPresent(ratingAuthority, forKey: .ratingAuthority)
        try values.encodeIfPresent(starRating, forKey: .starRating)
        try values.encodeIfPresent(imageURL, forKey: .image)
        if isHD { try values.encode(true, forKey: .hd) }
        if isWidescreen { try values.encode(true, forKey: .widescreen) }
        if isSubtitled { try values.encode(true, forKey: .subtitled) }
        if isNew { try values.encode(true, forKey: .new) }
        try values.encodeIfPresent(dvrUUID, forKey: .dvrUUID)
        try values.encodeIfPresent(dvrState, forKey: .dvrState)
    }
}

enum TVRecordingState: String, Codable, Sendable, CaseIterable {
    case upcoming
    case recording
    case completed
    case failed
    case removed

    var label: String {
        switch self {
        case .upcoming: "Upcoming"
        case .recording: "Recording"
        case .completed: "Recorded"
        case .failed: "Failed"
        case .removed: "Removed"
        }
    }
}

struct TVRecording: Identifiable, Hashable, Sendable {
    let id: String
    let eventID: Int64?
    let title: String
    let subtitle: String?
    let overview: String
    let channelID: String?
    let channelName: String
    let start: Date
    let end: Date
    let state: TVRecordingState
    let statusText: String?
    let warningText: String?
    let fileSize: Int64
    let errorCount: Int
    let dataErrorCount: Int
    let autorecID: String?
    let streamPath: String?

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var isPlayable: Bool { state == .recording || state == .completed }
}

struct TVRecordingRule: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let titlePattern: String
    let channelID: String?
    let channelName: String?
    let seriesLink: String?
    let enabled: Bool
}

struct TVRecordingSnapshot: Sendable {
    let entries: [TVRecording]
    let rules: [TVRecordingRule]
}

struct TVHeadendDVREntry: Decodable, Sendable {
    let uuid: String
    let eventID: Int64?
    let displayTitle: String?
    let displaySubtitle: String?
    let displayDescription: String?
    let channelUUID: String?
    let channelName: String?
    let start: Int64
    let stop: Int64
    let scheduleStatus: String?
    let status: String?
    let fileSize: Int64
    let errors: Int
    let dataErrors: Int
    let autorecUUID: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case uuid, status, filesize, errors, data_errors, url, channel
        case eventIDSnake = "event_id"
        case eventIDCamel = "eventId"
        case broadcast
        case displayTitle = "disp_title"
        case displaySubtitle = "disp_subtitle"
        case displayDescription = "disp_description"
        case channelName = "channelname"
        case start, startReal = "start_real"
        case stop, stopReal = "stop_real"
        case scheduleStatus = "sched_status"
        case autorecUUID = "autorec"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try values.decode(String.self, forKey: .uuid)
        eventID = values.flexibleInt64(forKey: .broadcast)
            ?? values.flexibleInt64(forKey: .eventIDSnake)
            ?? values.flexibleInt64(forKey: .eventIDCamel)
        displayTitle = try values.decodeIfPresent(String.self, forKey: .displayTitle)
        displaySubtitle = try values.decodeIfPresent(String.self, forKey: .displaySubtitle)
        displayDescription = try values.decodeIfPresent(String.self, forKey: .displayDescription)
        channelUUID = try values.decodeIfPresent(String.self, forKey: .channel)
        channelName = try values.decodeIfPresent(String.self, forKey: .channelName)
        start = values.flexibleInt64(forKey: .start) ?? values.flexibleInt64(forKey: .startReal) ?? 0
        stop = values.flexibleInt64(forKey: .stop) ?? values.flexibleInt64(forKey: .stopReal) ?? start
        scheduleStatus = try values.decodeIfPresent(String.self, forKey: .scheduleStatus)
        status = try values.decodeIfPresent(String.self, forKey: .status)
        fileSize = values.flexibleInt64(forKey: .filesize) ?? 0
        errors = Int(values.flexibleInt64(forKey: .errors) ?? 0)
        dataErrors = Int(values.flexibleInt64(forKey: .data_errors) ?? 0)
        autorecUUID = try values.decodeIfPresent(String.self, forKey: .autorecUUID)
        url = try values.decodeIfPresent(String.self, forKey: .url)
    }
}

struct TVHeadendAutorecEntry: Decodable, Sendable {
    let uuid: String
    let name: String?
    let title: String?
    let channelUUID: String?
    let channelName: String?
    let seriesLink: String?
    let enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case uuid, name, title, enabled, channel, channelname
        case seriesLink = "serieslink"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try values.decode(String.self, forKey: .uuid)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        channelUUID = try values.decodeIfPresent(String.self, forKey: .channel)
        channelName = try values.decodeIfPresent(String.self, forKey: .channelname)
        seriesLink = try values.decodeIfPresent(String.self, forKey: .seriesLink)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled)
    }
}

private extension KeyedDecodingContainer {
    func flexibleInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int64(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int64(value) }
        return nil
    }

    func flexibleString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func flexibleBool(forKey key: Key) -> Bool {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = flexibleInt64(forKey: key) { return value != 0 }
        if let value = flexibleString(forKey: key)?.lowercased() {
            return value == "true" || value == "yes" || value == "on"
        }
        return false
    }
}
