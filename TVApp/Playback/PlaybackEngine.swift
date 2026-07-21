import Foundation
import OSLog
import SwiftUI
@preconcurrency import VLCKit
#if os(tvOS)
import UIKit
#elseif os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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

#if DEBUG
private struct TimeshiftSeekPhaseTrace {
    let startedAt: TimeInterval
    var pipelineBaseline: PlaybackOutputCounters?
    var didLogFirstAudio = false
    var didLogFirstVideo = false
    var lastGatePhase: PostSeekPlaybackOutputGateDiagnostics.Phase?
}
#endif

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
final class VLCPlaybackEngine: NSObject, ObservableObject, PlaybackEngine, @preconcurrency VLCMediaPlayerDelegate {
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
    @Published private(set) var isPlaybackOutputConcealed = false
    @Published private(set) var pausedFrame: PlatformImage?
    @Published private(set) var timeshiftNavigationDebugState = "idle"
    @Published private(set) var nativeTimeshiftRecoveryCount = 0
    @Published private(set) var lastNativePipelineDiagnostic: String?
#if os(tvOS)
    @Published private(set) var isPictureInPictureReady = false
    @Published private(set) var usesSampleBufferRendering = false
    let sampleBufferBridge: TVPlayerSampleBufferBridge
    private var sampleBufferFallbackTask: Task<Void, Never>?
#endif

    let mediaPlayer: VLCMediaPlayer

    private var nativeInputStream: HTSPLiveInputStream?
    // VLCKit's custom-stream bridge does not retain the InputStream passed to
    // VLCMedia(stream:), and closes it asynchronously. Keep each disposable
    // reader alive for the engine lifetime to make that callback safe.
    private var retainedNativeVLCReaders: [InputStream] = []
    private var nativeTimeshiftActions: NativeTimeshiftActionController?
    private var nativeTimeshiftSessionID: UUID?
    private var pipelineRecoveryTask: Task<Void, Never>?
    private var pipelineRecoveryID: UUID?
    private var recoveryReason: PlaybackRecoveryReason?
    private var recoveryAttempt = 0
    private var outputHealthMonitor = PlaybackOutputHealthMonitor()
    private var postSeekOutputGate = PostSeekPlaybackOutputGate()
#if DEBUG
    private var timeshiftSeekPhaseTrace: TimeshiftSeekPhaseTrace?
#endif
    private var shouldRestoreAudioAfterOutputGate = false
    private var isPrimingPausedSeekFrame = false
    private var concealsSeekAfterPausedFrameCapture = false
    private var navigationShouldResume = true
    private var isReplacingPipelineForTimeshiftSeek = false
    private var pauseRequested = false
    private var livePlaybackPosition = LivePlaybackPositionTracker()
    private var lastMetricsUpdate = Date()
    private var hasStartedPlayback = false
    private var didLogCapabilities = false
    private var activeRequest: LiveStreamRequest?
    private var activePreparationID: UUID?
    private var pendingSnapshotURL: URL?

    override init() {
        mediaPlayer = VLCMediaPlayer(library: VLCLibrary(options: ["--quiet"]))
#if os(tvOS)
        sampleBufferBridge = TVPlayerSampleBufferBridge(mediaPlayer: mediaPlayer)
#endif
        super.init()
        mediaPlayer.delegate = self
        configureVideoSizing()
#if os(tvOS)
        sampleBufferBridge.readinessChanged = { [weak self] ready in
            self?.isPictureInPictureReady = ready
            if ready {
                self?.sampleBufferFallbackTask?.cancel()
                self?.sampleBufferFallbackTask = nil
            }
        }
#endif
    }

#if os(tvOS)
    func prepareForPictureInPicture() async -> Bool {
        if usesSampleBufferRendering {
            return await waitForSampleBufferRendering()
        }
        guard let request = activeRequest else { return false }

        let resumeAt = elapsedSeconds
        let wasPaused = state == .paused
        mediaPlayer.stop()
        guard sampleBufferBridge.installVideoCallbacks() else { return false }
        usesSampleBufferRendering = true

        do {
            try await prepare(request)
            play()
            guard await waitForSampleBufferRendering() else { return false }

            if request.kind.isLive == false, resumeAt > 0 {
                seek(to: resumeAt)
            }
            if wasPaused { pause() }
            return true
        } catch {
            reportFailure(error.localizedDescription)
            return false
        }
    }

    private func waitForSampleBufferRendering() async -> Bool {
        for _ in 0..<80 {
            guard !Task.isCancelled else { return false }
            if sampleBufferBridge.isReady { return true }
            if !usesSampleBufferRendering { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return sampleBufferBridge.isReady
    }
#endif

    func prepare(_ request: LiveStreamRequest) async throws {
        let preparationID = UUID()
        activePreparationID = preparationID
        defer {
            if activePreparationID == preparationID { activePreparationID = nil }
        }
        cancelPostSeekOutputGate()
        pipelineRecoveryTask?.cancel()
        pipelineRecoveryTask = nil
        pipelineRecoveryID = nil
        recoveryReason = nil
        recoveryAttempt = 0
        clearPausedFrame()
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
                    guard activePreparationID == preparationID, !Task.isCancelled else {
                        stream.close()
                        throw CancellationError()
                    }
                    let reader = stream.makeVLCReader()
                    retainedNativeVLCReaders.append(reader)
                    media = Self.makeMedia(stream: reader)
                    media.addOption(":demux=ts")
                    nativeInputStream = stream
                    nativeTimeshiftActions = NativeTimeshiftActionController(sink: stream)
                    let sessionID = UUID()
                    nativeTimeshiftSessionID = sessionID
                    configureNativeCallbacks(for: stream, sessionID: sessionID)
                    activeLivePlaybackMode = .tvHeadend
                    logger.info("Using TVHeadend native timeshift over HTSP")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard activePreparationID == preparationID else {
                        throw CancellationError()
                    }
                    logger.error("Native timeshift unavailable; using live-only HTTP: \(error.localizedDescription, privacy: .public)")
                    media = Self.makeMedia(url: request.url)
                    activeLivePlaybackMode = .liveOnly(reason: error.localizedDescription)
                }
            case let .liveOnly(reason):
                media = Self.makeMedia(url: request.url)
                activeLivePlaybackMode = .liveOnly(reason: reason)
            }
        case .recording:
            media = Self.makeMedia(url: request.url)
        }
        guard activePreparationID == preparationID, !Task.isCancelled else {
            throw CancellationError()
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
        isPrimingPausedSeekFrame = false
        clearPausedFrame()
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
        beginPostSeekOutputConcealmentIfNeeded()
        _ = nativeTimeshiftActions?.perform(.play)
        mediaPlayer.play()
#if os(tvOS)
        armSampleBufferFallbackIfNeeded()
#endif
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
        // A paused seek already has the requested user state. VLC is only
        // running invisibly long enough to decode the selected frame.
        guard !isPrimingPausedSeekFrame else { return }
        anchorLivePlaybackPositionIfNeeded()
        if nativeInputStream?.isNavigatingTimeshift == true {
            navigationShouldResume = false
        }
        pauseRequested = true
        suspendPostSeekOutputConcealment()
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
        capturePausedFrame()
    }

    func stop() {
        activePreparationID = nil
        lastNativePipelineDiagnostic = nil
        cancelPostSeekOutputGate()
        pipelineRecoveryTask?.cancel()
        pipelineRecoveryTask = nil
        pipelineRecoveryID = nil
        recoveryReason = nil
        recoveryAttempt = 0
        mediaPlayer.stop()
        mediaPlayer.drawable = nil
#if os(tvOS)
        sampleBufferFallbackTask?.cancel()
        sampleBufferFallbackTask = nil
        sampleBufferBridge.flush()
#endif
        nativeInputStream?.close()
        nativeInputStream = nil
        nativeTimeshiftActions = nil
        nativeTimeshiftSessionID = nil
        activeLivePlaybackMode = nil
        activeRequest = nil
        clearPausedFrame()
        resetPlaybackMetrics()
        setState(.idle)
    }

    func mediaPlayerSnapshot(_ notification: Notification) {
        guard let snapshotURL = pendingSnapshotURL else { return }
        pendingSnapshotURL = nil
        defer { try? FileManager.default.removeItem(at: snapshotURL) }
        let shouldConcealSeek = concealsSeekAfterPausedFrameCapture
        concealsSeekAfterPausedFrameCapture = false

        guard state == .paused,
              let image = PlatformImage(contentsOfFile: snapshotURL.path)
        else { return }
        installPausedFrame(image, shouldConcealSeek: shouldConcealSeek)
    }

    private func capturePausedFrame() {
        guard state == .paused, pendingSnapshotURL == nil else { return }
        pausedFrame = nil

        let snapshotURL = FileManager.default.temporaryDirectory
            .appending(path: "tvplayer-paused-frame-\(UUID().uuidString)")
            .appendingPathExtension("png")
        pendingSnapshotURL = snapshotURL
        mediaPlayer.saveVideoSnapshot(
            at: snapshotURL.path,
            withWidth: 1_280,
            andHeight: 0
        )
    }

    private func installPausedFrame(
        _ image: PlatformImage,
        shouldConcealSeek: Bool
    ) {
        pausedFrame = image
        if shouldConcealSeek, postSeekOutputGate.concealImmediately() {
            concealPlaybackOutput()
        }
    }

    private func clearPausedFrame() {
        pausedFrame = nil
        if let pendingSnapshotURL {
            try? FileManager.default.removeItem(at: pendingSnapshotURL)
        }
        pendingSnapshotURL = nil
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
        mediaPlayer.selectTrack(at: id, type: .audio)
        selectedAudioTrackID = id
    }

    func selectSubtitleTrack(_ id: Int) {
        guard id >= 0 else {
            mediaPlayer.deselectAllTextTracks()
            selectedSubtitleTrackID = nil
            return
        }
        mediaPlayer.selectTrack(at: id, type: .text)
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
        let output = playbackOutputCounters
        updatePostSeekOutputGate(with: output, at: date)
        if !postSeekOutputGate.isConcealing {
            confirmPlaybackResumeIfOutputAdvanced(output: output, at: date)
        }
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

    func waitForInitialPlaybackOutput() async -> Bool {
        for attempt in 0..<200 {
            guard !Task.isCancelled else { return false }
            refreshPlaybackInformation()
            let output = playbackOutputCounters
            let expectsAudio = nativeInputStream?.healthSnapshot.expectsAudio == true
            let hasExpectedAudio = !expectsAudio || output.playedAudioBuffers > 0
            if mediaPlayer.hasVideoOut, hasExpectedAudio { return true }

            if attempt == 30,
               mediaPlayer.hasVideoOut,
               expectsAudio,
               output.playedAudioBuffers == 0 {
                scheduleNativePipelineRecovery(
                    detail: "Video started but the expected audio stream produced no output for 3 seconds."
                )
            }
            if case .failed = state { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak self] in
            self?.applyPlayerState(newState.rawValue)
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
        let isOpening = playerState == .opening
        let isPlaying = playerState == .playing
        let isStopped = playerState == .stopped || playerState == .stopping
        if isReplacingPipelineForTimeshiftSeek {
            if isOpening || isPlaying {
                isReplacingPipelineForTimeshiftSeek = false
            } else if isStopped || playerState == .error {
                // The obsolete reader is expected to end when a seek begins.
                // Its terminal callback must not reset the long-lived session.
                refreshPlaybackInformation()
                return
            }
        }
        if isOpening {
            if pauseRequested {
                setState(.paused)
            } else if let recoveryReason {
                setState(.recovering(recoveryReason, attempt: recoveryAttempt))
            } else if livePlaybackPosition.isAwaitingPlaybackProgress {
                setState(.preparing)
            } else {
                setState(hasStartedPlayback || mediaPlayer.hasVideoOut ? .playing : .preparing)
            }
        } else if isPlaying {
            hasStartedPlayback = true
            if pauseRequested {
                setState(.paused)
            } else if let recoveryReason {
                setState(.recovering(recoveryReason, attempt: recoveryAttempt))
            } else {
                setState(livePlaybackPosition.isAwaitingPlaybackProgress ? .preparing : .playing)
            }
        } else if playerState == .paused {
            anchorLivePlaybackPositionIfNeeded()
            if let recoveryReason {
                setState(.recovering(recoveryReason, attempt: recoveryAttempt))
            } else {
                setState(.paused)
            }
        } else if playerState == .error {
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
        } else if isStopped, recoveryReason == nil, pipelineRecoveryTask == nil {
                hasStartedPlayback = false
                pauseRequested = false
                livePlaybackPosition.reset()
                setState(.idle)
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
                let navigationSucceeded: Bool
                switch result {
                case let .success(navigation):
                    navigationSucceeded = true
                    self.timeshiftNavigationDebugState = "server navigation completed"
#if DEBUG
                    self.traceTimeshiftSeekPhase(
                        String(
                            format: "server-buffer-ready preroll=%.1fms",
                            navigation.prerollDuration * 1_000
                        )
                    )
#endif
                    self.applyNavigationLanding(navigation)
                    await self.replaceVLCPipelineAfterTimeshiftNavigation()
                case let .failure(error):
                    navigationSucceeded = false
                    self.isReplacingPipelineForTimeshiftSeek = false
                    self.timeshiftNavigationDebugState = "server navigation failed: \(error.localizedDescription)"
                    self.cancelPostSeekOutputGate()
                    self.logger.error(
                        "Timeshift navigation failed: \(error.localizedDescription, privacy: .public)"
                    )
                }

                if self.navigationShouldResume {
                    self.resumeLocalPlaybackAfterTimeshiftNavigation()
                } else if navigationSucceeded {
                    self.primePausedFrameAfterTimeshiftNavigation()
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

    private func configureVideoSizing() {
        // Zero restores drawable-relative automatic scaling. Set VLC 4's fit
        // mode once; repeatedly changing it while replacing a vout can apply
        // the previous drawable's geometry to the next one.
        mediaPlayer.scaleFactor = 0
        mediaPlayer.videoFitMode = .smaller
    }

    private func rememberNavigationPlaybackIntent() {
        guard nativeInputStream?.isNavigatingTimeshift != true else {
            timeshiftNavigationDebugState = "ignored new intent while already navigating"
            return
        }
        navigationShouldResume = !pauseRequested
        timeshiftNavigationDebugState = navigationShouldResume
            ? "navigation requested; will resume"
            : "navigation requested; will remain paused"
    }

    private func handleNativeLifecycleEvent(_ event: HTSPStreamLifecycleEvent) {
        switch event {
        case let .reconnecting(reason, attempt):
            nativeTimeshiftRecoveryCount += 1
            logger.error(
                "Recovering TVHeadend stream (attempt \(attempt, privacy: .public)): \(reason, privacy: .public)"
            )
            anchorLivePlaybackPositionIfNeeded()
            publishLivePlaybackMarker()
            recoveryReason = .tvHeadend
            recoveryAttempt = attempt
            isSeekable = false
            mediaPlayer.pause()
            cancelPostSeekOutputGate()
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
            hasFreshInput: hasFreshInput,
            expectsAudio: health.expectsAudio
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

        let diagnostic = nativePipelineDiagnostic(detail: detail)
        lastNativePipelineDiagnostic = diagnostic
        nativeTimeshiftRecoveryCount += 1
        logger.error("Restarting stalled VLC pipeline: \(diagnostic, privacy: .public)")
#if DEBUG
        print("PLAYBACK_AUDIO_DIAGNOSTIC \(diagnostic)")
        fflush(stdout)
#endif
        anchorLivePlaybackPositionIfNeeded()
        publishLivePlaybackMarker()
        recoveryReason = .player
        recoveryAttempt = 1
        setState(.recovering(.player, attempt: 1))
        cancelPostSeekOutputGate()

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

    private func nativePipelineDiagnostic(
        detail: String,
        at date: Date = Date()
    ) -> String {
        let output = playbackOutputCounters
        guard let health = nativeInputStream?.healthSnapshot else {
            return "\(detail) htsp=unavailable vlcPictures=\(output.displayedPictures) vlcAudioBuffers=\(output.playedAudioBuffers)"
        }

        func ageDescription(_ timestamp: Date?) -> String {
            guard let timestamp else { return "never" }
            return String(format: "%.3fs", max(0, date.timeIntervalSince(timestamp)))
        }

        let codecs = health.audioStreamTypes.isEmpty
            ? "none"
            : health.audioStreamTypes.joined(separator: ",")
        return "\(detail) audioCodecs=\(codecs) "
            + "htspVideoPackets=\(health.videoPacketCount) "
            + "htspVideoBytes=\(health.videoPayloadBytes) "
            + "lastHTSPVideo=\(ageDescription(health.lastVideoPacketAt)) "
            + "htspAudioPackets=\(health.audioPacketCount) "
            + "htspAudioBytes=\(health.audioPayloadBytes) "
            + "lastHTSPAudio=\(ageDescription(health.lastAudioPacketAt)) "
            + "vlcPictures=\(output.displayedPictures) "
            + "vlcAudioBuffers=\(output.playedAudioBuffers) "
            + "tsStartup={\(health.transportStartup.summary)}"
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

                let reader = stream.makeVLCReader()
                retainedNativeVLCReaders.append(reader)
                let media = Self.makeMedia(stream: reader)
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
#if os(tvOS)
        if usesSampleBufferRendering {
            // LibVLC's custom-memory video callbacks require CPU-accessible
            // frames. VideoToolbox surfaces cannot be handed to the RV32
            // callback and otherwise leave audio playing with no video.
            media.addOption(":avcodec-hw=none")
            media.addOption(":no-avcodec-dr")
        }
#endif
    }

    private static func makeMedia(stream: InputStream) -> VLCMedia {
        guard let media = VLCMedia(stream: stream) else {
            preconditionFailure("VLC 4 rejected the native input stream")
        }
        return media
    }

    private static func makeMedia(url: URL) -> VLCMedia {
        guard let media = VLCMedia(url: url) else {
            preconditionFailure("VLC 4 rejected the media URL")
        }
        return media
    }

#if os(tvOS)
    private func armSampleBufferFallbackIfNeeded() {
        guard usesSampleBufferRendering, !sampleBufferBridge.isReady,
              sampleBufferFallbackTask == nil
        else { return }

        sampleBufferFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                  let self,
                  self.usesSampleBufferRendering,
                  !self.sampleBufferBridge.isReady,
                  let request = self.activeRequest
            else { return }

            self.sampleBufferFallbackTask = nil
            self.logger.error(
                "No sample-buffer video frame arrived; reverting to VLC's native video output"
            )
            self.mediaPlayer.stop()
            self.sampleBufferBridge.removeVideoCallbacks()
            self.sampleBufferBridge.flush()
            self.usesSampleBufferRendering = false
            self.isPictureInPictureReady = false

            do {
                try await self.prepare(request)
                guard !Task.isCancelled else { return }
                self.play()
            } catch {
                self.setState(.failed(error.localizedDescription))
            }
        }
    }
#endif

    private func resumeLocalPlaybackAfterTimeshiftNavigation() {
        timeshiftNavigationDebugState = "resuming VLC after navigation"
        isPrimingPausedSeekFrame = false
        concealsSeekAfterPausedFrameCapture = false
        pauseRequested = false
        nativeInputStream?.play()
        let waitsForPlaybackProgress = livePlaybackPosition.requestResume(
            from: playbackOutputCounters
        )
        if postSeekOutputGate.isArmed,
           nativeInputStream?.healthSnapshot.expectsVideo == true {
            // Decode a bounded run of destination pictures behind the held
            // pre-seek frame. VLC 4 drains the discontinuity reliably at 1×;
            // accelerating here leaks fast audio and can starve video after
            // the output gate opens.
            postSeekOutputGate.requireDisplayedPictures(12)
            // VLC can publish a burst of destination pictures and then pause
            // video for roughly half a second while audio continues. Require
            // a full second of wall-clock output and a picture advancing in
            // the reveal observation; VLC's startup clock is not monotonic.
            postSeekOutputGate.requireSustainedOutput(1)
        }
        playbackRate = 1
        beginPostSeekOutputConcealmentIfNeeded()
        mediaPlayer.play()
        mediaPlayer.rate = 1
        setState(waitsForPlaybackProgress ? .preparing : (hasStartedPlayback ? .playing : .preparing))
        lastMetricsUpdate = Date()
    }

    private func replaceVLCPipelineAfterTimeshiftNavigation() async {
        guard let stream = nativeInputStream, let request = activeRequest else { return }
#if DEBUG
        let replacementStartedAt = ProcessInfo.processInfo.systemUptime
#endif
        mediaPlayer.stop()
        // LibVLC 4 stops asynchronously. Installing and playing the fresh
        // media before the Stopped callback lets the old input teardown race
        // the replacement decoder, producing a long video-only stall.
        for _ in 0..<200 where mediaPlayer.state != .stopped {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
#if DEBUG
        let stoppedAt = ProcessInfo.processInfo.systemUptime
#endif
        let reader = stream.makeVLCReader()
        retainedNativeVLCReaders.append(reader)
        let media = Self.makeMedia(stream: reader)
        media.addOption(":demux=ts")
        addCachingOptions(to: media, milliseconds: request.networkCachingMilliseconds)
        mediaPlayer.media = media
        postSeekOutputGate.markPipelineRecreated()
#if DEBUG
        let installedAt = ProcessInfo.processInfo.systemUptime
        if timeshiftSeekPhaseTrace != nil {
            timeshiftSeekPhaseTrace?.pipelineBaseline = playbackOutputCounters
            traceTimeshiftSeekPhase(
                String(
                    format: "pipeline-installed stop=%.1fms install=%.1fms",
                    (stoppedAt - replacementStartedAt) * 1_000,
                    (installedAt - stoppedAt) * 1_000
                )
            )
        }
#endif
        outputHealthMonitor.restartGracePeriod(
            output: PlaybackOutputCounters(displayedPictures: 0, playedAudioBuffers: 0),
            at: Date()
        )
        logger.info("Recreated VLC pipeline at the selected timeshift position")
    }

    var nativeTimeshiftHealthSnapshot: HTSPStreamHealthSnapshot? {
        nativeInputStream?.healthSnapshot
    }

    private func applyNavigationLanding(
        _ navigation: HTSPNavigationResult,
        at date: Date = Date()
    ) {
        postSeekOutputGate.requirePrerollDuration(navigation.prerollDuration)
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
        func count(_ value: UInt64) -> Int {
            value <= UInt64(Int.max) ? Int(value) : 0
        }
        return PlaybackOutputCounters(
            displayedPictures: count(statistics?.displayedPictures ?? 0),
            playedAudioBuffers: count(statistics?.playedAudioBuffers ?? 0),
            demuxDiscontinuities: count(statistics?.demuxDiscontinuity ?? 0),
            playbackTimeMilliseconds: mediaPlayer.time.intValue > 0
                ? Int64(mediaPlayer.time.intValue)
                : nil
        )
    }

    private func beginPostSeekOutputConcealmentIfNeeded() {
        guard postSeekOutputGate.beginConcealing(from: playbackOutputCounters) else { return }
        concealPlaybackOutput()
    }

    private func concealPlaybackOutput() {
        guard !isPlaybackOutputConcealed else { return }

        isPlaybackOutputConcealed = true
        if let audio = mediaPlayer.audio, !audio.isMuted {
            audio.isMuted = true
            shouldRestoreAudioAfterOutputGate = true
        }
    }

    private func updatePostSeekOutputGate(
        with output: PlaybackOutputCounters,
        at date: Date
    ) {
#if DEBUG
        traceTimeshiftSeekOutput(output, at: date)
#endif
        guard postSeekOutputGate.observe(output, at: date) else { return }
        if isPrimingPausedSeekFrame {
            isPrimingPausedSeekFrame = false
            mediaPlayer.rate = 1
            playbackRate = 1
            mediaPlayer.pause()
            setState(.paused)
            timeshiftNavigationDebugState = "paused on selected frame"
            // Reveal VLC's verified destination picture before replacing the
            // frozen pre-seek snapshot. This prevents a transient black frame
            // between the two published updates.
            revealPostSeekPlaybackOutput()
            capturePausedFrame()
        } else {
            revealPostSeekPlaybackOutput()
        }
        logger.info("Revealed stable VLC output after the post-seek discontinuity")
#if DEBUG
        traceTimeshiftSeekPhase("output-revealed")
        timeshiftSeekPhaseTrace = nil
#endif
    }

#if DEBUG
    private func beginTimeshiftSeekPhaseTrace() {
        timeshiftSeekPhaseTrace = TimeshiftSeekPhaseTrace(
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        traceTimeshiftSeekPhase("navigation-started")
    }

    private func traceTimeshiftSeekPhase(_ detail: String) {
        guard let trace = timeshiftSeekPhaseTrace else { return }
        let elapsed = (ProcessInfo.processInfo.systemUptime - trace.startedAt) * 1_000
        print(String(format: "VLC_TIMESHIFT_PHASE +%.1fms %@", elapsed, detail))
        fflush(stdout)
    }

    private func traceTimeshiftSeekOutput(
        _ output: PlaybackOutputCounters,
        at date: Date
    ) {
        guard var trace = timeshiftSeekPhaseTrace else { return }
        if let baseline = trace.pipelineBaseline {
            if !trace.didLogFirstAudio,
               output.playedAudioBuffers > baseline.playedAudioBuffers {
                trace.didLogFirstAudio = true
                timeshiftSeekPhaseTrace = trace
                traceTimeshiftSeekPhase("first-audio-output")
            }
            if !trace.didLogFirstVideo,
               output.displayedPictures > baseline.displayedPictures {
                trace.didLogFirstVideo = true
                timeshiftSeekPhaseTrace = trace
                traceTimeshiftSeekPhase("first-video-output")
            }
        }

        let diagnostics = postSeekOutputGate.diagnostics(for: output, at: date)
        if diagnostics.phase != trace.lastGatePhase {
            trace.lastGatePhase = diagnostics.phase
            timeshiftSeekPhaseTrace = trace
            traceTimeshiftSeekPhase(
                "gate=\(diagnostics.phase.rawValue) "
                    + "output=\(diagnostics.sustainedOutputMilliseconds)/"
                    + "\(diagnostics.requiredSustainedOutputMilliseconds)ms "
                    + "pictures=\(diagnostics.displayedPictureAdvance)/"
                    + "\(diagnostics.requiredDisplayedPictureAdvance)"
            )
        } else {
            timeshiftSeekPhaseTrace = trace
        }
    }
#endif

    private func suspendPostSeekOutputConcealment() {
        guard !isPrimingPausedSeekFrame else { return }
        guard postSeekOutputGate.suspendConcealing() else { return }
        revealPostSeekPlaybackOutput()
    }

    private func cancelPostSeekOutputGate() {
        isReplacingPipelineForTimeshiftSeek = false
        isPrimingPausedSeekFrame = false
        concealsSeekAfterPausedFrameCapture = false
        postSeekOutputGate.cancel()
#if DEBUG
        timeshiftSeekPhaseTrace = nil
#endif
        revealPostSeekPlaybackOutput()
    }

    private func primePausedFrameAfterTimeshiftNavigation() {
        timeshiftNavigationDebugState = "decoding selected frame while paused"
        isPrimingPausedSeekFrame = true
        concealsSeekAfterPausedFrameCapture = false
        pauseRequested = true
        nativeInputStream?.pause()
        if nativeInputStream?.healthSnapshot.expectsVideo == true {
            postSeekOutputGate.requireDisplayedPicture()
        }
        playbackRate = 1
        beginPostSeekOutputConcealmentIfNeeded()
        mediaPlayer.play()
        mediaPlayer.rate = 1
        setState(.paused)
        lastMetricsUpdate = Date()
    }

    private func revealPostSeekPlaybackOutput() {
        if mediaPlayer.rate != 1 {
            mediaPlayer.rate = 1
        }
        if isPlaybackOutputConcealed { isPlaybackOutputConcealed = false }
        if shouldRestoreAudioAfterOutputGate {
            mediaPlayer.audio?.isMuted = false
            shouldRestoreAudioAfterOutputGate = false
        }
    }

    private func confirmPlaybackResumeIfOutputAdvanced(
        output: PlaybackOutputCounters,
        at date: Date
    ) {
        guard livePlaybackPosition.observePlaybackOutput(
            output,
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
            suspendPostSeekOutputConcealment()
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
            let preservesCurrentPausedFrame = pauseRequested || state == .paused
            cancelPostSeekOutputGate()
            if !preservesCurrentPausedFrame {
                clearPausedFrame()
            }
            postSeekOutputGate.arm(from: playbackOutputCounters)
#if DEBUG
            beginTimeshiftSeekPhaseTrace()
#endif
            isReplacingPipelineForTimeshiftSeek = true
            let hasCurrentPausedFrame = preservesCurrentPausedFrame && pausedFrame != nil
            if hasCurrentPausedFrame, postSeekOutputGate.concealImmediately() {
                concealPlaybackOutput()
            }
            anchorLivePlaybackPositionIfNeeded()
            publishLivePlaybackMarker()
            pauseRequested = true
            mediaPlayer.rate = 1
            playbackRate = 1
            mediaPlayer.pause()
            setState(.paused)
            if !hasCurrentPausedFrame {
                // Keep VLC's just-paused drawable visible until its matching
                // snapshot is ready. The snapshot then takes over before VLC
                // is allowed to decode the destination behind it.
                concealsSeekAfterPausedFrameCapture = true
                capturePausedFrame()
            }
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
        let vlcAudioTracks = mediaPlayer.audioTracks
        let updatedAudioTracks = vlcAudioTracks.enumerated().map { index, track in
            PlaybackTrack(id: index, name: track.trackName)
        }
        if audioTracks != updatedAudioTracks { audioTracks = updatedAudioTracks }
        let updatedAudioTrackID = vlcAudioTracks.firstIndex { $0.isSelected }
        if selectedAudioTrackID != updatedAudioTrackID {
            selectedAudioTrackID = updatedAudioTrackID
        }

        let vlcSubtitleTracks = mediaPlayer.textTracks
        let updatedSubtitleTracks = vlcSubtitleTracks.enumerated().map { index, track in
            PlaybackTrack(id: index, name: track.trackName)
        }
        if subtitleTracks != updatedSubtitleTracks { subtitleTracks = updatedSubtitleTracks }
        let updatedSubtitleTrackID = vlcSubtitleTracks.firstIndex { $0.isSelected }
        if selectedSubtitleTrackID != updatedSubtitleTrackID {
            selectedSubtitleTrackID = updatedSubtitleTrackID
        }
    }

    private func refreshTechnicalDetails() {
        guard let media = mediaPlayer.media else { return }

        let tracks = media.tracksInformation
        let video = tracks.first { $0.type == .video }
        let audio = tracks.first { $0.type == .audio }
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

        if let videoDetails = video?.video,
           videoDetails.width > 0, videoDetails.height > 0 {
            details.append(
                PlaybackTechnicalDetail(
                    label: "Resolution",
                    value: "\(videoDetails.width) × \(videoDetails.height)"
                )
            )
        }
        if let codec = video.map({ $0.codecName() }), !codec.isEmpty {
            details.append(PlaybackTechnicalDetail(label: "Video", value: codec))
        }
        if let codec = audio.map({ $0.codecName() }), !codec.isEmpty {
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
        isPrimingPausedSeekFrame = false
        concealsSeekAfterPausedFrameCapture = false
        recoveryReason = nil
        recoveryAttempt = 0
        nativeTimeshiftRecoveryCount = 0
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

#if canImport(UIKit)
struct VLCVideoSurface: UIViewRepresentable {
    let mediaPlayer: VLCMediaPlayer
    let attachmentRevision: Int
    let isActive: Bool
    let fadesLeadingEdge: Bool
    let leadingFadeInset: CGFloat
    let isOutputConcealed: Bool
    let concealmentImage: PlatformImage?

    init(
        mediaPlayer: VLCMediaPlayer,
        attachmentRevision: Int = 0,
        isActive: Bool = true,
        fadesLeadingEdge: Bool = false,
        leadingFadeInset: CGFloat = 0,
        isOutputConcealed: Bool = false,
        concealmentImage: PlatformImage? = nil
    ) {
        self.mediaPlayer = mediaPlayer
        self.attachmentRevision = attachmentRevision
        self.isActive = isActive
        self.fadesLeadingEdge = fadesLeadingEdge
        self.leadingFadeInset = leadingFadeInset
        self.isOutputConcealed = isOutputConcealed
        self.concealmentImage = concealmentImage
    }

    func makeUIView(context: Context) -> UIView {
        VLCVideoContainerView(
            mediaPlayer: mediaPlayer,
            attachmentRevision: attachmentRevision,
            isActive: isActive,
            fadesLeadingEdge: fadesLeadingEdge,
            leadingFadeInset: leadingFadeInset,
            isOutputConcealed: isOutputConcealed,
            concealmentImage: concealmentImage
        )
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? VLCVideoContainerView)?.updateAttachment(
            revision: attachmentRevision,
            isActive: isActive,
            fadesLeadingEdge: fadesLeadingEdge,
            leadingFadeInset: leadingFadeInset,
            isOutputConcealed: isOutputConcealed,
            concealmentImage: concealmentImage
        )
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        (uiView as? VLCVideoContainerView)?.detachIfOwned()
    }
}

private final class VLCVideoContainerView: UIView {
    private weak var mediaPlayer: VLCMediaPlayer?
    private var attachmentRevision: Int
    private var isActive: Bool
    private var fadesLeadingEdge: Bool
    private var leadingFadeInset: CGFloat
    private var attachedBoundsSize = CGSize.zero
    private let leadingFadeMask = CAGradientLayer()
    private let concealmentView = UIImageView()

    init(
        mediaPlayer: VLCMediaPlayer,
        attachmentRevision: Int,
        isActive: Bool,
        fadesLeadingEdge: Bool,
        leadingFadeInset: CGFloat,
        isOutputConcealed: Bool,
        concealmentImage: PlatformImage?
    ) {
        self.mediaPlayer = mediaPlayer
        self.attachmentRevision = attachmentRevision
        self.isActive = isActive
        self.fadesLeadingEdge = fadesLeadingEdge
        self.leadingFadeInset = leadingFadeInset
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        layer.masksToBounds = true
        concealmentView.backgroundColor = .black
        concealmentView.contentMode = .scaleAspectFill
        concealmentView.clipsToBounds = true
        concealmentView.isUserInteractionEnabled = false
        concealmentView.image = concealmentImage
        concealmentView.isHidden = !isOutputConcealed
        addSubview(concealmentView)
        updateLeadingFadeMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            detachIfOwned()
        } else if isActive {
            attachIfVisible()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isActive, bounds.width > 1, bounds.height > 1 else { return }

        if attachedBoundsSize != bounds.size {
            attachedBoundsSize = bounds.size
            updateLeadingFadeMask()
        }
        resizeVideoSubviews()
        concealmentView.frame = bounds
        bringSubviewToFront(concealmentView)
        attachIfVisible()
    }

    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        // VLC 4 creates its renderer at the drawable's current size. Keep that
        // one renderer attached and resize it as this persistent surface moves
        // between the guide preview and full-screen playback. Reassigning the
        // drawable here creates an additional renderer on every transition.
        subview.frame = bounds
        subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if subview !== concealmentView { bringSubviewToFront(concealmentView) }
    }

    private func resizeVideoSubviews() {
        for subview in subviews where subview !== concealmentView && subview.frame != bounds {
            subview.frame = bounds
        }
    }

    func updateAttachment(
        revision: Int,
        isActive: Bool,
        fadesLeadingEdge: Bool,
        leadingFadeInset: CGFloat,
        isOutputConcealed: Bool,
        concealmentImage: PlatformImage?
    ) {
        let mustReattach = revision != attachmentRevision
        attachmentRevision = revision
        self.isActive = isActive
        if self.fadesLeadingEdge != fadesLeadingEdge || self.leadingFadeInset != leadingFadeInset {
            self.fadesLeadingEdge = fadesLeadingEdge
            self.leadingFadeInset = leadingFadeInset
            updateLeadingFadeMask()
        }
        concealmentView.image = concealmentImage
        concealmentView.isHidden = !isOutputConcealed
        if isOutputConcealed { bringSubviewToFront(concealmentView) }
        guard isActive else {
            detachIfOwned()
            return
        }
        attachIfVisible(force: mustReattach)
    }

    private func updateLeadingFadeMask() {
        guard fadesLeadingEdge else {
            layer.mask = nil
            return
        }
        leadingFadeMask.frame = bounds
        leadingFadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        leadingFadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        leadingFadeMask.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.48).cgColor,
            UIColor.black.cgColor,
            UIColor.black.cgColor,
        ]
        let width = max(1, bounds.width)
        let visibleWidth = max(1, width - leadingFadeInset)
        let fadeStart = min(1, max(0, leadingFadeInset / width))
        let fadeMidpoint = min(
            1,
            max(fadeStart, (leadingFadeInset + visibleWidth * GuideArtworkStyle.fadeMidpoint) / width)
        )
        let fadeCompletion = min(
            1,
            max(fadeMidpoint, (leadingFadeInset + visibleWidth * GuideArtworkStyle.fadeCompletion) / width)
        )
        leadingFadeMask.locations = [
            NSNumber(value: Double(fadeStart)),
            NSNumber(value: Double(fadeMidpoint)),
            NSNumber(value: Double(fadeCompletion)),
            1,
        ]
        layer.mask = leadingFadeMask
    }

    func attachIfVisible(force: Bool = false) {
        guard window != nil, let mediaPlayer else { return }
        configureVideoSizing(mediaPlayer)
        if !force, let current = mediaPlayer.drawable as? UIView, current === self { return }

        // An explicit attachment revision is reserved for recovery/test
        // surfaces. Normal layout changes keep the existing renderer alive.
        mediaPlayer.drawable = nil
        mediaPlayer.drawable = self
        configureVideoSizing(mediaPlayer)
    }

    private func configureVideoSizing(_ mediaPlayer: VLCMediaPlayer) {
        mediaPlayer.scaleFactor = 0
    }

    func detachIfOwned() {
        guard let mediaPlayer,
              let current = mediaPlayer.drawable as? UIView,
              current === self
        else { return }
        mediaPlayer.drawable = nil
    }
}
#elseif os(macOS)
struct VLCVideoSurface: NSViewRepresentable {
    let mediaPlayer: VLCMediaPlayer
    let attachmentRevision: Int
    let isActive: Bool
    let fadesLeadingEdge: Bool
    let leadingFadeInset: CGFloat
    let isOutputConcealed: Bool
    let concealmentImage: PlatformImage?

    init(
        mediaPlayer: VLCMediaPlayer,
        attachmentRevision: Int = 0,
        isActive: Bool = true,
        fadesLeadingEdge: Bool = false,
        leadingFadeInset: CGFloat = 0,
        isOutputConcealed: Bool = false,
        concealmentImage: PlatformImage? = nil
    ) {
        self.mediaPlayer = mediaPlayer
        self.attachmentRevision = attachmentRevision
        self.isActive = isActive
        self.fadesLeadingEdge = fadesLeadingEdge
        self.leadingFadeInset = leadingFadeInset
        self.isOutputConcealed = isOutputConcealed
        self.concealmentImage = concealmentImage
    }

    func makeNSView(context: Context) -> NSView {
        VLCVideoContainerView(
            mediaPlayer: mediaPlayer,
            attachmentRevision: attachmentRevision,
            isActive: isActive,
            fadesLeadingEdge: fadesLeadingEdge,
            leadingFadeInset: leadingFadeInset,
            isOutputConcealed: isOutputConcealed,
            concealmentImage: concealmentImage
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? VLCVideoContainerView)?.updateAttachment(
            revision: attachmentRevision,
            isActive: isActive,
            fadesLeadingEdge: fadesLeadingEdge,
            leadingFadeInset: leadingFadeInset,
            isOutputConcealed: isOutputConcealed,
            concealmentImage: concealmentImage
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? VLCVideoContainerView)?.detachIfOwned()
    }
}

private final class VLCVideoContainerView: NSView {
    private weak var mediaPlayer: VLCMediaPlayer?
    private var attachmentRevision: Int
    private var isActive: Bool
    private var fadesLeadingEdge: Bool
    private var leadingFadeInset: CGFloat
    private var attachedBoundsSize = CGSize.zero
    private let leadingFadeMask = CAGradientLayer()
    private let concealmentView = NSImageView()

    init(
        mediaPlayer: VLCMediaPlayer,
        attachmentRevision: Int,
        isActive: Bool,
        fadesLeadingEdge: Bool,
        leadingFadeInset: CGFloat,
        isOutputConcealed: Bool,
        concealmentImage: PlatformImage?
    ) {
        self.mediaPlayer = mediaPlayer
        self.attachmentRevision = attachmentRevision
        self.isActive = isActive
        self.fadesLeadingEdge = fadesLeadingEdge
        self.leadingFadeInset = leadingFadeInset
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        concealmentView.wantsLayer = true
        concealmentView.layer?.backgroundColor = NSColor.black.cgColor
        concealmentView.layer?.contentsGravity = .resizeAspectFill
        concealmentView.imageScaling = .scaleProportionallyUpOrDown
        concealmentView.image = concealmentImage
        concealmentView.isHidden = !isOutputConcealed
        addSubview(concealmentView)
        updateLeadingFadeMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            detachIfOwned()
        } else if isActive {
            attachIfVisible()
        }
    }

    override func layout() {
        super.layout()
        guard isActive, bounds.width > 1, bounds.height > 1 else { return }

        if attachedBoundsSize != bounds.size {
            attachedBoundsSize = bounds.size
            updateLeadingFadeMask()
        }
        resizeVideoSubviews()
        concealmentView.frame = bounds
        if concealmentView.superview === self {
            addSubview(concealmentView, positioned: .above, relativeTo: nil)
        }
        attachIfVisible()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        subview.frame = bounds
        subview.autoresizingMask = [.width, .height]
        if subview !== concealmentView {
            addSubview(concealmentView, positioned: .above, relativeTo: subview)
        }
    }

    private func resizeVideoSubviews() {
        for subview in subviews where subview !== concealmentView && subview.frame != bounds {
            subview.frame = bounds
        }
    }

    func updateAttachment(
        revision: Int,
        isActive: Bool,
        fadesLeadingEdge: Bool,
        leadingFadeInset: CGFloat,
        isOutputConcealed: Bool,
        concealmentImage: PlatformImage?
    ) {
        let mustReattach = revision != attachmentRevision
        attachmentRevision = revision
        self.isActive = isActive
        if self.fadesLeadingEdge != fadesLeadingEdge || self.leadingFadeInset != leadingFadeInset {
            self.fadesLeadingEdge = fadesLeadingEdge
            self.leadingFadeInset = leadingFadeInset
            updateLeadingFadeMask()
        }
        concealmentView.image = concealmentImage
        concealmentView.isHidden = !isOutputConcealed
        if isOutputConcealed {
            addSubview(concealmentView, positioned: .above, relativeTo: nil)
        }
        guard isActive else {
            detachIfOwned()
            return
        }
        attachIfVisible(force: mustReattach)
    }

    private func updateLeadingFadeMask() {
        guard fadesLeadingEdge else {
            layer?.mask = nil
            return
        }
        leadingFadeMask.frame = bounds
        leadingFadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        leadingFadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        leadingFadeMask.colors = [
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.48).cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
        ]
        let width = max(1, bounds.width)
        let visibleWidth = max(1, width - leadingFadeInset)
        let fadeStart = min(1, max(0, leadingFadeInset / width))
        let fadeMidpoint = min(
            1,
            max(fadeStart, (leadingFadeInset + visibleWidth * GuideArtworkStyle.fadeMidpoint) / width)
        )
        let fadeCompletion = min(
            1,
            max(fadeMidpoint, (leadingFadeInset + visibleWidth * GuideArtworkStyle.fadeCompletion) / width)
        )
        leadingFadeMask.locations = [
            NSNumber(value: Double(fadeStart)),
            NSNumber(value: Double(fadeMidpoint)),
            NSNumber(value: Double(fadeCompletion)),
            1,
        ]
        layer?.mask = leadingFadeMask
    }

    private func attachIfVisible(force: Bool = false) {
        guard window != nil, let mediaPlayer else { return }
        configureVideoSizing(mediaPlayer)
        if !force, let current = mediaPlayer.drawable as? NSView, current === self { return }
        mediaPlayer.drawable = nil
        mediaPlayer.drawable = self
        configureVideoSizing(mediaPlayer)
    }

    private func configureVideoSizing(_ mediaPlayer: VLCMediaPlayer) {
        mediaPlayer.scaleFactor = 0
    }

    func detachIfOwned() {
        guard let mediaPlayer,
              let current = mediaPlayer.drawable as? NSView,
              current === self
        else { return }
        mediaPlayer.drawable = nil
    }
}
#endif
