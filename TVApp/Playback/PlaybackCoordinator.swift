import Foundation
import OSLog
#if os(tvOS)
import AVFAudio
#endif

struct PlaybackPresentation: Identifiable {
    let id: UUID
    let channel: GuideChannel
    let program: GuideProgram?
    let recording: TVRecording?
    let request: LiveStreamRequest

    var isRecording: Bool { recording != nil }

    init(
        id: UUID = UUID(),
        channel: GuideChannel,
        program: GuideProgram?,
        recording: TVRecording?,
        request: LiveStreamRequest
    ) {
        self.id = id
        self.channel = channel
        self.program = program
        self.recording = recording
        self.request = request
    }
}

struct PlaybackLaunchPresentation: Identifiable {
    let id: UUID
    let channel: GuideChannel
    let program: GuideProgram?
    let recording: TVRecording?
}

struct PlaybackNavigationSelection: Equatable, Sendable {
    let channelID: GuideChannel.ID
    let programID: GuideProgram.ID?
}

@MainActor
final class PlaybackStartIntentTracker {
    private var currentID: UUID?
    private var currentTask: Task<Void, Never>?

    func begin() -> UUID {
        cancel()
        let id = UUID()
        currentID = id
        return id
    }

    func attach(_ task: Task<Void, Never>, to id: UUID) {
        guard currentID == id else {
            task.cancel()
            return
        }
        currentTask = task
    }

    func isCurrent(_ id: UUID) -> Bool {
        currentID == id
    }

    func finish(_ id: UUID) {
        guard currentID == id else { return }
        currentTask = nil
        currentID = nil
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        currentID = nil
    }
}

@MainActor
final class PlaybackCoordinator: ObservableObject {
    private let logger = Logger(subsystem: "de.beutner.TVPlayer", category: "PlaybackCoordinator")
    @Published var presentation: PlaybackPresentation?
    @Published private(set) var launchPresentation: PlaybackLaunchPresentation?
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
    private let playbackStartIntents = PlaybackStartIntentTracker()
    private var launchShouldRestoreAudio = false
    private var playbackClient: TVHeadendClient?
    private var playbackClientConfiguration: TVHeadendConfiguration?
#if os(tvOS)
    private struct BackgroundSuspension {
        let presentationID: UUID
        let wasPlaying: Bool
    }

    private var backgroundSuspension: BackgroundSuspension?
    private var foregroundResumeTask: Task<Void, Never>?
#endif

    init() {
        let engine = VLCPlaybackEngine()
        self.engine = engine
#if os(tvOS)
        pictureInPicture = PictureInPictureCoordinator(engine: engine)
        pictureInPicture.connect(to: self)
#endif
    }

    var isUserInitiatedLivePlayback: Bool {
        guard isUserInitiatedPlayback else { return false }
        if let launchPresentation { return launchPresentation.recording == nil }
        return presentation?.isRecording == false
    }

    func start(
        channel: GuideChannel,
        program: GuideProgram?,
        configuration: TVHeadendConfiguration
    ) {
        cancelPlaybackStartIntent()
        clearLaunch(dismissPlayer: false)
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
            let presentationID = UUID()
            let needsLaunch = !engine.mediaPlayer.hasVideoOut
            if prewarmedChannelID == channel.id {
                engine.finishPrewarmingAtLiveEdge()
            }
            prewarmTask?.cancel()
            prewarmTask = nil
            prewarmedChannelID = nil
            presentation = PlaybackPresentation(
                id: presentationID,
                channel: channel,
                program: program,
                recording: nil,
                request: existingPresentation.request
            )
            if needsLaunch {
                beginLaunch(PlaybackLaunchPresentation(
                    id: presentationID,
                    channel: channel,
                    program: program,
                    recording: nil
                ))
            }
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
        let intentID = playbackStartIntents.begin()
        beginLaunch(PlaybackLaunchPresentation(
            id: intentID,
            channel: channel,
            program: program,
            recording: nil
        ))
        navigationSelection = PlaybackNavigationSelection(
            channelID: channel.id,
            programID: program?.id
        )
        isUserInitiatedPlayback = true
        isPlayerPresented = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard configuration.isComplete else { throw TVProviderError.incompleteConfiguration }
                let request = try await client(for: configuration)
                    .livePlaybackRequest(channelID: channel.id)
                try Task.checkCancellation()
                guard playbackStartIntents.isCurrent(intentID) else { return }
                engine.stop()
                presentation = PlaybackPresentation(
                    id: intentID,
                    channel: channel,
                    program: program,
                    recording: nil,
                    request: request
                )
                finishPlaybackStartIntent(intentID)
            } catch is CancellationError {
                finishPlaybackStartIntent(intentID)
            } catch {
                guard playbackStartIntents.isCurrent(intentID) else { return }
                errorMessage = error.localizedDescription
                finishLaunch(intentID, dismissPlayer: true)
                finishPlaybackStartIntent(intentID)
            }
        }
        playbackStartIntents.attach(task, to: intentID)
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

        cancelPlaybackStartIntent()
        clearLaunch(dismissPlayer: false)
        let intentID = playbackStartIntents.begin()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let request = try await client(for: configuration)
                    .livePlaybackRequest(channelID: target.id)
                try Task.checkCancellation()
                guard playbackStartIntents.isCurrent(intentID) else { return }

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
                finishPlaybackStartIntent(intentID)
            } catch is CancellationError {
                finishPlaybackStartIntent(intentID)
            } catch {
                guard playbackStartIntents.isCurrent(intentID) else { return }
                errorMessage = error.localizedDescription
                finishPlaybackStartIntent(intentID)
            }
        }
        playbackStartIntents.attach(task, to: intentID)
        return true
    }
#endif

    func leavePlayer() {
        cancelPlaybackStartIntent()
        if let launchPresentation {
            if presentation?.id == launchPresentation.id {
                engine.stop()
                presentation = nil
            }
            finishLaunch(launchPresentation.id, dismissPlayer: true)
            return
        }
        // Live television keeps running when it collapses into the guide's
        // artwork area. Recorded media retains the previous pause-on-exit
        // behavior because it has no corresponding live channel preview.
        if presentation?.isRecording == true {
            engine.pause()
        }
        isPlayerPresented = false
    }

    func returnToPlayer() {
        guard presentation != nil else { return }
        isPlayerPresented = true
        errorMessage = nil
    }

    func playerDidDismiss() {
        guard navigationSelection != nil else { return }
        focusReturnRevision &+= 1
    }

    func playbackDidStart(presentationID: UUID) {
        finishLaunch(presentationID, dismissPlayer: false)
    }

    func playbackDidFail(presentationID: UUID) {
        finishLaunch(presentationID, dismissPlayer: false)
    }

#if os(tvOS)
    func restorePlayerFromPictureInPicture() {
        returnToPlayer()
    }

    func suspendForBackground() {
        foregroundResumeTask?.cancel()
        foregroundResumeTask = nil

        guard isUserInitiatedPlayback, let presentation else {
            backgroundSuspension = nil
            return
        }

        let wasPlaying: Bool
        switch engine.state {
        case .preparing, .playing, .recovering:
            wasPlaying = true
        case .paused:
            wasPlaying = false
        case .idle, .failed:
            backgroundSuspension = nil
            return
        }
        backgroundSuspension = BackgroundSuspension(
            presentationID: presentation.id,
            wasPlaying: wasPlaying
        )

        if presentation.isRecording {
            if wasPlaying { engine.pause() }
        } else {
            // A live HTSP/VLC pipeline cannot be assumed to retain its audio
            // and video outputs while tvOS suspends the process. Close it and
            // establish a fresh subscription when the scene becomes active.
            engine.stop()
        }
    }

    func resumeAfterBackground() {
        guard let suspension = backgroundSuspension else { return }
        backgroundSuspension = nil
        guard let presentation, presentation.id == suspension.presentationID else { return }

        try? AVAudioSession.sharedInstance().setActive(true)

        if presentation.isRecording {
            if suspension.wasPlaying { engine.play() }
            return
        }

        foregroundResumeTask?.cancel()
        foregroundResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await engine.prepare(presentation.request)
                try Task.checkCancellation()
                engine.play()
                if !suspension.wasPlaying {
                    guard await engine.waitForPlaybackStart() else { return }
                    try Task.checkCancellation()
                    engine.pause()
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
                let request = try await client(for: configuration)
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
        cancelPlaybackStartIntent()
        clearLaunch(dismissPlayer: false)
        let sessionCanResume: Bool
        switch engine.state {
        case .idle, .failed: sessionCanResume = false
        case .preparing, .playing, .paused, .recovering: sessionCanResume = true
        }

        if presentation?.recording?.id == recording.id, sessionCanResume {
            if !engine.mediaPlayer.hasVideoOut, let presentation {
                beginLaunch(PlaybackLaunchPresentation(
                    id: presentation.id,
                    channel: presentation.channel,
                    program: nil,
                    recording: recording
                ))
            }
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
        let intentID = playbackStartIntents.begin()
        let playbackChannel = channel ?? Self.placeholderChannel(for: recording)
        beginLaunch(PlaybackLaunchPresentation(
            id: intentID,
            channel: playbackChannel,
            program: nil,
            recording: recording
        ))
        navigationSelection = PlaybackNavigationSelection(
            channelID: playbackChannel.id,
            programID: nil
        )
        isUserInitiatedPlayback = true
        isPlayerPresented = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard configuration.isComplete else { throw TVProviderError.incompleteConfiguration }
                let url = try await client(for: configuration)
                    .recordingStreamURL(recordingID: recording.id)
                try Task.checkCancellation()
                guard playbackStartIntents.isCurrent(intentID) else { return }
                engine.stop()
                presentation = PlaybackPresentation(
                    id: intentID,
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
                finishPlaybackStartIntent(intentID)
            } catch is CancellationError {
                finishPlaybackStartIntent(intentID)
            } catch {
                guard playbackStartIntents.isCurrent(intentID) else { return }
                errorMessage = error.localizedDescription
                finishLaunch(intentID, dismissPlayer: true)
                finishPlaybackStartIntent(intentID)
            }
        }
        playbackStartIntents.attach(task, to: intentID)
    }

    func streamProfiles(
        configuration: TVHeadendConfiguration
    ) async throws -> [TVHeadendStreamProfile] {
        try await client(for: configuration).streamProfiles()
    }

    func livePlaybackRequest(
        channelID: String,
        profile: String? = nil,
        networkCachingMilliseconds: Int = 1_500,
        configuration: TVHeadendConfiguration
    ) async throws -> LiveStreamRequest {
        try await client(for: configuration).livePlaybackRequest(
            channelID: channelID,
            profile: profile,
            networkCachingMilliseconds: networkCachingMilliseconds
        )
    }

    func recordingStreamURL(
        recordingID: String,
        configuration: TVHeadendConfiguration
    ) async throws -> URL {
        try await client(for: configuration).recordingStreamURL(recordingID: recordingID)
    }

    private func client(for configuration: TVHeadendConfiguration) -> TVHeadendClient {
        if playbackClientConfiguration == configuration, let playbackClient {
            return playbackClient
        }

        let client = TVHeadendClient(configuration: configuration)
        playbackClient = client
        playbackClientConfiguration = configuration
        return client
    }

    private func cancelPlaybackStartIntent() {
        playbackStartIntents.cancel()
    }

    private func finishPlaybackStartIntent(_ intentID: UUID) {
        playbackStartIntents.finish(intentID)
    }

    private func finishLaunch(_ id: UUID, dismissPlayer: Bool) {
        guard launchPresentation?.id == id else { return }
        clearLaunch(dismissPlayer: dismissPlayer)
    }

    private func beginLaunch(_ presentation: PlaybackLaunchPresentation) {
        launchPresentation = presentation
        if let audio = engine.mediaPlayer.audio, !audio.isMuted {
            audio.isMuted = true
            launchShouldRestoreAudio = true
        }
    }

    private func clearLaunch(dismissPlayer: Bool) {
        launchPresentation = nil
        if launchShouldRestoreAudio {
            engine.mediaPlayer.audio?.isMuted = false
            launchShouldRestoreAudio = false
        }
        if dismissPlayer { isPlayerPresented = false }
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
