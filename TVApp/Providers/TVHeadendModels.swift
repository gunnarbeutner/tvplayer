import Foundation

struct TVHeadendServerInfo: Decodable, Sendable {
    let name: String?
    let version: String?
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
    }
}
