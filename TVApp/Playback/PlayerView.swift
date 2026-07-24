import SwiftUI
#if os(iOS)
import UIKit
#endif

private enum PlayerChromeMode: Equatable {
    case hidden
    case timeline
    case panel
}

private struct PlayerChromeAutoHideTaskID: Equatable {
    let activity: UUID
    let mode: PlayerChromeMode
    let hasActiveSeekPreview: Bool
    let shouldAutoHide: Bool
}

private enum PlayerOverlayTab: String, CaseIterable, Identifiable {
    case details = "Details"
    case playback = "Playback"
    case technical = "Technical"

    var id: Self { self }
}

enum TimelineSeekCommitPolicy {
    static let coalescingDelayMilliseconds = 250
}

enum PlayerNavigationPolicy {
    static let skipInterval: TimeInterval = 10
}

enum HoldSeekVelocityPolicy {
    static let activationDelayMilliseconds = 350
    static let touchDeadZone: CGFloat = 16
    static let maximumRate: Double = 120
    static let remoteRampDuration: TimeInterval = 3

    static func touchRate(
        translation: CGFloat,
        playerWidth: CGFloat
    ) -> Double {
        let distance = abs(translation)
        guard distance > touchDeadZone else { return 0 }
        let accelerationDistance = max(80, playerWidth * 0.4)
        let normalized = min(
            1,
            Double((distance - touchDeadZone) / max(1, accelerationDistance - touchDeadZone))
        )
        let magnitude = 1 + (maximumRate - 1) * normalized * normalized
        return translation < 0 ? -magnitude : magnitude
    }

#if os(tvOS)
    static func remoteRate(
        direction: TVPlayerSeekDirection,
        heldFor duration: TimeInterval
    ) -> Double {
        let normalized = min(1, max(0, duration) / remoteRampDuration)
        let magnitude = 1 + (maximumRate - 1) * normalized * normalized
        return direction == .backward ? -magnitude : magnitude
    }
#endif

    static func advancedTarget(
        _ target: TimeInterval,
        rate: Double,
        elapsed: TimeInterval,
        lowerBound: TimeInterval,
        upperBound: TimeInterval
    ) -> TimeInterval {
        let proposed = target + rate * max(0, elapsed)
        return min(max(proposed, lowerBound), upperBound)
    }
}

#if os(tvOS)
enum RemoteSeekReleaseAction: Equatable {
    case commitQuickSkip
    case nudgePreview
    case continuePreview
}

enum RemoteSeekPreviewPolicy {
    static func releaseAction(
        previewWasActive: Bool,
        holdActivated: Bool
    ) -> RemoteSeekReleaseAction {
        if holdActivated { return .continuePreview }
        return previewWasActive ? .nudgePreview : .commitQuickSkip
    }
}
#endif

enum TimelineSeekBoundaryFeedback: Equatable {
    case bufferStart
    case liveEdge
    case recordingStart
    case recordingEnd

    var label: String {
        switch self {
        case .bufferStart: "Start of buffer"
        case .liveEdge: "Live"
        case .recordingStart: "Start of recording"
        case .recordingEnd: "End of recording"
        }
    }

    var accessibilityAnnouncement: String {
        switch self {
        case .bufferStart: "At the start of the timeshift buffer"
        case .liveEdge: "Already live"
        case .recordingStart: "At the start of the recording"
        case .recordingEnd: "At the end of the recording"
        }
    }
}

enum TimelineScrubbing {
    static func fraction(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(0, Double(x / width)), 1)
    }

    static func recordingTarget(
        at x: CGFloat,
        width: CGFloat,
        availableDuration: TimeInterval
    ) -> TimeInterval {
        max(0, availableDuration) * fraction(at: x, width: width)
    }

    static func liveTarget(
        at x: CGFloat,
        width: CGFloat,
        rangeStart: Date,
        rangeEnd: Date,
        availableStart: Date,
        availableEnd: Date
    ) -> Date {
        let duration = max(0, rangeEnd.timeIntervalSince(rangeStart))
        let proposed = rangeStart.addingTimeInterval(
            duration * fraction(at: x, width: width)
        )
        return min(max(proposed, availableStart), availableEnd)
    }
}

enum LiveTimelinePosition {
    static func userSeekableLiveEdge(at liveEdge: Date) -> Date {
        liveEdge.addingTimeInterval(-NativeTimeshiftActionPlan.preferredLiveDelay)
    }

    static func clampedDate(
        _ proposedDate: Date,
        liveEdge: Date,
        bufferStartedAt: Date?
    ) -> Date {
        min(max(proposedDate, bufferStartedAt ?? .distantPast), liveEdge)
    }

    static func clampedUserSeekDate(
        _ proposedDate: Date,
        liveEdge: Date,
        bufferStartedAt: Date?
    ) -> Date {
        let selectableLiveEdge = userSeekableLiveEdge(at: liveEdge)
        let availableStart = min(bufferStartedAt ?? selectableLiveEdge, selectableLiveEdge)
        return min(max(proposedDate, availableStart), selectableLiveEdge)
    }
}

#if os(macOS)
enum MacOSPlayerKeyboardCommand: Equatable {
    case togglePlayback
    case seekBackward(TimeInterval)
    case seekForward(TimeInterval)

    var isRepeatable: Bool {
        switch self {
        case .togglePlayback: false
        case .seekBackward, .seekForward: true
        }
    }
}

enum MacOSPlayerKeyboardShortcuts {
    static func command(
        for key: KeyEquivalent,
        modifiers: EventModifiers = []
    ) -> MacOSPlayerKeyboardCommand? {
        let reservedModifiers: EventModifiers = [.command, .control, .option]
        guard modifiers.intersection(reservedModifiers).isEmpty else { return nil }

        switch key {
        case .space:
            return .togglePlayback
        case .leftArrow:
            return .seekBackward(5)
        case .rightArrow:
            return .seekForward(5)
        default:
            switch String(key.character).lowercased() {
            case "k": return .togglePlayback
            case "j": return .seekBackward(10)
            case "l": return .seekForward(10)
            default: return nil
            }
        }
    }
}

extension Notification.Name {
    static let vlcTimeshiftBenchmarkPlayerCommand = Notification.Name(
        "VLC_TIMESHIFT_BENCHMARK_PLAYER_COMMAND"
    )
}
#endif

struct PlaybackView: View {
    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var engine: VLCPlaybackEngine

    @State private var chromeMode: PlayerChromeMode = .timeline
    @State private var selectedTab: PlayerOverlayTab = .details
    @State private var chromeActivity = UUID()
    @State private var profiles: [TVHeadendStreamProfile] = []
    @State private var hasStartedCurrentPresentation = false
    @State private var timelineSeekTargetDate: Date?
    @State private var timelineSeekTargetsLiveEdge = false
    @State private var timelineSeekCommitTask: Task<Void, Never>?
    @State private var recordingSeekTargetSeconds: TimeInterval?
    @State private var seekPreviewRate: Double?
    @State private var seekPreviewBoundaryFeedback: TimelineSeekBoundaryFeedback?
    @State private var seekPreviewTickerTask: Task<Void, Never>?
    @State private var isUserPaused = false
    @State private var userPauseRequestPending = false
    @State private var userResumeRequestPending = false
#if os(iOS)
    @State private var isTouchSeekPreviewActive = false
    @State private var touchSeekTranslation: CGFloat = 0
    @State private var touchSeekPlayerWidth: CGFloat = 1
#endif
#if os(tvOS)
    @State private var remoteSeekActivationTask: Task<Void, Never>?
    @State private var remoteSeekDirection: TVPlayerSeekDirection?
    @State private var remoteSeekHoldActivated = false
    @State private var isRemoteSeekPreviewActive = false
    @State private var remoteSeekPreviewWasActiveAtPress = false
    @FocusState private var remoteSeekConfirmationFocused: Bool
#endif
    @State private var isRefreshingGrowingRecording = false
    @State private var videoAttachmentRevision = 0
    @State private var showsCommercialDetectionOverlay = false
    @FocusState private var wakeSurfaceFocused: Bool

    let presentation: PlaybackPresentation
    var showsVideoSurface = true
    var retainsLivePlaybackOnDismiss = false

    private var usesCompactLayout: Bool {
#if os(iOS)
        horizontalSizeClass == .compact || usesCompactHeight
#else
        false
#endif
    }

    private var usesCompactHeight: Bool {
#if os(iOS)
        verticalSizeClass == .compact
#else
        false
#endif
    }

    private var isSeekConfirmationPending: Bool {
#if os(tvOS)
        isRemoteSeekPreviewActive
#else
        false
#endif
    }

    private var canPreviewSeek: Bool {
        engine.isSeekable
            && (presentation.isRecording || engine.bufferStartedAt != nil)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    var body: some View {
        ZStack {
            if showsVideoSurface {
                Color.black.ignoresSafeArea()

                VLCVideoSurface(
                    mediaPlayer: engine.mediaPlayer,
                    attachmentRevision: videoAttachmentRevision,
                    isOutputConcealed: engine.isPlaybackOutputConcealed,
                    concealmentImage: engine.pausedFrame
                )
                    .ignoresSafeArea()
            } else {
                Color.clear.ignoresSafeArea()
            }

#if os(iOS)
            IOSHoldSeekSurface(
                isEnabled: canPreviewSeek && chromeMode != .panel,
                activate: beginTouchSeekPreview,
                updateTranslation: updateTouchSeekPreview,
                finish: finishTouchSeekPreview,
                tap: {
                    switch chromeMode {
                    case .hidden, .panel:
                        showTimeline()
                    case .timeline:
                        hideChrome()
                    }
                }
            )
                .ignoresSafeArea()
                .accessibilityHidden(chromeMode != .hidden)
                .accessibilityLabel("Show playback timeline")
#else
            if chromeMode == .hidden {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .focusable()
                    .focused($wakeSurfaceFocused)
                    .focusEffectDisabled()
                    .onTapGesture(perform: showTimeline)
                    .accessibilityLabel("Show playback timeline")
            }
#endif

            if showsCommercialDetectionOverlay,
               !presentation.isRecording,
               chromeMode != .panel {
                CommercialDetectionDebugOverlay(
                    analyzer: playback.commercialAnalyzer
                )
                .padding(.horizontal, usesCompactLayout ? 16 : 34)
                .padding(.vertical, usesCompactHeight ? 8 : 26)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topTrailing
                )
                .allowsHitTesting(false)
                .zIndex(4)
            }

#if os(macOS)
            if chromeMode != .hidden {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        if chromeMode == .panel {
                            showTimeline()
                        } else {
                            hideChrome()
                        }
                    }
                    .accessibilityHidden(true)
            }
#endif

            if chromeMode == .timeline {
                VStack {
                    Spacer()
                    if let recording = presentation.recording {
                        RecordingPlaybackTimeline(
                            recording: recording,
                            elapsedSeconds: engine.elapsedSeconds,
                            seekTargetSeconds: recordingSeekTargetSeconds,
                            seekBoundaryFeedback: seekPreviewBoundaryFeedback,
                            seekPreviewRate: seekPreviewRate,
                            seekConfirmationPending: isSeekConfirmationPending,
                            isPlaying: engine.state == .playing,
                            isPaused: isUserPaused,
                            canSeek: engine.isSeekable,
                            usesCompactLayout: usesCompactLayout,
                            usesCompactHeight: usesCompactHeight,
                            seekBackward: { engine.skipBackward(by: $0); noteActivity() },
                            seekForward: { skipForward(by: $0) },
                            seekTo: { engine.seek(to: $0); noteActivity() },
                            togglePlayback: toggleTimelinePlayback,
                            showPanel: showPanel
                        )
                    } else {
                        ProgrammePlaybackTimeline(
                            channel: presentation.channel,
                            fallbackProgram: presentation.program,
                            pausedPlaybackDate: engine.isLivePlaybackPositionAnchored
                                ? engine.livePlaybackDate()
                                : nil,
                            seekTargetDate: timelineSeekTargetDate,
                            seekTargetsLiveEdge: timelineSeekTargetsLiveEdge,
                            seekBoundaryFeedback: seekPreviewBoundaryFeedback,
                            seekPreviewRate: seekPreviewRate,
                            seekConfirmationPending: isSeekConfirmationPending,
                            commercialBreaks: playback.commercialBreaks,
                            liveDelaySeconds: engine.liveDelaySeconds,
                            bufferStartedAt: engine.bufferStartedAt,
                            canPause: engine.canPause,
                            canSeek: engine.isSeekable,
                            isPlaying: engine.state == .playing,
                            isPaused: isUserPaused,
                            usesCompactLayout: usesCompactLayout,
                            usesCompactHeight: usesCompactHeight,
                            seekBackward: { stageTimelineSeek(by: -$0) },
                            seekForward: { stageTimelineSeek(by: $0) },
                            previewSeek: previewTimelineSeek,
                            commitSeek: commitTimelineSeek,
                            returnToLive: { Task { await returnToLive() } },
                            togglePlayback: toggleTimelinePlayback,
                            showPanel: showPanel
                        )
                    }
                }
                .transition(.opacity)
                .accessibilityIdentifier("tvplayer.playback.chrome.timeline")
            }

            // Keep the panel mounted for the lifetime of PlaybackView. In
            // particular, this lets ChannelBadge finish loading before the
            // first presentation and preserves its decoded image while the
            // timeline or another panel tab is visible. Recreating the panel
            // caused a one-frame monogram/logo flash even when the response
            // data was already in the authenticated channel-logo cache.
            VStack {
                PlayerTabbedOverlay(
                    presentation: presentation,
                    engine: engine,
                    profiles: profiles,
                    selectedTab: $selectedTab,
                    showsCommercialDetectionOverlay: $showsCommercialDetectionOverlay,
                    usesCompactLayout: usesCompactLayout,
                    usesCompactHeight: usesCompactHeight,
                    selectProfile: { profile in
                        Task { await switchProfile(to: profile) }
                    },
                    dismiss: hideChrome,
                    noteActivity: noteActivity
                )
                Spacer()
            }
            .opacity(chromeMode == .panel ? 1 : 0)
            .offset(y: chromeMode == .panel ? 0 : -28)
            .allowsHitTesting(chromeMode == .panel)
            .disabled(chromeMode != .panel)
            .accessibilityHidden(chromeMode != .panel)

            if case let .failed(message) = engine.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(24)
                    .background(.red.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
            }

#if !os(tvOS)
            if chromeMode != .hidden {
                Button {
                    if chromeMode == .panel {
                        showTimeline()
                    } else {
                        dismissPlayer()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.72), in: Circle())
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chromeMode == .panel ? "Close Info" : "Close Player")
                .keyboardShortcut(.cancelAction)
                .padding(.horizontal, usesCompactLayout ? 16 : 20)
                .padding(.vertical, usesCompactHeight ? 8 : (usesCompactLayout ? 12 : 20))
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .transition(.opacity)
                .zIndex(2)
            }
#endif

#if os(tvOS)
            if isRemoteSeekPreviewActive {
                Button {
                    confirmSeekFromFocusedRemoteButton()
                } label: {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .focused($remoteSeekConfirmationFocused)
                .accessibilityLabel("Confirm seek")
                .opacity(0.001)
                .zIndex(10)
                .task {
                    await Task.yield()
                    remoteSeekConfirmationFocused = true
                }
            }

            if chromeMode != .hidden, playback.pictureInPicture.isSupported {
                Button {
                    playback.pictureInPicture.start()
                    noteActivity()
                } label: {
                    Image(systemName: "pip.enter")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 54)
                        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start Picture in Picture")
                .padding(.horizontal, 34)
                .padding(.vertical, 26)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(3)
            }
#endif

            if case let .recovering(reason, attempt) = engine.state {
                HStack(spacing: 14) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(reason.message)
                            .font(.headline)
                        Text("Attempt \(attempt)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .task(id: presentation.id) {
            cancelSeekPreview()
            hasStartedCurrentPresentation = false
            isUserPaused = false
            userPauseRequestPending = false
            userResumeRequestPending = false
            if engine.state == .paused {
                engine.play()
                requestVideoReattachment()
            } else if engine.state == .playing {
                requestVideoReattachment()
            }
        }
        .task {
            guard !presentation.isRecording else { return }
            profiles = (try? await playback.streamProfiles(
                configuration: settings.configuration
            )) ?? []
        }
#if DEBUG
        .task(id: engine.state) {
            guard engine.state == .playing,
                  let panelTest = ProcessInfo.processInfo.environment["TVPLAYER_PANEL_TEST"]
            else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, engine.state == .playing else { return }
            showPanel()
            if let requestedTab = PlayerOverlayTab(rawValue: panelTest) {
                selectedTab = requestedTab
            }
        }
        .task {
            guard ProcessInfo.processInfo.environment["TVPLAYER_PAUSE_TEST"] == "1" else { return }
            for _ in 0..<100 where engine.state != .playing {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard engine.state == .playing else { return }
            try? await Task.sleep(for: .seconds(3))
            engine.pause()
            try? await Task.sleep(for: .seconds(20))
            engine.play()
        }
#endif
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                engine.refreshPlaybackInformation()
            }
        }
        .task(id: chromeAutoHideTaskID) {
            guard chromeMode == .timeline,
                  !hasActiveSeekPreview,
                  shouldAutoHideChrome
            else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  chromeMode == .timeline,
                  !hasActiveSeekPreview,
                  shouldAutoHideChrome
            else { return }
            hideChrome()
        }
#if os(tvOS)
        .onAppear {
            TVRemoteCommandCenter.playerExitHandler = handlePlayerExitCommand
            TVRemoteCommandCenter.playerPlayPauseHandler =
                handlePlayerPlayPauseCommand
            TVRemoteCommandCenter.seekHoldHandler = handleRemoteSeekPress
            // Playback UI automation installs a UIKit press recognizer which
            // forwards the same begin/end transitions. Listening through
            // GameController as well can turn one XCUIRemote press into two
            // sequential quick skips and two VLC pipeline replacements.
            if !TVPlaybackAutomation.isEnabled {
                TVRemoteSeekInputBridge.shared.start()
            }
        }
#if DEBUG
        .onReceive(
            NotificationCenter.default.publisher(for: .tvPlaybackAutomationSeekPress)
        ) { notification in
            guard let rawDirection = notification.userInfo?["direction"] as? String,
                  let isPressed = notification.userInfo?["pressed"] as? Bool
            else { return }
            let direction: TVPlayerSeekDirection = rawDirection == "backward"
                ? .backward
                : .forward
            _ = handleRemoteSeekPress(direction, isPressed: isPressed)
        }
#endif
#endif
        .onDisappear {
            timelineSeekCommitTask?.cancel()
            seekPreviewTickerTask?.cancel()
#if os(tvOS)
            remoteSeekActivationTask?.cancel()
#endif
#if os(tvOS)
            TVRemoteCommandCenter.playerExitHandler = nil
            TVRemoteCommandCenter.playerPlayPauseHandler = nil
            TVRemoteCommandCenter.seekHoldHandler = nil
            TVRemoteSeekInputBridge.shared.stop()
#endif
            // Back intentionally collapses live playback into the guide
            // header. Only pause when the player view disappears for another
            // reason (or when the coordinator already paused a recording).
            guard playback.isPlayerPresented else { return }
            switch engine.state {
            case .playing, .preparing, .recovering:
                engine.pause()
            case .idle, .paused, .failed:
                break
            }
        }
        .televisionPlayPauseCommand {
#if os(tvOS)
            if !handlePlayerPlayPauseCommand() {
                toggleTimelinePlayback()
            }
#endif
        }
        .platformMoveCommand { direction in
            switch direction {
            case .up:
                if chromeMode == .panel {
                    // Directional navigation belongs to the panel while it is
                    // open. Back is the explicit way to dismiss its chrome.
                    noteActivity()
                } else {
                    showTimeline()
                }
            case .down:
                if chromeMode == .hidden || chromeMode == .timeline {
                    showPanel()
                } else {
                    // Re-presenting an already-visible panel resets its focus
                    // hierarchy and makes Down look as if it dismissed the
                    // content. Leave the panel intact so its ScrollViews and
                    // controls handle the movement instead.
                    noteActivity()
                }
            case .left, .right:
                if chromeMode == .hidden { showTimeline() } else { noteActivity() }
            @unknown default:
                showTimeline()
            }
        }
        .platformExitCommand { _ = handlePlayerExitCommand() }
#if os(macOS)
        .onKeyPress(phases: [.down, .repeat]) { keyPress in
            guard chromeMode != .panel else { return .ignored }
            guard let command = MacOSPlayerKeyboardShortcuts.command(
                for: keyPress.key,
                modifiers: keyPress.modifiers
            ) else {
                return .ignored
            }
            guard keyPress.phase != .repeat || command.isRepeatable else {
                return .handled
            }
            perform(command)
            return .handled
        }
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            if chromeMode == .hidden {
                showTimeline()
            } else {
                noteActivity()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .vlcTimeshiftBenchmarkPlayerCommand)
        ) { notification in
            guard ProcessInfo.processInfo.arguments.contains("--vlc-timeshift-benchmark"),
                  let command = notification.object as? MacOSPlayerKeyboardCommand
            else { return }
            perform(command)
        }
#endif
#if os(iOS)
        .onKeyPress(.space) {
            guard chromeMode != .panel else { return .ignored }
            toggleTimelinePlayback()
            return .handled
        }
#endif
        .onChange(of: engine.state) { _, state in
            let announcesPause = state == .paused && userPauseRequestPending
            let announcesResume = state == .playing && userResumeRequestPending

            if announcesPause {
                userPauseRequestPending = false
                isUserPaused = true
            }
            if announcesResume {
                userResumeRequestPending = false
            }

            if state == .playing {
                hasStartedCurrentPresentation = true
                if chromeMode == .timeline { noteActivity() }
            } else if state == .idle,
                      hasStartedCurrentPresentation,
                      let recording = presentation.recording,
                      recording.state == .recording,
                      Date() < recording.end.addingTimeInterval(120),
                      !isRefreshingGrowingRecording {
                Task { await refreshGrowingRecording() }
            } else {
                showTimeline()
            }

            if announcesPause {
                announcePlaybackStatus("paused")
            } else if announcesResume {
                announcePlaybackStatus("playing")
            }
        }
        .onChange(of: engine.bufferStartedAt) { _, bufferStartedAt in
            if let bufferStartedAt {
                playback.pruneCommercialBreaks(before: bufferStartedAt)
            }
        }
    }

    private func startPlayback(with request: LiveStreamRequest) async {
        do {
            try await engine.prepare(request)
            engine.play()
            requestVideoReattachment()
            guard await engine.waitForPlaybackStart() else { return }
            showTimeline()
        } catch {
            engine.reportFailure(error.localizedDescription)
        }
    }

    private func requestVideoReattachment() {
#if !os(macOS)
        videoAttachmentRevision &+= 1
#endif
    }

    private func refreshGrowingRecording() async {
        guard let recording = presentation.recording else { return }
        isRefreshingGrowingRecording = true
        defer { isRefreshingGrowingRecording = false }
        let resumeAt = engine.elapsedSeconds

        do {
            // A growing file can report EOF before TVheadend has flushed the
            // next segment. Avoid rapidly reopening the same temporary end.
            try await Task.sleep(for: .seconds(2))

            // Ticket credentials are deliberately short-lived, so obtain a
            // fresh URL each time a growing recording reaches its current EOF.
            let url = try await playback.recordingStreamURL(
                recordingID: recording.id,
                configuration: settings.configuration
            )
            await startPlayback(
                with: LiveStreamRequest(
                    url: url,
                    networkCachingMilliseconds: presentation.request.networkCachingMilliseconds,
                    profile: "recording",
                    kind: .recording(isGrowing: true),
                    expectedDurationSeconds: recording.duration,
                    cachedAddressRoutes: CachedAddressRoutes(settings.configuration)
                )
            )
            if resumeAt > 0, engine.isSeekable { engine.seek(to: resumeAt) }
        } catch {
            engine.reportFailure(error.localizedDescription)
        }
    }

    private func showTimeline() {
        wakeSurfaceFocused = false
        withAnimation(.easeOut(duration: 0.18)) { chromeMode = .timeline }
        noteActivity()
    }

    private func dismissPlayer() {
        playback.leavePlayer(
            retainingLivePlayback: retainsLivePlaybackOnDismiss && !presentation.isRecording
        )
    }

    @discardableResult
    private func handlePlayerExitCommand() -> Bool {
        if hasActiveSeekPreview {
            cancelSeekPreview()
        } else if chromeMode == .panel {
            showTimeline()
        } else if chromeMode == .timeline {
            hideChrome()
        } else {
            dismissPlayer()
        }
        return true
    }

    private func toggleTimelinePlayback() {
        if confirmSeekPreviewIfNeeded() { return }
        let wasPlaying = engine.mediaPlayer.isPlaying
        if wasPlaying, engine.canPause {
            userPauseRequestPending = true
            userResumeRequestPending = false
        } else if isUserPaused {
            isUserPaused = false
            userPauseRequestPending = false
            userResumeRequestPending = true
        }
        engine.togglePlayPause()
        if !wasPlaying { requestVideoReattachment() }
        showTimeline()
    }

#if os(macOS)
    private func perform(_ command: MacOSPlayerKeyboardCommand) {
        switch command {
        case .togglePlayback:
            toggleTimelinePlayback()
        case let .seekBackward(seconds):
            if engine.isSeekable {
                if presentation.isRecording {
                    engine.skipBackward(by: seconds)
                } else {
                    stageTimelineSeek(by: -seconds)
                }
            }
            showTimeline()
        case let .seekForward(seconds):
            if engine.isSeekable {
                if presentation.isRecording {
                    skipForward(by: seconds)
                } else {
                    stageTimelineSeek(by: seconds)
                }
            }
            showTimeline()
        }
    }
#endif

    private func showPanel() {
        wakeSurfaceFocused = false
        if chromeMode != .panel {
            selectedTab = .details
        }
        withAnimation(.easeOut(duration: 0.18)) { chromeMode = .panel }
        noteActivity()
    }

    private func hideChrome() {
        withAnimation(.easeOut(duration: 0.2)) { chromeMode = .hidden }
        chromeActivity = UUID()
        Task { @MainActor in
            await Task.yield()
            wakeSurfaceFocused = true
        }
    }

    private func noteActivity() {
        chromeActivity = UUID()
    }

    private var chromeAutoHideTaskID: PlayerChromeAutoHideTaskID {
        PlayerChromeAutoHideTaskID(
            activity: chromeActivity,
            mode: chromeMode,
            hasActiveSeekPreview: hasActiveSeekPreview,
            shouldAutoHide: shouldAutoHideChrome
        )
    }

    private var shouldAutoHideChrome: Bool {
#if os(iOS)
        !isUserPaused && {
            if case .failed = engine.state { return false }
            return true
        }()
#else
        engine.state == .playing
#endif
    }

    private var hasActiveSeekPreview: Bool {
        var isActive = timelineSeekTargetDate != nil
            || recordingSeekTargetSeconds != nil
#if os(iOS)
        isActive = isActive || isTouchSeekPreviewActive
#endif
#if os(tvOS)
        isActive = isActive || isRemoteSeekPreviewActive
#endif
        return isActive
    }

    private func recordingAvailableDuration(at date: Date = Date()) -> TimeInterval {
        guard let recording = presentation.recording else { return 0 }
        let totalDuration = max(0, recording.duration)
        if recording.state == .recording {
            return min(totalDuration, max(0, date.timeIntervalSince(recording.start)))
        }
        return totalDuration
    }

    private func seekPreviewBounds(at date: Date) -> ClosedRange<TimeInterval>? {
        if presentation.isRecording {
            return 0...recordingAvailableDuration(at: date)
        }
        guard let bufferStartedAt = engine.bufferStartedAt else { return nil }
        let lowerBound = bufferStartedAt.timeIntervalSinceReferenceDate
        return lowerBound...date.timeIntervalSinceReferenceDate
    }

    private func currentSeekPreviewTarget(at date: Date) -> TimeInterval {
        if presentation.isRecording {
            return recordingSeekTargetSeconds ?? engine.elapsedSeconds
        }
        if timelineSeekTargetsLiveEdge {
            return date.timeIntervalSinceReferenceDate
        }
        return (timelineSeekTargetDate ?? liveTimelinePlaybackDate(at: date))
            .timeIntervalSinceReferenceDate
    }

    private func updateSeekPreviewTarget(_ target: TimeInterval, at date: Date) {
        if presentation.isRecording {
            recordingSeekTargetSeconds = target
            noteActivity()
        } else {
            previewTimelineSeek(Date(timeIntervalSinceReferenceDate: target))
        }
    }

    @discardableResult
    private func advanceSeekPreview(
        rate: Double,
        elapsed: TimeInterval,
        at date: Date
    ) -> Bool {
        guard rate != 0, let bounds = seekPreviewBounds(at: date) else { return false }
        let current = currentSeekPreviewTarget(at: date)
        let target = HoldSeekVelocityPolicy.advancedTarget(
            current,
            rate: rate,
            elapsed: min(max(0, elapsed), 0.1),
            lowerBound: bounds.lowerBound,
            upperBound: bounds.upperBound
        )
        updateSeekPreviewTarget(target, at: date)

        let boundary: TimelineSeekBoundaryFeedback?
        if rate < 0, target <= bounds.lowerBound {
            boundary = presentation.isRecording ? .recordingStart : .bufferStart
        } else if rate > 0, target >= bounds.upperBound {
            boundary = presentation.isRecording ? .recordingEnd : .liveEdge
        } else {
            boundary = nil
        }
        updateSeekPreviewBoundary(boundary)
        return boundary != nil
    }

    @discardableResult
    private func nudgeSeekPreview(by interval: TimeInterval) -> Bool {
        let date = Date()
        guard let bounds = seekPreviewBounds(at: date) else { return false }
        let current = currentSeekPreviewTarget(at: date)
        let target = min(max(current + interval, bounds.lowerBound), bounds.upperBound)
        updateSeekPreviewTarget(target, at: date)

        let boundary: TimelineSeekBoundaryFeedback?
        if interval < 0, target <= bounds.lowerBound {
            boundary = presentation.isRecording ? .recordingStart : .bufferStart
        } else if interval > 0, target >= bounds.upperBound {
            boundary = presentation.isRecording ? .recordingEnd : .liveEdge
        } else {
            boundary = nil
        }
        updateSeekPreviewBoundary(boundary)
        return boundary != nil
    }

    private func updateSeekPreviewBoundary(
        _ boundary: TimelineSeekBoundaryFeedback?
    ) {
        guard seekPreviewBoundaryFeedback != boundary else { return }
        seekPreviewBoundaryFeedback = boundary
        guard let boundary else { return }
        AccessibilityNotification.Announcement(boundary.accessibilityAnnouncement).post()
#if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
#endif
    }

    @discardableResult
    private func commitSeekPreview() -> Bool {
        seekPreviewTickerTask?.cancel()
        seekPreviewTickerTask = nil
        seekPreviewRate = nil
        seekPreviewBoundaryFeedback = nil
#if os(iOS)
        isTouchSeekPreviewActive = false
#endif
#if os(tvOS)
        remoteSeekActivationTask?.cancel()
        remoteSeekActivationTask = nil
        remoteSeekDirection = nil
        remoteSeekHoldActivated = false
        isRemoteSeekPreviewActive = false
        remoteSeekPreviewWasActiveAtPress = false
        remoteSeekConfirmationFocused = false
#endif

        if let target = recordingSeekTargetSeconds {
            recordingSeekTargetSeconds = nil
            engine.seek(to: target)
            noteActivity()
            return true
        }
        guard let target = timelineSeekTargetDate else { return false }
        commitTimelineSeek(target)
        return true
    }

    private func cancelSeekPreview() {
        seekPreviewTickerTask?.cancel()
        seekPreviewTickerTask = nil
        seekPreviewRate = nil
        seekPreviewBoundaryFeedback = nil
        recordingSeekTargetSeconds = nil
#if os(iOS)
        isTouchSeekPreviewActive = false
        touchSeekTranslation = 0
#endif
#if os(tvOS)
        remoteSeekActivationTask?.cancel()
        remoteSeekActivationTask = nil
        remoteSeekDirection = nil
        remoteSeekHoldActivated = false
        isRemoteSeekPreviewActive = false
        remoteSeekPreviewWasActiveAtPress = false
        remoteSeekConfirmationFocused = false
#endif
        cancelTimelineSeek()
    }

    private func confirmSeekPreviewIfNeeded() -> Bool {
#if os(tvOS)
        confirmRemoteSeekPreview()
#else
        false
#endif
    }

#if os(iOS)
    private func beginTouchSeekPreview(playerWidth: CGFloat) {
        guard canPreviewSeek, chromeMode != .panel else { return }
        isTouchSeekPreviewActive = true
        touchSeekTranslation = 0
        touchSeekPlayerWidth = max(1, playerWidth)
        seekPreviewRate = nil
        updateSeekPreviewBoundary(nil)
        showTimeline()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func updateTouchSeekPreview(
        translation: CGFloat,
        playerWidth: CGFloat
    ) {
        guard isTouchSeekPreviewActive else { return }
        touchSeekTranslation = translation
        touchSeekPlayerWidth = max(1, playerWidth)
        let rate = HoldSeekVelocityPolicy.touchRate(
            translation: translation,
            playerWidth: touchSeekPlayerWidth
        )
        seekPreviewRate = rate == 0 ? nil : rate
        if rate != 0, seekPreviewTickerTask == nil {
            startTouchSeekPreviewTicker()
        }
    }

    private func startTouchSeekPreviewTicker() {
        seekPreviewTickerTask?.cancel()
        seekPreviewTickerTask = Task { @MainActor in
            let clock = ContinuousClock()
            var previous = clock.now
            do {
                while !Task.isCancelled, isTouchSeekPreviewActive {
                    try await Task.sleep(for: .milliseconds(33))
                    let now = clock.now
                    let elapsed = Self.seconds(previous.duration(to: now))
                    previous = now
                    let rate = HoldSeekVelocityPolicy.touchRate(
                        translation: touchSeekTranslation,
                        playerWidth: touchSeekPlayerWidth
                    )
                    seekPreviewRate = rate == 0 ? nil : rate
                    advanceSeekPreview(rate: rate, elapsed: elapsed, at: Date())
                }
            } catch {
                // Releasing or cancelling the gesture stops preview updates.
            }
        }
    }

    private func finishTouchSeekPreview(shouldCommit: Bool) {
        guard isTouchSeekPreviewActive else { return }
        seekPreviewTickerTask?.cancel()
        seekPreviewTickerTask = nil
        isTouchSeekPreviewActive = false
        touchSeekTranslation = 0
        seekPreviewRate = nil
        if shouldCommit,
           timelineSeekTargetDate != nil || recordingSeekTargetSeconds != nil {
            _ = commitSeekPreview()
        } else {
            seekPreviewBoundaryFeedback = nil
        }
        noteActivity()
    }
#endif

    private func announcePlaybackStatus(_ status: String) {
        AccessibilityNotification.Announcement("Playback \(status)").post()
    }

    private func skipForward(by seconds: TimeInterval) {
        let needsLiveReconnect = engine.skipForward(by: seconds)
        noteActivity()
        if needsLiveReconnect { Task { await returnToLive() } }
    }

    @discardableResult
    private func stageTimelineSeek(by seconds: TimeInterval) -> Bool {
        guard !presentation.isRecording, engine.isSeekable, seconds != 0 else { return false }
        let liveEdge = Date()
        let selectableLiveEdge = LiveTimelinePosition.userSeekableLiveEdge(at: liveEdge)
        let current = timelineSeekTargetsLiveEdge
            ? selectableLiveEdge
            : (timelineSeekTargetDate ?? liveTimelinePlaybackDate(at: liveEdge))
        let target = LiveTimelinePosition.clampedUserSeekDate(
            current.addingTimeInterval(seconds),
            liveEdge: liveEdge,
            bufferStartedAt: engine.bufferStartedAt
        )
        guard abs(target.timeIntervalSince(current)) > NativeTimeshiftActionPlan.liveEdgeTolerance else {
            return false
        }
        updateTimelineSeekTarget(target, liveEdge: liveEdge)
        scheduleTimelineSeekCommit()
        return true
    }

    private func previewTimelineSeek(_ proposedTarget: Date) {
        guard !presentation.isRecording, engine.isSeekable else { return }
        timelineSeekCommitTask?.cancel()
        timelineSeekCommitTask = nil
        updateTimelineSeekTarget(proposedTarget)
    }

    private func commitTimelineSeek(_ proposedTarget: Date) {
        guard !presentation.isRecording, engine.isSeekable else { return }
        updateTimelineSeekTarget(proposedTarget)
        scheduleTimelineSeekCommit(afterMilliseconds: 0)
    }

    private func updateTimelineSeekTarget(_ proposedTarget: Date, liveEdge: Date = Date()) {
        let selectableLiveEdge = LiveTimelinePosition.userSeekableLiveEdge(at: liveEdge)
        let target = LiveTimelinePosition.clampedUserSeekDate(
            proposedTarget,
            liveEdge: liveEdge,
            bufferStartedAt: engine.bufferStartedAt
        )
        timelineSeekTargetDate = target
        timelineSeekTargetsLiveEdge = target >= selectableLiveEdge.addingTimeInterval(
            -NativeTimeshiftActionPlan.liveEdgeTolerance
        )
        noteActivity()
    }

    private func scheduleTimelineSeekCommit(
        afterMilliseconds delay: Int = TimelineSeekCommitPolicy.coalescingDelayMilliseconds
    ) {
        timelineSeekCommitTask?.cancel()
        timelineSeekCommitTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(delay))
            }
            guard !Task.isCancelled else { return }
            guard let target = timelineSeekTargetDate else { return }
            let targetsLiveEdge = timelineSeekTargetsLiveEdge

            engine.refreshPlaybackInformation()
            if targetsLiveEdge {
                engine.seekToPreferredLivePosition()
            } else {
                let delta = target.timeIntervalSince(liveTimelinePlaybackDate())
                if delta < -NativeTimeshiftActionPlan.liveEdgeTolerance {
                    engine.skipBackward(by: -delta)
                } else if delta > NativeTimeshiftActionPlan.liveEdgeTolerance {
                    skipForward(by: delta)
                } else {
                    timelineSeekTargetDate = nil
                    timelineSeekTargetsLiveEdge = false
                    noteActivity()
                    return
                }
            }

            for _ in 0..<150 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                engine.refreshPlaybackInformation()
                let health = engine.nativeTimeshiftHealthSnapshot
                if (engine.state == .playing || engine.state == .paused),
                   !engine.isPlaybackOutputConcealed,
                   health?.isNavigating != true {
                    timelineSeekTargetDate = nil
                    timelineSeekTargetsLiveEdge = false
                    timelineSeekCommitTask = nil
                    noteActivity()
                    return
                }
            }
        }
    }

    private func liveTimelinePlaybackDate(at liveEdge: Date = Date()) -> Date {
        LiveTimelinePosition.clampedDate(
            engine.livePlaybackDate(at: liveEdge),
            liveEdge: liveEdge,
            bufferStartedAt: engine.bufferStartedAt
        )
    }

#if os(tvOS)
    private func performRemoteQuickSkip(_ direction: TVPlayerSeekDirection) {
        let interval = PlayerNavigationPolicy.skipInterval
        if direction == .backward {
            engine.skipBackward(by: interval)
            noteActivity()
        } else {
            skipForward(by: interval)
        }
    }

    private func handleRemoteSeekPress(
        _ direction: TVPlayerSeekDirection,
        isPressed: Bool
    ) -> Bool {
        let interval = direction == .backward
            ? -PlayerNavigationPolicy.skipInterval
            : PlayerNavigationPolicy.skipInterval

        guard isPressed else {
            guard remoteSeekDirection == direction else { return true }
            remoteSeekActivationTask?.cancel()
            remoteSeekActivationTask = nil
            let action = RemoteSeekPreviewPolicy.releaseAction(
                previewWasActive: remoteSeekPreviewWasActiveAtPress,
                holdActivated: remoteSeekHoldActivated
            )
            remoteSeekDirection = nil
            remoteSeekHoldActivated = false
            remoteSeekPreviewWasActiveAtPress = false
            switch action {
            case .commitQuickSkip:
                seekPreviewTickerTask?.cancel()
                seekPreviewTickerTask = nil
                seekPreviewRate = nil
                performRemoteQuickSkip(direction)
            case .nudgePreview:
                if nudgeSeekPreview(by: interval) {
                    _ = commitSeekPreview()
                }
            case .continuePreview:
                // The ticker retains the last rate reached while the button
                // was held. Select/Play commits, while Back still cancels.
                break
            }
            noteActivity()
            return true
        }

        guard chromeMode != .panel, canPreviewSeek else { return false }
        remoteSeekActivationTask?.cancel()
        remoteSeekDirection = direction
        remoteSeekHoldActivated = false
        remoteSeekPreviewWasActiveAtPress = isRemoteSeekPreviewActive
        showTimeline()
        remoteSeekActivationTask = Task { @MainActor in
            do {
                try await Task.sleep(
                    for: .milliseconds(HoldSeekVelocityPolicy.activationDelayMilliseconds)
                )
                guard !Task.isCancelled, remoteSeekDirection == direction else { return }
                remoteSeekHoldActivated = true
                isRemoteSeekPreviewActive = true
                nudgeSeekPreview(by: 0)
                seekPreviewRate = HoldSeekVelocityPolicy.remoteRate(
                    direction: direction,
                    heldFor: 0
                )
                remoteSeekConfirmationFocused = true
                startRemoteSeekPreviewTicker(direction)
            } catch {
                // A quick release keeps this as a ten-second skip or nudge.
            }
        }
        return true
    }

    private func startRemoteSeekPreviewTicker(_ direction: TVPlayerSeekDirection) {
        seekPreviewTickerTask?.cancel()
        seekPreviewTickerTask = Task { @MainActor in
            let clock = ContinuousClock()
            let started = clock.now
            var previous = started
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(33))
                    let now = clock.now
                    let elapsed = Self.seconds(previous.duration(to: now))
                    let heldFor = Self.seconds(started.duration(to: now))
                    previous = now
                    let isStillHeld = remoteSeekDirection == direction
                        && remoteSeekHoldActivated
                    let rate: Double
                    if isStillHeld {
                        rate = HoldSeekVelocityPolicy.remoteRate(
                            direction: direction,
                            heldFor: heldFor
                        )
                        seekPreviewRate = rate
                    } else {
                        rate = seekPreviewRate ?? HoldSeekVelocityPolicy.remoteRate(
                            direction: direction,
                            heldFor: 0
                        )
                    }
                    if advanceSeekPreview(rate: rate, elapsed: elapsed, at: Date()) {
                        _ = commitSeekPreview()
                        return
                    }
                }
            } catch {
                // Confirming, cancelling, or changing direction ends this ticker.
            }
        }
    }

    @discardableResult
    private func confirmRemoteSeekPreview() -> Bool {
        guard isRemoteSeekPreviewActive else { return false }
        return commitSeekPreview()
    }

    private func confirmSeekFromFocusedRemoteButton() {
        guard confirmRemoteSeekPreview() else { return }

        // A focused tvOS Button treats Play/Pause as a primary action and the
        // same physical press then also reaches onPlayPauseCommand. Suppress
        // only that duplicate delivery so confirming a held seek cannot
        // immediately pause playback again.
        TVRemoteCommandCenter.ignoreDuplicatePlayPauseCommands()
    }

    private func handlePlayerPlayPauseCommand() -> Bool {
        if TVRemoteCommandCenter.ignoresDuplicatePlayPauseCommand {
            return true
        }
        if confirmRemoteSeekPreview() {
            TVRemoteCommandCenter.ignoreDuplicatePlayPauseCommands()
            return true
        }
        return false
    }
#endif

    private func cancelTimelineSeek() {
        timelineSeekCommitTask?.cancel()
        timelineSeekCommitTask = nil
        timelineSeekTargetDate = nil
        timelineSeekTargetsLiveEdge = false
        noteActivity()
    }

    private func returnToLive() async {
        guard !presentation.isRecording else { return }
        if engine.activeLivePlaybackMode == .tvHeadend {
            engine.seekToPreferredLivePosition()
            return
        }
        do {
            let request = try await playback.livePlaybackRequest(
                channelID: presentation.channel.id,
                profile: engine.activeProfile,
                networkCachingMilliseconds: presentation.request.networkCachingMilliseconds,
                configuration: settings.configuration
            )
            await startPlayback(with: request)
        } catch {
            engine.reportFailure(error.localizedDescription)
        }
    }

    private func switchProfile(to profile: TVHeadendStreamProfile) async {
        guard !presentation.isRecording else { return }
        guard profile.name != engine.activeProfile else { return }
        do {
            let request = try await playback.livePlaybackRequest(
                channelID: presentation.channel.id,
                profile: profile.name,
                networkCachingMilliseconds: presentation.request.networkCachingMilliseconds,
                configuration: settings.configuration
            )
            await startPlayback(with: request)
            showPanel()
        } catch {
            engine.reportFailure(error.localizedDescription)
        }
    }

}

private struct CommercialDetectionDebugOverlay: View {
    @ObservedObject var analyzer: CommercialLiveAnalyzer

    private var diagnostics: CommercialDetectionDiagnostics { analyzer.diagnostics }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Commercial detector")
                    .font(.headline)
                Spacer(minLength: 16)
                Text(diagnostics.phase)
                    .font(.caption.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(phaseColor.opacity(0.9), in: Capsule())
            }

            CommercialDetectionDebugFrame(diagnostics: diagnostics)
                .frame(width: 320, height: 180)

            if diagnostics.isActive {
                HStack(spacing: 8) {
                    if let similarity = diagnostics.logoSimilarity {
                        Text("Logo \(similarity.formatted(.percent.precision(.fractionLength(0))))")
                        Text(presenceDescription)
                            .foregroundStyle(
                                diagnostics.logoIsPresent == true
                                    ? .green
                                    : (diagnostics.logoIsPresent == false ? .orange : .yellow)
                            )
                    } else {
                        Text("Learning \(diagnostics.learningProgress.formatted(.percent.precision(.fractionLength(0))))")
                    }
                }
                .font(.caption.bold().monospacedDigit())

                Text(modelDescription)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                ForEach(Array(diagnostics.candidates.prefix(4).enumerated()), id: \.element.id) {
                    item in
                    let index = item.offset
                    let candidate = item.element
                    HStack(spacing: 6) {
                        Circle()
                            .fill(candidateColor(candidate.role))
                            .frame(width: 7, height: 7)
                        Text("\(index + 1) \(candidate.role.rawValue)")
                        Spacer(minLength: 8)
                        Text(candidate.similarity?.formatted(
                            .percent.precision(.fractionLength(0))
                        ) ?? "—")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.78))
                }
                if let reason = diagnostics.abstentionReason {
                    Text(reason)
                        .font(.caption.bold())
                        .foregroundStyle(.yellow)
                }
            } else {
                Text("No native timeshift analyser is active.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var phaseColor: Color {
        switch diagnostics.phase {
        case "Commercial": .orange
        case "Possible commercial": .yellow
        case "Programme": .green
        default: .gray
        }
    }

    private var modelDescription: String {
        guard !diagnostics.candidates.isEmpty else { return "No logo candidates learned yet" }
        let trusted = diagnostics.candidates.filter { $0.role == .channelIdentity }.count
        let auxiliary = diagnostics.candidates.filter { $0.role == .auxiliary }.count
        let untrusted = diagnostics.candidates.filter { $0.role == .untrusted }.count
        return "\(trusted) trusted · \(auxiliary) auxiliary · \(untrusted) untrusted"
    }

    private var presenceDescription: String {
        switch diagnostics.logoIsPresent {
        case true: "present"
        case false: "absent"
        case nil: "uncertain"
        }
    }

    private func candidateColor(_ role: CommercialLogoRole) -> Color {
        switch role {
        case .channelIdentity: .green
        case .auxiliary: .cyan
        case .untrusted: .yellow
        }
    }

    private var accessibilitySummary: String {
        var parts = ["Commercial detector", diagnostics.phase]
        if let similarity = diagnostics.logoSimilarity {
            parts.append("logo match \(similarity.formatted(.percent))")
        } else if diagnostics.isActive {
            parts.append("learning \(diagnostics.learningProgress.formatted(.percent))")
        }
        parts.append(modelDescription)
        if let reason = diagnostics.abstentionReason { parts.append(reason) }
        return parts.joined(separator: ", ")
    }
}

private struct CommercialDetectionDebugFrame: View {
    let diagnostics: CommercialDetectionDiagnostics

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = sampledImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                } else {
                    Rectangle().fill(.white.opacity(0.06))
                    Text("Waiting for frame")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.62))
                }

                Canvas { context, size in
                    drawLogoMask(context: &context, size: size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
        }
        .aspectRatio(
            CGFloat(CommercialFrameFeatures.width)
                / CGFloat(CommercialFrameFeatures.height),
            contentMode: .fit
        )
    }

    private var sampledImage: CGImage? {
        let width = CommercialFrameFeatures.width
        let height = CommercialFrameFeatures.height
        guard diagnostics.sampledPixels.count == width * height else { return nil }
        let data = Data(diagnostics.sampledPixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func drawLogoMask(context: inout GraphicsContext, size: CGSize) {
        let sourceWidth = CGFloat(CommercialFrameFeatures.width)
        let sourceHeight = CGFloat(CommercialFrameFeatures.height)
        let scaleX = size.width / sourceWidth
        let scaleY = size.height / sourceHeight
        for candidate in diagnostics.candidates {
            let bounds = candidate.bounds
            let color: Color = switch candidate.role {
            case .channelIdentity: .green
            case .auxiliary: .cyan
            case .untrusted: .yellow
            }
            let region = CGRect(
                x: CGFloat(bounds.x) * scaleX,
                y: CGFloat(bounds.y) * scaleY,
                width: CGFloat(bounds.width) * scaleX,
                height: CGFloat(bounds.height) * scaleY
            )
            context.stroke(
                Path(roundedRect: region, cornerRadius: 3),
                with: .color(color),
                lineWidth: candidate.role == .channelIdentity ? 3 : 2
            )

            guard candidate.edgeMask.count == bounds.width * bounds.height else { continue }
            for index in candidate.edgeMask.indices where candidate.edgeMask[index] != 0 {
                let x = bounds.x + index % bounds.width
                let y = bounds.y + index / bounds.width
                context.fill(
                    Path(CGRect(
                        x: CGFloat(x) * scaleX,
                        y: CGFloat(y) * scaleY,
                        width: max(1, scaleX),
                        height: max(1, scaleY)
                    )),
                    with: .color(color.opacity(0.9))
                )
            }
        }
    }
}

private struct SeekPreviewFeedbackLine: View {
    let message: String?
    let rate: Double?
    let confirmationPending: Bool

    private var isVisible: Bool {
        message != nil || rate != nil || confirmationPending
    }

    var body: some View {
        HStack(spacing: 10) {
            Label(message ?? "Seek position", systemImage: "scope")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            if let rate, rate != 0 {
                Label(
                    "\(Int(abs(rate).rounded()))×",
                    systemImage: rate < 0 ? "backward.fill" : "forward.fill"
                )
                .fixedSize()
            } else if confirmationPending {
                Text("Press Select or Play to seek")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .font(.callout.weight(.semibold).monospacedDigit())
        .foregroundStyle(AppTheme.accent)
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .opacity(isVisible ? 1 : 0)
        .accessibilityHidden(!isVisible)
        .accessibilityElement(children: .combine)
    }
}

private struct RecordingPlaybackTimeline: View {
    let recording: TVRecording
    let elapsedSeconds: TimeInterval
    let seekTargetSeconds: TimeInterval?
    let seekBoundaryFeedback: TimelineSeekBoundaryFeedback?
    let seekPreviewRate: Double?
    let seekConfirmationPending: Bool
    let isPlaying: Bool
    let isPaused: Bool
    let canSeek: Bool
    let usesCompactLayout: Bool
    let usesCompactHeight: Bool
    let seekBackward: (TimeInterval) -> Void
    let seekForward: (TimeInterval) -> Void
    let seekTo: (TimeInterval) -> Void
    let togglePlayback: () -> Void
    let showPanel: () -> Void

    @FocusState private var isFocused: Bool

    private var totalDuration: TimeInterval { max(1, recording.duration) }
    private var availableDuration: TimeInterval {
        if recording.state == .recording {
            return min(totalDuration, max(0, Date().timeIntervalSince(recording.start)))
        }
        return totalDuration
    }

    var body: some View {
        VStack(spacing: usesCompactHeight ? 6 : 12) {
            if usesCompactLayout && !usesCompactHeight {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.title)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(recording.channelName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Text(recording.title)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Text(recording.channelName)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.82))
                }
            }

            RecordingTimelineBar(
                recordingStart: recording.start,
                totalDuration: totalDuration,
                availableDuration: availableDuration,
                elapsedSeconds: elapsedSeconds,
                previewElapsedSeconds: seekTargetSeconds,
                isPaused: isPaused,
                isFocused: isFocused,
                seek: seekTo
            )

            Group {
                if usesCompactLayout && !usesCompactHeight {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(clock(recording.start))–\(clock(recording.end))")
                        if recording.state == .recording {
                            Text("Recording through \(clock(recording.start.addingTimeInterval(availableDuration)))")
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack {
                        Text("\(clock(recording.start))–\(clock(recording.end))")
                        Spacer()
                        if recording.state == .recording {
                            Text("Recording · available through \(clock(recording.start.addingTimeInterval(availableDuration)))")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.white.opacity(0.76))

            SeekPreviewFeedbackLine(
                message: seekBoundaryFeedback?.label ?? seekTargetSeconds.map {
                    "Seek to \(clock(recording.start.addingTimeInterval($0)))"
                },
                rate: seekPreviewRate,
                confirmationPending: seekConfirmationPending
            )

#if !os(tvOS)
            PlaybackTransportControls(
                isPlaying: isPlaying,
                canPause: true,
                canSeek: canSeek,
                usesCompactLayout: usesCompactLayout,
                seekBackward: { seekBackward(PlayerNavigationPolicy.skipInterval) },
                seekForward: { seekForward(PlayerNavigationPolicy.skipInterval) },
                showsGoLive: false,
                goLive: {},
                togglePlayback: togglePlayback,
                showPanel: showPanel
            )
#endif
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .playerTimelineTapGesture(perform: togglePlayback)
        .platformMoveCommand { direction in
            if direction == .down {
                showPanel()
                return
            }
            guard canSeek else { return }
            switch direction {
            case .left: seekBackward(PlayerNavigationPolicy.skipInterval)
            case .right: seekForward(PlayerNavigationPolicy.skipInterval)
            default: break
            }
        }
        .padding(.horizontal, usesCompactLayout ? 20 : 44)
        .padding(.top, usesCompactHeight ? 8 : (usesCompactLayout ? 18 : 26))
        .padding(.bottom, usesCompactHeight ? 8 : (usesCompactLayout ? 18 : 28))
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

}

private struct RecordingTimelineBar: View {
    let recordingStart: Date
    let totalDuration: TimeInterval
    let availableDuration: TimeInterval
    let elapsedSeconds: TimeInterval
    let previewElapsedSeconds: TimeInterval?
    let isPaused: Bool
    let isFocused: Bool
    let seek: (TimeInterval) -> Void

    @State private var scrubTargetSeconds: TimeInterval?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let displayedElapsed = scrubTargetSeconds
                ?? previewElapsedSeconds
                ?? elapsedSeconds
            let availableWidth = width * CGFloat(availableDuration / totalDuration)
            let playhead = width * CGFloat(min(max(0, displayedElapsed / totalDuration), 1))

            interactiveTimeline(
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white.opacity(isFocused ? 0.24 : 0.16))
                        .frame(height: 16)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(AppTheme.accent.opacity(0.82))
                        .frame(width: max(0, availableWidth), height: 16)
                    Rectangle()
                        .fill(.white)
                        .frame(width: 3, height: 31)
                        .offset(x: min(max(0, playhead - 1.5), width - 3))
                    Text(playbackTimeLabel(recordingStart.addingTimeInterval(displayedElapsed)))
                        .font(.callout.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .fixedSize()
                        .position(
                            x: min(max(timeLabelInset, playhead), width - timeLabelInset),
                            y: 38
                        )
                },
                width: width
            )
        }
        .frame(height: 52)
        .accessibilityLabel("Playback position")
        .accessibilityValue(playbackTimeLabel(recordingStart.addingTimeInterval(elapsedSeconds)))
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment
                ? PlayerNavigationPolicy.skipInterval
                : -PlayerNavigationPolicy.skipInterval
            seek(min(max(0, elapsedSeconds + delta), availableDuration))
        }
    }

    @ViewBuilder
    private func interactiveTimeline<Content: View>(_ content: Content, width: CGFloat) -> some View {
#if os(tvOS)
        content
#else
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubTargetSeconds = TimelineScrubbing.recordingTarget(
                            at: value.location.x,
                            width: width,
                            availableDuration: availableDuration
                        )
                    }
                    .onEnded { value in
                        let target = TimelineScrubbing.recordingTarget(
                            at: value.location.x,
                            width: width,
                            availableDuration: availableDuration
                        )
                        scrubTargetSeconds = nil
                        seek(target)
                    }
            )
#endif
    }

    private func playbackTimeLabel(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard) + (isPaused ? " · Paused" : "")
    }

    private var timeLabelInset: CGFloat { isPaused ? 86 : 54 }
}

private struct ProgrammePlaybackTimeline: View {
    let channel: GuideChannel
    let fallbackProgram: GuideProgram?
    let pausedPlaybackDate: Date?
    let seekTargetDate: Date?
    let seekTargetsLiveEdge: Bool
    let seekBoundaryFeedback: TimelineSeekBoundaryFeedback?
    let seekPreviewRate: Double?
    let seekConfirmationPending: Bool
    let commercialBreaks: [CommercialBreak]
    let liveDelaySeconds: TimeInterval
    let bufferStartedAt: Date?
    let canPause: Bool
    let canSeek: Bool
    let isPlaying: Bool
    let isPaused: Bool
    let usesCompactLayout: Bool
    let usesCompactHeight: Bool
    let seekBackward: (TimeInterval) -> Void
    let seekForward: (TimeInterval) -> Void
    let previewSeek: (Date) -> Void
    let commitSeek: (Date) -> Void
    let returnToLive: () -> Void
    let togglePlayback: () -> Void
    let showPanel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            timeline(at: context.date)
        }
        .padding(.horizontal, usesCompactLayout ? 20 : 44)
        .padding(.top, usesCompactHeight ? 8 : (usesCompactLayout ? 18 : 26))
        .padding(.bottom, usesCompactHeight ? 8 : (usesCompactLayout ? 18 : 28))
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func timeline(at liveDate: Date) -> some View {
        let selectableLiveEdge = LiveTimelinePosition.userSeekableLiveEdge(at: liveDate)
        let proposedPlaybackDate = seekTargetsLiveEdge
            ? selectableLiveEdge
            : (seekTargetDate ?? pausedPlaybackDate
                ?? liveDate.addingTimeInterval(-liveDelaySeconds))
        let playbackDate = LiveTimelinePosition.clampedDate(
            proposedPlaybackDate,
            liveEdge: liveDate,
            bufferStartedAt: bufferStartedAt
        )
        let program = channel.programs.first { $0.start <= playbackDate && playbackDate < $0.end } ?? fallbackProgram
        let next = program.flatMap { current in
            channel.programs.first { $0.start >= current.end && $0.id != current.id }
        }

        return VStack(spacing: usesCompactHeight ? 6 : 12) {
            if usesCompactLayout && !usesCompactHeight {
                VStack(alignment: .leading, spacing: 4) {
                    Text(program?.title ?? channel.name)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .layoutPriority(1)
                    if let next {
                        Text("Next: \(next.title)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 30) {
                    Text(program?.title ?? channel.name)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    if let next {
                        Text("Next: \(next.title)")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                }
            }

            if let program {
                let availableEnd = min(program.end, selectableLiveEdge)
                TimelineBar(
                    program: program,
                    playbackDate: playbackDate,
                    availableStart: min(
                        max(program.start, bufferStartedAt ?? availableEnd),
                        availableEnd
                    ),
                    availableEnd: availableEnd,
                    commercialBreaks: commercialBreaks,
                    isPaused: isPaused,
                    isFocused: isFocused,
                    canSeek: canSeek,
                    previewSeek: previewSeek,
                    commitSeek: commitSeek
                )

                Group {
                    if usesCompactLayout {
                        Text("\(clock(program.start))–\(clock(program.end))")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack {
                            Text("\(clock(program.start))–\(clock(program.end))")
                            Spacer()
                            if let next { Text("Next · \(clock(next.start))") }
                        }
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.76))

                SeekPreviewFeedbackLine(
                    message: seekBoundaryFeedback?.label ?? seekTargetDate.map {
                        seekTargetsLiveEdge
                            ? "Go to live"
                            : seekDescription(target: $0, liveEdge: liveDate)
                    },
                    rate: seekPreviewRate,
                    confirmationPending: seekConfirmationPending
                )
            } else {
                Capsule().fill(.white.opacity(0.25)).frame(height: 14)
            }

#if !os(tvOS)
            PlaybackTransportControls(
                isPlaying: isPlaying,
                canPause: canPause,
                canSeek: canSeek,
                usesCompactLayout: usesCompactLayout,
                seekBackward: { seekBackward(PlayerNavigationPolicy.skipInterval) },
                seekForward: { seekForward(PlayerNavigationPolicy.skipInterval) },
                showsGoLive: canSeek
                    && liveDate.timeIntervalSince(playbackDate)
                        > NativeTimeshiftActionPlan.preferredLiveDelay
                            + NativeTimeshiftActionPlan.liveEdgeTolerance,
                goLive: returnToLive,
                togglePlayback: togglePlayback,
                showPanel: showPanel
            )
#endif
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .playerTimelineTapGesture {
            if canPause { togglePlayback() }
        }
        .platformMoveCommand { direction in
            if direction == .down {
                showPanel()
                return
            }
            guard canSeek else { return }
            switch direction {
            case .left: seekBackward(PlayerNavigationPolicy.skipInterval)
            case .right: seekForward(PlayerNavigationPolicy.skipInterval)
            default: break
            }
        }
        .accessibilityHint(
            canSeek
                ? "Timeshift is available from \(bufferStartedAt.map(clock) ?? "the start of playback"). Swipe left or right to move 10 seconds"
                : "Live playback without timeshift"
        )
    }

    private func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    private func seekDescription(target: Date, liveEdge: Date) -> String {
        let delay = max(0, Int(liveEdge.timeIntervalSince(target).rounded()))
        if delay == 0 { return "Go to live" }
        let minutes = delay / 60
        let seconds = delay % 60
        let offset = minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
        return "Seek to \(clock(target)) · \(offset) behind live"
    }
}

#if !os(tvOS)
private struct PlaybackTransportControls: View {
    let isPlaying: Bool
    let canPause: Bool
    let canSeek: Bool
    let usesCompactLayout: Bool
    let seekBackward: () -> Void
    let seekForward: () -> Void
    let showsGoLive: Bool
    let goLive: () -> Void
    let togglePlayback: () -> Void
    let showPanel: () -> Void

    var body: some View {
        Group {
            if usesCompactLayout {
                compactControls
            } else {
                regularControls
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var compactControls: some View {
        HStack(spacing: 8) {
            compactButton(
                label: "Back 10 Seconds",
                systemImage: "gobackward.10",
                isEnabled: canSeek,
                action: seekBackward
            )
            compactButton(
                label: isPlaying ? "Pause" : "Play",
                systemImage: isPlaying ? "pause.fill" : "play.fill",
                isEnabled: canPause,
                isProminent: true,
                action: togglePlayback
            )
            compactButton(
                label: "Forward 10 Seconds",
                systemImage: "goforward.10",
                isEnabled: canSeek,
                action: seekForward
            )
            if showsGoLive {
                compactButton(
                    label: "Go Live",
                    systemImage: "dot.radiowaves.left.and.right",
                    action: goLive
                )
            }
            compactButton(
                label: "Playback Options",
                systemImage: "slider.horizontal.3",
                action: showPanel
            )
        }
    }

    private var regularControls: some View {
        HStack(spacing: usesCompactLayout ? 12 : 18) {
            Button(action: seekBackward) {
                Label("Back 10 Seconds", systemImage: "gobackward.10")
                    .labelStyle(.iconOnly)
                    .frame(width: usesCompactLayout ? 36 : nil, height: usesCompactLayout ? 36 : nil)
            }
            .disabled(!canSeek)

            Button(action: togglePlayback) {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: usesCompactLayout ? 36 : nil, height: usesCompactLayout ? 36 : nil)
            }
            .disabled(!canPause)
            .buttonStyle(.borderedProminent)

            Button(action: seekForward) {
                Label("Forward 10 Seconds", systemImage: "goforward.10")
                    .labelStyle(.iconOnly)
                    .frame(width: usesCompactLayout ? 36 : nil, height: usesCompactLayout ? 36 : nil)
            }
            .disabled(!canSeek)

            if showsGoLive {
                Button(action: goLive) {
                    if usesCompactLayout {
                        Label("Go Live", systemImage: "dot.radiowaves.left.and.right")
                            .labelStyle(.iconOnly)
                            .frame(width: 36, height: 36)
                    } else {
                        Label("Go Live", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .accessibilityLabel("Go Live")
            }

            Spacer(minLength: usesCompactLayout ? 0 : 8)

            Button(action: showPanel) {
                if usesCompactLayout {
                    Label("Playback Options", systemImage: "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                        .frame(width: 36, height: 36)
                } else {
                    Label("Playback Options", systemImage: "slider.horizontal.3")
                }
            }
        }
        .font(.title3)
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func compactButton(
        label: String,
        systemImage: String,
        isEnabled: Bool = true,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.bold())
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(
                    isProminent ? AppTheme.accent : AppTheme.surfaceRaised,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
    }
}
#endif

private struct TimelineBar: View {
    let program: GuideProgram
    let playbackDate: Date
    let availableStart: Date
    let availableEnd: Date
    let commercialBreaks: [CommercialBreak]
    let isPaused: Bool
    let isFocused: Bool
    let canSeek: Bool
    let previewSeek: (Date) -> Void
    let commitSeek: (Date) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(1, program.duration)
            let playhead = position(playbackDate, width: width, duration: duration)
            let availableX = position(availableStart, width: width, duration: duration)
            let availableRight = position(availableEnd, width: width, duration: duration)

            interactiveTimeline(
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white.opacity(isFocused ? 0.24 : 0.16))
                        .frame(height: 16)

                    RoundedRectangle(cornerRadius: 5)
                        .fill(AppTheme.accent.opacity(0.82))
                        .frame(width: max(0, availableRight - availableX), height: 16)
                        .offset(x: availableX)

                    ForEach(commercialBreaks) { commercial in
                        let start = max(commercial.start, max(program.start, availableStart))
                        let end = min(commercial.end, min(program.end, availableEnd))
                        if end > start {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.orange.opacity(0.92))
                                .frame(
                                    width: max(
                                        2,
                                        position(end, width: width, duration: duration)
                                            - position(start, width: width, duration: duration)
                                    ),
                                    height: 16
                                )
                                .offset(x: position(start, width: width, duration: duration))
                        }
                    }

                    Rectangle()
                        .fill(.white)
                        .frame(width: 3, height: 31)
                        .offset(x: min(max(0, playhead - 1.5), width - 3))

                    Text(playbackTimeLabel(playbackDate))
                        .font(.callout.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .fixedSize()
                        .position(
                            x: min(max(timeLabelInset, playhead), width - timeLabelInset),
                            y: 38
                        )
                },
                width: width
            )
        }
        .frame(height: 52)
        .accessibilityLabel("Playback position")
        .accessibilityValue(
            playbackTimeLabel(playbackDate)
                + (commercialBreaks.contains(where: { $0.contains(playbackDate) })
                    ? ", Commercial"
                    : "")
        )
        .accessibilityAdjustableAction { direction in
            guard canSeek else { return }
            let delta = direction == .increment
                ? PlayerNavigationPolicy.skipInterval
                : -PlayerNavigationPolicy.skipInterval
            commitSeek(
                min(max(playbackDate.addingTimeInterval(delta), availableStart), availableEnd)
            )
        }
    }

    @ViewBuilder
    private func interactiveTimeline<Content: View>(_ content: Content, width: CGFloat) -> some View {
#if os(tvOS)
        content
#else
        if canSeek {
            content
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            previewSeek(target(at: value.location.x, width: width))
                        }
                        .onEnded { value in
                            commitSeek(target(at: value.location.x, width: width))
                        }
                )
        } else {
            content
        }
#endif
    }

    private func target(at x: CGFloat, width: CGFloat) -> Date {
        TimelineScrubbing.liveTarget(
            at: x,
            width: width,
            rangeStart: program.start,
            rangeEnd: program.end,
            availableStart: availableStart,
            availableEnd: availableEnd
        )
    }

    private func position(_ date: Date, width: CGFloat, duration: TimeInterval) -> CGFloat {
        min(max(0, CGFloat(date.timeIntervalSince(program.start) / duration) * width), width)
    }

    private func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    private func playbackTimeLabel(_ date: Date) -> String {
        clock(date) + (isPaused ? " · Paused" : "")
    }

    private var timeLabelInset: CGFloat { isPaused ? 86 : 54 }
}

private struct PlayerTabbedOverlay: View {
    let presentation: PlaybackPresentation
    @ObservedObject var engine: VLCPlaybackEngine
    let profiles: [TVHeadendStreamProfile]
    @Binding var selectedTab: PlayerOverlayTab
    @Binding var showsCommercialDetectionOverlay: Bool
    let usesCompactLayout: Bool
    let usesCompactHeight: Bool
    let selectProfile: (TVHeadendStreamProfile) -> Void
    let dismiss: () -> Void
    let noteActivity: () -> Void

    @FocusState private var tabBarFocused: Bool
    @FocusState private var focusedTab: PlayerOverlayTab?
    @FocusState private var focusedTechnicalDetailID: PlaybackTechnicalDetail.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: usesCompactHeight ? 10 : 22) {
            tabSelector

            Divider().overlay(.white.opacity(0.2))

            // Keep each tab subtree alive while switching. The Details tab
            // owns the asynchronously loaded channel badge; tearing it down
            // briefly exposed its fallback whenever the tab was revisited.
            ZStack(alignment: .topLeading) {
                tabContent(details, for: .details)
                tabContent(playbackSettings, for: .playback)
                tabContent(technicalDetails, for: .technical)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: panelMinimumHeight,
                maxHeight: panelMaximumHeight,
                alignment: .topLeading
            )
        }
        .padding(.horizontal, overlayHorizontalPadding)
        .padding(.top, usesCompactHeight ? 8 : (usesCompactLayout ? 72 : 26))
        .padding(.bottom, usesCompactHeight ? 10 : (usesCompactLayout ? 24 : 34))
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.92))
        .onChange(of: focusedTechnicalDetailID) { _, detailID in
            guard detailID != nil else { return }
            noteActivity()
        }
    }

    @ViewBuilder
    private var tabSelector: some View {
#if os(tvOS)
        HStack(spacing: 12) {
            ForEach(PlayerOverlayTab.allCases) { tab in
                tabLabel(tab, isFocused: false)
                    .onTapGesture { selectTab(tab) }
            }
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($tabBarFocused)
        .focusEffectDisabled()
        .platformMoveCommand(moveTab)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(selectedTab.rawValue) tab")
        .accessibilityValue("\(selectedTab.rawValue), \(selectedTabIndex + 1) of \(PlayerOverlayTab.allCases.count)")
        .accessibilityHint("Swipe up or down to change tabs")
        .accessibilityAdjustableAction { direction in
            adjustSelectedTab(direction)
        }
        .padding(.leading, usesCompactHeight ? 56 : 0)
#else
        HStack(spacing: 12) {
            ForEach(PlayerOverlayTab.allCases) { tab in
                Button {
                    selectTab(tab)
                } label: {
                    tabLabel(tab, isFocused: focusedTab == tab)
                }
                .buttonStyle(.plain)
                .focused($focusedTab, equals: tab)
                .focusEffectDisabled()
                .accessibilityLabel(tab.rawValue)
                .accessibilityValue(selectedTab == tab ? "Selected" : "")
            }
        }
        .padding(.leading, usesCompactHeight ? 56 : 0)
#endif
    }

    private func tabLabel(_ tab: PlayerOverlayTab, isFocused: Bool) -> some View {
        Text(tab.rawValue)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: usesCompactLayout ? .infinity : nil)
            .padding(.horizontal, usesCompactLayout ? 10 : 24)
            .padding(.vertical, usesCompactLayout ? 10 : 12)
            .background(
                selectedTab == tab || isFocused
                    ? AppTheme.focused
                    : Color.white.opacity(0.08),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(isFocused ? AppTheme.focusBorder : .clear, lineWidth: 2)
            }
            .contentShape(Capsule())
    }

    private func selectTab(_ tab: PlayerOverlayTab) {
        selectedTab = tab
        noteActivity()
    }

    private var selectedTabIndex: Int {
        PlayerOverlayTab.allCases.firstIndex(of: selectedTab) ?? 0
    }

    private func adjustSelectedTab(_ direction: AccessibilityAdjustmentDirection) {
        let tabs = PlayerOverlayTab.allCases
        let delta = direction == .increment ? 1 : -1
        let index = min(max(0, selectedTabIndex + delta), tabs.count - 1)
        selectTab(tabs[index])
    }

    private var overlayHorizontalPadding: CGFloat {
        if usesCompactHeight { return 16 }
        if usesCompactLayout { return 20 }
#if os(macOS)
        return 28
#else
        return 48
#endif
    }

    private var panelMinimumHeight: CGFloat {
        if usesCompactHeight { return 190 }
        if usesCompactLayout { return 440 }
#if os(macOS)
        return 260
#else
        return 300
#endif
    }

    private var panelMaximumHeight: CGFloat {
        if usesCompactHeight { return 240 }
        if usesCompactLayout { return 560 }
#if os(macOS)
        return 360
#else
        return 420
#endif
    }

    private func moveTab(_ direction: PlatformMoveDirection) {
        let tabs = PlayerOverlayTab.allCases
        guard let index = tabs.firstIndex(of: selectedTab) else { return }

        let nextIndex: Int
        switch direction {
        case .up:
            dismiss()
            return
        case .left:
            nextIndex = max(tabs.startIndex, index - 1)
        case .right:
            nextIndex = min(tabs.index(before: tabs.endIndex), index + 1)
        default:
            return
        }

        guard nextIndex != index else { return }
        selectedTab = tabs[nextIndex]
        noteActivity()
    }

    private func tabContent<Content: View>(
        _ content: Content,
        for tab: PlayerOverlayTab
    ) -> some View {
        content
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .disabled(selectedTab != tab)
            .accessibilityHidden(selectedTab != tab)
    }

    private var playbackDate: Date {
        let liveEdge = Date()
        return LiveTimelinePosition.clampedDate(
            engine.livePlaybackDate(at: liveEdge),
            liveEdge: liveEdge,
            bufferStartedAt: engine.bufferStartedAt
        )
    }

    private var currentProgram: GuideProgram? {
        presentation.channel.programs.first {
            $0.start <= playbackDate && playbackDate < $0.end
        } ?? presentation.program
    }

    private var details: some View {
        ScrollView(.vertical) {
            Group {
                if usesCompactHeight {
                    HStack(alignment: .top, spacing: 14) {
                        ChannelBadge(channel: presentation.channel, diameter: 56)
                        VStack(alignment: .leading, spacing: 8) {
                            detailHeading
                            detailMetadata
                        }
                    }
                } else if usesCompactLayout {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 16) {
                            ChannelBadge(channel: presentation.channel, diameter: 64)
                            detailHeading
                        }
                        detailMetadata
                    }
                } else {
                    HStack(alignment: .top, spacing: 42) {
                        ChannelBadge(channel: presentation.channel, diameter: 112)
                        VStack(alignment: .leading, spacing: 12) {
                            detailHeading
                            detailMetadata
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)
        }
        .scrollIndicators(.visible)
        .contentMargins(.vertical, 4, for: .scrollContent)
        .focusable()
        .focusEffectDisabled()
        .accessibilityLabel("Programme details")
        .accessibilityHint("Swipe up or down to read the full description")
    }

    @ViewBuilder
    private var detailHeading: some View {
        VStack(alignment: .leading, spacing: usesCompactLayout ? 5 : 8) {
            Text(presentation.recording?.title ?? currentProgram?.title ?? presentation.channel.name)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .lineLimit(usesCompactLayout ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = presentation.recording?.subtitle ?? currentProgram?.subtitle,
               !subtitle.isEmpty {
                Text(subtitle)
                    .font(usesCompactLayout ? .subheadline.weight(.semibold) : .headline.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(usesCompactLayout ? 2 : nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var detailMetadata: some View {
        if let recording = presentation.recording {
            Text("\(recording.start.formatted(date: .abbreviated, time: .shortened))–\(recording.end.formatted(date: .omitted, time: .shortened)) · \(recording.channelName)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(AppTheme.secondaryText)
            programmeOverview(recording.overview)
        } else if let program = currentProgram {
            Text("\(program.start.formatted(date: .abbreviated, time: .shortened))–\(program.end.formatted(date: .omitted, time: .shortened)) · \(presentation.channel.name)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(AppTheme.secondaryText)
            if let metadataDescription = program.metadata.displayDescription {
                Text(metadataDescription)
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !program.metadata.displayFacts.isEmpty {
                Text(program.metadata.displayFacts.joined(separator: "  •  "))
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            programmeOverview(program.overview)
            ForEach(
                program.metadata.supplementaryDescriptions(excluding: program.overview),
                id: \.self
            ) { description in
                programmeOverview(description)
            }
        }
    }

    private func programmeOverview(_ overview: String) -> some View {
        Text(overview.isEmpty ? "No description available." : overview)
            .font(.body)
            .foregroundStyle(.white.opacity(overview.isEmpty ? 0.62 : 0.9))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var playbackSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !presentation.isRecording, profiles.count > 1 {
                    playbackSettingsRow(
                        title: "Stream quality",
                        systemImage: "sparkles.tv"
                    ) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 12)],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(profiles) { profile in
                                choiceButton(
                                    title: profile.name == "pass" ? "Original" : profile.name,
                                    subtitle: profile.name == "pass" ? "Direct play" : "Transcode",
                                    selected: engine.activeProfile == profile.name
                                ) { selectProfile(profile) }
                            }
                        }
                    }
                    playbackSettingsDivider
                }

                playbackSettingsRow(
                    title: "Audio",
                    systemImage: "speaker.wave.2.fill"
                ) {
                    trackChoices(
                        tracks: engine.audioTracks,
                        selectedTrackID: engine.selectedAudioTrackID,
                        emptyMessage: "No audio streams reported yet",
                        selectTrack: engine.selectAudioTrack
                    )
                }
                if selectedTrackIsEnabled(
                    tracks: engine.audioTracks,
                    selectedTrackID: engine.selectedAudioTrackID
                ) {
                    playbackSettingsDivider
                    playbackSettingsRow(title: "Audio sync", systemImage: "waveform") {
                        delayButtons(
                            value: engine.audioDelayMilliseconds,
                            change: engine.adjustAudioDelay
                        )
                    }
                }

                playbackSettingsDivider
                playbackSettingsRow(
                    title: "Subtitles",
                    systemImage: "captions.bubble.fill"
                ) {
                    trackChoices(
                        tracks: subtitleTrackChoices,
                        selectedTrackID: engine.selectedSubtitleTrackID,
                        emptyMessage: "No subtitles available",
                        selectTrack: engine.selectSubtitleTrack
                    )
                }
                if selectedTrackIsEnabled(
                    tracks: engine.subtitleTracks,
                    selectedTrackID: engine.selectedSubtitleTrackID
                ) {
                    playbackSettingsDivider
                    playbackSettingsRow(title: "Subtitle sync", systemImage: "waveform") {
                        delayButtons(
                            value: engine.subtitleDelayMilliseconds,
                            change: engine.adjustSubtitleDelay
                        )
                    }
                }
            }
            .frame(maxWidth: usesCompactLayout ? .infinity : 1_360, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }

    private func trackChoices(
        tracks: [PlaybackTrack],
        selectedTrackID: Int?,
        emptyMessage: String,
        selectTrack: @escaping (Int) -> Void
    ) -> some View {
        let orderedTracks = tracks.filter { !isDisabledTrack($0) }
            + tracks.filter(isDisabledTrack)

        return LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(
                        minimum: usesCompactLayout ? 190 : regularTrackMinimumWidth,
                        maximum: usesCompactLayout ? 320 : regularTrackMaximumWidth
                    ),
                    spacing: 12
                )
            ],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(orderedTracks) { track in
                let labels = trackLabels(track)
                choiceButton(
                    title: labels.title,
                    subtitle: labels.subtitle,
                    selected: isDisabledTrack(track)
                        ? selectedTrackID == nil
                        : selectedTrackID == track.id
                ) {
                    selectTrack(track.id)
                    noteActivity()
                }
            }
            if tracks.isEmpty {
                unavailable(emptyMessage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isDisabledTrack(_ track: PlaybackTrack) -> Bool {
        track.id < 0 || track.name.localizedCaseInsensitiveContains("disable")
    }

    private var subtitleTrackChoices: [PlaybackTrack] {
        guard !engine.subtitleTracks.isEmpty else { return [] }
        if engine.subtitleTracks.contains(where: isDisabledTrack) {
            return engine.subtitleTracks
        }
        return [PlaybackTrack(id: -1, name: "Off")] + engine.subtitleTracks
    }

    private func selectedTrackIsEnabled(
        tracks: [PlaybackTrack],
        selectedTrackID: Int?
    ) -> Bool {
        guard let selectedTrackID,
              let track = tracks.first(where: { $0.id == selectedTrackID })
        else { return false }
        return !isDisabledTrack(track)
    }

    private func trackLabels(_ track: PlaybackTrack) -> (title: String, subtitle: String?) {
        guard !isDisabledTrack(track) else { return ("Off", nil) }

        let separator = " - ["
        guard let separatorRange = track.name.range(of: separator),
              track.name.hasSuffix("]")
        else { return (track.name, nil) }

        let trackName = String(track.name[..<separatorRange.lowerBound])
        let valueStart = separatorRange.upperBound
        let valueEnd = track.name.index(before: track.name.endIndex)
        let rawValue = String(track.name[valueStart..<valueEnd])
        let displayValue = rawValue.count <= 3 ? rawValue.uppercased() : rawValue
        return (displayValue, trackName)
    }

    private var technicalDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Toggle(isOn: $showsCommercialDetectionOverlay) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Commercial detector overlay")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("Show the sampled frame, learned logo mask, and match confidence.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .toggleStyle(.switch)
                .disabled(presentation.isRecording)
                .padding(18)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible()),
                        count: usesCompactHeight ? 2 : (usesCompactLayout ? 1 : 3)
                    ),
                    alignment: .leading,
                    spacing: 18
                ) {
                    ForEach(engine.technicalDetails) { detail in
                        let isFocused = focusedTechnicalDetailID == detail.id

                        VStack(alignment: .leading, spacing: 5) {
                            Text(detail.label.uppercased())
                                .font(.caption.bold())
                                .tracking(1.1)
                                .foregroundStyle(AppTheme.secondaryText)
                            Text(detail.value)
                                .font(.headline)
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(
                            isFocused ? AppTheme.focused : Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    isFocused ? AppTheme.focusBorder : Color.clear,
                                    lineWidth: 3
                                )
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                        .focusable()
                        .focused($focusedTechnicalDetailID, equals: detail.id)
                        .focusEffectDisabled()
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func playbackSettingsRow<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if usesCompactLayout {
            VStack(alignment: .leading, spacing: 12) {
                playbackSettingsLabel(title: title, systemImage: systemImage)
                content()
            }
            .padding(.vertical, 14)
        } else {
            HStack(alignment: .top, spacing: playbackSettingsColumnSpacing) {
                playbackSettingsLabel(title: title, systemImage: systemImage)
                    .frame(width: playbackSettingsLabelWidth, alignment: .leading)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 18)
        }
    }

    private func playbackSettingsLabel(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.86))
            .lineLimit(usesCompactLayout ? 2 : 1)
            .padding(.top, 10)
    }

    private var playbackSettingsDivider: some View {
        Divider().overlay(.white.opacity(0.12))
    }

    private func choiceButton(
        title: String,
        subtitle: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        PlayerChoiceButton(
            title: title,
            subtitle: subtitle,
            selected: selected,
            height: usesCompactLayout ? 72 : regularChoiceHeight,
            action: action
        )
    }

    private var regularTrackMinimumWidth: CGFloat {
#if os(macOS)
        220
#else
        300
#endif
    }

    private var regularTrackMaximumWidth: CGFloat {
#if os(macOS)
        320
#else
        360
#endif
    }

    private var playbackSettingsColumnSpacing: CGFloat {
#if os(macOS)
        22
#else
        34
#endif
    }

    private var playbackSettingsLabelWidth: CGFloat {
#if os(macOS)
        180
#else
        260
#endif
    }

    private var regularChoiceHeight: CGFloat {
#if os(macOS)
        78
#else
        128
#endif
    }

    private func unavailable(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.white.opacity(0.62))
            .padding(.vertical, 12)
    }

    private func delayButtons(value: Int, change: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 12) {
            PlayerStepButton(systemImage: "minus") {
                change(-50)
                noteActivity()
            }
            Text(value == 0 ? "0 ms" : String(format: "%+d ms", value))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: usesCompactLayout ? 80 : 105)
            PlayerStepButton(systemImage: "plus") {
                change(50)
                noteActivity()
            }
        }
        .frame(maxWidth: usesCompactLayout ? .infinity : nil, alignment: .leading)
    }
}

private struct PlayerChoiceButton: View {
    let title: String
    let subtitle: String?
    let selected: Bool
    let height: CGFloat
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    if selected { Image(systemName: "checkmark.circle.fill") }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isFocused
                    ? AppTheme.focused
                    : Color.white.opacity(selected ? 0.16 : 0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isFocused
                            ? AppTheme.focusBorder
                            : (selected ? AppTheme.accent.opacity(0.85) : Color.white.opacity(0.08)),
                        lineWidth: isFocused ? 3 : (selected ? 2 : 1)
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
    }
}

private struct PlayerStepButton: View {
    let systemImage: String
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.bold())
                .foregroundStyle(.white)
                .frame(width: 48, height: 38)
                .background(
                    isFocused ? AppTheme.focused : Color.white.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(isFocused ? AppTheme.focusBorder : Color.clear, lineWidth: 2)
                }
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .focusEffectDisabled()
        .accessibilityLabel(systemImage == "minus" ? "Decrease delay" : "Increase delay")
    }
}

#if os(iOS)
private struct IOSHoldSeekSurface: UIViewRepresentable {
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    let isEnabled: Bool
    let activate: (CGFloat) -> Void
    let updateTranslation: (CGFloat, CGFloat) -> Void
    let finish: (Bool) -> Void
    let tap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(surface: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        context.coordinator.installRecognizers(on: view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.surface = self
        context.coordinator.longPressRecognizer?.isEnabled =
            isEnabled && !voiceOverEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var surface: IOSHoldSeekSurface
        weak var view: UIView?
        weak var longPressRecognizer: UILongPressGestureRecognizer?

        private var activationLocation: CGPoint?
        private var isActivated = false
        private var movedOutsideDeadZone = false

        init(surface: IOSHoldSeekSurface) {
            self.surface = surface
        }

        func installRecognizers(on view: UIView) {
            self.view = view

            let longPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPress(_:))
            )
            longPress.minimumPressDuration =
                Double(HoldSeekVelocityPolicy.activationDelayMilliseconds) / 1_000
            longPress.allowableMovement = 22
            view.addGestureRecognizer(longPress)
            longPressRecognizer = longPress

            let tap = UITapGestureRecognizer(
                target: self,
                action: #selector(handleTap)
            )
            tap.require(toFail: longPress)
            view.addGestureRecognizer(tap)
        }

        @objc
        private func handleTap() {
            surface.tap()
        }

        @objc
        private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let view else { return }
            let playerWidth = max(1, view.bounds.width)

            switch recognizer.state {
            case .began:
                isActivated = true
                movedOutsideDeadZone = false
                activationLocation = recognizer.location(in: view)
                surface.activate(playerWidth)
            case .changed:
                updateTranslation(for: recognizer, in: view, playerWidth: playerWidth)
            case .ended:
                updateTranslation(for: recognizer, in: view, playerWidth: playerWidth)
                finishGesture(shouldCommit: isActivated && movedOutsideDeadZone)
            case .cancelled, .failed:
                finishGesture(shouldCommit: false)
            default:
                break
            }
        }

        private func updateTranslation(
            for recognizer: UILongPressGestureRecognizer,
            in view: UIView,
            playerWidth: CGFloat
        ) {
            guard let activationLocation else { return }
            let translation = recognizer.location(in: view).x - activationLocation.x
            if abs(translation) > HoldSeekVelocityPolicy.touchDeadZone {
                movedOutsideDeadZone = true
            }
            surface.updateTranslation(translation, playerWidth)
        }

        private func finishGesture(shouldCommit: Bool) {
            surface.finish(shouldCommit)
            activationLocation = nil
            isActivated = false
            movedOutsideDeadZone = false
        }
    }
}
#endif

private extension View {
    @ViewBuilder
    func playerTimelineTapGesture(perform action: @escaping () -> Void) -> some View {
#if os(tvOS)
        onTapGesture(perform: action)
#else
        self
#endif
    }
}
