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
            return "Tvheadend has not been configured yet."
        case .invalidEndpoint:
            return "The Tvheadend URL could not be constructed."
        case .invalidResponse:
            return "Tvheadend returned an invalid response."
        case let .httpStatus(status):
            if status == 401 { return "Tvheadend rejected the username or password." }
            if status == 403 {
                return "Tvheadend denied this request. Recording support requires Web Interface and Recorder privileges for this account."
            }
            return "Tvheadend returned HTTP \(status)."
        case .noChannels:
            return "Tvheadend did not return any channels."
        case .channelNotInPlaylist:
            return "Tvheadend did not include this channel in its playback playlist."
        }
    }
}
