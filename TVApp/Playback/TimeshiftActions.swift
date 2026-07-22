import Foundation

protocol NativeTimeshiftCommandSink: AnyObject {
    func play()
    func pause()
    func seek(by seconds: TimeInterval)
    func returnToLive()
}

enum NativeTimeshiftAction: Equatable {
    case play
    case pause
    case skipBackward(TimeInterval)
    case skipForward(TimeInterval, liveDelay: TimeInterval)
    case returnToLive
}

enum NativeTimeshiftServerCommand: Equatable {
    case play
    case pause
    case seek(TimeInterval)
    case returnToLive
}

struct NativeTimeshiftActionPlan: Equatable {
    static let liveEdgeTolerance: TimeInterval = 0.25

    let serverCommands: [NativeTimeshiftServerCommand]
    let localPlaybackEffect: NativeTimeshiftLocalPlaybackEffect

    static func make(for action: NativeTimeshiftAction) -> NativeTimeshiftActionPlan {
        switch action {
        case .play:
            return NativeTimeshiftActionPlan(serverCommands: [.play], localPlaybackEffect: .resume)

        case .pause:
            return NativeTimeshiftActionPlan(serverCommands: [.pause], localPlaybackEffect: .pause)

        case let .skipBackward(seconds):
            guard seconds > 0 else {
                return NativeTimeshiftActionPlan(serverCommands: [], localPlaybackEffect: .none)
            }
            return NativeTimeshiftActionPlan(
                serverCommands: [.pause, .seek(-seconds)],
                localPlaybackEffect: .pauseUntilNavigationCompletes
            )

        case let .skipForward(seconds, liveDelay):
            guard seconds > 0 else {
                return NativeTimeshiftActionPlan(serverCommands: [], localPlaybackEffect: .none)
            }
            let reachesLiveEdge = seconds >= max(0, liveDelay - liveEdgeTolerance)
            return NativeTimeshiftActionPlan(
                serverCommands: reachesLiveEdge
                    ? [.pause, .returnToLive]
                    : [.pause, .seek(seconds)],
                localPlaybackEffect: .pauseUntilNavigationCompletes
            )

        case .returnToLive:
            return NativeTimeshiftActionPlan(
                serverCommands: [.pause, .returnToLive],
                localPlaybackEffect: .pauseUntilNavigationCompletes
            )
        }
    }
}

enum HTSPRecoveryPolicy {
    static let stalledPacketThreshold: TimeInterval = 10
    static let fastRetryDelay: TimeInterval = 0.5
    static let slowRetryDelay: TimeInterval = 10
    static let fastRetryCount = 5

    /// The first replacement connection is attempted immediately. As in
    /// Kodi, failed connection attempts are retried quickly five times before
    /// settling into a slower, unbounded retry loop.
    static func delay(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        return attempt <= fastRetryCount + 1 ? fastRetryDelay : slowRetryDelay
    }

    static func isTerminal(_ error: Error) -> Bool {
        guard let error = error as? HTSPError else { return false }
        switch error {
        case .invalidHost,
             .authenticationFailed,
             .streamingUnavailable,
             .timeshiftUnavailable,
             .channelUnavailable,
             .unsupportedStream:
            return true
        case .connectionFailed, .disconnected, .readTimedOut, .server:
            return false
        }
    }
}

enum NativeTimeshiftLocalPlaybackEffect: Equatable {
    case none
    case pause
    case resume
    case pauseUntilNavigationCompletes
}

final class NativeTimeshiftActionController {
    private let sink: any NativeTimeshiftCommandSink

    init(sink: any NativeTimeshiftCommandSink) {
        self.sink = sink
    }

    @discardableResult
    func perform(
        _ action: NativeTimeshiftAction,
        beforeServerCommands: ((NativeTimeshiftLocalPlaybackEffect) -> Void)? = nil
    ) -> NativeTimeshiftLocalPlaybackEffect {
        let plan = NativeTimeshiftActionPlan.make(for: action)
        beforeServerCommands?(plan.localPlaybackEffect)
        for command in plan.serverCommands {
            switch command {
            case .play:
                sink.play()
            case .pause:
                sink.pause()
            case let .seek(seconds):
                sink.seek(by: seconds)
            case .returnToLive:
                sink.returnToLive()
            }
        }
        return plan.localPlaybackEffect
    }
}

enum PlaybackCapabilityPolicy {
    static func isSeekable(
        isLive: Bool,
        hasNativeTimeshift: Bool,
        mediaIsSeekable: Bool
    ) -> Bool {
        hasNativeTimeshift || (!isLive && mediaIsSeekable)
    }

    static func canPause(
        isLive: Bool,
        hasNativeTimeshift: Bool,
        mediaCanPause: Bool
    ) -> Bool {
        hasNativeTimeshift || (!isLive && mediaCanPause)
    }
}

struct PlaybackOutputCounters: Equatable {
    let displayedPictures: Int
    let playedAudioBuffers: Int
    let demuxDiscontinuities: Int
    let playbackTimeMilliseconds: Int64?
    let decodedVideo: Int
    let decodedAudio: Int
    let lostPictures: Int
    let lostAudioBuffers: Int

    init(
        displayedPictures: Int,
        playedAudioBuffers: Int,
        demuxDiscontinuities: Int = 0,
        playbackTimeMilliseconds: Int64? = nil,
        decodedVideo: Int = 0,
        decodedAudio: Int = 0,
        lostPictures: Int = 0,
        lostAudioBuffers: Int = 0
    ) {
        self.displayedPictures = displayedPictures
        self.playedAudioBuffers = playedAudioBuffers
        self.demuxDiscontinuities = demuxDiscontinuities
        self.playbackTimeMilliseconds = playbackTimeMilliseconds
        self.decodedVideo = decodedVideo
        self.decodedAudio = decodedAudio
        self.lostPictures = lostPictures
        self.lostAudioBuffers = lostAudioBuffers
    }

    func hasAdvanced(since previous: PlaybackOutputCounters) -> Bool {
        displayedPictures > previous.displayedPictures
            || playedAudioBuffers > previous.playedAudioBuffers
    }
}

/// Keeps post-seek output hidden until VLC has consumed the transport-stream
/// discontinuity and presented media decoded after it. VLC can retain decoded
/// pictures and audio while paused; those samples must not become visible when
/// playback is resumed after moving within the timeshift buffer.
struct PostSeekPlaybackOutputGateDiagnostics: Equatable {
    enum Phase: String {
        case inactive
        case armed
        case waitingForDiscontinuity
        case establishingDiscontinuityBaseline
        case waitingForAudio
        case waitingForSustainedOutput
        case waitingForStablePictures
        case ready
    }

    let phase: Phase
    let sustainedOutputMilliseconds: Int64
    let requiredSustainedOutputMilliseconds: Int64
    let displayedPictureAdvance: Int
    let requiredDisplayedPictureAdvance: Int
}

struct PostSeekPlaybackOutputGate {
    private(set) var isArmed = false
    private(set) var isConcealing = false
    private var isEvaluatingFreshOutput = false
    private var baselineDiscontinuities = 0
    private var minimumPrerollDurationMilliseconds: Int64 = 0
    private var minimumSustainedOutputMilliseconds: Int64 = 0
    private var minimumDisplayedPictureAdvance = 0
    private var requiresFreshVideoAtReveal = false
    private var requiresAudioOutput = false
    private var outputAfterDiscontinuity: PlaybackOutputCounters?
    private var firstFreshOutputAt: Date?
    private var firstFreshAudioOutputAt: Date?
    private var sustainedOutputStartedAt: Date?
    private var videoContinuityStartedAt: Date?
    private var audioContinuityStartedAt: Date?
    private var anyContinuityStartedAt: Date?
    private var lastVideoOutputAdvanceAt: Date?
    private var lastAudioOutputAdvanceAt: Date?
    private var lastAnyOutputAdvanceAt: Date?
    private var previousObservedOutput: PlaybackOutputCounters?
    private var pictureEpochBaseline: PlaybackOutputCounters?
    private var startsWithFreshPipeline = false

    /// Output counters are sampled at 50–100 ms intervals in production.
    /// Treat three-tenths of a second of observed non-progress as a real cadence break,
    /// while tolerating a delayed individual statistics callback.
    private static let sustainedOutputGapToleranceMilliseconds: Int64 = 300

    mutating func arm(from output: PlaybackOutputCounters) {
        isArmed = true
        isConcealing = false
        isEvaluatingFreshOutput = false
        baselineDiscontinuities = output.demuxDiscontinuities
        outputAfterDiscontinuity = nil
        firstFreshOutputAt = nil
        firstFreshAudioOutputAt = nil
        resetSustainedOutputState()
        previousObservedOutput = nil
        pictureEpochBaseline = nil
        startsWithFreshPipeline = false
    }

    mutating func requirePrerollDuration(_ duration: TimeInterval) {
        minimumPrerollDurationMilliseconds = Int64(
            (max(0, duration) * 1_000).rounded(.up)
        )
    }

    mutating func requireSustainedOutput(_ duration: TimeInterval) {
        minimumSustainedOutputMilliseconds = Int64(
            (max(0, duration) * 1_000).rounded(.up)
        )
    }

    mutating func requireDisplayedPicture() {
        requireDisplayedPictures(1)
    }

    mutating func requireDisplayedPictures(_ count: Int) {
        let requiredCount = max(minimumDisplayedPictureAdvance, max(0, count))
        if minimumDisplayedPictureAdvance == 0, requiredCount > 0 {
            // A continuity epoch established for audio/any-output alone
            // cannot prove newly-required video continuity.
            resetSustainedOutputState()
        }
        minimumDisplayedPictureAdvance = requiredCount
    }

    /// Requires a newly displayed picture on the observation which opens the
    /// gate without treating video as the cadence clock. Initial live tuning
    /// can use advancing audio to prove that VLC's presentation clock is
    /// running, while this final check still prevents a frozen startup picture
    /// from dismissing the launch surface. Post-seek gates retain their stricter
    /// picture-cadence behavior unless they opt into this explicitly.
    mutating func requireFreshVideoAtReveal() {
        requiresFreshVideoAtReveal = true
    }

    mutating func requireAudioOutput() {
        guard !requiresAudioOutput else { return }
        requiresAudioOutput = true
        // Do not count a preceding video-only interval toward an A/V
        // continuity requirement added after observation has begun.
        resetSustainedOutputState()
    }

    /// A newly-created VLC media pipeline cannot contain samples from the old
    /// position. Treat its first output as post-discontinuity output even when
    /// the fresh MPEG-TS starts cleanly and VLC reports no discontinuity.
    mutating func markPipelineRecreated() {
        guard isArmed else { return }
        startsWithFreshPipeline = true
        baselineDiscontinuities = 0
        outputAfterDiscontinuity = nil
        firstFreshOutputAt = nil
        firstFreshAudioOutputAt = nil
        resetSustainedOutputState()
        previousObservedOutput = nil
        pictureEpochBaseline = nil
    }

    @discardableResult
    mutating func concealImmediately() -> Bool {
        guard isArmed else { return false }
        let startedConcealing = !isConcealing
        isConcealing = true
        return startedConcealing
    }

    @discardableResult
    mutating func beginConcealing(from output: PlaybackOutputCounters) -> Bool {
        guard isArmed else { return false }
        isConcealing = true
        isEvaluatingFreshOutput = true
        if hasObservedDiscontinuity(in: output) {
            // The demuxer may consume the marker while VLC is paused. In that
            // case presentation still needs to advance after playback starts.
            outputAfterDiscontinuity = output
            previousObservedOutput = output
            pictureEpochBaseline = output
        }
        return true
    }

    /// Returns true once output can safely be revealed.
    mutating func observe(_ output: PlaybackOutputCounters, at date: Date = Date()) -> Bool {
        guard isArmed, isEvaluatingFreshOutput else { return false }

        if output.demuxDiscontinuities < baselineDiscontinuities {
            // VLC statistics restart if the media pipeline is recreated.
            baselineDiscontinuities = 0
            outputAfterDiscontinuity = nil
            firstFreshOutputAt = nil
            firstFreshAudioOutputAt = nil
            resetSustainedOutputState()
            previousObservedOutput = nil
            pictureEpochBaseline = nil
        }
        // Counter progress alone is unsafe here: VLC can drain many
        // seconds of queued pre-seek media before it consumes our transport
        // discontinuity. Keep that stale output hidden until the demuxer has
        // explicitly crossed into the new epoch.
        guard hasObservedDiscontinuity(in: output) else { return false }

        guard let outputAfterDiscontinuity else {
            self.outputAfterDiscontinuity = output
            previousObservedOutput = output
            pictureEpochBaseline = output
            return false
        }

        guard isConcealing else { return false }
        let previous = previousObservedOutput ?? outputAfterDiscontinuity
        let countersReset = output.displayedPictures < previous.displayedPictures
            || output.playedAudioBuffers < previous.playedAudioBuffers
        if countersReset {
            pictureEpochBaseline = output
            firstFreshOutputAt = nil
            firstFreshAudioOutputAt = nil
            resetSustainedOutputState()
        }
        let outputAdvancedNow = output.hasAdvanced(since: previous)
        if firstFreshOutputAt == nil, outputAdvancedNow { firstFreshOutputAt = date }
        let audioAdvancedNow = output.playedAudioBuffers > previous.playedAudioBuffers
        if requiresAudioOutput,
           firstFreshAudioOutputAt == nil,
           audioAdvancedNow {
            firstFreshAudioOutputAt = date
        }
        let videoAdvancedNow = output.displayedPictures > previous.displayedPictures
        let requiresVideoOutput = minimumDisplayedPictureAdvance > 0
        let usesAnyOutput = !requiresVideoOutput && !requiresAudioOutput
        let detectsCadenceBreaks = minimumSustainedOutputMilliseconds > 0
        let videoStalled = detectsCadenceBreaks
            && requiresVideoOutput
            && !videoAdvancedNow
            && lastVideoOutputAdvanceAt.map {
                Self.elapsedMilliseconds(from: $0, to: date)
                    >= Self.sustainedOutputGapToleranceMilliseconds
            } == true
        let audioStalled = detectsCadenceBreaks
            && requiresAudioOutput
            && !audioAdvancedNow
            && lastAudioOutputAdvanceAt.map {
                Self.elapsedMilliseconds(from: $0, to: date)
                    >= Self.sustainedOutputGapToleranceMilliseconds
            } == true
        let anyOutputStalled = detectsCadenceBreaks
            && usesAnyOutput
            && !outputAdvancedNow
            && lastAnyOutputAdvanceAt.map {
                Self.elapsedMilliseconds(from: $0, to: date)
                    >= Self.sustainedOutputGapToleranceMilliseconds
            } == true

        if videoStalled || audioStalled || anyOutputStalled {
            resetSustainedOutputState()
            // Count pictures only from the cadence epoch that can become
            // visible. A burst preceding an observed stall is preroll.
            pictureEpochBaseline = output
        }
        if videoAdvancedNow {
            videoContinuityStartedAt = videoContinuityStartedAt ?? date
            lastVideoOutputAdvanceAt = date
        }
        if audioAdvancedNow {
            audioContinuityStartedAt = audioContinuityStartedAt ?? date
            lastAudioOutputAdvanceAt = date
        }
        if outputAdvancedNow {
            anyContinuityStartedAt = anyContinuityStartedAt ?? date
            lastAnyOutputAdvanceAt = date
        }
        if sustainedOutputStartedAt == nil {
            var requiredStarts: [Date] = []
            if requiresVideoOutput, let videoContinuityStartedAt {
                requiredStarts.append(videoContinuityStartedAt)
            }
            if requiresAudioOutput, let audioContinuityStartedAt {
                requiredStarts.append(audioContinuityStartedAt)
            }
            if usesAnyOutput, let anyContinuityStartedAt {
                requiredStarts.append(anyContinuityStartedAt)
            }
            let expectedStartCount = (requiresVideoOutput ? 1 : 0)
                + (requiresAudioOutput ? 1 : 0)
                + (usesAnyOutput ? 1 : 0)
            if requiredStarts.count == expectedStartCount,
               let continuityStart = requiredStarts.max() {
                sustainedOutputStartedAt = continuityStart
            }
        }
        previousObservedOutput = output

        guard let firstFreshOutputAt else { return false }
        if requiresAudioOutput, firstFreshAudioOutputAt == nil { return false }
        guard let sustainedOutputStartedAt else { return false }
        let prerollProgress = Self.elapsedMilliseconds(from: firstFreshOutputAt, to: date)
        let sustainedProgress = Self.elapsedMilliseconds(
            from: sustainedOutputStartedAt,
            to: date
        )
        guard prerollProgress >= minimumPrerollDurationMilliseconds,
              sustainedProgress >= minimumSustainedOutputMilliseconds
        else { return false }

        let freshnessBaseline = pictureEpochBaseline ?? outputAfterDiscontinuity
        let hasRecentAudioOutput = !requiresAudioOutput
            || lastAudioOutputAdvanceAt.map {
                Self.elapsedMilliseconds(from: $0, to: date)
                    < Self.sustainedOutputGapToleranceMilliseconds
            } == true
        guard hasRecentAudioOutput,
              !requiresAudioOutput
                || output.playedAudioBuffers > freshnessBaseline.playedAudioBuffers
        else { return false }
        let hasFreshOutput: Bool
        if minimumDisplayedPictureAdvance > 0 {
            hasFreshOutput = videoAdvancedNow
                && output.displayedPictures - freshnessBaseline.displayedPictures
                    >= minimumDisplayedPictureAdvance
        } else if requiresFreshVideoAtReveal {
            // Sustained, recently advancing audio already proved the clock.
            // Do not require its statistics counter to happen to change in the
            // exact same poll as the sparse video picture used for reveal.
            hasFreshOutput = videoAdvancedNow
                && output.displayedPictures > freshnessBaseline.displayedPictures
        } else if requiresAudioOutput {
            hasFreshOutput = audioAdvancedNow
                && output.playedAudioBuffers > freshnessBaseline.playedAudioBuffers
        } else {
            hasFreshOutput = output.hasAdvanced(since: freshnessBaseline)
        }
        let hasFreshVideoAtReveal = !requiresFreshVideoAtReveal
            || (videoAdvancedNow
                && output.displayedPictures > freshnessBaseline.displayedPictures)
        guard hasFreshOutput, hasFreshVideoAtReveal else { return false }

        reset()
        return true
    }

    func diagnostics(
        for output: PlaybackOutputCounters,
        at date: Date = Date()
    ) -> PostSeekPlaybackOutputGateDiagnostics {
        func result(
            _ phase: PostSeekPlaybackOutputGateDiagnostics.Phase,
            progress: Int64 = 0,
            pictures: Int = 0
        ) -> PostSeekPlaybackOutputGateDiagnostics {
            PostSeekPlaybackOutputGateDiagnostics(
                phase: phase,
                sustainedOutputMilliseconds: progress,
                requiredSustainedOutputMilliseconds: max(
                    minimumPrerollDurationMilliseconds,
                    minimumSustainedOutputMilliseconds
                ),
                displayedPictureAdvance: pictures,
                requiredDisplayedPictureAdvance: max(
                    minimumDisplayedPictureAdvance,
                    requiresFreshVideoAtReveal ? 1 : 0
                )
            )
        }

        guard isArmed else { return result(.inactive) }
        guard isEvaluatingFreshOutput else { return result(.armed) }
        guard hasObservedDiscontinuity(in: output) else {
            return result(.waitingForDiscontinuity)
        }
        guard let outputAfterDiscontinuity else {
            return result(.establishingDiscontinuityBaseline)
        }

        let freshOutputAt = firstFreshOutputAt
            ?? (output.hasAdvanced(since: previousObservedOutput ?? outputAfterDiscontinuity)
                ? date
                : nil)
        let freshnessBaseline = pictureEpochBaseline ?? outputAfterDiscontinuity
        let audioOutputAt = firstFreshAudioOutputAt
            ?? (output.playedAudioBuffers > freshnessBaseline.playedAudioBuffers ? date : nil)
        if requiresAudioOutput, audioOutputAt == nil {
            return result(.waitingForAudio)
        }
        let prerollProgress = Self.elapsedMilliseconds(from: freshOutputAt ?? date, to: date)
        let stabilityProgress = sustainedOutputStartedAt.map {
            Self.elapsedMilliseconds(from: $0, to: date)
        } ?? 0
        let requiredProgress = max(
            minimumPrerollDurationMilliseconds,
            minimumSustainedOutputMilliseconds
        )
        let remainingProgress = max(
            max(0, minimumPrerollDurationMilliseconds - prerollProgress),
            max(0, minimumSustainedOutputMilliseconds - stabilityProgress)
        )
        let readinessProgress = max(0, requiredProgress - remainingProgress)
        guard isConcealing,
              prerollProgress >= minimumPrerollDurationMilliseconds,
              stabilityProgress >= minimumSustainedOutputMilliseconds
        else {
            return result(.waitingForSustainedOutput, progress: readinessProgress)
        }
        let pictureAdvance = max(
            0,
            output.displayedPictures - freshnessBaseline.displayedPictures
        )
        let videoAdvancedNow = output.displayedPictures
            > (previousObservedOutput ?? outputAfterDiscontinuity).displayedPictures
        let audioAdvancedNow = output.playedAudioBuffers
            > (previousObservedOutput ?? outputAfterDiscontinuity).playedAudioBuffers
        let audioRecentlyAdvanced = !requiresAudioOutput
            || lastAudioOutputAdvanceAt.map {
                Self.elapsedMilliseconds(from: $0, to: date)
                    < Self.sustainedOutputGapToleranceMilliseconds
            } == true
        let requiredPictureAdvance = max(
            minimumDisplayedPictureAdvance,
            requiresFreshVideoAtReveal ? 1 : 0
        )
        let requiredOutputAdvancedNow = requiredPictureAdvance > 0
            ? videoAdvancedNow
            : (requiresAudioOutput
                ? audioAdvancedNow
                    : output.hasAdvanced(since: previousObservedOutput ?? outputAfterDiscontinuity))
        guard pictureAdvance >= requiredPictureAdvance,
              requiredOutputAdvancedNow,
              audioRecentlyAdvanced else {
            return result(
                .waitingForStablePictures,
                progress: readinessProgress,
                pictures: pictureAdvance
            )
        }
        return result(.ready, progress: readinessProgress, pictures: pictureAdvance)
    }

    @discardableResult
    mutating func suspendConcealing() -> Bool {
        let wasConcealing = isConcealing
        isConcealing = false
        outputAfterDiscontinuity = nil
        firstFreshOutputAt = nil
        firstFreshAudioOutputAt = nil
        resetSustainedOutputState()
        previousObservedOutput = nil
        pictureEpochBaseline = nil
        return wasConcealing
    }

    @discardableResult
    mutating func cancel() -> Bool {
        let wasConcealing = isConcealing
        reset()
        return wasConcealing
    }

    private func hasObservedDiscontinuity(in output: PlaybackOutputCounters) -> Bool {
        startsWithFreshPipeline || output.demuxDiscontinuities > baselineDiscontinuities
    }

    private mutating func reset() {
        isArmed = false
        isConcealing = false
        isEvaluatingFreshOutput = false
        baselineDiscontinuities = 0
        minimumPrerollDurationMilliseconds = 0
        minimumSustainedOutputMilliseconds = 0
        minimumDisplayedPictureAdvance = 0
        requiresFreshVideoAtReveal = false
        requiresAudioOutput = false
        outputAfterDiscontinuity = nil
        firstFreshOutputAt = nil
        firstFreshAudioOutputAt = nil
        resetSustainedOutputState()
        previousObservedOutput = nil
        pictureEpochBaseline = nil
        startsWithFreshPipeline = false
    }

    private mutating func resetSustainedOutputState() {
        sustainedOutputStartedAt = nil
        videoContinuityStartedAt = nil
        audioContinuityStartedAt = nil
        anyContinuityStartedAt = nil
        lastVideoOutputAdvanceAt = nil
        lastAudioOutputAdvanceAt = nil
        lastAnyOutputAdvanceAt = nil
    }

    private static func elapsedMilliseconds(from start: Date, to end: Date) -> Int64 {
        Int64((max(0, end.timeIntervalSince(start)) * 1_000).rounded(.down))
    }
}

enum PlaybackHealthAction: Equatable {
    case none
    case rebuildPlayer
    case rebuildPlayerForStartupAudioStall
}

struct PlaybackOutputHealthMonitor {
    static let stalledOutputThreshold: TimeInterval = 10
    // VLC statistics normally report audio-output progress at least every
    // half-second. During startup, allow three times that interval before
    // treating a short decoded burst followed by silence as a dead audio
    // output. Once cadence has held for three seconds, the normal watchdog is
    // deliberately more forgiving of transient steady-state interruptions.
    static let startupAudioStallThreshold: TimeInterval = 1.5
    static let startupAudioStabilityDuration: TimeInterval = 3

    private var previousOutput: PlaybackOutputCounters?
    private var lastProgressDate: Date?
    private var lastAudioProgressDate: Date?
    private var startupAudioProgressStartedAt: Date?
    private var hasStableStartupAudio = false
    private var wasExpectingAudio = false
    private var hasRequestedRecovery = false
    private var hasRequestedAudioRecovery = false

    mutating func observe(
        output: PlaybackOutputCounters,
        at date: Date,
        expectsOutput: Bool,
        hasFreshInput: Bool,
        expectsAudio: Bool = false
    ) -> PlaybackHealthAction {
        guard expectsOutput, hasFreshInput else {
            restartGracePeriod(output: output, at: date)
            return .none
        }

        guard let previousOutput else {
            restartGracePeriod(output: output, at: date)
            return .none
        }

        self.previousOutput = output
        let audioAdvanced = output.playedAudioBuffers > previousOutput.playedAudioBuffers
        let audioCounterReset = output.playedAudioBuffers < previousOutput.playedAudioBuffers
        var action = PlaybackHealthAction.none

        if output.hasAdvanced(since: previousOutput) {
            lastProgressDate = date
            hasRequestedRecovery = false
        } else if !hasRequestedRecovery,
                  date.timeIntervalSince(lastProgressDate ?? date)
                    >= Self.stalledOutputThreshold {
            hasRequestedRecovery = true
            action = .rebuildPlayer
        }

        if expectsAudio {
            if !wasExpectingAudio {
                // Give a newly discovered audio stream a full grace period, but
                // retain the existing deadline when audio has already started.
                if output.playedAudioBuffers == 0 {
                    lastAudioProgressDate = date
                }
                startupAudioProgressStartedAt = nil
                hasStableStartupAudio = false
                hasRequestedAudioRecovery = false
            }

            if audioAdvanced {
                lastAudioProgressDate = date
                hasRequestedAudioRecovery = false
                if let startupAudioProgressStartedAt,
                   date.timeIntervalSince(startupAudioProgressStartedAt)
                    >= Self.startupAudioStabilityDuration {
                    hasStableStartupAudio = true
                } else if startupAudioProgressStartedAt == nil {
                    startupAudioProgressStartedAt = date
                }
            } else if audioCounterReset {
                // VLC statistics can restart when its pipeline is rebuilt.
                // Keep expecting audio, but give the new counter a full grace
                // period before declaring it stalled.
                lastAudioProgressDate = date
                startupAudioProgressStartedAt = nil
                hasStableStartupAudio = false
                hasRequestedAudioRecovery = false
            }

            let audioStallThreshold = startupAudioProgressStartedAt != nil
                && !hasStableStartupAudio
                ? Self.startupAudioStallThreshold
                : Self.stalledOutputThreshold
            if !hasRequestedAudioRecovery,
               date.timeIntervalSince(lastAudioProgressDate ?? date)
                >= audioStallThreshold {
                hasRequestedAudioRecovery = true
                action = hasStableStartupAudio || startupAudioProgressStartedAt == nil
                    ? .rebuildPlayer
                    : .rebuildPlayerForStartupAudioStall
            }
        } else {
            lastAudioProgressDate = date
            startupAudioProgressStartedAt = nil
            hasStableStartupAudio = false
            hasRequestedAudioRecovery = false
        }
        wasExpectingAudio = expectsAudio

        return action
    }

    mutating func restartGracePeriod(
        output: PlaybackOutputCounters,
        at date: Date
    ) {
        previousOutput = output
        lastProgressDate = date
        lastAudioProgressDate = date
        startupAudioProgressStartedAt = nil
        hasStableStartupAudio = false
        wasExpectingAudio = false
        hasRequestedRecovery = false
        hasRequestedAudioRecovery = false
    }

    mutating func reset() {
        previousOutput = nil
        lastProgressDate = nil
        lastAudioProgressDate = nil
        startupAudioProgressStartedAt = nil
        hasStableStartupAudio = false
        wasExpectingAudio = false
        hasRequestedRecovery = false
        hasRequestedAudioRecovery = false
    }
}

struct LivePlaybackPositionTracker {
    private var pausedDate: Date?
    private var lastResumeOutput: PlaybackOutputCounters?
    private var lastOutputObservationDate: Date?
    private var highestPlaybackTimeMilliseconds: Int64?
    private var awaitingPlaybackProgress = false

    var hasAnchoredDate: Bool {
        pausedDate != nil
    }

    var isAwaitingPlaybackProgress: Bool {
        awaitingPlaybackProgress
    }

    mutating func pause(
        at date: Date,
        liveDelay: TimeInterval,
        bufferStartedAt: Date?
    ) {
        if pausedDate == nil {
            pausedDate = playbackDate(
                at: date,
                liveDelay: liveDelay,
                bufferStartedAt: bufferStartedAt
            )
        }
        lastResumeOutput = nil
        lastOutputObservationDate = nil
        highestPlaybackTimeMilliseconds = nil
        awaitingPlaybackProgress = false
    }

    mutating func moveAnchor(
        by seconds: TimeInterval,
        at liveEdge: Date,
        bufferStartedAt: Date?
    ) {
        guard let pausedDate else { return }
        let lowerBound = bufferStartedAt ?? .distantPast
        self.pausedDate = min(max(pausedDate.addingTimeInterval(seconds), lowerBound), liveEdge)
        lastResumeOutput = nil
        lastOutputObservationDate = nil
        highestPlaybackTimeMilliseconds = nil
        awaitingPlaybackProgress = false
    }

    mutating func moveAnchor(
        to playbackDate: Date,
        liveEdge: Date,
        bufferStartedAt: Date?
    ) {
        let lowerBound = bufferStartedAt ?? .distantPast
        pausedDate = min(max(playbackDate, lowerBound), liveEdge)
        lastResumeOutput = nil
        lastOutputObservationDate = nil
        highestPlaybackTimeMilliseconds = nil
        awaitingPlaybackProgress = false
    }

    mutating func moveAnchorToLive(at liveEdge: Date) {
        guard pausedDate != nil else { return }
        pausedDate = liveEdge
        lastResumeOutput = nil
        lastOutputObservationDate = nil
        highestPlaybackTimeMilliseconds = nil
        awaitingPlaybackProgress = false
    }

    mutating func recoverAtLiveEdge(_ liveEdge: Date) {
        pausedDate = liveEdge
        lastResumeOutput = nil
        lastOutputObservationDate = nil
        highestPlaybackTimeMilliseconds = nil
        awaitingPlaybackProgress = false
    }

    @discardableResult
    mutating func requestResume(from output: PlaybackOutputCounters) -> Bool {
        guard pausedDate != nil else { return false }
        lastResumeOutput = output
        lastOutputObservationDate = nil
        highestPlaybackTimeMilliseconds = output.playbackTimeMilliseconds
        awaitingPlaybackProgress = true
        return true
    }

    @discardableResult
    mutating func observePlaybackOutput(
        _ output: PlaybackOutputCounters,
        at date: Date = Date()
    ) -> Bool {
        guard let previous = lastResumeOutput else { return false }
        let observationInterval = lastOutputObservationDate.map {
            max(0, date.timeIntervalSince($0))
        } ?? 0
        lastResumeOutput = output

        let outputAdvanced: Bool
        let playbackProgress: TimeInterval?
        if let playbackTime = output.playbackTimeMilliseconds {
            if let highestPlaybackTimeMilliseconds {
                if playbackTime < highestPlaybackTimeMilliseconds - 1_000 {
                    // A seek can reset VLC's media clock. Establish the new
                    // baseline. If this is the first accepted output after a
                    // resume, its advancing presentation counters prove that
                    // playback reached the new epoch and can release the
                    // timeline anchor immediately.
                    self.highestPlaybackTimeMilliseconds = playbackTime
                    if awaitingPlaybackProgress,
                       output.hasAdvanced(since: previous) {
                        lastOutputObservationDate = date
                        awaitingPlaybackProgress = false
                        return true
                    }
                    return false
                }
                outputAdvanced = playbackTime > highestPlaybackTimeMilliseconds
                playbackProgress = outputAdvanced
                    ? TimeInterval(playbackTime - highestPlaybackTimeMilliseconds) / 1_000
                    : nil
                self.highestPlaybackTimeMilliseconds = max(
                    playbackTime,
                    highestPlaybackTimeMilliseconds
                )
            } else {
                highestPlaybackTimeMilliseconds = playbackTime
                outputAdvanced = output.hasAdvanced(since: previous)
                playbackProgress = nil
            }
        } else {
            outputAdvanced = output.hasAdvanced(since: previous)
            playbackProgress = nil
        }

        guard outputAdvanced else { return false }
        lastOutputObservationDate = date
        if awaitingPlaybackProgress {
            awaitingPlaybackProgress = false
        } else if let pausedDate {
            // Prefer VLC's media-clock delta because that clock can update
            // less frequently than this tracker is sampled. Advancing by only
            // the most recent sampling interval made the programme timeline
            // steadily fall behind during otherwise uninterrupted playback.
            // A replaced stream can also jump VLC's media clock forward by
            // minutes or hours. Treat a delta larger than plausible wall-clock
            // progress as a new clock epoch instead of moving the programme
            // timeline into the future.
            let maximumPlausibleProgress = max(1, observationInterval * 2)
            let boundedProgress = playbackProgress.flatMap { progress in
                progress <= maximumPlausibleProgress ? progress : nil
            }
            self.pausedDate = pausedDate.addingTimeInterval(
                boundedProgress ?? min(1, observationInterval)
            )
        }
        return true
    }

    mutating func reset() {
        pausedDate = nil
        lastResumeOutput = nil
        lastOutputObservationDate = nil
        highestPlaybackTimeMilliseconds = nil
        awaitingPlaybackProgress = false
    }

    func playbackDate(
        at date: Date,
        liveDelay: TimeInterval,
        bufferStartedAt: Date?
    ) -> Date {
        let calculatedDate = pausedDate
            ?? date.addingTimeInterval(-max(0, liveDelay))
        return min(max(calculatedDate, bufferStartedAt ?? .distantPast), date)
    }
}

struct HTSPTimeshiftMetrics: Equatable {
    let liveDelay: TimeInterval
    let window: TimeInterval
    let startTime: Int64?
    let endTime: Int64?

    var playheadTime: Int64? {
        guard let endTime else { return nil }
        return endTime - Int64((liveDelay * 1_000_000).rounded())
    }

    static func decode(from message: [String: HTSPValue]) -> HTSPTimeshiftMetrics {
        let liveDelay = abs(TimeInterval(message["shift"]?.intValue ?? 0) / 1_000_000)
        let window: TimeInterval
        if let start = message["start"]?.intValue,
           let end = message["end"]?.intValue {
            window = max(0, TimeInterval(end - start) / 1_000_000)
        } else {
            window = 0
        }
        return HTSPTimeshiftMetrics(
            liveDelay: liveDelay,
            window: window,
            startTime: message["start"]?.intValue,
            endTime: message["end"]?.intValue
        )
    }
}

struct HTSPNavigationResult: Equatable, Sendable {
    let landingTime: Int64
    let serverLandingTime: Int64
    let bufferStartTime: Int64?
    let liveEdgeTime: Int64?

    init(
        landingTime: Int64,
        serverLandingTime: Int64? = nil,
        bufferStartTime: Int64?,
        liveEdgeTime: Int64?
    ) {
        self.landingTime = landingTime
        self.serverLandingTime = serverLandingTime ?? landingTime
        self.bufferStartTime = bufferStartTime
        self.liveEdgeTime = liveEdgeTime
    }

    var prerollDuration: TimeInterval {
        max(0, TimeInterval(landingTime - serverLandingTime) / 1_000_000)
    }

    var liveDelay: TimeInterval {
        guard let liveEdgeTime else { return 0 }
        return max(0, TimeInterval(liveEdgeTime - landingTime) / 1_000_000)
    }

}

enum HTSPNavigationError: LocalizedError, Equatable, Sendable {
    case rejected
    case timedOut
    case invalidResponse
    case controlFailed(String)

    var errorDescription: String? {
        switch self {
        case .rejected: "TVHeadend rejected the timeshift seek."
        case .timedOut: "TVHeadend did not finish the timeshift seek in time."
        case .invalidResponse: "TVHeadend returned an invalid timeshift position."
        case let .controlFailed(message): "TVHeadend timeshift control failed: \(message)"
        }
    }
}

enum HTSPSeekCompletion: Equatable {
    case seek(Int64)
    case buffer(HTSPNavigationResult)
}

struct HTSPAbsoluteSeekCoordinator {
    static let landingTolerance: Int64 = 250_000
    static let initialEarlierSeekBackoff: Int64 = 1_000_000

    private(set) var inFlightTarget: Int64?
    private(set) var desiredTarget: Int64?
    private(set) var currentTime: Int64?
    private(set) var bufferStartTime: Int64?
    private(set) var liveEdgeTime: Int64?
    private var pendingRelativeDelta: Int64 = 0
    private var pendingLiveEdge = false
    private var earlierSeekBackoff = Self.initialEarlierSeekBackoff
    private var earlierCorrectionInFlight = false

    var isTargetingLiveEdge: Bool {
        if pendingLiveEdge { return true }
        guard let liveEdgeTime,
              let target = desiredTarget ?? inFlightTarget else { return false }
        return target >= liveEdgeTime - Self.landingTolerance
    }

    mutating func update(
        metrics: HTSPTimeshiftMetrics,
        updateCurrentPosition: Bool
    ) -> Int64? {
        bufferStartTime = metrics.startTime
        liveEdgeTime = metrics.endTime

        if updateCurrentPosition, let playheadTime = metrics.playheadTime {
            currentTime = clamp(playheadTime)
            if inFlightTarget == nil { desiredTarget = currentTime }
        }

        if pendingLiveEdge, let liveEdgeTime {
            desiredTarget = liveEdgeTime
            pendingLiveEdge = false
            return startIfPossible()
        } else if pendingRelativeDelta != 0,
                  let base = desiredTarget ?? inFlightTarget ?? currentTime ?? metrics.playheadTime {
            desiredTarget = clamp(base + pendingRelativeDelta)
            pendingRelativeDelta = 0
            return startIfPossible()
        }
        return nil
    }

    mutating func requestRelative(seconds: TimeInterval) -> Int64? {
        let delta = Int64((seconds * 1_000_000).rounded())
        guard delta != 0 else { return nil }
        pendingLiveEdge = false

        if let base = desiredTarget ?? inFlightTarget ?? currentTime {
            desiredTarget = clamp(base + delta)
        } else {
            pendingRelativeDelta += delta
        }
        return startIfPossible()
    }

    mutating func requestLiveEdge() -> Int64? {
        pendingRelativeDelta = 0
        pendingLiveEdge = true
        guard let liveEdgeTime else { return nil }
        desiredTarget = liveEdgeTime
        pendingLiveEdge = false
        return startIfPossible()
    }

    mutating func complete(
        landingTime: Int64,
        acceptsLiveEdgeLanding: Bool = false
    ) -> HTSPSeekCompletion {
        let satisfiedLiveEdge = acceptsLiveEdgeLanding && isTargetingLiveEdge
        let serverLandingTime = clamp(landingTime)
        let completedRequestTarget = inFlightTarget
        let completedEarlierCorrection = earlierCorrectionInFlight
        inFlightTarget = nil
        earlierCorrectionInFlight = false
        pendingLiveEdge = false

        if !satisfiedLiveEdge,
           !completedEarlierCorrection,
           let desiredTarget,
           completedRequestTarget != desiredTarget {
            inFlightTarget = desiredTarget
            return .seek(desiredTarget)
        }

        if !satisfiedLiveEdge,
           let desiredTarget,
           serverLandingTime > desiredTarget + Self.landingTolerance {
            let earlierTarget = clamp(desiredTarget - earlierSeekBackoff)
            if earlierTarget < desiredTarget {
                earlierSeekBackoff = min(earlierSeekBackoff, Int64.max / 2) * 2
                inFlightTarget = earlierTarget
                earlierCorrectionInFlight = true
                return .seek(earlierTarget)
            }
        }

        let exactLandingTime = satisfiedLiveEdge
            ? serverLandingTime
            : clamp(desiredTarget ?? serverLandingTime)
        currentTime = exactLandingTime
        desiredTarget = exactLandingTime
        earlierSeekBackoff = Self.initialEarlierSeekBackoff
        earlierCorrectionInFlight = false
        return .buffer(
            HTSPNavigationResult(
                landingTime: exactLandingTime,
                serverLandingTime: serverLandingTime,
                bufferStartTime: bufferStartTime,
                liveEdgeTime: liveEdgeTime
            )
        )
    }

    mutating func fail() {
        inFlightTarget = nil
        desiredTarget = currentTime
        pendingRelativeDelta = 0
        pendingLiveEdge = false
        earlierSeekBackoff = Self.initialEarlierSeekBackoff
        earlierCorrectionInFlight = false
    }

    private mutating func startIfPossible() -> Int64? {
        guard inFlightTarget == nil, let desiredTarget else { return nil }
        let target = clamp(desiredTarget)
        inFlightTarget = target
        return target
    }

    private func clamp(_ time: Int64) -> Int64 {
        min(max(time, bufferStartTime ?? time), liveEdgeTime ?? time)
    }
}

struct HTSPSubscriptionSpeedController {
    private(set) var desiredSpeed: Int32
    private(set) var actualSpeed: Int32
    private(set) var outstandingSpeed: Int32?

    init(desiredSpeed: Int32 = 100, actualSpeed: Int32 = 100, outstandingSpeed: Int32? = nil) {
        self.desiredSpeed = desiredSpeed
        self.actualSpeed = actualSpeed
        self.outstandingSpeed = outstandingSpeed
    }

    mutating func request(_ speed: Int32) -> Int32? {
        desiredSpeed = speed
        return nextCommandIfReady()
    }

    mutating func observeActual(_ speed: Int32) -> Int32? {
        actualSpeed = speed
        if outstandingSpeed == speed { outstandingSpeed = nil }
        return nextCommandIfReady()
    }

    mutating func commandSucceeded(_ speed: Int32) -> Int32? {
        guard outstandingSpeed == speed else { return nil }
        actualSpeed = speed
        outstandingSpeed = nil
        return nextCommandIfReady()
    }

    mutating func commandFailed(_ speed: Int32) -> Int32? {
        guard outstandingSpeed == speed else { return nil }
        outstandingSpeed = nil
        if desiredSpeed == speed { desiredSpeed = actualSpeed }
        return nextCommandIfReady()
    }

    mutating func expectServerSpeed(_ speed: Int32) {
        desiredSpeed = speed
    }

    private mutating func nextCommandIfReady() -> Int32? {
        guard outstandingSpeed == nil, actualSpeed != desiredSpeed else { return nil }
        outstandingSpeed = desiredSpeed
        return desiredSpeed
    }
}

enum HTSPSeekStartPolicy {
    static func canSendSeek(
        actualSpeed: Int32,
        outstandingSpeed: Int32?
    ) -> Bool {
        actualSpeed == 0 && outstandingSpeed == nil
    }
}

enum HTSPNavigationRecoveryPolicy {
    static func shouldRetryWithLiveCommand(
        acceptsLiveEdge: Bool,
        targetsLiveEdge: Bool
    ) -> Bool {
        targetsLiveEdge && !acceptsLiveEdge
    }
}

struct HTSPPostSeekBufferTracker {
    static let minimumRequiredDuration: Int64 = 500_000
    static let audioLeadTolerance: Int64 = 100_000
    private(set) var result: HTSPNavigationResult?
    private var requiredDuration = Self.minimumRequiredDuration
    private var waitsForVideoKeyframe = false
    private var requiredAudioStreamIndexes: Set<Int> = []
    private var firstAcceptedVideoTime: Int64?
    private var droppedLeadingAudioPacketCount = 0
    private var firstTime: Int64?
    private var latestTime: Int64?
    private var videoPacketCount = 0
    private var audioPacketCount = 0
    private var videoFrameCounts: [UInt8: Int] = [:]
    private var firstVideoTime: Int64?
    private var latestVideoTime: Int64?
    private var latestVideoDecodeTime: Int64?
    private var firstAudioTime: Int64?
    private var latestAudioTime: Int64?
    private var firstAudioTimes: [Int: Int64] = [:]
    private var latestAudioEndTimes: [Int: Int64] = [:]
    private(set) var completionDiagnostics: String?
    private var anchorsInitialTuneToFirstPlayablePacket = false
    private var initialTuneHasVideo = false
    private var isInitialTune = false
    private var acceptedAudioLeadTolerance = Self.audioLeadTolerance

    var isActive: Bool { result != nil }

    /// Describes the current, potentially incomplete A/V horizon. This is
    /// intentionally available before completion so a bounded staging
    /// fallback does not hide which stream missed its timestamp target.
    var progressDiagnostics: String {
        guard let result else { return "coverage inactive" }
        let anchor = firstAcceptedVideoTime ?? result.landingTime
        let targetAddition = anchor.addingReportingOverflow(requiredDuration)
        let target = targetAddition.overflow ? Int64.max : targetAddition.partialValue
        let relative: (Int64?) -> String = { value in
            guard let value else { return "n/a" }
            return String(format: "%.0fms", Double(value - anchor) / 1_000)
        }
        let audioCoverage = requiredAudioStreamIndexes.sorted().map { streamIndex in
            "\(streamIndex):\(relative(latestAudioEndTimes[streamIndex]))"
        }.joined(separator: ",")
        let missingVideo = firstAcceptedVideoTime != nil
            && latestVideoDecodeTime.map { $0 < target } != false
        let missingAudio = requiredAudioStreamIndexes.filter { streamIndex in
            latestAudioEndTimes[streamIndex].map { $0 < target } != false
        }.sorted()
        return "coverage pending required=\(requiredDuration / 1_000)ms"
            + " video=\(relative(latestVideoDecodeTime))"
            + " audio=[\(audioCoverage)]"
            + " missingVideo=\(missingVideo) missingAudio=\(missingAudio)"
    }

    mutating func begin(
        _ result: HTSPNavigationResult,
        hasVideo: Bool,
        audioStreamIndexes: Set<Int> = [],
        requiredDuration: Int64 = Self.minimumRequiredDuration
    ) {
        self.result = result
        self.requiredDuration = max(Self.minimumRequiredDuration, requiredDuration)
        waitsForVideoKeyframe = hasVideo
        requiredAudioStreamIndexes = audioStreamIndexes
        firstAcceptedVideoTime = nil
        droppedLeadingAudioPacketCount = 0
        firstTime = nil
        latestTime = nil
        videoPacketCount = 0
        audioPacketCount = 0
        videoFrameCounts.removeAll(keepingCapacity: true)
        firstVideoTime = nil
        latestVideoTime = nil
        latestVideoDecodeTime = nil
        firstAudioTime = nil
        latestAudioTime = nil
        firstAudioTimes.removeAll(keepingCapacity: true)
        latestAudioEndTimes.removeAll(keepingCapacity: true)
        completionDiagnostics = nil
        anchorsInitialTuneToFirstPlayablePacket = false
        initialTuneHasVideo = false
        isInitialTune = false
        acceptedAudioLeadTolerance = Self.audioLeadTolerance
    }

    mutating func beginInitialTune(
        hasVideo: Bool,
        audioStreamIndexes: Set<Int> = [],
        requiredDuration: Int64 = Self.minimumRequiredDuration,
        audioLeadTolerance: Int64 = 0
    ) {
        begin(
            HTSPNavigationResult(
                landingTime: 0,
                bufferStartTime: nil,
                liveEdgeTime: nil
            ),
            hasVideo: hasVideo,
            audioStreamIndexes: audioStreamIndexes,
            requiredDuration: requiredDuration
        )
        anchorsInitialTuneToFirstPlayablePacket = true
        initialTuneHasVideo = hasVideo
        isInitialTune = true
        acceptedAudioLeadTolerance = max(0, audioLeadTolerance)
    }

    mutating func cancel() {
        result = nil
        requiredDuration = Self.minimumRequiredDuration
        waitsForVideoKeyframe = false
        requiredAudioStreamIndexes.removeAll(keepingCapacity: true)
        firstAcceptedVideoTime = nil
        firstAudioTimes.removeAll(keepingCapacity: true)
        latestAudioEndTimes.removeAll(keepingCapacity: true)
        firstTime = nil
        latestTime = nil
        latestVideoDecodeTime = nil
        anchorsInitialTuneToFirstPlayablePacket = false
        initialTuneHasVideo = false
        isInitialTune = false
        acceptedAudioLeadTolerance = Self.audioLeadTolerance
    }

    mutating func shouldAcceptPacket(
        time: Int64? = nil,
        decodeTime: Int64? = nil,
        duration: Int64? = nil,
        isVideo: Bool,
        isAudio: Bool = false,
        frameType: UInt8
    ) -> Bool {
        guard result != nil else { return true }
        if waitsForVideoKeyframe {
            guard isVideo, frameType == Character("I").asciiValue else {
                if isAudio { droppedLeadingAudioPacketCount += 1 }
                return false
            }
            waitsForVideoKeyframe = false
            // MPEG-TS starts its PCR epoch from video DTS. H.264 open GOPs can
            // put the I-frame PTS more than a second later because following
            // B-frames are displayed first. Anchor audio to that DTS/PCR, not
            // to the I-frame PTS, or those B-frames lose their matching audio.
            firstAcceptedVideoTime = decodeTime ?? time
            anchorInitialTuneIfNeeded(at: firstAcceptedVideoTime)
            return true
        }
        guard !requiredAudioStreamIndexes.isEmpty, isAudio else { return true }
        guard let time else { return true }
        guard let videoTime = firstAcceptedVideoTime else {
            // A timestamp-less keyframe prevents a meaningful comparison.
            return true
        }
        let subtraction = videoTime.subtractingReportingOverflow(acceptedAudioLeadTolerance)
        let earliestAcceptedAudioTime = subtraction.overflow
            ? Int64.min
            : subtraction.partialValue
        if time >= earliestAcceptedAudioTime {
            return true
        }
        guard let duration, duration >= 0 else {
            // Initial tuning has to reject a clearly old, timestamped audio
            // backlog even when TVHeadend omitted the access-unit duration.
            // Keep a small inferred-duration window so a packet immediately
            // preceding the video DTS can still overlap the retained GOP.
            guard isInitialTune else { return true }
            let inferredEarliestTime = earliestAcceptedAudioTime.subtractingReportingOverflow(
                Self.audioLeadTolerance
            )
            let minimumInferredTime = inferredEarliestTime.overflow
                ? Int64.min
                : inferredEarliestTime.partialValue
            guard time < minimumInferredTime else { return true }
            droppedLeadingAudioPacketCount += 1
            return false
        }
        let addition = time.addingReportingOverflow(duration)
        guard !addition.overflow else { return true }
        guard addition.partialValue >= earliestAcceptedAudioTime else {
            droppedLeadingAudioPacketCount += 1
            return false
        }
        return true
    }

    mutating func observePacket(time: Int64?) -> HTSPNavigationResult? {
        observePacket(
            time: time,
            decodeTime: nil,
            duration: nil,
            streamIndex: 0,
            isVideo: false,
            isAudio: false,
            frameType: 0
        )
    }

    mutating func observePacket(
        time: Int64?,
        decodeTime: Int64? = nil,
        duration: Int64? = nil,
        streamIndex: Int = 0,
        isVideo: Bool,
        isAudio: Bool,
        frameType: UInt8
    ) -> HTSPNavigationResult? {
        if anchorsInitialTuneToFirstPlayablePacket,
           initialTuneHasVideo
                ? isVideo
                : isAudio && (requiredAudioStreamIndexes.isEmpty
                    || requiredAudioStreamIndexes.contains(streamIndex)) {
            anchorInitialTuneIfNeeded(at: isVideo ? (decodeTime ?? time) : time)
        }
        guard let result else { return nil }
        if let time {
            firstTime = min(firstTime ?? time, time)
            latestTime = max(latestTime ?? time, time)
            if isVideo {
                firstVideoTime = min(firstVideoTime ?? time, time)
                latestVideoTime = max(latestVideoTime ?? time, time)
            } else if isAudio {
                firstAudioTime = min(firstAudioTime ?? time, time)
                latestAudioTime = max(latestAudioTime ?? time, time)
                firstAudioTimes[streamIndex] = min(
                    firstAudioTimes[streamIndex] ?? time,
                    time
                )
                let endTime: Int64
                if let duration, duration >= 0 {
                    let addition = time.addingReportingOverflow(duration)
                    endTime = addition.overflow ? time : addition.partialValue
                } else {
                    endTime = time
                }
                latestAudioEndTimes[streamIndex] = max(
                    latestAudioEndTimes[streamIndex] ?? endTime,
                    endTime
                )
            }
        }
        if isVideo, let videoDecodeTime = decodeTime ?? time {
            latestVideoDecodeTime = max(latestVideoDecodeTime ?? videoDecodeTime, videoDecodeTime)
        }
        if isVideo {
            videoPacketCount += 1
            videoFrameCounts[frameType, default: 0] += 1
        } else if isAudio {
            audioPacketCount += 1
        }
        // An initial stream with no usable timestamp cannot prove that it has
        // accumulated a safe A/V horizon. Its owner applies a bounded payload
        // fallback instead of releasing an arbitrarily small preroll here.
        guard !anchorsInitialTuneToFirstPlayablePacket else { return nil }
        let bufferedDuration = max(0, (latestTime ?? 0) - (firstTime ?? 0))
        if let firstAcceptedVideoTime {
            // The decoder consumes everything between the preceding keyframe
            // and the requested position while output is concealed. Keep the
            // requested reserve *after* that preroll, or a long GOP can leave
            // CoreAudio with only VLC's small callback-input cushion when the
            // destination is finally revealed.
            let reserveStart = max(firstAcceptedVideoTime, result.landingTime)
            let addition = reserveStart.addingReportingOverflow(requiredDuration)
            let minimumBufferedEnd = addition.overflow
                ? Int64.max
                : addition.partialValue
            guard latestVideoDecodeTime.map({ $0 >= minimumBufferedEnd }) == true,
                  requiredAudioStreamIndexes.allSatisfy({ streamIndex in
                      latestAudioEndTimes[streamIndex].map { $0 >= minimumBufferedEnd } == true
                  })
            else { return nil }
        } else if !requiredAudioStreamIndexes.isEmpty {
            let addition = result.landingTime.addingReportingOverflow(requiredDuration)
            let minimumBufferedEnd = addition.overflow
                ? Int64.max
                : addition.partialValue
            guard requiredAudioStreamIndexes.allSatisfy({ streamIndex in
                latestAudioEndTimes[streamIndex].map { $0 >= minimumBufferedEnd } == true
            }) else { return nil }
        } else {
            let addition = result.landingTime.addingReportingOverflow(requiredDuration)
            let minimumBufferedEnd = addition.overflow
                ? Int64.max
                : addition.partialValue
            guard latestTime.map({ $0 >= minimumBufferedEnd }) == true else { return nil }
        }
        let span: (Int64?, Int64?) -> String = { first, latest in
            guard let first, let latest else { return "n/a" }
            return String(format: "%.0fms", Double(max(0, latest - first)) / 1_000)
        }
        let iFrameCount = videoFrameCounts[0x49] ?? 0
        let pFrameCount = videoFrameCounts[0x50] ?? 0
        let bFrameCount = videoFrameCounts[0x42] ?? 0
        let firstAVDelta = firstAcceptedVideoTime.flatMap { video in
            firstAudioTime.map { audio in Double(audio - video) / 1_000 }
        }.map { String(format: "%.0fms", $0) } ?? "n/a"
        let audioCoverage = requiredAudioStreamIndexes.sorted().map { streamIndex in
            guard let anchor = firstAcceptedVideoTime,
                  let first = firstAudioTimes[streamIndex],
                  let end = latestAudioEndTimes[streamIndex]
            else { return "\(streamIndex):n/a" }
            return String(
                format: "%d:%.0f…%.0fms",
                streamIndex,
                Double(first - anchor) / 1_000,
                Double(end - anchor) / 1_000
            )
        }.joined(separator: ",")
        let postTargetAudioReserve = requiredAudioStreamIndexes.sorted().map { streamIndex in
            guard let end = latestAudioEndTimes[streamIndex] else {
                return "\(streamIndex):n/a"
            }
            return String(
                format: "%d:%.0fms",
                streamIndex,
                Double(end - result.landingTime) / 1_000
            )
        }.joined(separator: ",")
        let audioTailLag = latestVideoDecodeTime.flatMap { videoEnd in
            requiredAudioStreamIndexes.compactMap { latestAudioEndTimes[$0] }.min().map {
                max(0, videoEnd - $0)
            }
        }.map { String(format: "%.0fms", Double($0) / 1_000) } ?? "n/a"
        completionDiagnostics = "video=\(videoPacketCount)"
            + "(I\(iFrameCount)/P\(pFrameCount)/B\(bFrameCount))"
            + " span=\(span(firstVideoTime, latestVideoTime))"
            + " audio=\(audioPacketCount) span=\(span(firstAudioTime, latestAudioTime))"
            + " coverage=[\(audioCoverage)]"
            + " postTarget=[\(postTargetAudioReserve)]"
            + " audioTailLag=\(audioTailLag)"
            + " firstAV=\(firstAVDelta) droppedAudio=\(droppedLeadingAudioPacketCount)"
            + " total=\(Double(bufferedDuration) / 1_000)ms"
        cancel()
        return result
    }

    private mutating func anchorInitialTuneIfNeeded(at time: Int64?) {
        guard anchorsInitialTuneToFirstPlayablePacket, let time else { return }
        result = HTSPNavigationResult(
            landingTime: time,
            bufferStartTime: nil,
            liveEdgeTime: nil
        )
        anchorsInitialTuneToFirstPlayablePacket = false
    }
}

final class HTSPTimeshiftDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var navigating = false

    var shouldDeliverPackets: Bool {
        lock.withLock { !navigating }
    }

    func beginNavigation() {
        lock.withLock { navigating = true }
    }

    func completeNavigation() {
        lock.withLock { navigating = false }
    }

    func cancelAllNavigation() {
        lock.withLock { navigating = false }
    }
}
