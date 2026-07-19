import Foundation

struct TVProviderSnapshot {
    let channels: [GuideChannel]
    let serverName: String
}

protocol TVProvider: Sendable {
    func fetchGuide(for timeline: GuideTimeline) async throws -> TVProviderSnapshot
    func liveStreamURL(channelID: String) throws -> URL
}

enum TVProviderError: LocalizedError {
    case incompleteConfiguration
    case invalidEndpoint
    case invalidResponse
    case httpStatus(Int)
    case noChannels
    case channelNotInPlaylist

    var errorDescription: String? {
        switch self {
        case .incompleteConfiguration:
            return "TVHeadend has not been configured yet."
        case .invalidEndpoint:
            return "The TVHeadend URL could not be constructed."
        case .invalidResponse:
            return "TVHeadend returned an invalid response."
        case let .httpStatus(status):
            return status == 401
                ? "TVHeadend rejected the username or password."
                : "TVHeadend returned HTTP \(status)."
        case .noChannels:
            return "TVHeadend did not return any channels."
        case .channelNotInPlaylist:
            return "TVHeadend did not include this channel in its playback playlist."
        }
    }
}
