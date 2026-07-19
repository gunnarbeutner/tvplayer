import Foundation

struct PlaybackPresentation: Identifiable {
    let id = UUID()
    let channel: GuideChannel
    let program: GuideProgram?
    let request: LiveStreamRequest
}

@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published var presentation: PlaybackPresentation?
    @Published var errorMessage: String?

    func start(
        channel: GuideChannel,
        program: GuideProgram?,
        configuration: TVHeadendConfiguration
    ) {
        Task {
            do {
                guard configuration.isComplete else { throw TVProviderError.incompleteConfiguration }
                let url = try await TVHeadendClient(configuration: configuration)
                    .canonicalLiveStreamURL(channelID: channel.id)
                presentation = PlaybackPresentation(
                    channel: channel,
                    program: program,
                    request: LiveStreamRequest(
                        url: url,
                        networkCachingMilliseconds: 1_500
                    )
                )
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
