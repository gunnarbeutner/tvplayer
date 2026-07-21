import Foundation

struct TVHeadendConfiguration: Equatable, Sendable {
    let serverProfileID: String?
    let baseURL: URL?
    let username: String
    let password: String
    let streamProfile: String
    let htspPort: Int
    let guideCacheURL: URL?
    let xmltvURL: URL?

    init(
        serverProfileID: String? = nil,
        baseURL: URL?,
        username: String,
        password: String,
        streamProfile: String,
        htspPort: Int = 9982,
        guideCacheURL: URL?,
        xmltvURL: URL?
    ) {
        self.serverProfileID = serverProfileID
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.streamProfile = streamProfile
        self.htspPort = htspPort
        self.guideCacheURL = guideCacheURL
        self.xmltvURL = xmltvURL
    }

    var isComplete: Bool {
        baseURL != nil && hasValidAuthentication
    }

    var usesAuthentication: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasValidAuthentication: Bool {
        usesAuthentication == !password.isEmpty
    }

    /// Separates on-device guide snapshots by source without persisting the
    /// password as part of the cache key.
    var guideSnapshotIdentifier: String {
        if let serverProfileID { return "profile:\(serverProfileID)" }
        return legacyGuideSnapshotIdentifier
    }

    var legacyGuideSnapshotIdentifier: String {
        [
            baseURL?.absoluteString ?? "",
            username,
            guideCacheURL?.absoluteString ?? "",
            xmltvURL?.absoluteString ?? "",
        ].joined(separator: "|")
    }

    /// Keeps device-local channel preferences isolated by TVHeadend server and
    /// account without including the password or guide-source overrides.
    var channelPreferencesIdentifier: String? {
        if let serverProfileID { return "profile:\(serverProfileID)" }
        return legacyChannelPreferencesIdentifier
    }

    var legacyChannelPreferencesIdentifier: String? {
        guard let baseURL else { return nil }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        let normalizedScheme = components?.scheme?.lowercased()
        let normalizedHost = components?.host?.lowercased()
        components?.scheme = normalizedScheme
        components?.host = normalizedHost
        if components?.path == "/" {
            components?.path = ""
        } else {
            while components?.path.hasSuffix("/") == true {
                components?.path.removeLast()
            }
        }
        let normalizedURL = components?.url?.absoluteString
            ?? baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(normalizedURL)|\(username.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    var dataStoreIdentifier: String {
        serverProfileID.map { "profile:\($0)" }
            ?? "\(baseURL?.absoluteString ?? "tvheadend")|\(username)"
    }
}

enum ConfigurationError: LocalizedError {
    case invalidServerURL
    case invalidHTSPPort
    case invalidGuideCacheURL
    case invalidXMLTVURL
    case incompleteCredentials
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
        case .incompleteCredentials:
            return "Enter both a username and password, or clear both fields for anonymous access."
        case let .keychain(message):
            return "The password could not be saved securely: \(message)"
        }
    }
}
