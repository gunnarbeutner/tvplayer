import Foundation

enum TVHeadendServerOrigin: String, Codable, Sendable {
    case manual
    case discovered
}

struct TVHeadendServerProfile: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var baseURL: URL
    var username: String
    var streamProfile: String
    var htspPort: Int
    var guideCacheURL: URL?
    var xmltvURL: URL?
    var origin: TVHeadendServerOrigin
    var isEdited: Bool
    var discoveryID: String?
    var discoveryServiceIdentity: String?
    var lastSeenAt: Date?

    init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: URL,
        username: String,
        streamProfile: String,
        htspPort: Int,
        guideCacheURL: URL?,
        xmltvURL: URL?,
        origin: TVHeadendServerOrigin,
        isEdited: Bool,
        discoveryID: String? = nil,
        discoveryServiceIdentity: String? = nil,
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.username = username
        self.streamProfile = streamProfile
        self.htspPort = htspPort
        self.guideCacheURL = guideCacheURL
        self.xmltvURL = xmltvURL
        self.origin = origin
        self.isEdited = isEdited
        self.discoveryID = discoveryID
        self.discoveryServiceIdentity = discoveryServiceIdentity
        self.lastSeenAt = lastSeenAt
    }

    func configuration(password: String) -> TVHeadendConfiguration {
        TVHeadendConfiguration(
            serverProfileID: id,
            baseURL: baseURL,
            username: username,
            password: password,
            streamProfile: streamProfile,
            htspPort: htspPort,
            guideCacheURL: guideCacheURL,
            xmltvURL: xmltvURL
        )
    }
}
