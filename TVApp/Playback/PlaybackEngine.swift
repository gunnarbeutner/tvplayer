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
    case failed(String)
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

    let mediaPlayer: VLCMediaPlayer

    private var nativeInputStream: HTSPLiveInputStream?
    private var nativeTimeshiftActions: NativeTimeshiftActionController?
    private var nativeTimeshiftSessionID: UUID?
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
                    stream.setNavigationCompletionHandler { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self, self.nativeTimeshiftSessionID == sessionID else { return }
                            self.resumeLocalPlaybackAfterTimeshiftNavigation()
                        }
                    }
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
        media.addOption(":network-caching=\(request.networkCachingMilliseconds)")
        media.addOption(":live-caching=\(request.networkCachingMilliseconds)")
        media.addOption(":file-caching=\(request.networkCachingMilliseconds)")

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
        // A paused native HTSP subscription continues buffering on TVHeadend.
    }

    func finishPrewarmingAtLiveEdge() {
        nativeInputStream?.returnToLive()
    }

    func play() {
        guard nativeInputStream?.isNavigatingTimeshift != true else {
            logger.info("Playback remains paused until TVHeadend completes the timeshift seek")
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
        let waitsForPlaybackProgress = livePlaybackPosition.requestResume(
            from: playbackOutputCounters
        )
        _ = nativeTimeshiftActions?.perform(.play)
        mediaPlayer.play()
        setState(waitsForPlaybackProgress || !wasPaused ? .preparing : .playing)
        lastMetricsUpdate = Date()
    }

    func pause() {
        if activeRequest?.kind.isLive == true, nativeInputStream == nil {
            logger.info("Pause ignored for a live-only HTTP stream")
            return
        }
        anchorLivePlaybackPositionIfNeeded()
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
        setState(.paused)
        refreshPlaybackInformation()
    }

    func stop() {
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
        livePlaybackPosition.playbackDate(
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

        if let nativeTimeshiftActions {
            let navigationDate = Date()
            nativeTimeshiftActions.perform(
                .skipForward(seconds, liveDelay: liveDelaySeconds),
                beforeServerCommands: { [self] effect in
                    applyNativeTimeshiftLocalEffect(effect)
                    guard effect == .pauseUntilNavigationCompletes else { return }
                    livePlaybackPosition.moveAnchor(
                        by: seconds,
                        at: navigationDate,
                        bufferStartedAt: bufferStartedAt
                    )
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
        if let nativeTimeshiftActions {
            let navigationDate = Date()
            nativeTimeshiftActions.perform(
                .skipBackward(seconds),
                beforeServerCommands: { [self] effect in
                    applyNativeTimeshiftLocalEffect(effect)
                    guard effect == .pauseUntilNavigationCompletes else { return }
                    livePlaybackPosition.moveAnchor(
                        by: -seconds,
                        at: navigationDate,
                        bufferStartedAt: bufferStartedAt
                    )
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
        guard let nativeTimeshiftActions else { return }
        let navigationDate = Date()
        nativeTimeshiftActions.perform(
            .returnToLive,
            beforeServerCommands: { [self] effect in
                applyNativeTimeshiftLocalEffect(effect)
                guard effect == .pauseUntilNavigationCompletes else { return }
                livePlaybackPosition.moveAnchorToLive(at: navigationDate)
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
        confirmPlaybackResumeIfOutputAdvanced()

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

        let updatedSeekable = PlaybackCapabilityPolicy.isSeekable(
            isLive: isLive,
            hasNativeTimeshift: nativeInputStream != nil,
            mediaIsSeekable: mediaPlayer.isSeekable
        )
        if isSeekable != updatedSeekable { isSeekable = updatedSeekable }
        let updatedCanPause = PlaybackCapabilityPolicy.canPause(
            isLive: isLive,
            hasNativeTimeshift: nativeInputStream != nil,
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
            } else if livePlaybackPosition.isAwaitingPlaybackProgress {
                setState(.preparing)
            } else {
                setState(hasStartedPlayback || mediaPlayer.hasVideoOut ? .playing : .preparing)
            }
        case .playing, .esAdded:
            hasStartedPlayback = true
            setState(
                pauseRequested
                    ? .paused
                    : (livePlaybackPosition.isAwaitingPlaybackProgress ? .preparing : .playing)
            )
        case .paused:
            anchorLivePlaybackPositionIfNeeded()
            setState(.paused)
        case .error:
            let detail = VLCLibrary.currentErrorMessage
            logger.error("VLC playback failed: \(detail ?? "No additional error was reported", privacy: .public)")
            setState(.failed(detail ?? "VLC could not play this TVHeadend stream."))
        case .stopped, .ended:
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

    private func resumeLocalPlaybackAfterTimeshiftNavigation() {
        pauseRequested = false
        let waitsForPlaybackProgress = livePlaybackPosition.requestResume(
            from: playbackOutputCounters
        )
        mediaPlayer.rate = 1
        playbackRate = 1
        mediaPlayer.play()
        setState(waitsForPlaybackProgress ? .preparing : (hasStartedPlayback ? .playing : .preparing))
        lastMetricsUpdate = Date()
    }

    private var playbackOutputCounters: PlaybackOutputCounters {
        let statistics = mediaPlayer.media?.statistics
        return PlaybackOutputCounters(
            displayedPictures: Int(statistics?.displayedPictures ?? 0),
            playedAudioBuffers: Int(statistics?.playedAudioBuffers ?? 0)
        )
    }

    private func confirmPlaybackResumeIfOutputAdvanced() {
        guard livePlaybackPosition.observePlaybackOutput(playbackOutputCounters) else { return }
        hasStartedPlayback = true
        if !pauseRequested { setState(.playing) }
    }

    private func applyNativeTimeshiftLocalEffect(_ effect: NativeTimeshiftLocalPlaybackEffect) {
        switch effect {
        case .none:
            break
        case .pause:
            anchorLivePlaybackPositionIfNeeded()
            pauseRequested = true
            mediaPlayer.rate = 1
            playbackRate = 1
            mediaPlayer.pause()
            setState(.paused)
        case .resume:
            resumeLocalPlaybackAfterTimeshiftNavigation()
        case .pauseUntilNavigationCompletes:
            anchorLivePlaybackPositionIfNeeded()
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
            delivery = nativeInputStream == nil
                ? "TVheadend HTTP · live only · \(activeProfile)"
                : "TVheadend HTSP · timeshift · \(activeProfile)"
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
        livePlaybackPosition.reset()
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

private struct LegacyPlaybackView: View {
    private enum TrackMenuFocus: Hashable {
        case audio
        case subtitles
    }

    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @ObservedObject var engine: VLCPlaybackEngine
    @State private var showChrome = true
    @State private var chromeActivity = UUID()
    @FocusState private var hiddenPlayerSurfaceFocused: Bool
    @FocusState private var focusedTrackMenu: TrackMenuFocus?

    let presentation: PlaybackPresentation

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCVideoSurface(mediaPlayer: engine.mediaPlayer)
                .ignoresSafeArea()

            if !showChrome {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .focusable()
                    .focused($hiddenPlayerSurfaceFocused)
                    .onTapGesture(perform: revealChrome)
                    .focusEffectDisabled()
                    .accessibilityLabel("Show playback controls")
            }

            if showChrome {
                playbackChrome
                    .transition(.opacity)
            }
        }
        .task(id: presentation.id) {
            if engine.state == .idle {
                await startPlayback(with: presentation.request)
            } else if engine.state == .paused || engine.state == .preparing {
                engine.play()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                engine.refreshPlaybackInformation()
            }
        }
        .task(id: chromeActivity) {
            guard showChrome, engine.state == .playing, focusedTrackMenu == nil else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  engine.state == .playing,
                  focusedTrackMenu == nil
            else { return }
            hideChrome()
        }
        .onDisappear {
            if engine.state != .idle { engine.pause() }
        }
        .onPlayPauseCommand {
            engine.togglePlayPause()
            revealChrome()
        }
        .onMoveCommand { _ in revealChrome() }
        .onExitCommand {
            if showChrome {
                hideChrome()
            } else {
                playback.leavePlayer()
            }
        }
        .onChange(of: engine.state) { _, newState in
            if newState != .playing { revealChrome() }
        }
        .onChange(of: focusedTrackMenu) { _, newValue in
            if newValue != nil { revealChrome() }
        }
    }

    private var playbackChrome: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(presentation.channel.name)
                        .font(.title.bold())
                        .foregroundStyle(.white)
                    if let title = presentation.program?.title {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }

                Spacer()

                playbackStatus
            }
            .padding(.horizontal, 38)
            .padding(.vertical, 20)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.9), .black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Spacer()

            transportControls
        }
    }

    private var transportControls: some View {
        VStack(spacing: 22) {
            playbackTimeline

            HStack(spacing: 24) {
                Button { engine.skipBackward(by: 30); revealChrome() } label: {
                    Label("Back 30 seconds", systemImage: "gobackward.30")
                        .labelStyle(.iconOnly)
                }
                .disabled(!engine.isSeekable)
                .accessibilityHint(
                    engine.isSeekable
                        ? "Moves playback back 30 seconds"
                        : "Rewind is unavailable for this HTTP live stream"
                )

                Button {
                    engine.togglePlayPause()
                    revealChrome()
                } label: {
                    Label(
                        engine.state == .paused ? "Resume" : "Pause",
                        systemImage: engine.state == .paused ? "play.fill" : "pause.fill"
                    )
                    .labelStyle(.iconOnly)
                }

                Button { skipForward() } label: {
                    Label("Forward 30 seconds", systemImage: "goforward.30")
                        .labelStyle(.iconOnly)
                }
                .disabled(!engine.isSeekable && engine.liveDelaySeconds < 1)

                Button { Task { await returnToLive() } } label: {
                    Label("Go Live", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(engine.liveDelaySeconds < 1 && !engine.isSeekable)

                Spacer()

                PlaybackTrackMenu(
                    title: "Audio",
                    systemImage: "waveform",
                    tracks: engine.audioTracks,
                    selectedID: engine.selectedAudioTrackID,
                    select: {
                        engine.selectAudioTrack($0)
                        revealChrome()
                    }
                )
                .equatable()
                .focused($focusedTrackMenu, equals: .audio)

                PlaybackTrackMenu(
                    title: "Subtitles",
                    systemImage: "captions.bubble",
                    tracks: engine.subtitleTracks,
                    selectedID: engine.selectedSubtitleTrackID,
                    select: {
                        engine.selectSubtitleTrack($0)
                        revealChrome()
                    }
                )
                .equatable()
                .focused($focusedTrackMenu, equals: .subtitles)
            }
            .buttonStyle(.borderedProminent)
            .tint(.black.opacity(0.82))
        }
        .padding(.horizontal, 38)
        .padding(.top, 32)
        .padding(.bottom, 26)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var playbackTimeline: some View {
        if engine.isSeekable, let duration = engine.durationSeconds, duration > 0 {
            SeekableTimeline(
                elapsedSeconds: engine.elapsedSeconds,
                durationSeconds: duration,
                seek: { engine.seek(to: $0); revealChrome() }
            )
        } else {
            LiveTimeshiftTimeline(
                windowSeconds: engine.timeshiftWindowSeconds,
                delaySeconds: engine.liveDelaySeconds
            )
        }
    }

    @ViewBuilder
    private var playbackStatus: some View {
        switch engine.state {
        case .preparing:
            Label("Opening live stream…", systemImage: "hourglass")
                .foregroundStyle(.white)
        case .playing:
            if engine.playbackRate > 1 {
                Label("Catching up \(Int(engine.playbackRate))×", systemImage: "forward.fill")
                    .foregroundStyle(.white)
            } else if engine.liveDelaySeconds >= 1 {
                Label("\(formatDuration(engine.liveDelaySeconds)) behind live", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.white)
            } else {
                Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.red)
            }
        case .paused:
            Label("Paused · \(formatDuration(engine.liveDelaySeconds)) behind live", systemImage: "pause.fill")
                .foregroundStyle(.white)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    private func startPlayback(with request: LiveStreamRequest) async {
        do {
            try await engine.prepare(request)
            engine.play()
            guard await engine.waitForPlaybackStart() else { return }
            revealChrome()
        } catch {
            engine.reportFailure(error.localizedDescription)
        }
    }

    private func skipForward() {
        let needsLiveReconnect = engine.skipForward(by: 30)
        revealChrome()
        if needsLiveReconnect {
            Task { await returnToLive() }
        }
    }

    private func returnToLive() async {
        do {
            let url = try await TVHeadendClient(configuration: settings.configuration)
                .canonicalLiveStreamURL(channelID: presentation.channel.id)
            await startPlayback(
                with: LiveStreamRequest(
                    url: url,
                    networkCachingMilliseconds: presentation.request.networkCachingMilliseconds,
                    profile: settings.configuration.streamProfile
                )
            )
        } catch {
            engine.reportFailure(error.localizedDescription)
        }
    }

    private func revealChrome() {
        hiddenPlayerSurfaceFocused = false
        withAnimation(.easeOut(duration: 0.18)) { showChrome = true }
        chromeActivity = UUID()
    }

    private func hideChrome() {
        withAnimation(.easeOut(duration: 0.25)) { showChrome = false }
        chromeActivity = UUID()
        Task { @MainActor in
            await Task.yield()
            hiddenPlayerSurfaceFocused = true
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

private struct PlaybackTrackMenu: View, Equatable {
    let title: String
    let systemImage: String
    let tracks: [PlaybackTrack]
    let selectedID: Int?
    let select: (Int) -> Void

    nonisolated static func == (lhs: PlaybackTrackMenu, rhs: PlaybackTrackMenu) -> Bool {
        lhs.title == rhs.title
            && lhs.systemImage == rhs.systemImage
            && lhs.tracks == rhs.tracks
            && lhs.selectedID == rhs.selectedID
    }

    var body: some View {
        Menu {
            if tracks.isEmpty {
                Text("No tracks available")
            } else {
                ForEach(tracks) { track in
                    Button {
                        select(track.id)
                    } label: {
                        if selectedID == track.id {
                            Label(track.name, systemImage: "checkmark")
                        } else {
                            Text(track.name)
                        }
                    }
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

private struct SeekableTimeline: View {
    let elapsedSeconds: TimeInterval
    let durationSeconds: TimeInterval
    let seek: (TimeInterval) -> Void

    @FocusState private var isFocused: Bool

    private var progress: CGFloat {
        guard durationSeconds > 0 else { return 0 }
        return min(max(0, CGFloat(elapsedSeconds / durationSeconds)), 1)
    }

    var body: some View {
        VStack(spacing: 8) {
            Button(action: {}) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.28))
                        Capsule()
                            .fill(AppTheme.accent)
                            .frame(width: max(8, geometry.size.width * progress))
                        Circle()
                            .fill(.white)
                            .frame(width: isFocused ? 24 : 18, height: isFocused ? 24 : 18)
                            .offset(x: max(0, geometry.size.width * progress - (isFocused ? 12 : 9)))
                    }
                }
                .frame(height: 24)
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .left:
                    seek(max(0, elapsedSeconds - 15))
                case .right:
                    seek(min(durationSeconds, elapsedSeconds + 15))
                default:
                    break
                }
            }

            HStack {
                Text(formatDuration(elapsedSeconds))
                Spacer()
                Text(formatDuration(durationSeconds))
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(AppTheme.secondaryText)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

private struct LiveTimeshiftTimeline: View {
    let windowSeconds: TimeInterval
    let delaySeconds: TimeInterval

    private var playheadProgress: CGFloat {
        guard windowSeconds > 0 else { return 1 }
        return min(max(0, CGFloat((windowSeconds - delaySeconds) / windowSeconds)), 1)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            timeline(at: context.date)
        }
    }

    private func timeline(at now: Date) -> some View {
        VStack(spacing: 9) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.28))
                    Capsule()
                        .fill(AppTheme.accent)
                        .frame(width: max(8, geometry.size.width * playheadProgress))
                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .offset(x: max(0, geometry.size.width * playheadProgress - 9))
                }
            }
            .frame(height: 18)

            HStack {
                if windowSeconds > 1 {
                    Text(formatClock(now.addingTimeInterval(-windowSeconds)))
                } else {
                    Text(formatClock(now))
                }
                Spacer()
                if delaySeconds >= 1 {
                    Text(formatClock(now.addingTimeInterval(-delaySeconds)))
                }
                Spacer()
                Text("LIVE · \(formatClock(now))")
                    .fontWeight(.bold)
                    .foregroundStyle(.red)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(AppTheme.secondaryText)
        }
    }

    private func formatClock(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .medium)
    }
}
