import Foundation

struct TopShelfLaunchContext: Equatable, Sendable {
    let programID: String
    let artworkFilename: String?
}

enum AppRoute: Equatable, Sendable {
    case guide
    case showChannelDetails(String, programID: String?)
    case showRecordingDetails(String)
    case playChannel(String, topShelf: TopShelfLaunchContext? = nil)
    case playRecording(String)

    var opensPlayback: Bool {
        switch self {
        case .guide, .showChannelDetails, .showRecordingDetails: false
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
        guard let host, ["play", "show"].contains(host), components.count == 2,
              let identifier = components[1].removingPercentEncoding,
              !identifier.isEmpty
        else { return nil }

        let queryItems = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        switch components[0].lowercased() {
        case "channel":
            let programID = queryItems.first { $0.name == "program" }?.value
            if host == "show" {
                self = .showChannelDetails(identifier, programID: programID)
                return
            }
            let artworkFilename = queryItems.first { $0.name == "artwork" }?.value
            let context = programID.flatMap { programID in
                programID.isEmpty ? nil : TopShelfLaunchContext(
                    programID: programID,
                    artworkFilename: artworkFilename
                )
            }
            self = .playChannel(identifier, topShelf: context)
        case "recording":
            self = host == "show"
                ? .showRecordingDetails(identifier)
                : .playRecording(identifier)
        default: return nil
        }
    }

    var url: URL {
        switch self {
        case .guide:
            return URL(string: "tvplayer://guide")!
        case let .showChannelDetails(identifier, programID):
            return Self.contentURL(
                action: "show",
                kind: "channel",
                identifier: identifier,
                queryItems: programID.map {
                    [URLQueryItem(name: "program", value: $0)]
                } ?? []
            )
        case let .showRecordingDetails(identifier):
            return Self.contentURL(
                action: "show",
                kind: "recording",
                identifier: identifier
            )
        case let .playChannel(identifier, context):
            var queryItems: [URLQueryItem] = []
            if let context {
                queryItems.append(URLQueryItem(name: "program", value: context.programID))
                if let artworkFilename = context.artworkFilename {
                    queryItems.append(URLQueryItem(name: "artwork", value: artworkFilename))
                }
            }
            return Self.contentURL(
                action: "play",
                kind: "channel",
                identifier: identifier,
                queryItems: queryItems
            )
        case let .playRecording(identifier):
            return Self.contentURL(
                action: "play",
                kind: "recording",
                identifier: identifier
            )
        }
    }

    private static func contentURL(
        action: String,
        kind: String,
        identifier: String,
        queryItems: [URLQueryItem] = []
    ) -> URL {
        var components = URLComponents()
        components.scheme = "tvplayer"
        components.host = action
        components.path = "/\(kind)/\(identifier)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url!
    }
}
