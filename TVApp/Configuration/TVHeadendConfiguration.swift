import Foundation

struct TVHeadendConfiguration: Equatable, Sendable {
    let baseURL: URL?
    let username: String
    let password: String
    let streamProfile: String
    let htspPort: Int
    let guideCacheURL: URL?
    let xmltvURL: URL?

    init(
        baseURL: URL?,
        username: String,
        password: String,
        streamProfile: String,
        htspPort: Int = 9982,
        guideCacheURL: URL?,
        xmltvURL: URL?
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.streamProfile = streamProfile
        self.htspPort = htspPort
        self.guideCacheURL = guideCacheURL
        self.xmltvURL = xmltvURL
    }

    var isComplete: Bool {
        baseURL != nil && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    /// Separates on-device guide snapshots by source without persisting the
    /// password as part of the cache key.
    var guideSnapshotIdentifier: String {
        [
            baseURL?.absoluteString ?? "",
            username,
            guideCacheURL?.absoluteString ?? "",
            xmltvURL?.absoluteString ?? "",
        ].joined(separator: "|")
    }
}

enum ConfigurationError: LocalizedError {
    case invalidServerURL
    case invalidHTSPPort
    case invalidGuideCacheURL
    case invalidXMLTVURL
    case keychain(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Enter a valid HTTP or HTTPS TVHeadend URL."
        case .invalidHTSPPort:
            return "The HTSP port must be a number between 1 and 65535."
        case .invalidGuideCacheURL:
            return "The guide cache must be a valid HTTP or HTTPS URL."
        case .invalidXMLTVURL:
            return "The XMLTV override must be a valid HTTP or HTTPS URL."
        case let .keychain(message):
            return "The password could not be saved securely: \(message)"
        }
    }
}
