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

    init(
        displayedPictures: Int,
        playedAudioBuffers: Int,
        demuxDiscontinuities: Int = 0,
        playbackTimeMilliseconds: Int64? = nil
    ) {
        self.displayedPictures = displayedPictures
        self.playedAudioBuffers = playedAudioBuffers
        self.demuxDiscontinuities = demuxDiscontinuities
        self.playbackTimeMilliseconds = playbackTimeMilliseconds
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
struct PostSeekPlaybackOutputGate {
    private static let fallbackPlaybackProgressMilliseconds: Int64 = 500
    private static let fallbackVideoPictures = 3
    private static let fallbackAudioBuffers = 12

    private(set) var isArmed = false
    private(set) var isConcealing = false
    private var baselineDiscontinuities = 0
    private var minimumPlaybackProgressMilliseconds: Int64 = 0
    private var outputAtConcealment: PlaybackOutputCounters?
    private var outputAfterDiscontinuity: PlaybackOutputCounters?

    mutating func arm(from output: PlaybackOutputCounters) {
        isArmed = true
        isConcealing = false
        baselineDiscontinuities = output.demuxDiscontinuities
        outputAtConcealment = nil
        outputAfterDiscontinuity = nil
    }

    mutating func requirePlaybackProgress(_ duration: TimeInterval) {
        minimumPlaybackProgressMilliseconds = Int64(
            (max(0, duration) * 1_000).rounded(.up)
        )
    }

    @discardableResult
    mutating func beginConcealing(from output: PlaybackOutputCounters) -> Bool {
        guard isArmed else { return false }
        isConcealing = true
        outputAtConcealment = output
        if hasObservedDiscontinuity(in: output) {
            // The demuxer may consume the marker while VLC is paused. In that
            // case presentation still needs to advance after playback starts.
            outputAfterDiscontinuity = output
        }
        return true
    }

    /// Returns true once output can safely be revealed.
    mutating func observe(_ output: PlaybackOutputCounters) -> Bool {
        guard isArmed else { return false }

        if output.demuxDiscontinuities < baselineDiscontinuities {
            // VLC statistics restart if the media pipeline is recreated.
            baselineDiscontinuities = 0
            outputAfterDiscontinuity = nil
        }
        guard hasObservedDiscontinuity(in: output) else {
            guard isConcealing,
                  hasSustainedPlaybackProgressWithoutDiscontinuity(in: output)
            else { return false }

            // VLC does not reliably increment the demux discontinuity
            // statistic for every marker in a long-running transport stream.
            // Navigation has already completed before concealment begins, so
            // sustained clock and presentation progress after local resume is
            // a safe fallback signal that its queued pre-seek output is gone.
            reset()
            return true
        }

        guard let outputAfterDiscontinuity else {
            self.outputAfterDiscontinuity = output
            return false
        }
        guard isConcealing,
              hasReachedMinimumPlaybackProgress(in: output),
              output.hasAdvanced(since: outputAfterDiscontinuity)
        else { return false }

        reset()
        return true
    }

    @discardableResult
    mutating func suspendConcealing() -> Bool {
        let wasConcealing = isConcealing
        isConcealing = false
        outputAtConcealment = nil
        outputAfterDiscontinuity = nil
        return wasConcealing
    }

    @discardableResult
    mutating func cancel() -> Bool {
        let wasConcealing = isConcealing
        reset()
        return wasConcealing
    }

    private func hasObservedDiscontinuity(in output: PlaybackOutputCounters) -> Bool {
        output.demuxDiscontinuities > baselineDiscontinuities
    }

    private func hasSustainedPlaybackProgressWithoutDiscontinuity(
        in output: PlaybackOutputCounters
    ) -> Bool {
        guard let baseline = outputAtConcealment,
              let baselineTime = baseline.playbackTimeMilliseconds,
              let outputTime = output.playbackTimeMilliseconds,
              abs(outputTime - baselineTime) >= max(
                  Self.fallbackPlaybackProgressMilliseconds,
                  minimumPlaybackProgressMilliseconds
              )
        else { return false }

        if baseline.displayedPictures > 0 {
            return output.displayedPictures - baseline.displayedPictures
                >= Self.fallbackVideoPictures
        }
        return output.playedAudioBuffers - baseline.playedAudioBuffers
            >= Self.fallbackAudioBuffers
    }

    private func hasReachedMinimumPlaybackProgress(
        in output: PlaybackOutputCounters
    ) -> Bool {
        guard minimumPlaybackProgressMilliseconds > 0 else { return true }
        guard let baselineTime = outputAtConcealment?.playbackTimeMilliseconds,
              let outputTime = output.playbackTimeMilliseconds
        else { return false }
        return abs(outputTime - baselineTime) >= minimumPlaybackProgressMilliseconds
    }

    private mutating func reset() {
        isArmed = false
        isConcealing = false
        baselineDiscontinuities = 0
        minimumPlaybackProgressMilliseconds = 0
        outputAtConcealment = nil
        outputAfterDiscontinuity = nil
    }
}

enum PlaybackHealthAction: Equatable {
    case none
    case rebuildPlayer
}

struct PlaybackOutputHealthMonitor {
    static let stalledOutputThreshold: TimeInterval = 10

    private var previousOutput: PlaybackOutputCounters?
    private var lastProgressDate: Date?
    private var lastAudioProgressDate: Date?
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
                hasRequestedAudioRecovery = false
            } else if audioAdvanced {
                lastAudioProgressDate = date
                hasRequestedAudioRecovery = false
            } else if audioCounterReset {
                // VLC statistics can restart when its pipeline is rebuilt.
                // Keep expecting audio, but give the new counter a full grace
                // period before declaring it stalled.
                lastAudioProgressDate = date
                hasRequestedAudioRecovery = false
            }

            if !hasRequestedAudioRecovery,
               date.timeIntervalSince(lastAudioProgressDate ?? date)
                >= Self.stalledOutputThreshold {
                hasRequestedAudioRecovery = true
                action = .rebuildPlayer
            }
        } else {
            lastAudioProgressDate = date
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
        wasExpectingAudio = false
        hasRequestedRecovery = false
        hasRequestedAudioRecovery = false
    }

    mutating func reset() {
        previousOutput = nil
        lastProgressDate = nil
        lastAudioProgressDate = nil
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
        lastOutputObservationDate = date
        lastResumeOutput = output

        let outputAdvanced: Bool
        if let playbackTime = output.playbackTimeMilliseconds {
            if let highestPlaybackTimeMilliseconds {
                if playbackTime < highestPlaybackTimeMilliseconds - 1_000 {
                    // A seek can reset VLC's media clock. Establish the new
                    // baseline without treating the reset as presented media.
                    self.highestPlaybackTimeMilliseconds = playbackTime
                    return false
                }
                outputAdvanced = playbackTime > highestPlaybackTimeMilliseconds
                self.highestPlaybackTimeMilliseconds = max(
                    playbackTime,
                    highestPlaybackTimeMilliseconds
                )
            } else {
                highestPlaybackTimeMilliseconds = playbackTime
                outputAdvanced = false
            }
        } else {
            outputAdvanced = output.hasAdvanced(since: previous)
        }

        guard outputAdvanced else { return false }
        if awaitingPlaybackProgress {
            awaitingPlaybackProgress = false
        } else if let pausedDate {
            // Advance only by time observed between two genuinely newer VLC
            // presentation samples. This freezes the marker during stalls and
            // ignores small backwards/forwards media-clock flaps.
            self.pausedDate = pausedDate.addingTimeInterval(min(1, observationInterval))
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
        return max(calculatedDate, bufferStartedAt ?? .distantPast)
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

        if !satisfiedLiveEdge, let desiredTarget, serverLandingTime > desiredTarget {
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
    static let requiredDuration: Int64 = 1_000_000
    static let packetFallbackCount = 48

    private(set) var result: HTSPNavigationResult?
    private var waitsForVideoKeyframe = false
    private var firstTime: Int64?
    private var latestTime: Int64?
    private var packetCount = 0

    mutating func begin(_ result: HTSPNavigationResult, hasVideo: Bool) {
        self.result = result
        waitsForVideoKeyframe = hasVideo
        firstTime = nil
        latestTime = nil
        packetCount = 0
    }

    mutating func cancel() {
        result = nil
        waitsForVideoKeyframe = false
        firstTime = nil
        latestTime = nil
        packetCount = 0
    }

    mutating func shouldAcceptPacket(isVideo: Bool, frameType: UInt8) -> Bool {
        guard result != nil else { return true }
        guard waitsForVideoKeyframe else { return true }
        guard isVideo, frameType == Character("I").asciiValue else { return false }
        waitsForVideoKeyframe = false
        return true
    }

    mutating func observePacket(time: Int64?) -> HTSPNavigationResult? {
        guard let result else { return nil }
        packetCount += 1
        if let time {
            firstTime = firstTime ?? time
            latestTime = max(latestTime ?? time, time)
        }
        let bufferedDuration = max(0, (latestTime ?? 0) - (firstTime ?? 0))
        let reachedExactLanding = latestTime.map { $0 >= result.landingTime } ?? false
        guard (bufferedDuration >= Self.requiredDuration && reachedExactLanding)
                || (latestTime == nil && packetCount >= Self.packetFallbackCount)
        else { return nil }
        cancel()
        return result
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
