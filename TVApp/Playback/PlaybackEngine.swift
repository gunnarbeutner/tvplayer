import Foundation
import OSLog
import SwiftUI
#if os(tvOS)
@preconcurrency import TVVLCKit
import UIKit
#elseif os(iOS)
@preconcurrency import MobileVLCKit
import UIKit
#elseif os(macOS)
@preconcurrency import VLCKit
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
    // Match TVHeadend's 400% post-seek prebuffer rate. Faster local draining
    // can outrun the replacement stream and destabilize VLC.
    private static let postSeekDrainRate: Float = 4
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
#if os(tvOS)
    @Published private(set) var isPictureInPictureReady = false
    @Published private(set) var usesSampleBufferRendering = false
    let sampleBufferBridge: TVPlayerSampleBufferBridge
    private var sampleBufferFallbackTask: Task<Void, Never>?
#endif

    let mediaPlayer: VLCMediaPlayer

    private var nativeInputStream: HTSPLiveInputStream?
    private var nativeTimeshiftActions: NativeTimeshiftActionController?
    private var nativeTimeshiftSessionID: UUID?
    private var pipelineRecoveryTask: Task<Void, Never>?
    private var pipelineRecoveryID: UUID?
    private var recoveryReason: PlaybackRecoveryReason?
    private var recoveryAttempt = 0
    private var outputHealthMonitor = PlaybackOutputHealthMonitor()
    private var postSeekOutputGate = PostSeekPlaybackOutputGate()
    private var shouldRestoreAudioAfterOutputGate = false
    private var isPrimingPausedSeekFrame = false
    private var concealsSeekAfterPausedFrameCapture = false
    private var navigationShouldResume = true
    private var pauseRequested = false
    private var livePlaybackPosition = LivePlaybackPositionTracker()
    private var lastMetricsUpdate = Date()
    private var hasStartedPlayback = false
    private var didLogCapabilities = false
    private var activeRequest: LiveStreamRequest?
    private var pendingSnapshotURL: URL?

    override init() {
        mediaPlayer = VLCMediaPlayer()
#if os(tvOS)
        sampleBufferBridge = TVPlayerSampleBufferBridge(mediaPlayer: mediaPlayer)
#endif
        super.init()
        mediaPlayer.delegate = self
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

#if canImport(UIKit)
        if let drawable = mediaPlayer.drawable as? UIView,
           let image = captureRenderedVideoSurface(drawable) {
            let shouldConcealSeek = concealsSeekAfterPausedFrameCapture
            concealsSeekAfterPausedFrameCapture = false
            installPausedFrame(image, shouldConcealSeek: shouldConcealSeek)
            return
        }
#endif

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

#if canImport(UIKit)
    private func captureRenderedVideoSurface(_ view: UIView) -> UIImage? {
        guard view.bounds.width > 0, view.bounds.height > 0, view.window != nil else { return nil }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        format.scale = view.traitCollection.displayScale
        format.preferredRange = .extended
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        var captured = false
        let image = renderer.image { _ in
            captured = view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        return captured ? image : nil
    }
#endif

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
        let output = playbackOutputCounters
        updatePostSeekOutputGate(with: output)
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

    func waitForVideoOutput() async -> Bool {
        for _ in 0..<150 {
            guard !Task.isCancelled else { return false }
            if mediaPlayer.hasVideoOut { return true }
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
                let navigationSucceeded: Bool
                switch result {
                case let .success(navigation):
                    navigationSucceeded = true
                    self.timeshiftNavigationDebugState = "server navigation completed"
                    self.applyNavigationLanding(navigation)
                case let .failure(error):
                    navigationSucceeded = false
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

        nativeTimeshiftRecoveryCount += 1
        logger.error("Restarting stalled VLC pipeline: \(detail, privacy: .public)")
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
        // VLC may still have many seconds of pre-seek transport data queued
        // ahead of the discontinuity marker. Drain it quickly while output is
        // hidden and muted, then restore normal rate when the new epoch is
        // ready to reveal.
        let drainsQueuedOutput = postSeekOutputGate.isArmed
        if drainsQueuedOutput, mediaPlayer.hasVideoOut {
            // A few pictures can already be decoded behind VLC's demux
            // discontinuity. Drain that bounded vout queue while the frozen
            // seek frame remains visible. Paused seeks use a separate path
            // which stops on the first verified target picture.
            postSeekOutputGate.requireDisplayedPictures(6)
        }
        playbackRate = 1
        beginPostSeekOutputConcealmentIfNeeded()
        mediaPlayer.play()
        mediaPlayer.rate = drainsQueuedOutput ? Self.postSeekDrainRate : 1
        setState(waitsForPlaybackProgress ? .preparing : (hasStartedPlayback ? .playing : .preparing))
        lastMetricsUpdate = Date()
    }

    var nativeTimeshiftHealthSnapshot: HTSPStreamHealthSnapshot? {
        nativeInputStream?.healthSnapshot
    }

    private func applyNavigationLanding(
        _ navigation: HTSPNavigationResult,
        at date: Date = Date()
    ) {
        postSeekOutputGate.requirePlaybackProgress(navigation.prerollDuration)
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
            demuxDiscontinuities: Int(statistics?.demuxDiscontinuity ?? 0),
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

    private func updatePostSeekOutputGate(with output: PlaybackOutputCounters) {
        guard postSeekOutputGate.observe(output) else { return }
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
        logger.info("Revealed VLC output after the post-seek discontinuity")
    }

    private func suspendPostSeekOutputConcealment() {
        guard !isPrimingPausedSeekFrame else { return }
        guard postSeekOutputGate.suspendConcealing() else { return }
        revealPostSeekPlaybackOutput()
    }

    private func cancelPostSeekOutputGate() {
        isPrimingPausedSeekFrame = false
        concealsSeekAfterPausedFrameCapture = false
        postSeekOutputGate.cancel()
        revealPostSeekPlaybackOutput()
    }

    private func primePausedFrameAfterTimeshiftNavigation() {
        timeshiftNavigationDebugState = "decoding selected frame while paused"
        isPrimingPausedSeekFrame = true
        concealsSeekAfterPausedFrameCapture = false
        pauseRequested = true
        nativeInputStream?.pause()
        if mediaPlayer.hasVideoOut {
            postSeekOutputGate.requireDisplayedPicture()
        }
        playbackRate = 1
        beginPostSeekOutputConcealmentIfNeeded()
        mediaPlayer.play()
        mediaPlayer.rate = postSeekOutputGate.isArmed ? Self.postSeekDrainRate : 1
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

    init(
        mediaPlayer: VLCMediaPlayer,
        attachmentRevision: Int = 0,
        isActive: Bool = true,
        fadesLeadingEdge: Bool = false,
        leadingFadeInset: CGFloat = 0
    ) {
        self.mediaPlayer = mediaPlayer
        self.attachmentRevision = attachmentRevision
        self.isActive = isActive
        self.fadesLeadingEdge = fadesLeadingEdge
        self.leadingFadeInset = leadingFadeInset
    }

    func makeUIView(context: Context) -> UIView {
        VLCVideoContainerView(
            mediaPlayer: mediaPlayer,
            attachmentRevision: attachmentRevision,
            isActive: isActive,
            fadesLeadingEdge: fadesLeadingEdge,
            leadingFadeInset: leadingFadeInset
        )
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? VLCVideoContainerView)?.updateAttachment(
            revision: attachmentRevision,
            isActive: isActive,
            fadesLeadingEdge: fadesLeadingEdge,
            leadingFadeInset: leadingFadeInset
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

    init(
        mediaPlayer: VLCMediaPlayer,
        attachmentRevision: Int,
        isActive: Bool,
        fadesLeadingEdge: Bool,
        leadingFadeInset: CGFloat
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
        guard isActive, bounds.width > 1, bounds.height > 1,
              attachedBoundsSize != bounds.size
        else { return }

        attachedBoundsSize = bounds.size
        updateLeadingFadeMask()
        // SwiftUI installs representable views before assigning their final
        // frame. Rebind once that frame is known so VLC sizes and positions
        // its video output for the guide preview rather than the old player.
        attachIfVisible(force: true)
    }

    func updateAttachment(
        revision: Int,
        isActive: Bool,
        fadesLeadingEdge: Bool,
        leadingFadeInset: CGFloat
    ) {
        let mustReattach = revision != attachmentRevision
        attachmentRevision = revision
        self.isActive = isActive
        if self.fadesLeadingEdge != fadesLeadingEdge || self.leadingFadeInset != leadingFadeInset {
            self.fadesLeadingEdge = fadesLeadingEdge
            self.leadingFadeInset = leadingFadeInset
            updateLeadingFadeMask()
        }
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
#elseif os(macOS)
struct VLCVideoSurface: NSViewRepresentable {
    let mediaPlayer: VLCMediaPlayer
    let attachmentRevision: Int
    let isActive: Bool
    let fadesLeadingEdge: Bool
    let leadingFadeInset: CGFloat

    init(
        mediaPlayer: VLCMediaPlayer,
        attachmentRevision: Int = 0,
        isActive: Bool = true,
        fadesLeadingEdge: Bool = false,
        leadingFadeInset: CGFloat = 0
    ) {
        self.mediaPlayer = mediaPlayer
        self.attachmentRevision = attachmentRevision
        self.isActive = isActive
        self.fadesLeadingEdge = fadesLeadingEdge
        self.leadingFadeInset = leadingFadeInset
    }

    func makeNSView(context: Context) -> NSView {
        VLCVideoContainerView(
            mediaPlayer: mediaPlayer,
            attachmentRevision: attachmentRevision,
            isActive: isActive,
            fadesLeadingEdge: fadesLeadingEdge,
            leadingFadeInset: leadingFadeInset
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? VLCVideoContainerView)?.updateAttachment(
            revision: attachmentRevision,
            isActive: isActive,
            fadesLeadingEdge: fadesLeadingEdge,
            leadingFadeInset: leadingFadeInset
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

    init(
        mediaPlayer: VLCMediaPlayer,
        attachmentRevision: Int,
        isActive: Bool,
        fadesLeadingEdge: Bool,
        leadingFadeInset: CGFloat
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
        guard attachedBoundsSize != bounds.size else { return }

        attachedBoundsSize = bounds.size
        updateLeadingFadeMask()
        guard isActive, bounds.width > 1, bounds.height > 1 else { return }

        // SwiftUI can resize the persistent drawable from full-screen player
        // dimensions to the guide preview without replacing its NSView. Force
        // VLC to bind again once AppKit has assigned the new frame.
        attachIfVisible(force: true)
    }

    func updateAttachment(
        revision: Int,
        isActive: Bool,
        fadesLeadingEdge: Bool,
        leadingFadeInset: CGFloat
    ) {
        let mustReattach = revision != attachmentRevision
        attachmentRevision = revision
        self.isActive = isActive
        if self.fadesLeadingEdge != fadesLeadingEdge || self.leadingFadeInset != leadingFadeInset {
            self.fadesLeadingEdge = fadesLeadingEdge
            self.leadingFadeInset = leadingFadeInset
            updateLeadingFadeMask()
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
        if !force, let current = mediaPlayer.drawable as? NSView, current === self { return }
        mediaPlayer.drawable = nil
        mediaPlayer.drawable = self
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
