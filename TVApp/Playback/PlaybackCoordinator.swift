import Foundation
import OSLog

struct PlaybackPresentation: Identifiable {
    let id = UUID()
    let channel: GuideChannel
    let program: GuideProgram?
    let recording: TVRecording?
    let request: LiveStreamRequest

    var isRecording: Bool { recording != nil }
}

struct PlaybackNavigationSelection: Equatable, Sendable {
    let channelID: GuideChannel.ID
    let programID: GuideProgram.ID?
}

@MainActor
final class PlaybackCoordinator: ObservableObject {
    private let logger = Logger(subsystem: "de.beutner.TVPlayer", category: "PlaybackCoordinator")
    @Published var presentation: PlaybackPresentation?
    @Published var isPlayerPresented = false
    @Published var errorMessage: String?
    @Published private(set) var navigationSelection: PlaybackNavigationSelection?
    @Published private(set) var focusReturnRevision = 0
    @Published private(set) var isUserInitiatedPlayback = false
    let engine: VLCPlaybackEngine
#if os(tvOS)
    let pictureInPicture: PictureInPictureCoordinator
#endif
    private var prewarmTask: Task<Void, Never>?
    private var prewarmedChannelID: String?
    private var channelSwitchTask: Task<Void, Never>?

    init() {
        let engine = VLCPlaybackEngine()
        self.engine = engine
#if os(tvOS)
        pictureInPicture = PictureInPictureCoordinator(engine: engine)
        pictureInPicture.connect(to: self)
#endif
    }

    var isUserInitiatedLivePlayback: Bool {
        isUserInitiatedPlayback && presentation?.isRecording == false
    }

    func start(
        channel: GuideChannel,
        program: GuideProgram?,
        configuration: TVHeadendConfiguration
    ) {
        let sessionCanResume: Bool
        switch engine.state {
        case .idle, .failed:
            sessionCanResume = false
        case .preparing, .playing, .paused, .recovering:
            sessionCanResume = true
        }

        if let existingPresentation = presentation,
           existingPresentation.recording == nil,
           existingPresentation.channel.id == channel.id,
           sessionCanResume {
            if prewarmedChannelID == channel.id {
                engine.finishPrewarmingAtLiveEdge()
            }
            prewarmTask?.cancel()
            prewarmTask = nil
            prewarmedChannelID = nil
            presentation = PlaybackPresentation(
                channel: channel,
                program: program,
                recording: nil,
                request: existingPresentation.request
            )
            navigationSelection = PlaybackNavigationSelection(
                channelID: channel.id,
                programID: program?.id
            )
            isUserInitiatedPlayback = true
            isPlayerPresented = true
            errorMessage = nil
            return
        }

        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmedChannelID = nil
        Task {
            do {
                guard configuration.isComplete else { throw TVProviderError.incompleteConfiguration }
                let request = try await TVHeadendClient(configuration: configuration)
                    .livePlaybackRequest(channelID: channel.id)
                engine.stop()
                presentation = PlaybackPresentation(
                    channel: channel,
                    program: program,
                    recording: nil,
                    request: request
                )
                navigationSelection = PlaybackNavigationSelection(
                    channelID: channel.id,
                    programID: program?.id
                )
                isUserInitiatedPlayback = true
                isPlayerPresented = true
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

#if os(tvOS)
    @discardableResult
    func switchLiveChannel(
        direction: TVPageDirection,
        channels: [GuideChannel],
        at date: Date,
        configuration: TVHeadendConfiguration
    ) -> Bool {
        guard isPlayerPresented,
              let current = presentation,
              current.recording == nil,
              channels.count > 1,
              let currentIndex = channels.firstIndex(where: { $0.id == current.channel.id })
        else { return false }

        let offset = direction == .up ? 1 : -1
        let targetIndex = (currentIndex + offset + channels.count) % channels.count
        let target = channels[targetIndex]
        let program = target.programs.first { $0.isAiring(at: date) }

        channelSwitchTask?.cancel()
        channelSwitchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let request = try await TVHeadendClient(configuration: configuration)
                    .livePlaybackRequest(channelID: target.id)
                try Task.checkCancellation()

                engine.stop()
                presentation = PlaybackPresentation(
                    channel: target,
                    program: program,
                    recording: nil,
                    request: request
                )
                navigationSelection = PlaybackNavigationSelection(
                    channelID: target.id,
                    programID: program?.id
                )
                isUserInitiatedPlayback = true
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        return true
    }
#endif

    func leavePlayer() {
        // Live television keeps running when it collapses into the guide's
        // artwork area. Recorded media retains the previous pause-on-exit
        // behavior because it has no corresponding live channel preview.
        if presentation?.isRecording == true {
            engine.pause()
        }
        isPlayerPresented = false
    }

    func playerDidDismiss() {
        guard navigationSelection != nil else { return }
        focusReturnRevision &+= 1
    }

#if os(tvOS)
    func restorePlayerFromPictureInPicture() {
        guard presentation != nil else { return }
        isPlayerPresented = true
    }
#endif

    func prewarm(
        channel: GuideChannel,
        program: GuideProgram?,
        configuration: TVHeadendConfiguration
    ) {
        if presentation != nil, prewarmedChannelID == nil { return }
        if prewarmedChannelID == channel.id { return }

        prewarmTask?.cancel()
        isUserInitiatedPlayback = false
        prewarmedChannelID = channel.id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard configuration.isComplete else { return }
                let request = try await TVHeadendClient(configuration: configuration)
                    .livePlaybackRequest(channelID: channel.id)
                guard !Task.isCancelled else { return }

                guard case .live(.nativeTimeshift) = request.kind else {
                    if prewarmedChannelID == channel.id { prewarmedChannelID = nil }
                    return
                }

                engine.stop()
                presentation = PlaybackPresentation(
                    channel: channel,
                    program: program,
                    recording: nil,
                    request: request
                )
                try await engine.prepare(request)
                guard !Task.isCancelled else { return }
                guard engine.activeLivePlaybackMode == .tvHeadend else {
                    engine.stop()
                    presentation = nil
                    if prewarmedChannelID == channel.id { prewarmedChannelID = nil }
                    return
                }
                engine.beginBuffering()
                prewarmedChannelID = channel.id
            } catch {
                if !Task.isCancelled {
                    logger.info("Live-stream prewarm did not complete: \(error.localizedDescription, privacy: .public)")
                    if prewarmedChannelID == channel.id { prewarmedChannelID = nil }
                }
            }
        }
        prewarmTask = task
    }

    func endPrewarming(channelID: String) {
        guard prewarmedChannelID == channelID else { return }
        prewarmTask?.cancel()
        prewarmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled,
                  let self,
                  self.prewarmedChannelID == channelID,
                  !self.isPlayerPresented
            else { return }
            self.engine.stop()
            self.presentation = nil
            self.prewarmedChannelID = nil
        }
    }

    func start(
        recording: TVRecording,
        channel: GuideChannel?,
        configuration: TVHeadendConfiguration
    ) {
        let sessionCanResume: Bool
        switch engine.state {
        case .idle, .failed: sessionCanResume = false
        case .preparing, .playing, .paused, .recovering: sessionCanResume = true
        }

        if presentation?.recording?.id == recording.id, sessionCanResume {
            if let channelID = channel?.id ?? presentation?.channel.id {
                navigationSelection = PlaybackNavigationSelection(
                    channelID: channelID,
                    programID: nil
                )
            }
            isUserInitiatedPlayback = true
            isPlayerPresented = true
            errorMessage = nil
            return
        }

        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmedChannelID = nil
        Task {
            do {
                guard configuration.isComplete else { throw TVProviderError.incompleteConfiguration }
                let url = try await TVHeadendClient(configuration: configuration)
                    .recordingStreamURL(recordingID: recording.id)
                let playbackChannel = channel ?? Self.placeholderChannel(for: recording)
                engine.stop()
                presentation = PlaybackPresentation(
                    channel: playbackChannel,
                    program: nil,
                    recording: recording,
                    request: LiveStreamRequest(
                        url: url,
                        networkCachingMilliseconds: 1_500,
                        profile: "recording",
                        kind: .recording(isGrowing: recording.state == .recording),
                        expectedDurationSeconds: recording.duration
                    )
                )
                navigationSelection = PlaybackNavigationSelection(
                    channelID: playbackChannel.id,
                    programID: nil
                )
                isUserInitiatedPlayback = true
                isPlayerPresented = true
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func placeholderChannel(for recording: TVRecording) -> GuideChannel {
        let name = recording.channelName
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "." })
        let monogram = words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return GuideChannel(
            id: recording.channelID ?? "recording-\(recording.id)",
            number: 0,
            name: name,
            monogram: monogram.isEmpty ? "TV" : monogram,
            tint: .orange,
            iconURL: nil,
            programs: []
        )
    }

}
