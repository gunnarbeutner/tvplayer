import Foundation

enum AppRoute: Equatable, Sendable {
    case guide
    case playChannel(String)
    case playRecording(String)

    init?(url: URL) {
        guard url.scheme?.localizedCaseInsensitiveCompare("tvplayer") == .orderedSame else {
            return nil
        }

        let host = url.host?.lowercased()
        let components = url.pathComponents.filter { $0 != "/" }
        if host == "guide" {
            self = .guide
            return
        }
        guard host == "play", components.count == 2,
              let identifier = components[1].removingPercentEncoding,
              !identifier.isEmpty
        else { return nil }

        switch components[0].lowercased() {
        case "channel": self = .playChannel(identifier)
        case "recording": self = .playRecording(identifier)
        default: return nil
        }
    }

    var url: URL {
        switch self {
        case .guide:
            return URL(string: "tvplayer://guide")!
        case let .playChannel(identifier):
            return Self.playURL(kind: "channel", identifier: identifier)
        case let .playRecording(identifier):
            return Self.playURL(kind: "recording", identifier: identifier)
        }
    }

    private static func playURL(kind: String, identifier: String) -> URL {
        var components = URLComponents()
        components.scheme = "tvplayer"
        components.host = "play"
        components.path = "/\(kind)/\(identifier)"
        return components.url!
    }
}
