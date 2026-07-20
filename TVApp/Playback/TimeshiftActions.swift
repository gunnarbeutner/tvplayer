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

    func hasAdvanced(since previous: PlaybackOutputCounters) -> Bool {
        displayedPictures > previous.displayedPictures
            || playedAudioBuffers > previous.playedAudioBuffers
    }
}

struct LivePlaybackPositionTracker {
    private var pausedDate: Date?
    private var lastResumeOutput: PlaybackOutputCounters?

    var hasAnchoredDate: Bool {
        pausedDate != nil
    }

    var isAwaitingPlaybackProgress: Bool {
        lastResumeOutput != nil
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
    }

    mutating func moveAnchorToLive(at liveEdge: Date) {
        guard pausedDate != nil else { return }
        pausedDate = liveEdge
        lastResumeOutput = nil
    }

    @discardableResult
    mutating func requestResume(from output: PlaybackOutputCounters) -> Bool {
        guard pausedDate != nil else { return false }
        lastResumeOutput = output
        return true
    }

    @discardableResult
    mutating func observePlaybackOutput(_ output: PlaybackOutputCounters) -> Bool {
        guard let previous = lastResumeOutput else { return false }
        guard output.hasAdvanced(since: previous) else {
            // VLC counters can reset across a discontinuity. Treat the reset
            // as a new baseline and wait for an actual output increment.
            lastResumeOutput = output
            return false
        }
        pausedDate = nil
        lastResumeOutput = nil
        return true
    }

    mutating func reset() {
        pausedDate = nil
        lastResumeOutput = nil
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

    static func decode(from message: [String: HTSPValue]) -> HTSPTimeshiftMetrics {
        let liveDelay = abs(TimeInterval(message["shift"]?.intValue ?? 0) / 1_000_000)
        let window: TimeInterval
        if let start = message["start"]?.intValue,
           let end = message["end"]?.intValue {
            window = max(0, TimeInterval(end - start) / 1_000_000)
        } else {
            window = 0
        }
        return HTSPTimeshiftMetrics(liveDelay: liveDelay, window: window)
    }
}

final class HTSPTimeshiftDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingNavigationCount = 0
    private var awaitsPostNavigationPacket = false

    var shouldDeliverPackets: Bool {
        lock.withLock { pendingNavigationCount == 0 }
    }

    func beginNavigation() {
        lock.withLock {
            pendingNavigationCount += 1
            awaitsPostNavigationPacket = false
        }
    }

    @discardableResult
    func completeNavigation() -> Bool {
        lock.withLock {
            guard pendingNavigationCount > 0 else { return false }
            pendingNavigationCount -= 1
            let completedAllNavigation = pendingNavigationCount == 0
            if completedAllNavigation { awaitsPostNavigationPacket = true }
            return completedAllNavigation
        }
    }

    @discardableResult
    func consumePostNavigationPacket() -> Bool {
        lock.withLock {
            guard pendingNavigationCount == 0, awaitsPostNavigationPacket else { return false }
            awaitsPostNavigationPacket = false
            return true
        }
    }

    func cancelAllNavigation() {
        lock.withLock {
            pendingNavigationCount = 0
            awaitsPostNavigationPacket = false
        }
    }
}
