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
    var resolvedAddresses: [String]
    var guideResolvedAddresses: [String]
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
        resolvedAddresses: [String] = [],
        guideResolvedAddresses: [String] = [],
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
        self.resolvedAddresses = resolvedAddresses
        self.guideResolvedAddresses = guideResolvedAddresses
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
            xmltvURL: xmltvURL,
            resolvedAddresses: resolvedAddresses,
            guideResolvedAddresses: guideResolvedAddresses
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, username, streamProfile, htspPort
        case guideCacheURL, xmltvURL, resolvedAddresses, guideResolvedAddresses
        case origin, isEdited, discoveryID, discoveryServiceIdentity, lastSeenAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        baseURL = try values.decode(URL.self, forKey: .baseURL)
        username = try values.decode(String.self, forKey: .username)
        streamProfile = try values.decode(String.self, forKey: .streamProfile)
        htspPort = try values.decode(Int.self, forKey: .htspPort)
        guideCacheURL = try values.decodeIfPresent(URL.self, forKey: .guideCacheURL)
        xmltvURL = try values.decodeIfPresent(URL.self, forKey: .xmltvURL)
        resolvedAddresses = try values.decodeIfPresent(
            [String].self,
            forKey: .resolvedAddresses
        ) ?? []
        guideResolvedAddresses = try values.decodeIfPresent(
            [String].self,
            forKey: .guideResolvedAddresses
        ) ?? []
        origin = try values.decode(TVHeadendServerOrigin.self, forKey: .origin)
        isEdited = try values.decode(Bool.self, forKey: .isEdited)
        discoveryID = try values.decodeIfPresent(String.self, forKey: .discoveryID)
        discoveryServiceIdentity = try values.decodeIfPresent(
            String.self,
            forKey: .discoveryServiceIdentity
        )
        lastSeenAt = try values.decodeIfPresent(Date.self, forKey: .lastSeenAt)
    }
}
