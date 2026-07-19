import Foundation

struct TVHeadendConfiguration: Equatable, Sendable {
    let baseURL: URL?
    let username: String
    let password: String
    let streamProfile: String
    let guideCacheURL: URL?
    let xmltvURL: URL?

    var isComplete: Bool {
        baseURL != nil && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }
}

enum ConfigurationError: LocalizedError {
    case invalidServerURL
    case invalidGuideCacheURL
    case invalidXMLTVURL
    case keychain(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Enter a valid HTTP or HTTPS TVHeadend URL."
        case .invalidGuideCacheURL:
            return "The guide cache must be a valid HTTP or HTTPS URL."
        case .invalidXMLTVURL:
            return "The XMLTV override must be a valid HTTP or HTTPS URL."
        case let .keychain(message):
            return "The password could not be saved securely: \(message)"
        }
    }
}
