import Foundation

struct TVHeadendServerInfo: Decodable, Sendable {
    let name: String?
    let version: String?
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
    let seriesLink: String?
    let title: String?
    let subtitle: String?
    let summary: String?
    let description: String?
    let start: Int64
    let stop: Int64

    enum CodingKeys: String, CodingKey {
        case title, subtitle, summary, description, start, stop
        case eventID = "eventId"
        case channelUUID = "channelUuid"
        case seriesLink = "serieslinkUri"
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
}
