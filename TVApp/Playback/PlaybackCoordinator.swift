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
    private struct LivePrefetchKey: Equatable {
        let channelID: String
        let configuration: TVHeadendConfiguration
    }

    private struct CachedLivePrefetch {
        let id: UUID
        let key: LivePrefetchKey
        let request: LiveStreamRequest
        let completedAt: Date
    }

    private struct InFlightLivePrefetch {
        let id: UUID
        let key: LivePrefetchKey
        let task: Task<LiveStreamRequest, Error>
    }

    private static let livePrefetchLifetime: TimeInterval = 8
    private let logger = Logger(subsystem: "de.beutner.TVPlayer", category: "PlaybackCoordinator")
    @Published var presentation: PlaybackPresentation? {
        didSet { synchronizeCommercialAnalysis() }
    }
    @Published private(set) var launchPresentation: PlaybackLaunchPresentation?
    @Published private(set) var launchFailureMessage: String?
    @Published var isPlayerPresented = false
    @Published var errorMessage: String?
    @Published private(set) var navigationSelection: PlaybackNavigationSelection?
    @Published private(set) var focusReturnRevision = 0
    @Published private(set) var isUserInitiatedPlayback = false
    @Published private(set) var commercialBreaks: [CommercialBreak] = []
    let engine: VLCPlaybackEngine
    let commercialAnalyzer: CommercialLiveAnalyzer
#if os(tvOS)
    let pictureInPicture: PictureInPictureCoordinator
#endif
    private var prewarmTask: Task<Void, Never>?
    private var prewarmedChannelID: String?
    private let playbackStartIntents = PlaybackStartIntentTracker()
    private var launchShouldRestoreAudio = false
    private var cachedLivePrefetch: CachedLivePrefetch?
    private var inFlightLivePrefetch: InFlightLivePrefetch?
    private var liveCandidateGeneration: UUID?
    private var launchStartedAt: [UUID: Date] = [:]
    private var engineStartIntentID: UUID?
    private var playbackClient: TVHeadendClient?
    private var playbackClientConfiguration: TVHeadendConfiguration?
    private var commercialAnalysisStartTask: Task<Void, Never>?
    private var liveChannelOrder: [GuideChannel] = []
    private var liveChannelOrderConfiguration: TVHeadendConfiguration?
    private var predictsForwardChannel = true
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
        let commercialAnalyzer = CommercialLiveAnalyzer()
        self.engine = engine
        self.commercialAnalyzer = commercialAnalyzer
#if os(tvOS)
        pictureInPicture = PictureInPictureCoordinator(engine: engine)
        pictureInPicture.connect(to: self)
#endif
        commercialAnalyzer.breaksChanged = { [weak self] breaks in
            self?.commercialBreaks = breaks
        }
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
            cancelLivePlaybackPrefetch()
            let presentationID = UUID()
            let needsLaunch = !engine.mediaPlayer.hasVideoOut
            prewarmTask?.cancel()
            prewarmTask = nil
            prewarmedChannelID = nil
            if engine.state == .preparing || engine.state == .paused {
                engine.play()
            }
            preconnectStandby(for: existingPresentation.request)
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
                logLaunchStage("request-ready", id: presentationID)
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
                let request = try await livePlaybackRequestForStart(
                    channelID: channel.id,
                    configuration: configuration
                )
                try Task.checkCancellation()
                guard playbackStartIntents.isCurrent(intentID) else { return }
                logLaunchStage("request-ready", id: intentID)
                let newPresentation = PlaybackPresentation(
                    id: intentID,
                    channel: channel,
                    program: program,
                    recording: nil,
                    request: request
                )
                try await prepareAndPlay(request, intentID: intentID)
                guard playbackStartIntents.isCurrent(intentID) else { return }
                presentation = newPresentation
                finishPlaybackStartIntent(intentID)
            } catch is CancellationError {
                finishPlaybackStartIntent(intentID)
            } catch {
                guard playbackStartIntents.isCurrent(intentID) else { return }
                logLaunchStage("request-failed", id: intentID)
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
        predictsForwardChannel = direction == .up
        let intentID = playbackStartIntents.begin()
        beginLaunch(PlaybackLaunchPresentation(
            id: intentID,
            channel: target,
            program: program,
            recording: nil
        ))
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let request = try await livePlaybackRequestForStart(
                    channelID: target.id,
                    configuration: configuration
                )
                try Task.checkCancellation()
                guard playbackStartIntents.isCurrent(intentID) else { return }
                logLaunchStage("request-ready", id: intentID)

                let newPresentation = PlaybackPresentation(
                    id: intentID,
                    channel: target,
                    program: program,
                    recording: nil,
                    request: request
                )
                try await prepareAndPlay(request, intentID: intentID)
                guard playbackStartIntents.isCurrent(intentID) else { return }
                presentation = newPresentation
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
                finishLaunch(intentID, dismissPlayer: false)
                finishPlaybackStartIntent(intentID)
            }
        }
        playbackStartIntents.attach(task, to: intentID)
        return true
    }
#endif

    func leavePlayer(retainingLivePlayback: Bool = false) {
        cancelPlaybackStartIntent()
        cancelLivePlaybackPrefetch()
        if let launchPresentation {
            if presentation?.id == launchPresentation.id {
                engine.stop()
                presentation = nil
            }
            finishLaunch(launchPresentation.id, dismissPlayer: true)
            return
        }
        // Keep live television running only when the caller is about to expose
        // the guide preview. Otherwise stopping the player must also stop its
        // audio; leaving the live engine active behind Channels (or anywhere on
        // iOS, which has no embedded preview) produces invisible playback.
        if presentation?.isRecording == true {
            engine.pause()
        } else if !retainingLivePlayback {
            engine.stop()
            presentation = nil
            isUserInitiatedPlayback = false
        }
        isPlayerPresented = false
    }

    func pruneCommercialBreaks(before date: Date) {
        commercialAnalyzer.prune(before: date)
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
        logLaunchStage("audio-video-ready", id: presentationID)
        finishLaunch(presentationID, dismissPlayer: false)
        stagePredictedAdjacentChannel()
    }

    func playbackDidFail(presentationID: UUID, message: String) {
        guard launchPresentation?.id == presentationID else { return }
        logLaunchStage("playback-failed", id: presentationID)
        launchFailureMessage = message
    }

    func prefetchLivePlaybackRequest(
        channelID: String,
        configuration: TVHeadendConfiguration
    ) {
        guard configuration.isComplete else { return }
        let key = LivePrefetchKey(channelID: channelID, configuration: configuration)
        if let cachedLivePrefetch,
           cachedLivePrefetch.key == key,
           Date().timeIntervalSince(cachedLivePrefetch.completedAt) < Self.livePrefetchLifetime {
            return
        }
        if inFlightLivePrefetch?.key == key { return }

        invalidateLivePlaybackPrefetch()
        let id = UUID()
        liveCandidateGeneration = id
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            let request = try await client(for: configuration)
                .livePlaybackRequest(channelID: channelID)
            try Task.checkCancellation()
            guard liveCandidateGeneration == id,
                  inFlightLivePrefetch?.id == id
            else { throw CancellationError() }
            if let descriptor = HTSPLiveCandidateDescriptor(request) {
                await HTSPLiveCandidatePool.shared.stage(
                    descriptor,
                    generation: id
                )
                guard !Task.isCancelled,
                      liveCandidateGeneration == id,
                      inFlightLivePrefetch?.id == id
                else {
                    await HTSPLiveCandidatePool.shared.cancel(generation: id)
                    throw CancellationError()
                }
            }
            return request
        }
        inFlightLivePrefetch = InFlightLivePrefetch(id: id, key: key, task: task)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let request = try await task.value
                guard !Task.isCancelled, inFlightLivePrefetch?.id == id else { return }
                cachedLivePrefetch = CachedLivePrefetch(
                    id: id,
                    key: key,
                    request: request,
                    completedAt: Date()
                )
                inFlightLivePrefetch = nil
                logger.debug("Prefetched playback request for channel \(channelID, privacy: .public)")
            } catch {
                guard inFlightLivePrefetch?.id == id else { return }
                inFlightLivePrefetch = nil
                cancelLiveCandidateGenerationIfCurrent(id)
            }
        }
    }

    func cancelLivePlaybackPrefetch() {
        invalidateLivePlaybackPrefetch()
    }

    private func invalidateLivePlaybackPrefetch() {
        inFlightLivePrefetch?.task.cancel()
        inFlightLivePrefetch = nil
        cachedLivePrefetch = nil
        guard let generation = liveCandidateGeneration else { return }
        liveCandidateGeneration = nil
        Task {
            await HTSPLiveCandidatePool.shared.cancel(generation: generation)
        }
    }

    private func cancelLiveCandidateGenerationIfCurrent(_ generation: UUID) {
        guard liveCandidateGeneration == generation else { return }
        liveCandidateGeneration = nil
        Task {
            await HTSPLiveCandidatePool.shared.cancel(generation: generation)
        }
    }

    func updateLiveChannelOrder(
        _ channels: [GuideChannel],
        configuration: TVHeadendConfiguration
    ) {
        liveChannelOrder = channels
        liveChannelOrderConfiguration = configuration
        if launchPresentation == nil { stagePredictedAdjacentChannel() }
    }

#if os(tvOS)
    func restorePlayerFromPictureInPicture() {
        returnToPlayer()
    }

    func suspendForBackground() {
        foregroundResumeTask?.cancel()
        foregroundResumeTask = nil
        cancelLivePlaybackPrefetch()

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
        commercialAnalysisStartTask?.cancel()
        commercialAnalyzer.stop(resetMarkers: false)

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

        synchronizeCommercialAnalysis(forceRestart: true)

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
        if prewarmedChannelID == channel.id { return }

        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmedChannelID = channel.id
        prefetchLivePlaybackRequest(
            channelID: channel.id,
            configuration: configuration
        )
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
            self.invalidateLivePlaybackPrefetch()
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
        cancelLivePlaybackPrefetch()
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
                logLaunchStage("request-ready", id: presentation.id)
            }
            if engine.state == .preparing || engine.state == .paused {
                engine.play()
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
                logLaunchStage("request-ready", id: intentID)
                let request = LiveStreamRequest(
                    url: url,
                    networkCachingMilliseconds: 1_500,
                    profile: "recording",
                    kind: .recording(isGrowing: recording.state == .recording),
                    expectedDurationSeconds: recording.duration
                )
                let newPresentation = PlaybackPresentation(
                    id: intentID,
                    channel: playbackChannel,
                    program: nil,
                    recording: recording,
                    request: request
                )
                try await prepareAndPlay(request, intentID: intentID)
                guard playbackStartIntents.isCurrent(intentID) else { return }
                presentation = newPresentation
                finishPlaybackStartIntent(intentID)
            } catch is CancellationError {
                finishPlaybackStartIntent(intentID)
            } catch {
                guard playbackStartIntents.isCurrent(intentID) else { return }
                logLaunchStage("request-failed", id: intentID)
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

    private func synchronizeCommercialAnalysis(forceRestart: Bool = false) {
        commercialAnalysisStartTask?.cancel()
        guard let presentation,
              presentation.recording == nil,
              case let .live(.nativeTimeshift(htsp)) = presentation.request.kind
        else {
            commercialAnalyzer.stop(resetMarkers: true)
            commercialBreaks = []
            return
        }
        if !forceRestart, commercialAnalyzer.channelID == presentation.channel.id { return }

        commercialAnalyzer.stop(
            resetMarkers: commercialAnalyzer.channelID != presentation.channel.id
        )
        let presentationID = presentation.id
        let channelID = presentation.channel.id
        let commercialContext = CommercialChannelContext(
            serverIdentifier: htsp.configuration.dataStoreIdentifier,
            channelID: channelID,
            channelIconURL: presentation.channel.iconURL,
            programmes: presentation.channel.programs
        )
        let profile = presentation.request.profile
        commercialAnalysisStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await TVHeadendClient(configuration: htsp.configuration)
                    .canonicalLiveStreamURL(channelID: channelID, profile: profile)
                try Task.checkCancellation()
                guard self.presentation?.id == presentationID else { return }
                await self.commercialAnalyzer.start(context: commercialContext, url: url)
            } catch is CancellationError {
                return
            } catch {
                self.logger.info(
                    "Commercial analysis unavailable: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func cancelPlaybackStartIntent() {
        playbackStartIntents.cancel()
        if engineStartIntentID != nil {
            engineStartIntentID = nil
            engine.stop()
        }
    }

    private func finishPlaybackStartIntent(_ intentID: UUID) {
        playbackStartIntents.finish(intentID)
    }

    private func prepareAndPlay(
        _ request: LiveStreamRequest,
        intentID: UUID
    ) async throws {
        engineStartIntentID = intentID
        do {
            try await engine.prepare(request)
            try Task.checkCancellation()
            guard playbackStartIntents.isCurrent(intentID),
                  engineStartIntentID == intentID
            else { throw CancellationError() }
            logLaunchStage("prepared", id: intentID)
            engine.play()
            engineStartIntentID = nil
            preconnectStandby(for: request)
        } catch {
            if engineStartIntentID == intentID {
                engineStartIntentID = nil
                engine.stop()
            }
            throw error
        }
    }

    private func preconnectStandby(for request: LiveStreamRequest) {
        guard case let .live(.nativeTimeshift(htsp)) = request.kind else { return }
        Task {
            await HTSPConnectionPrewarmer.shared.preconnect(
                configuration: htsp.configuration
            )
        }
    }

    private func stagePredictedAdjacentChannel() {
        guard isPlayerPresented,
              launchPresentation == nil,
              let presentation,
              presentation.recording == nil,
              liveChannelOrder.count > 1,
              let configuration = liveChannelOrderConfiguration,
              let currentIndex = liveChannelOrder.firstIndex(where: {
                  $0.id == presentation.channel.id
              })
        else { return }
        let offset = predictsForwardChannel ? 1 : -1
        let targetIndex = (
            currentIndex + offset + liveChannelOrder.count
        ) % liveChannelOrder.count
        prefetchLivePlaybackRequest(
            channelID: liveChannelOrder[targetIndex].id,
            configuration: configuration
        )
    }

    private func finishLaunch(_ id: UUID, dismissPlayer: Bool) {
        guard launchPresentation?.id == id else { return }
        clearLaunch(dismissPlayer: dismissPlayer)
    }

    private func beginLaunch(_ presentation: PlaybackLaunchPresentation) {
        launchFailureMessage = nil
        launchPresentation = presentation
        launchStartedAt[presentation.id] = Date()
        logLaunchStage("intent", id: presentation.id)
        if let audio = engine.mediaPlayer.audio, !audio.isMuted {
            audio.isMuted = true
            launchShouldRestoreAudio = true
        }
    }

    private func clearLaunch(dismissPlayer: Bool) {
        if let id = launchPresentation?.id { launchStartedAt[id] = nil }
        launchFailureMessage = nil
        launchPresentation = nil
        if launchShouldRestoreAudio {
            engine.mediaPlayer.audio?.isMuted = false
            launchShouldRestoreAudio = false
        }
        if dismissPlayer { isPlayerPresented = false }
    }

    private func livePlaybackRequestForStart(
        channelID: String,
        configuration: TVHeadendConfiguration
    ) async throws -> LiveStreamRequest {
        let key = LivePrefetchKey(channelID: channelID, configuration: configuration)
        if let cachedLivePrefetch,
           cachedLivePrefetch.key == key,
           Date().timeIntervalSince(cachedLivePrefetch.completedAt) < Self.livePrefetchLifetime {
            self.cachedLivePrefetch = nil
            releaseLiveCandidateGeneration(cachedLivePrefetch.id)
            logger.debug("Using prefetched playback request for channel \(channelID, privacy: .public)")
            return cachedLivePrefetch.request
        }

        if let inFlightLivePrefetch, inFlightLivePrefetch.key == key {
            logger.debug("Joining playback request prefetch for channel \(channelID, privacy: .public)")
            let task = inFlightLivePrefetch.task
            let request = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if self.inFlightLivePrefetch?.id == inFlightLivePrefetch.id {
                self.inFlightLivePrefetch = nil
            }
            if cachedLivePrefetch?.id == inFlightLivePrefetch.id {
                cachedLivePrefetch = nil
            }
            releaseLiveCandidateGeneration(inFlightLivePrefetch.id)
            return request
        }

        invalidateLivePlaybackPrefetch()
        return try await client(for: configuration)
            .livePlaybackRequest(channelID: channelID)
    }

    private func releaseLiveCandidateGeneration(_ generation: UUID) {
        guard liveCandidateGeneration == generation else { return }
        liveCandidateGeneration = nil
    }

    func startAfterDetailDismissal(
        channel: GuideChannel,
        program: GuideProgram?,
        configuration: TVHeadendConfiguration
    ) {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.start(channel: channel, program: program, configuration: configuration)
        }
    }

    func startAfterDetailDismissal(
        recording: TVRecording,
        channel: GuideChannel?,
        configuration: TVHeadendConfiguration
    ) {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.start(recording: recording, channel: channel, configuration: configuration)
        }
    }

    private func logLaunchStage(_ stage: String, id: UUID) {
        guard let startedAt = launchStartedAt[id] else { return }
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        logger.notice(
            "Playback startup \(stage, privacy: .public) after \(milliseconds, privacy: .public) ms"
        )
#if DEBUG
        print("PLAYBACK_STARTUP \(id.uuidString) \(stage) \(milliseconds)ms")
        fflush(stdout)
#endif
    }

    private static func placeholderChannel(for recording: TVRecording) -> GuideChannel {
        let name = recording.channelName
        return GuideChannel(
            id: recording.channelID ?? "recording-\(recording.id)",
            number: 0,
            name: name,
            monogram: GuideChannelAppearance.monogram(for: name),
            tint: .orange,
            iconURL: nil,
            programs: []
        )
    }

}
