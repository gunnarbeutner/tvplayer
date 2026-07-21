import SwiftUI

private enum PlayerChromeMode: Equatable {
    case hidden
    case timeline
    case panel
}

private enum PlayerOverlayTab: String, CaseIterable, Identifiable {
    case details = "Details"
    case playback = "Playback"
    case technical = "Technical"

    var id: Self { self }
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
    @State private var timelineSeekRepeatTask: Task<Void, Never>?
    @State private var isRefreshingGrowingRecording = false
    @State private var videoAttachmentRevision = 0
    @FocusState private var wakeSurfaceFocused: Bool

    let presentation: PlaybackPresentation
    var showsVideoSurface = true

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

    private func platformImage(_ image: PlatformImage) -> Image {
#if canImport(UIKit)
        Image(uiImage: image)
#else
        Image(nsImage: image)
#endif
    }

    var body: some View {
        ZStack {
            if showsVideoSurface {
                Color.black.ignoresSafeArea()

                VLCVideoSurface(
                    mediaPlayer: engine.mediaPlayer,
                    attachmentRevision: videoAttachmentRevision
                )
                    .ignoresSafeArea()
            } else {
                Color.clear.ignoresSafeArea()
            }

            if engine.isPlaybackOutputConcealed {
                Group {
                    if let pausedFrame = engine.pausedFrame {
                        GeometryReader { geometry in
                            platformImage(pausedFrame)
                                .resizable()
                                .scaledToFill()
                                .frame(
                                    width: geometry.size.width,
                                    height: geometry.size.height
                                )
                                .clipped()
                        }
                        .background(Color.black)
                    } else {
                        Color.black
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }

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

            if chromeMode == .timeline {
                VStack {
                    Spacer()
                    if let recording = presentation.recording {
                        RecordingPlaybackTimeline(
                            recording: recording,
                            elapsedSeconds: engine.elapsedSeconds,
                            isPlaying: engine.state == .playing,
                            canSeek: engine.isSeekable,
                            usesCompactLayout: usesCompactLayout,
                            usesCompactHeight: usesCompactHeight,
                            seekBackward: { engine.skipBackward(by: $0); noteActivity() },
                            seekForward: { skipForward(by: $0) },
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
                            liveDelaySeconds: engine.liveDelaySeconds,
                            bufferStartedAt: engine.bufferStartedAt,
                            canPause: engine.canPause,
                            canSeek: engine.isSeekable,
                            isPlaying: engine.state == .playing,
                            usesCompactLayout: usesCompactLayout,
                            usesCompactHeight: usesCompactHeight,
                            seekBackward: { stageTimelineSeek(by: -$0) },
                            seekForward: { stageTimelineSeek(by: $0) },
                            togglePlayback: toggleTimelinePlayback,
                            showPanel: showPanel
                        )
                    }
                }
                .transition(.opacity)
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
                    playback.leavePlayer()
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
                .accessibilityLabel("Close Player")
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
            hasStartedCurrentPresentation = false
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
        .task(id: chromeActivity) {
            guard chromeMode == .timeline, engine.state == .playing else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, chromeMode == .timeline, engine.state == .playing else { return }
            hideChrome()
        }
#if os(tvOS)
        .onAppear {
            TVRemoteCommandCenter.seekHoldHandler = handleRemoteSeekPress
        }
#endif
        .onDisappear {
            timelineSeekCommitTask?.cancel()
            timelineSeekRepeatTask?.cancel()
#if os(tvOS)
            TVRemoteCommandCenter.seekHoldHandler = nil
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
            toggleTimelinePlayback()
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
        .platformExitCommand {
            if timelineSeekTargetDate != nil {
                cancelTimelineSeek()
            } else if chromeMode != .hidden {
                hideChrome()
            } else {
                playback.leavePlayer()
            }
        }
#if os(macOS)
        .onKeyPress(phases: [.down, .repeat]) { keyPress in
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
        .onReceive(
            NotificationCenter.default.publisher(for: .vlcTimeshiftBenchmarkPlayerCommand)
        ) { notification in
            guard ProcessInfo.processInfo.arguments.contains("--vlc-timeshift-benchmark"),
                  let command = notification.object as? MacOSPlayerKeyboardCommand
            else { return }
            perform(command)
        }
#endif
        .onChange(of: engine.state) { _, state in
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
        videoAttachmentRevision &+= 1
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
                    expectedDurationSeconds: recording.duration
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

    private func toggleTimelinePlayback() {
        let wasPlaying = engine.mediaPlayer.isPlaying
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

    private func skipForward(by seconds: TimeInterval) {
        let needsLiveReconnect = engine.skipForward(by: seconds)
        noteActivity()
        if needsLiveReconnect { Task { await returnToLive() } }
    }

    @discardableResult
    private func stageTimelineSeek(by seconds: TimeInterval) -> Bool {
        guard !presentation.isRecording, engine.isSeekable, seconds != 0 else { return false }
        let liveEdge = Date()
        let current = timelineSeekTargetsLiveEdge
            ? liveEdge
            : (timelineSeekTargetDate ?? engine.livePlaybackDate(at: liveEdge))
        let availableStart = engine.bufferStartedAt ?? liveEdge
        let target = min(max(current.addingTimeInterval(seconds), availableStart), liveEdge)
        guard abs(target.timeIntervalSince(current)) > NativeTimeshiftActionPlan.liveEdgeTolerance else {
            return false
        }
        timelineSeekTargetDate = target
        let targetsLiveEdge = target >= liveEdge.addingTimeInterval(
            -NativeTimeshiftActionPlan.liveEdgeTolerance
        )
        timelineSeekTargetsLiveEdge = targetsLiveEdge
        noteActivity()

        timelineSeekCommitTask?.cancel()
        timelineSeekCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }

            engine.refreshPlaybackInformation()
            if targetsLiveEdge {
                engine.returnToLive()
            } else {
                let delta = target.timeIntervalSince(engine.livePlaybackDate())
                if delta < -NativeTimeshiftActionPlan.liveEdgeTolerance {
                    engine.skipBackward(by: -delta)
                } else if delta > NativeTimeshiftActionPlan.liveEdgeTolerance {
                    skipForward(by: delta)
                } else {
                    timelineSeekTargetDate = nil
                    timelineSeekTargetsLiveEdge = false
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
                    return
                }
            }
        }
        return true
    }

#if os(tvOS)
    private func handleRemoteSeekPress(
        _ direction: TVPlayerSeekDirection,
        isPressed: Bool
    ) -> Bool {
        guard isPressed else {
            timelineSeekRepeatTask?.cancel()
            timelineSeekRepeatTask = nil
            noteActivity()
            return true
        }
        guard chromeMode != .panel, !presentation.isRecording else { return false }

        let wasHidden = chromeMode == .hidden
        if wasHidden { showTimeline() }
        guard engine.isSeekable else { return true }

        let interval: TimeInterval = direction == .backward ? -15 : 15
        if !wasHidden, !stageTimelineSeek(by: interval) { return true }

        timelineSeekRepeatTask?.cancel()
        timelineSeekRepeatTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(450))
                while !Task.isCancelled {
                    guard stageTimelineSeek(by: interval) else { return }
                    try await Task.sleep(for: .milliseconds(180))
                }
            } catch {
                // Releasing or cancelling the directional press ends repeat.
            }
        }
        return true
    }
#endif

    private func cancelTimelineSeek() {
        timelineSeekCommitTask?.cancel()
        timelineSeekCommitTask = nil
        timelineSeekRepeatTask?.cancel()
        timelineSeekRepeatTask = nil
        timelineSeekTargetDate = nil
        timelineSeekTargetsLiveEdge = false
        noteActivity()
    }

    private func returnToLive() async {
        guard !presentation.isRecording else { return }
        if engine.activeLivePlaybackMode == .tvHeadend {
            engine.returnToLive()
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

private struct RecordingPlaybackTimeline: View {
    let recording: TVRecording
    let elapsedSeconds: TimeInterval
    let isPlaying: Bool
    let canSeek: Bool
    let usesCompactLayout: Bool
    let usesCompactHeight: Bool
    let seekBackward: (TimeInterval) -> Void
    let seekForward: (TimeInterval) -> Void
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

            GeometryReader { geometry in
                let width = geometry.size.width
                let availableWidth = width * CGFloat(availableDuration / totalDuration)
                let playhead = width * CGFloat(min(max(0, elapsedSeconds / totalDuration), 1))

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
                    Text(clock(recording.start.addingTimeInterval(elapsedSeconds)))
                        .font(.callout.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .fixedSize()
                        .position(x: min(max(54, playhead), width - 54), y: 38)
                }
            }
            .frame(height: 52)

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

#if !os(tvOS)
            PlaybackTransportControls(
                isPlaying: isPlaying,
                canPause: true,
                canSeek: canSeek,
                usesCompactLayout: usesCompactLayout,
                seekBackward: { seekBackward(15) },
                seekForward: { seekForward(15) },
                togglePlayback: togglePlayback,
                showPanel: showPanel
            )
#endif
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onTapGesture(perform: togglePlayback)
        .platformMoveCommand { direction in
            if direction == .down {
                showPanel()
                return
            }
            guard canSeek else { return }
            switch direction {
            case .left: seekBackward(15)
            case .right: seekForward(15)
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

private struct ProgrammePlaybackTimeline: View {
    let channel: GuideChannel
    let fallbackProgram: GuideProgram?
    let pausedPlaybackDate: Date?
    let seekTargetDate: Date?
    let seekTargetsLiveEdge: Bool
    let liveDelaySeconds: TimeInterval
    let bufferStartedAt: Date?
    let canPause: Bool
    let canSeek: Bool
    let isPlaying: Bool
    let usesCompactLayout: Bool
    let usesCompactHeight: Bool
    let seekBackward: (TimeInterval) -> Void
    let seekForward: (TimeInterval) -> Void
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
        let playbackDate = seekTargetsLiveEdge
            ? liveDate
            : (seekTargetDate ?? pausedPlaybackDate
                ?? liveDate.addingTimeInterval(-liveDelaySeconds))
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
                TimelineBar(
                    program: program,
                    playbackDate: playbackDate,
                    availableStart: max(program.start, bufferStartedAt ?? liveDate),
                    availableEnd: min(program.end, liveDate),
                    isFocused: isFocused
                )

                Group {
                    if usesCompactLayout {
                        HStack(spacing: 10) {
                            Text("\(clock(program.start))–\(clock(program.end))")
                            Spacer(minLength: 8)
                            if canSeek, bufferStartedAt != nil {
                                Label("Timeshift", systemImage: "clock.arrow.circlepath")
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                    } else {
                        HStack {
                            Text("\(clock(program.start))–\(clock(program.end))")
                            Spacer()
                            if canSeek, let bufferStartedAt {
                                Label(
                                    "Timeshift from \(clock(bufferStartedAt))",
                                    systemImage: "clock.arrow.circlepath"
                                )
                                .foregroundStyle(AppTheme.accent)
                                Spacer()
                            }
                            if let next { Text("Next · \(clock(next.start))") }
                        }
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.76))

                if let seekTargetDate {
                    Label(
                        seekTargetsLiveEdge
                            ? "Go to live"
                            : seekDescription(target: seekTargetDate, liveEdge: liveDate),
                        systemImage: "scope"
                    )
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(AppTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                }
            } else {
                Capsule().fill(.white.opacity(0.25)).frame(height: 14)
            }

#if !os(tvOS)
            PlaybackTransportControls(
                isPlaying: isPlaying,
                canPause: canPause,
                canSeek: canSeek,
                usesCompactLayout: usesCompactLayout,
                seekBackward: { seekBackward(15) },
                seekForward: { seekForward(15) },
                togglePlayback: togglePlayback,
                showPanel: showPanel
            )
#endif
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onTapGesture {
            if canPause { togglePlayback() }
        }
        .platformMoveCommand { direction in
            if direction == .down {
                showPanel()
                return
            }
            guard canSeek else { return }
            switch direction {
            case .left: seekBackward(15)
            case .right: seekForward(15)
            default: break
            }
        }
        .accessibilityHint(
            canSeek
                ? "Timeshift is available from \(bufferStartedAt.map(clock) ?? "the start of playback"). Swipe left or right to move 15 seconds"
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
    let togglePlayback: () -> Void
    let showPanel: () -> Void

    var body: some View {
        HStack(spacing: usesCompactLayout ? 12 : 18) {
            Button(action: seekBackward) {
                Label("Back 15 Seconds", systemImage: "gobackward.15")
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
#if !os(macOS)
            .keyboardShortcut(.space, modifiers: [])
#endif

            Button(action: seekForward) {
                Label("Forward 15 Seconds", systemImage: "goforward.15")
                    .labelStyle(.iconOnly)
                    .frame(width: usesCompactLayout ? 36 : nil, height: usesCompactLayout ? 36 : nil)
            }
            .disabled(!canSeek)

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
        .frame(maxWidth: .infinity)
        .font(.title3)
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}
#endif

private struct TimelineBar: View {
    let program: GuideProgram
    let playbackDate: Date
    let availableStart: Date
    let availableEnd: Date
    let isFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(1, program.duration)
            let playhead = position(playbackDate, width: width, duration: duration)
            let availableX = position(availableStart, width: width, duration: duration)
            let availableRight = position(availableEnd, width: width, duration: duration)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.white.opacity(isFocused ? 0.24 : 0.16))
                    .frame(height: 16)

                RoundedRectangle(cornerRadius: 5)
                    .fill(AppTheme.accent.opacity(0.82))
                    .frame(width: max(0, availableRight - availableX), height: 16)
                    .offset(x: availableX)

                Rectangle()
                    .fill(.white)
                    .frame(width: 3, height: 31)
                    .offset(x: min(max(0, playhead - 1.5), width - 3))

                Text(clock(playbackDate))
                    .font(.callout.bold().monospacedDigit())
                    .foregroundStyle(.white)
                    .fixedSize()
                    .position(x: min(max(54, playhead), width - 54), y: 38)
            }
        }
        .frame(height: 52)
    }

    private func position(_ date: Date, width: CGFloat, duration: TimeInterval) -> CGFloat {
        min(max(0, CGFloat(date.timeIntervalSince(program.start) / duration) * width), width)
    }

    private func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

private struct PlayerTabbedOverlay: View {
    let presentation: PlaybackPresentation
    @ObservedObject var engine: VLCPlaybackEngine
    let profiles: [TVHeadendStreamProfile]
    @Binding var selectedTab: PlayerOverlayTab
    let usesCompactLayout: Bool
    let usesCompactHeight: Bool
    let selectProfile: (TVHeadendStreamProfile) -> Void
    let dismiss: () -> Void
    let noteActivity: () -> Void

    @FocusState private var tabBarFocused: Bool
    @FocusState private var focusedTechnicalDetailID: PlaybackTechnicalDetail.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: usesCompactHeight ? 10 : 22) {
            HStack(spacing: 12) {
                ForEach(PlayerOverlayTab.allCases) { tab in
                    Text(tab.rawValue)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: usesCompactLayout ? .infinity : nil)
                        .padding(.horizontal, usesCompactLayout ? 10 : 24)
                        .padding(.vertical, usesCompactLayout ? 10 : 12)
                        .background(
                            selectedTab == tab
                                ? AppTheme.focused
                                : Color.white.opacity(0.08),
                            in: Capsule()
                        )
                        .contentShape(Capsule())
                        .onTapGesture {
                            selectedTab = tab
                            noteActivity()
                        }
                        .accessibilityAddTraits(.isButton)
                }
            }
            .contentShape(Rectangle())
            .focusable()
            .focused($tabBarFocused)
            .focusEffectDisabled()
            .platformMoveCommand(moveTab)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(selectedTab.rawValue) tab")
            .accessibilityHint("Swipe left or right to change tabs")
            .padding(.leading, usesCompactHeight ? 56 : 0)

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
                minHeight: usesCompactHeight ? 190 : (usesCompactLayout ? 440 : 300),
                maxHeight: usesCompactHeight ? 240 : (usesCompactLayout ? 560 : 420),
                alignment: .topLeading
            )
        }
        .padding(.horizontal, usesCompactHeight ? 16 : (usesCompactLayout ? 20 : 48))
        .padding(.top, usesCompactHeight ? 8 : (usesCompactLayout ? 72 : 26))
        .padding(.bottom, usesCompactHeight ? 10 : (usesCompactLayout ? 24 : 34))
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.92))
        .onChange(of: focusedTechnicalDetailID) { _, detailID in
            guard detailID != nil else { return }
            noteActivity()
        }
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

    private var playbackDate: Date { engine.livePlaybackDate() }

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
            programmeOverview(program.overview)
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
                        minimum: usesCompactLayout ? 190 : 300,
                        maximum: usesCompactLayout ? 320 : 360
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
            HStack(alignment: .top, spacing: 34) {
                playbackSettingsLabel(title: title, systemImage: systemImage)
                    .frame(width: 260, alignment: .leading)
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
            height: usesCompactLayout ? 72 : 128,
            action: action
        )
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
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

private struct PlayerStepButton: View {
    let systemImage: String
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
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
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .accessibilityLabel(systemImage == "minus" ? "Decrease delay" : "Increase delay")
    }
}
