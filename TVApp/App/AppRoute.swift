import Foundation

struct TopShelfLaunchContext: Equatable, Sendable {
    let programID: String
    let artworkFilename: String?
}

enum AppRoute: Equatable, Sendable {
    case guide
    case playChannel(String, topShelf: TopShelfLaunchContext? = nil)
    case playRecording(String)

    var opensPlayback: Bool {
        switch self {
        case .guide: false
        case .playChannel, .playRecording: true
        }
    }

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
        case "channel":
            let queryItems = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? []
            let programID = queryItems.first { $0.name == "program" }?.value
            let artworkFilename = queryItems.first { $0.name == "artwork" }?.value
            let context = programID.flatMap { programID in
                programID.isEmpty ? nil : TopShelfLaunchContext(
                    programID: programID,
                    artworkFilename: artworkFilename
                )
            }
            self = .playChannel(identifier, topShelf: context)
        case "recording": self = .playRecording(identifier)
        default: return nil
        }
    }

    var url: URL {
        switch self {
        case .guide:
            return URL(string: "tvplayer://guide")!
        case let .playChannel(identifier, context):
            var queryItems: [URLQueryItem] = []
            if let context {
                queryItems.append(URLQueryItem(name: "program", value: context.programID))
                if let artworkFilename = context.artworkFilename {
                    queryItems.append(URLQueryItem(name: "artwork", value: artworkFilename))
                }
            }
            return Self.playURL(
                kind: "channel",
                identifier: identifier,
                queryItems: queryItems
            )
        case let .playRecording(identifier):
            return Self.playURL(kind: "recording", identifier: identifier)
        }
    }

    private static func playURL(
        kind: String,
        identifier: String,
        queryItems: [URLQueryItem] = []
    ) -> URL {
        var components = URLComponents()
        components.scheme = "tvplayer"
        components.host = "play"
        components.path = "/\(kind)/\(identifier)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url!
    }
}
