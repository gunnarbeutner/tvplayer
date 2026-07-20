import Foundation
import OSLog
import SwiftUI
@preconcurrency import TVVLCKit
import UIKit

enum PlaybackState: Equatable {
    case idle
    case preparing
    case playing
    case paused
    case recovering(PlaybackRecoveryReason, attempt: Int)
    case failed(String)
}

enum PlaybackRecoveryReason: Equatable {
    case tvHeadend
    case player

    var message: String {
        switch self {
        case .tvHeadend: "Reconnecting to TVHeadend…"
        case .player: "Restarting video playback…"
        }
    }
}

struct LiveStreamRequest: Equatable {
    let url: URL
    let networkCachingMilliseconds: Int
    let profile: String
    let kind: PlaybackRequestKind
    let expectedDurationSeconds: TimeInterval?

    init(
        url: URL,
        networkCachingMilliseconds: Int,
        profile: String,
        kind: PlaybackRequestKind = .live(.liveOnly(reason: nil)),
        expectedDurationSeconds: TimeInterval? = nil
    ) {
        self.url = url
        self.networkCachingMilliseconds = networkCachingMilliseconds
        self.profile = profile
        self.kind = kind
        self.expectedDurationSeconds = expectedDurationSeconds
    }
}

enum PlaybackRequestKind: Equatable {
    case live(LivePlaybackMode)
    case recording(isGrowing: Bool)

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}

struct HTSPPlaybackConfiguration: Equatable, Sendable {
    let configuration: TVHeadendConfiguration
    let channelID: UInt32
}

enum LivePlaybackMode: Equatable, Sendable {
    case nativeTimeshift(HTSPPlaybackConfiguration)
    case liveOnly(reason: String?)
}

enum ActiveLivePlaybackMode: Equatable, Sendable {
    case tvHeadend
    case liveOnly(reason: String?)
}

struct PlaybackTrack: Identifiable, Equatable {
    let id: Int
    let name: String
}

struct PlaybackTechnicalDetail: Identifiable, Equatable {
    let label: String
    let value: String

    var id: String { label }
}

@MainActor
protocol PlaybackEngine: AnyObject {
    var state: PlaybackState { get }

    func prepare(_ request: LiveStreamRequest) async throws
    func play()
    func pause()
    func stop()
}

@MainActor
final class VLCPlaybackEngine: NSObject, ObservableObject, PlaybackEngine, VLCMediaPlayerDelegate {
    private let logger = Logger(subsystem: "de.beutner.TVPlayer", category: "Playback")
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var durationSeconds: TimeInterval?
    @Published private(set) var isSeekable = false
    @Published private(set) var canPause = false
    @Published private(set) var audioTracks: [PlaybackTrack] = []
    @Published private(set) var subtitleTracks: [PlaybackTrack] = []
    @Published private(set) var selectedAudioTrackID: Int?
    @Published private(set) var selectedSubtitleTrackID: Int?
    @Published private(set) var liveDelaySeconds: TimeInterval = 0
    @Published private(set) var timeshiftWindowSeconds: TimeInterval = 0
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var bufferStartedAt: Date?
    @Published private(set) var bufferedBytes: Int64 = 0
    @Published private(set) var technicalDetails: [PlaybackTechnicalDetail] = []
    @Published private(set) var audioDelayMilliseconds = 0
    @Published private(set) var subtitleDelayMilliseconds = 0
    @Published private(set) var activeProfile = "pass"
    @Published private(set) var activeLivePlaybackMode: ActiveLivePlaybackMode?
    @Published private(set) var livePlaybackMarkerDate: Date?

    let mediaPlayer: VLCMediaPlayer

    private var nativeInputStream: HTSPLiveInputStream?
    private var nativeTimeshiftActions: NativeTimeshiftActionController?
    private var nativeTimeshiftSessionID: UUID?
    private var pipelineRecoveryTask: Task<Void, Never>?
    private var pipelineRecoveryID: UUID?
    private var recoveryReason: PlaybackRecoveryReason?
    private var recoveryAttempt = 0
    private var outputHealthMonitor = PlaybackOutputHealthMonitor()
    private var navigationShouldResume = true
    private var pauseRequested = false
    private var livePlaybackPosition = LivePlaybackPositionTracker()
    private var lastMetricsUpdate = Date()
    private var hasStartedPlayback = false
    private var didLogCapabilities = false
    private var activeRequest: LiveStreamRequest?

    override init() {
        mediaPlayer = VLCMediaPlayer()
        super.init()
        mediaPlayer.delegate = self
    }

    func prepare(_ request: LiveStreamRequest) async throws {
        pipelineRecoveryTask?.cancel()
        pipelineRecoveryTask = nil
        pipelineRecoveryID = nil
        recoveryReason = nil
        recoveryAttempt = 0
        setState(.preparing)
        logger.info("Preparing stream from \(request.url.host ?? "unknown host", privacy: .public)")

        mediaPlayer.stop()
        nativeInputStream?.close()
        nativeInputStream = nil
        nativeTimeshiftActions = nil
        nativeTimeshiftSessionID = nil
        activeLivePlaybackMode = nil

        let media: VLCMedia
        switch request.kind {
        case let .live(mode):
            switch mode {
            case let .nativeTimeshift(htsp):
                do {
                    let stream = try await HTSPLiveInputStream.connect(
                        configuration: htsp.configuration,
                        channelID: htsp.channelID,
                        profile: request.profile
                    )
                    media = VLCMedia(stream: stream)
                    media.addOption(":demux=ts")
                    nativeInputStream = stream
                    nativeTimeshiftActions = NativeTimeshiftActionController(sink: stream)
                    let sessionID = UUID()
                    nativeTimeshiftSessionID = sessionID
                    configureNativeCallbacks(for: stream, sessionID: sessionID)
                    activeLivePlaybackMode = .tvHeadend
                    logger.info("Using TVHeadend native timeshift over HTSP")
                } catch {
                    logger.error("Native timeshift unavailable; using live-only HTTP: \(error.localizedDescription, privacy: .public)")
                    media = VLCMedia(url: request.url)
                    activeLivePlaybackMode = .liveOnly(reason: error.localizedDescription)
                }
            case let .liveOnly(reason):
                media = VLCMedia(url: request.url)
                activeLivePlaybackMode = .liveOnly(reason: reason)
            }
        case .recording:
            media = VLCMedia(url: request.url)
        }
        addCachingOptions(to: media, milliseconds: request.networkCachingMilliseconds)

        activeRequest = request
        activeProfile = request.profile
        mediaPlayer.media = media
        resetPlaybackMetrics()
        if let nativeInputStream {
            // A successful native subscription has already accepted a
            // positive timeshift period. Expose its controls immediately;
            // timeshiftStatus is informational and may arrive later.
            isSeekable = true
            canPause = true
            bufferStartedAt = nativeInputStream.bufferStartedAt
        }
        hasStartedPlayback = false
        didLogCapabilities = false
    }

    func beginBuffering() {
        // Prewarming has no VLC reader yet. Start the HTSP receiver explicitly
        // so the sequenced pause can be acknowledged instead of sitting behind
        // unread subscription messages until presentation begins.
        nativeInputStream?.open()
        nativeInputStream?.pause()
    }

    func finishPrewarmingAtLiveEdge() {
        nativeInputStream?.returnToLive()
    }

    func play() {
        guard nativeInputStream?.isNavigatingTimeshift != true else {
            logger.info("Playback remains paused until TVHeadend completes the timeshift seek")
            navigationShouldResume = true
            pauseRequested = true
            setState(.paused)
            return
        }
        let wasPaused = state == .paused
        if wasPaused {
            logger.info("Resuming VLC playback")
        } else {
            logger.info("Starting VLC playback")
        }
        pauseRequested = false
        anchorLivePlaybackPositionIfNeeded()
        let waitsForPlaybackProgress = livePlaybackPosition.requestResume(
            from: playbackOutputCounters
        )
        publishLivePlaybackMarker()
        _ = nativeTimeshiftActions?.perform(.play)
        mediaPlayer.play()
        if let recoveryReason {
            setState(.recovering(recoveryReason, attempt: recoveryAttempt))
        } else {
            setState(waitsForPlaybackProgress || !wasPaused ? .preparing : .playing)
        }
        lastMetricsUpdate = Date()
    }

    func pause() {
        if activeRequest?.kind.isLive == true,
           case .liveOnly = activeLivePlaybackMode {
            logger.info("Pause ignored for a live-only HTTP stream")
            return
        }
        anchorLivePlaybackPositionIfNeeded()
        if nativeInputStream?.isNavigatingTimeshift == true {
            navigationShouldResume = false
        }
        pauseRequested = true
        mediaPlayer.rate = 1
        playbackRate = 1
        mediaPlayer.pause()
        _ = nativeTimeshiftActions?.perform(.pause)
        if nativeInputStream == nil {
            logger.info("Paused VLC recording")
        } else {
            logger.info("Paused TVHeadend timeshift subscription")
        }
        if let recoveryReason {
            setState(.recovering(recoveryReason, attempt: recoveryAttempt))
        } else {
            setState(.paused)
        }
        refreshPlaybackInformation()
    }

    func stop() {
        pipelineRecoveryTask?.cancel()
        pipelineRecoveryTask = nil
        pipelineRecoveryID = nil
        recoveryReason = nil
        recoveryAttempt = 0
        mediaPlayer.stop()
        mediaPlayer.drawable = nil
        nativeInputStream?.close()
        nativeInputStream = nil
        nativeTimeshiftActions = nil
        nativeTimeshiftSessionID = nil
        activeLivePlaybackMode = nil
        activeRequest = nil
        resetPlaybackMetrics()
        setState(.idle)
    }

    func togglePlayPause() {
        pauseRequested || state == .paused ? play() : pause()
    }

    /// The programme-clock position represented by VLC's current live-buffer
    /// read position. While paused this is anchored to the instant at which
    /// playback stopped, even if VLC subsequently reports a transient
    /// buffering/playing state while the upstream stream keeps downloading.
    func livePlaybackDate(at date: Date = Date()) -> Date {
        livePlaybackMarkerDate ?? livePlaybackPosition.playbackDate(
            at: date,
            liveDelay: liveDelaySeconds,
            bufferStartedAt: bufferStartedAt
        )
    }

    var isLivePlaybackPositionAnchored: Bool {
        livePlaybackPosition.hasAnchoredDate
    }

    /// Returns true when the caller should reconnect at the live edge.
    func skipForward(by seconds: TimeInterval) -> Bool {
        refreshPlaybackInformation()
        guard recoveryReason == nil else { return false }

        if let nativeTimeshiftActions {
            rememberNavigationPlaybackIntent()
            nativeTimeshiftActions.perform(
                .skipForward(seconds, liveDelay: liveDelaySeconds),
                beforeServerCommands: { [self] effect in
                    applyNativeTimeshiftLocalEffect(effect)
                }
            )
            return false
        }

        if isSeekable {
            seek(to: elapsedSeconds + seconds)
            return false
        }

        return false
    }

    func skipBackward(by seconds: TimeInterval) {
        refreshPlaybackInformation()
        guard recoveryReason == nil else { return }
        if let nativeTimeshiftActions {
            rememberNavigationPlaybackIntent()
            nativeTimeshiftActions.perform(
                .skipBackward(seconds),
                beforeServerCommands: { [self] effect in
                    applyNativeTimeshiftLocalEffect(effect)
                }
            )
            return
        }

        guard isSeekable else { return }
        seek(to: elapsedSeconds - seconds)
    }

    func seek(to seconds: TimeInterval) {
        guard isSeekable else { return }
        let upperBound = durationSeconds ?? seconds
        let target = min(max(0, seconds), upperBound)
        mediaPlayer.time = VLCTime(number: NSNumber(value: target * 1_000))
        refreshPlaybackInformation()
    }

    func returnToLive() {
        guard recoveryReason == nil, let nativeTimeshiftActions else { return }
        rememberNavigationPlaybackIntent()
        nativeTimeshiftActions.perform(
            .returnToLive,
            beforeServerCommands: { [self] effect in
                applyNativeTimeshiftLocalEffect(effect)
            }
        )
    }

    func selectAudioTrack(_ id: Int) {
        mediaPlayer.currentAudioTrackIndex = Int32(id)
        selectedAudioTrackID = id
    }

    func selectSubtitleTrack(_ id: Int) {
        mediaPlayer.currentVideoSubTitleIndex = Int32(id)
        selectedSubtitleTrackID = id
    }

    func adjustAudioDelay(by milliseconds: Int) {
        audioDelayMilliseconds = min(max(-2_000, audioDelayMilliseconds + milliseconds), 2_000)
        mediaPlayer.currentAudioPlaybackDelay = audioDelayMilliseconds * 1_000
    }

    func adjustSubtitleDelay(by milliseconds: Int) {
        subtitleDelayMilliseconds = min(max(-10_000, subtitleDelayMilliseconds + milliseconds), 10_000)
        mediaPlayer.currentVideoSubTitleDelay = subtitleDelayMilliseconds * 1_000
    }

    func refreshPlaybackInformation(at date: Date = Date()) {
        lastMetricsUpdate = date

        let isLive = activeRequest?.kind.isLive == true
        if let nativeInputStream {
            let delay = nativeInputStream.liveDelaySeconds
            let window = nativeInputStream.timeshiftWindowSeconds
            if abs(delay - liveDelaySeconds) >= 0.2 { liveDelaySeconds = delay }
            if abs(window - timeshiftWindowSeconds) >= 0.2 { timeshiftWindowSeconds = window }
            bufferStartedAt = nativeInputStream.bufferStartedAt
            bufferedBytes = nativeInputStream.queuedByteCount
        } else {
            if liveDelaySeconds != 0 { liveDelaySeconds = 0 }
            if timeshiftWindowSeconds != 0 { timeshiftWindowSeconds = 0 }
            if isLive { bufferStartedAt = nil }
            bufferedBytes = 0
        }
        confirmPlaybackResumeIfOutputAdvanced(at: date)
        publishLivePlaybackMarker(at: date)
        monitorPlaybackHealth(at: date)

        let hasNativeTimeshiftSession = activeLivePlaybackMode == .tvHeadend
        let nativeTimeshiftIsReady = hasNativeTimeshiftSession
            && recoveryReason == nil
            && (nativeInputStream.map { !$0.healthSnapshot.isRecovering } ?? false)
        let updatedSeekable = PlaybackCapabilityPolicy.isSeekable(
            isLive: isLive,
            hasNativeTimeshift: nativeTimeshiftIsReady,
            mediaIsSeekable: mediaPlayer.isSeekable
        )
        if isSeekable != updatedSeekable { isSeekable = updatedSeekable }
        let updatedCanPause = PlaybackCapabilityPolicy.canPause(
            isLive: isLive,
            hasNativeTimeshift: hasNativeTimeshiftSession,
            mediaCanPause: mediaPlayer.canPause
        )
        if canPause != updatedCanPause { canPause = updatedCanPause }

        if updatedSeekable, !isLive {
            let updatedElapsed = max(0, TimeInterval(mediaPlayer.time.intValue) / 1_000)
            if abs(updatedElapsed - elapsedSeconds) >= 0.2 { elapsedSeconds = updatedElapsed }

            let rawLength = mediaPlayer.media?.length.value?.doubleValue ?? 0
            let mediaDuration: TimeInterval? = rawLength > 0 ? rawLength / 1_000 : nil
            let updatedDuration: TimeInterval?
            if case .recording(isGrowing: true) = activeRequest?.kind {
                updatedDuration = max(mediaDuration ?? 0, elapsedSeconds)
            } else {
                updatedDuration = mediaDuration ?? activeRequest?.expectedDurationSeconds
            }
            if durationSeconds != updatedDuration { durationSeconds = updatedDuration }
        } else if !isLive {
            if elapsedSeconds != 0 { elapsedSeconds = 0 }
            if durationSeconds != nil { durationSeconds = nil }
        }
        refreshTracks()
        refreshTechnicalDetails()
        if hasStartedPlayback, !didLogCapabilities {
            didLogCapabilities = true
            logger.info(
                "Playback capabilities: pause=\(self.canPause, privacy: .public), seek=\(self.isSeekable, privacy: .public), audioTracks=\(self.audioTracks.count, privacy: .public), subtitleTracks=\(self.subtitleTracks.count, privacy: .public)"
            )
        }
    }

    func reportFailure(_ message: String) {
        setState(.failed(message))
    }

    func waitForPlaybackStart() async -> Bool {
        for _ in 0..<100 {
            guard !Task.isCancelled else { return false }

            if !livePlaybackPosition.isAwaitingPlaybackProgress,
               state == .playing || mediaPlayer.hasVideoOut || mediaPlayer.isPlaying {
                hasStartedPlayback = true
                setState(.playing)
                return true
            }
            if case .failed = state { return false }

            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        guard let player = notification.object as? VLCMediaPlayer else { return }
        let rawState = player.state.rawValue

        Task { @MainActor [weak self] in
            self?.applyPlayerState(rawState)
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.refreshPlaybackInformation()
        }
    }

    private func applyPlayerState(_ rawState: Int) {
        guard let playerState = VLCMediaPlayerState(rawValue: rawState) else { return }
        logger.info("VLC state changed: \(String(describing: playerState), privacy: .public)")
        switch playerState {
        case .opening, .buffering:
            if pauseRequested {
                setState(.paused)
            } else if let recoveryReason {
                setState(.recovering(recoveryReason, attempt: recoveryAttempt))
            } else if livePlaybackPosition.isAwaitingPlaybackProgress {
                setState(.preparing)
            } else {
                setState(hasStartedPlayback || mediaPlayer.hasVideoOut ? .playing : .preparing)
            }
        case .playing, .esAdded:
            hasStartedPlayback = true
            if pauseRequested {
                setState(.paused)
            } else if let recoveryReason {
                setState(.recovering(recoveryReason, attempt: recoveryAttempt))
            } else {
                setState(livePlaybackPosition.isAwaitingPlaybackProgress ? .preparing : .playing)
            }
        case .paused:
            anchorLivePlaybackPositionIfNeeded()
            if let recoveryReason {
                setState(.recovering(recoveryReason, attempt: recoveryAttempt))
            } else {
                setState(.paused)
            }
        case .error:
            let detail = VLCLibrary.currentErrorMessage
            logger.error("VLC playback failed: \(detail ?? "No additional error was reported", privacy: .public)")
            if let streamError = nativeInputStream?.streamError {
                recoveryReason = nil
                recoveryAttempt = 0
                setState(.failed(streamError.localizedDescription))
            } else if nativeInputStream != nil, activeRequest?.kind.isLive == true {
                scheduleNativePipelineRecovery(
                    detail: detail ?? "VLC reported a playback error."
                )
            } else {
                setState(.failed(detail ?? "VLC could not play this TVHeadend stream."))
            }
        case .stopped, .ended:
            guard recoveryReason == nil, pipelineRecoveryTask == nil else { break }
            hasStartedPlayback = false
            pauseRequested = false
            livePlaybackPosition.reset()
            setState(.idle)
        default:
            break
        }
        refreshPlaybackInformation()
    }

    private func setState(_ updatedState: PlaybackState) {
        guard state != updatedState else { return }
        state = updatedState
    }

    private func configureNativeCallbacks(
        for stream: HTSPLiveInputStream,
        sessionID: UUID
    ) {
        stream.setNavigationCompletionHandler { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.nativeTimeshiftSessionID == sessionID else { return }
                if case let .success(navigation) = result {
                    self.applyNavigationLanding(navigation)
                } else if case let .failure(error) = result {
                    self.logger.error(
                        "Timeshift navigation failed: \(error.localizedDescription, privacy: .public)"
                    )
                }

                if self.navigationShouldResume {
                    self.resumeLocalPlaybackAfterTimeshiftNavigation()
                } else {
                    self.pauseRequested = true
                    self.nativeInputStream?.pause()
                    self.mediaPlayer.pause()
                    self.setState(.paused)
                    self.publishLivePlaybackMarker()
                }
                self.navigationShouldResume = true
            }
        }
        stream.setLifecycleHandler { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.nativeTimeshiftSessionID == sessionID else { return }
                self.handleNativeLifecycleEvent(event)
            }
        }
    }

    private func rememberNavigationPlaybackIntent() {
        guard nativeInputStream?.isNavigatingTimeshift != true else { return }
        navigationShouldResume = !pauseRequested
    }

    private func handleNativeLifecycleEvent(_ event: HTSPStreamLifecycleEvent) {
        switch event {
        case let .reconnecting(reason, attempt):
            logger.error(
                "Recovering TVHeadend stream (attempt \(attempt, privacy: .public)): \(reason, privacy: .public)"
            )
            anchorLivePlaybackPositionIfNeeded()
            publishLivePlaybackMarker()
            recoveryReason = .tvHeadend
            recoveryAttempt = attempt
            isSeekable = false
            mediaPlayer.pause()
            outputHealthMonitor.restartGracePeriod(
                output: playbackOutputCounters,
                at: Date()
            )
            setState(.recovering(.tvHeadend, attempt: attempt))

        case .readyAfterRecovery:
            let now = Date()
            livePlaybackPosition.recoverAtLiveEdge(now)
            publishLivePlaybackMarker(at: now)
            outputHealthMonitor.restartGracePeriod(
                output: playbackOutputCounters,
                at: now
            )
            isSeekable = true
            if pauseRequested {
                nativeInputStream?.pause()
                recoveryReason = nil
                recoveryAttempt = 0
                setState(.paused)
            } else {
                _ = livePlaybackPosition.requestResume(from: playbackOutputCounters)
                mediaPlayer.play()
                setState(.recovering(.tvHeadend, attempt: recoveryAttempt))
            }

        case let .terminalFailure(message):
            recoveryReason = nil
            recoveryAttempt = 0
            setState(.failed(message))
        }
    }

    private func monitorPlaybackHealth(at date: Date) {
        guard let stream = nativeInputStream else {
            outputHealthMonitor.reset()
            return
        }
        let health = stream.healthSnapshot
        let hasFreshInput = health.lastMuxPacketAt.map {
            date.timeIntervalSince($0) < HTSPRecoveryPolicy.stalledPacketThreshold
        } ?? false
        let expectsOutput = !pauseRequested
            && !health.isRecovering
            && !health.isNavigating
            && pipelineRecoveryTask == nil
        guard outputHealthMonitor.observe(
            output: playbackOutputCounters,
            at: date,
            expectsOutput: expectsOutput,
            hasFreshInput: hasFreshInput
        ) == .rebuildPlayer else { return }

        scheduleNativePipelineRecovery(
            detail: "HTSP packets are arriving but VLC output has not advanced for 10 seconds."
        )
    }

    private func scheduleNativePipelineRecovery(detail: String) {
        guard pipelineRecoveryTask == nil,
              let request = activeRequest,
              case .live(.nativeTimeshift) = request.kind
        else { return }

        logger.error("Restarting stalled VLC pipeline: \(detail, privacy: .public)")
        anchorLivePlaybackPositionIfNeeded()
        publishLivePlaybackMarker()
        recoveryReason = .player
        recoveryAttempt = 1
        setState(.recovering(.player, attempt: 1))

        let recoveryID = UUID()
        pipelineRecoveryID = recoveryID
        nativeTimeshiftSessionID = nil
        nativeTimeshiftActions = nil
        mediaPlayer.pause()
        mediaPlayer.stop()
        nativeInputStream?.close()
        nativeInputStream = nil
        outputHealthMonitor.restartGracePeriod(
            output: playbackOutputCounters,
            at: Date()
        )

        pipelineRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.rebuildNativePipeline(
                request: request,
                recoveryID: recoveryID
            )
        }
    }

    private func rebuildNativePipeline(
        request: LiveStreamRequest,
        recoveryID: UUID
    ) async {
        guard case let .live(.nativeTimeshift(htsp)) = request.kind else { return }
        var attempt = 1

        while !Task.isCancelled, pipelineRecoveryID == recoveryID {
            recoveryAttempt = attempt
            setState(.recovering(.player, attempt: attempt))
            let delay = HTSPRecoveryPolicy.delay(beforeAttempt: attempt)
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, pipelineRecoveryID == recoveryID else { return }
            }

            do {
                let stream = try await HTSPLiveInputStream.connect(
                    configuration: htsp.configuration,
                    channelID: htsp.channelID,
                    profile: request.profile
                )
                guard !Task.isCancelled, pipelineRecoveryID == recoveryID else {
                    stream.close()
                    return
                }

                let media = VLCMedia(stream: stream)
                media.addOption(":demux=ts")
                addCachingOptions(to: media, milliseconds: request.networkCachingMilliseconds)
                nativeInputStream = stream
                nativeTimeshiftActions = NativeTimeshiftActionController(sink: stream)
                let sessionID = UUID()
                nativeTimeshiftSessionID = sessionID
                configureNativeCallbacks(for: stream, sessionID: sessionID)
                mediaPlayer.media = media
                mediaPlayer.currentAudioPlaybackDelay = audioDelayMilliseconds * 1_000
                mediaPlayer.currentVideoSubTitleDelay = subtitleDelayMilliseconds * 1_000

                let now = Date()
                liveDelaySeconds = 0
                timeshiftWindowSeconds = 0
                bufferStartedAt = nil
                livePlaybackPosition.recoverAtLiveEdge(now)
                publishLivePlaybackMarker(at: now)
                outputHealthMonitor.restartGracePeriod(
                    output: playbackOutputCounters,
                    at: now
                )
                pipelineRecoveryTask = nil
                pipelineRecoveryID = nil

                if pauseRequested {
                    stream.open()
                    stream.pause()
                    recoveryReason = nil
                    recoveryAttempt = 0
                    setState(.paused)
                } else {
                    _ = livePlaybackPosition.requestResume(from: playbackOutputCounters)
                    stream.play()
                    mediaPlayer.play()
                    setState(.recovering(.player, attempt: attempt))
                }
                logger.info("Rebuilt VLC and HTSP playback at the live edge")
                return
            } catch {
                guard !Task.isCancelled, pipelineRecoveryID == recoveryID else { return }
                if HTSPRecoveryPolicy.isTerminal(error) {
                    pipelineRecoveryTask = nil
                    pipelineRecoveryID = nil
                    recoveryReason = nil
                    recoveryAttempt = 0
                    setState(.failed(error.localizedDescription))
                    return
                }
                logger.error(
                    "VLC pipeline rebuild attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                attempt += 1
            }
        }
    }

    private func addCachingOptions(to media: VLCMedia, milliseconds: Int) {
        media.addOption(":network-caching=\(milliseconds)")
        media.addOption(":live-caching=\(milliseconds)")
        media.addOption(":file-caching=\(milliseconds)")
    }

    private func resumeLocalPlaybackAfterTimeshiftNavigation() {
        pauseRequested = false
        nativeInputStream?.play()
        let waitsForPlaybackProgress = livePlaybackPosition.requestResume(
            from: playbackOutputCounters
        )
        mediaPlayer.rate = 1
        playbackRate = 1
        mediaPlayer.play()
        setState(waitsForPlaybackProgress ? .preparing : (hasStartedPlayback ? .playing : .preparing))
        lastMetricsUpdate = Date()
    }

    private func applyNavigationLanding(
        _ navigation: HTSPNavigationResult,
        at date: Date = Date()
    ) {
        let liveEdge = date
        let landingDate = liveEdge.addingTimeInterval(-navigation.liveDelay)
        livePlaybackPosition.moveAnchor(
            to: landingDate,
            liveEdge: liveEdge,
            bufferStartedAt: bufferStartedAt
        )
        publishLivePlaybackMarker(at: date)
    }

    private var playbackOutputCounters: PlaybackOutputCounters {
        let statistics = mediaPlayer.media?.statistics
        return PlaybackOutputCounters(
            displayedPictures: Int(statistics?.displayedPictures ?? 0),
            playedAudioBuffers: Int(statistics?.playedAudioBuffers ?? 0),
            playbackTimeMilliseconds: mediaPlayer.time.intValue > 0
                ? Int64(mediaPlayer.time.intValue)
                : nil
        )
    }

    private func confirmPlaybackResumeIfOutputAdvanced(at date: Date) {
        guard livePlaybackPosition.observePlaybackOutput(
            playbackOutputCounters,
            at: date
        ) else { return }
        hasStartedPlayback = true
        if !pauseRequested {
            recoveryReason = nil
            setState(.playing)
        }
    }

    private func publishLivePlaybackMarker(at date: Date = Date()) {
        guard activeRequest?.kind.isLive == true,
              livePlaybackPosition.hasAnchoredDate else {
            if livePlaybackMarkerDate != nil { livePlaybackMarkerDate = nil }
            return
        }
        let marker = livePlaybackPosition.playbackDate(
            at: date,
            liveDelay: liveDelaySeconds,
            bufferStartedAt: bufferStartedAt
        )
        if livePlaybackMarkerDate.map({ abs($0.timeIntervalSince(marker)) >= 0.05 }) ?? true {
            livePlaybackMarkerDate = marker
        }
    }

    private func applyNativeTimeshiftLocalEffect(_ effect: NativeTimeshiftLocalPlaybackEffect) {
        switch effect {
        case .none:
            break
        case .pause:
            anchorLivePlaybackPositionIfNeeded()
            publishLivePlaybackMarker()
            pauseRequested = true
            mediaPlayer.rate = 1
            playbackRate = 1
            mediaPlayer.pause()
            setState(.paused)
        case .resume:
            resumeLocalPlaybackAfterTimeshiftNavigation()
        case .pauseUntilNavigationCompletes:
            anchorLivePlaybackPositionIfNeeded()
            publishLivePlaybackMarker()
            pauseRequested = true
            mediaPlayer.rate = 1
            playbackRate = 1
            mediaPlayer.pause()
            setState(.paused)
            lastMetricsUpdate = Date()
        }
    }

    private func anchorLivePlaybackPositionIfNeeded(at date: Date = Date()) {
        guard activeRequest?.kind.isLive == true else { return }
        livePlaybackPosition.pause(
            at: date,
            liveDelay: liveDelaySeconds,
            bufferStartedAt: bufferStartedAt
        )
    }

    private func refreshTracks() {
        let audioNames = mediaPlayer.audioTrackNames.map { String(describing: $0) }
        let audioIDs = mediaPlayer.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.intValue }
        let updatedAudioTracks = zip(audioIDs, audioNames).map(PlaybackTrack.init)
        if audioTracks != updatedAudioTracks { audioTracks = updatedAudioTracks }
        let updatedAudioTrackID = Int(mediaPlayer.currentAudioTrackIndex)
        if selectedAudioTrackID != updatedAudioTrackID {
            selectedAudioTrackID = updatedAudioTrackID
        }

        let subtitleNames = mediaPlayer.videoSubTitlesNames.map { String(describing: $0) }
        let subtitleIDs = mediaPlayer.videoSubTitlesIndexes.compactMap { ($0 as? NSNumber)?.intValue }
        let updatedSubtitleTracks = zip(subtitleIDs, subtitleNames).map(PlaybackTrack.init)
        if subtitleTracks != updatedSubtitleTracks { subtitleTracks = updatedSubtitleTracks }
        let updatedSubtitleTrackID = Int(mediaPlayer.currentVideoSubTitleIndex)
        if selectedSubtitleTrackID != updatedSubtitleTrackID {
            selectedSubtitleTrackID = updatedSubtitleTrackID
        }
    }

    private func refreshTechnicalDetails() {
        guard let media = mediaPlayer.media else { return }

        let tracks = media.tracksInformation.compactMap { $0 as? [String: Any] }
        let video = tracks.first { ($0[VLCMediaTracksInformationType] as? String) == VLCMediaTracksInformationTypeVideo }
        let audio = tracks.first { ($0[VLCMediaTracksInformationType] as? String) == VLCMediaTracksInformationTypeAudio }
        let statistics = media.statistics

        let delivery: String
        if activeRequest?.kind.isLive == true {
            if activeLivePlaybackMode == .tvHeadend {
                delivery = "TVheadend HTSP · timeshift · \(activeProfile)"
            } else {
                delivery = "TVheadend HTTP · live only · \(activeProfile)"
            }
        } else {
            delivery = "TVheadend recording"
        }
        var details = [
            PlaybackTechnicalDetail(label: "Delivery", value: delivery),
            PlaybackTechnicalDetail(label: "Container", value: "MPEG transport stream"),
            PlaybackTechnicalDetail(label: "Player", value: "VLC"),
        ]

        if let width = (video?[VLCMediaTracksInformationVideoWidth] as? NSNumber)?.intValue,
           let height = (video?[VLCMediaTracksInformationVideoHeight] as? NSNumber)?.intValue,
           width > 0, height > 0 {
            details.append(PlaybackTechnicalDetail(label: "Resolution", value: "\(width) × \(height)"))
        }
        if let codec = codecName(from: video) {
            details.append(PlaybackTechnicalDetail(label: "Video", value: codec))
        }
        if let codec = codecName(from: audio) {
            details.append(PlaybackTechnicalDetail(label: "Audio", value: codec))
        }
        if statistics.inputBitrate > 0 {
            details.append(
                PlaybackTechnicalDetail(
                    label: "Input bitrate",
                    value: String(format: "%.1f Mbit/s", statistics.inputBitrate * 8)
                )
            )
        }
        if nativeInputStream != nil {
            details.append(
                PlaybackTechnicalDetail(
                    label: "Timeshift window",
                    value: Self.formatDuration(timeshiftWindowSeconds)
                )
            )
        }
        details.append(PlaybackTechnicalDetail(label: "Dropped pictures", value: "\(statistics.lostPictures)"))
        details.append(PlaybackTechnicalDetail(label: "Discontinuities", value: "\(statistics.demuxDiscontinuity)"))

        if technicalDetails != details { technicalDetails = details }
    }

    private func codecName(from track: [String: Any]?) -> String? {
        guard let codecNumber = track?[VLCMediaTracksInformationCodec] as? NSNumber else { return nil }
        let codec = VLCMedia.codecName(forFourCC: codecNumber.uint32Value, trackType: track?[VLCMediaTracksInformationType] as? String ?? "")
        return codec.isEmpty ? nil : codec
    }

    private func resetPlaybackMetrics() {
        elapsedSeconds = 0
        durationSeconds = nil
        isSeekable = false
        canPause = false
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
        liveDelaySeconds = 0
        timeshiftWindowSeconds = 0
        playbackRate = 1
        pauseRequested = false
        navigationShouldResume = true
        recoveryReason = nil
        recoveryAttempt = 0
        outputHealthMonitor.reset()
        livePlaybackPosition.reset()
        livePlaybackMarkerDate = nil
        bufferStartedAt = nil
        bufferedBytes = 0
        lastMetricsUpdate = Date()
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }
}

struct VLCVideoSurface: UIViewRepresentable {
    let mediaPlayer: VLCMediaPlayer
    let attachmentRevision: Int

    init(mediaPlayer: VLCMediaPlayer, attachmentRevision: Int = 0) {
        self.mediaPlayer = mediaPlayer
        self.attachmentRevision = attachmentRevision
    }

    func makeUIView(context: Context) -> UIView {
        VLCVideoContainerView(
            mediaPlayer: mediaPlayer,
            attachmentRevision: attachmentRevision
        )
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? VLCVideoContainerView)?.updateAttachment(revision: attachmentRevision)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        (uiView as? VLCVideoContainerView)?.detachIfOwned()
    }
}

private final class VLCVideoContainerView: UIView {
    private weak var mediaPlayer: VLCMediaPlayer?
    private var attachmentRevision: Int

    init(mediaPlayer: VLCMediaPlayer, attachmentRevision: Int) {
        self.mediaPlayer = mediaPlayer
        self.attachmentRevision = attachmentRevision
        super.init(frame: .zero)
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            detachIfOwned()
        } else {
            attachIfVisible()
        }
    }

    func updateAttachment(revision: Int) {
        let mustReattach = revision != attachmentRevision
        attachmentRevision = revision
        attachIfVisible(force: mustReattach)
    }

    func attachIfVisible(force: Bool = false) {
        guard window != nil, let mediaPlayer else { return }
        if !force, let current = mediaPlayer.drawable as? UIView, current === self { return }

        // VLC can retain the previous full-screen cover's UIView after that
        // cover has disappeared. Clearing first forces the video output to
        // bind to this newly visible surface instead of continuing headlessly.
        // A retained player may already point at this UIView while its video
        // output remains detached, so resumed sessions can explicitly force
        // the nil/self transition through attachmentRevision.
        mediaPlayer.drawable = nil
        mediaPlayer.drawable = self
    }

    func detachIfOwned() {
        guard let mediaPlayer,
              let current = mediaPlayer.drawable as? UIView,
              current === self
        else { return }
        mediaPlayer.drawable = nil
    }
}
