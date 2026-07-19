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

struct PlaybackView: View {
    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @ObservedObject var engine: VLCPlaybackEngine

    @State private var chromeMode: PlayerChromeMode = .timeline
    @State private var selectedTab: PlayerOverlayTab = .details
    @State private var chromeActivity = UUID()
    @State private var automaticallyHiddenAt: Date?
    @State private var profiles: [TVHeadendStreamProfile] = []
    @State private var hasStartedCurrentPresentation = false
    @State private var isRefreshingGrowingRecording = false
    @FocusState private var wakeSurfaceFocused: Bool

    let presentation: PlaybackPresentation

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCVideoSurface(mediaPlayer: engine.mediaPlayer)
                .ignoresSafeArea()

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

            switch chromeMode {
            case .hidden:
                EmptyView()
            case .timeline:
                VStack {
                    Spacer()
                    if let recording = presentation.recording {
                        RecordingPlaybackTimeline(
                            recording: recording,
                            elapsedSeconds: engine.elapsedSeconds,
                            canSeek: engine.isSeekable,
                            seekBackward: { engine.skipBackward(by: $0); noteActivity() },
                            seekForward: { skipForward(by: $0) },
                            showPanel: showPanel
                        )
                    } else {
                        ProgrammePlaybackTimeline(
                            channel: presentation.channel,
                            fallbackProgram: presentation.program,
                            liveDelaySeconds: engine.liveDelaySeconds,
                            bufferStartedAt: engine.bufferStartedAt,
                            canSeek: engine.isSeekable,
                            seekBackward: { engine.skipBackward(by: $0); noteActivity() },
                            seekForward: { skipForward(by: $0) },
                            showPanel: showPanel
                        )
                    }
                }
                .transition(.opacity)
            case .panel:
                VStack {
                    PlayerTabbedOverlay(
                        presentation: presentation,
                        engine: engine,
                        profiles: profiles,
                        selectedTab: $selectedTab,
                        selectProfile: { profile in
                            Task { await switchProfile(to: profile) }
                        },
                        dismiss: { hideChrome(automatically: false) },
                        noteActivity: noteActivity
                    )
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if case let .failed(message) = engine.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(24)
                    .background(.red.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task(id: presentation.id) {
            hasStartedCurrentPresentation = false
            if engine.state == .idle {
                await startPlayback(with: presentation.request)
            } else if engine.state == .paused || engine.state == .preparing {
                engine.play()
            }
        }
        .task {
            guard !presentation.isRecording else { return }
            profiles = (try? await TVHeadendClient(configuration: settings.configuration).streamProfiles()) ?? []
        }
#if DEBUG
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
            hideChrome(automatically: true)
        }
        .onDisappear {
            if engine.state == .playing || engine.state == .preparing { engine.pause() }
        }
        .onPlayPauseCommand {
            engine.togglePlayPause()
            showTimeline()
        }
        .onMoveCommand { direction in
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
        .onExitCommand {
            if chromeMode != .hidden {
                hideChrome(automatically: false)
            } else if let automaticallyHiddenAt,
                      Date().timeIntervalSince(automaticallyHiddenAt) < 1.25 {
                // Avoid treating a Back press immediately after auto-hide as a
                // second action that leaves playback.
            } else {
                playback.leavePlayer()
            }
        }
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
            guard await engine.waitForPlaybackStart() else { return }
            showTimeline()
        } catch {
            engine.reportFailure(error.localizedDescription)
        }
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
            let url = try await TVHeadendClient(configuration: settings.configuration)
                .recordingStreamURL(recordingID: recording.id)
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
        automaticallyHiddenAt = nil
        withAnimation(.easeOut(duration: 0.18)) { chromeMode = .timeline }
        noteActivity()
    }

    private func showPanel() {
        wakeSurfaceFocused = false
        automaticallyHiddenAt = nil
        withAnimation(.easeOut(duration: 0.18)) { chromeMode = .panel }
        noteActivity()
    }

    private func hideChrome(automatically: Bool) {
        withAnimation(.easeOut(duration: 0.2)) { chromeMode = .hidden }
        automaticallyHiddenAt = automatically ? Date() : nil
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

    private func returnToLive() async {
        guard !presentation.isRecording else { return }
        do {
            let url = try await TVHeadendClient(configuration: settings.configuration)
                .canonicalLiveStreamURL(channelID: presentation.channel.id, profile: engine.activeProfile)
            await startPlayback(
                with: LiveStreamRequest(
                    url: url,
                    networkCachingMilliseconds: presentation.request.networkCachingMilliseconds,
                    profile: engine.activeProfile
                )
            )
        } catch {
            engine.reportFailure(error.localizedDescription)
        }
    }

    private func switchProfile(to profile: TVHeadendStreamProfile) async {
        guard !presentation.isRecording else { return }
        guard profile.name != engine.activeProfile else { return }
        do {
            let url = try await TVHeadendClient(configuration: settings.configuration)
                .canonicalLiveStreamURL(channelID: presentation.channel.id, profile: profile.name)
            await startPlayback(
                with: LiveStreamRequest(
                    url: url,
                    networkCachingMilliseconds: presentation.request.networkCachingMilliseconds,
                    profile: profile.name
                )
            )
            showPanel()
        } catch {
            engine.reportFailure(error.localizedDescription)
        }
    }
}

private struct RecordingPlaybackTimeline: View {
    let recording: TVRecording
    let elapsedSeconds: TimeInterval
    let canSeek: Bool
    let seekBackward: (TimeInterval) -> Void
    let seekForward: (TimeInterval) -> Void
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
        Button(action: {}) {
            VStack(spacing: 12) {
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

                HStack {
                    Text("\(clock(recording.start))–\(clock(recording.end))")
                    Spacer()
                    if recording.state == .recording {
                        Text("Recording · available through \(clock(recording.start.addingTimeInterval(availableDuration)))")
                            .foregroundStyle(.red)
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.76))
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
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
        .padding(.horizontal, 44)
        .padding(.top, 26)
        .padding(.bottom, 28)
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
    let liveDelaySeconds: TimeInterval
    let bufferStartedAt: Date?
    let canSeek: Bool
    let seekBackward: (TimeInterval) -> Void
    let seekForward: (TimeInterval) -> Void
    let showPanel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            timeline(at: context.date)
        }
        .padding(.horizontal, 44)
        .padding(.top, 26)
        .padding(.bottom, 28)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func timeline(at liveDate: Date) -> some View {
        let playbackDate = liveDate.addingTimeInterval(-liveDelaySeconds)
        let program = channel.programs.first { $0.start <= playbackDate && playbackDate < $0.end } ?? fallbackProgram
        let next = program.flatMap { current in
            channel.programs.first { $0.start >= current.end && $0.id != current.id }
        }

        return Button(action: {}) {
            VStack(spacing: 12) {
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

                if let program {
                    TimelineBar(
                        program: program,
                        playbackDate: playbackDate,
                        availableStart: max(program.start, bufferStartedAt ?? liveDate),
                        availableEnd: min(program.end, liveDate),
                        isFocused: isFocused
                    )

                    HStack {
                        Text("\(clock(program.start))–\(clock(program.end))")
                        Spacer()
                        if let next { Text("Next · \(clock(next.start))") }
                    }
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.76))
                } else {
                    Capsule().fill(.white.opacity(0.25)).frame(height: 14)
                }
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
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
        .accessibilityHint(canSeek ? "Swipe left or right to move 15 seconds" : "Live playback")
    }

    private func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

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
    let selectProfile: (TVHeadendStreamProfile) -> Void
    let dismiss: () -> Void
    let noteActivity: () -> Void

    @FocusState private var tabBarFocused: Bool
    @FocusState private var focusedTechnicalDetailID: PlaybackTechnicalDetail.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                ForEach(PlayerOverlayTab.allCases) { tab in
                    Text(tab.rawValue)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            selectedTab == tab
                                ? AppTheme.focused
                                : Color.white.opacity(0.08),
                            in: Capsule()
                        )
                }
            }
            .contentShape(Rectangle())
            .focusable()
            .focused($tabBarFocused)
            .focusEffectDisabled()
            .onMoveCommand(perform: moveTab)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("(selectedTab.rawValue) tab")
            .accessibilityHint("Swipe left or right to change tabs")

            Divider().overlay(.white.opacity(0.2))

            Group {
                switch selectedTab {
                case .details:
                    details
                case .playback:
                    playbackSettings
                case .technical:
                    technicalDetails
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 420, alignment: .topLeading)
        }
        .padding(.horizontal, 48)
        .padding(.top, 26)
        .padding(.bottom, 34)
        .background(.black.opacity(0.92))
        .onChange(of: focusedTechnicalDetailID) { _, detailID in
            guard detailID != nil else { return }
            noteActivity()
        }
    }

    private func moveTab(_ direction: MoveCommandDirection) {
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

    private var playbackDate: Date { Date().addingTimeInterval(-engine.liveDelaySeconds) }

    private var currentProgram: GuideProgram? {
        presentation.channel.programs.first {
            $0.start <= playbackDate && playbackDate < $0.end
        } ?? presentation.program
    }

    private var details: some View {
        HStack(alignment: .top, spacing: 42) {
            ChannelBadge(channel: presentation.channel, diameter: 112)

            VStack(alignment: .leading, spacing: 12) {
                Text(presentation.recording?.title ?? currentProgram?.title ?? presentation.channel.name)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                if let subtitle = presentation.recording?.subtitle ?? currentProgram?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                if let recording = presentation.recording {
                    Text("\(recording.start.formatted(date: .abbreviated, time: .shortened))–\(recording.end.formatted(date: .omitted, time: .shortened)) · \(recording.channelName)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(recording.overview)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(6)
                } else if let program = currentProgram {
                    Text("\(program.start.formatted(date: .abbreviated, time: .shortened))–\(program.end.formatted(date: .omitted, time: .shortened)) · \(presentation.channel.name)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(program.overview)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(6)
                }
            }
        }
    }

    private var playbackSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !presentation.isRecording {
                    settingSection("Quality") {
                        HStack(spacing: 14) {
                            ForEach(profiles) { profile in
                                choiceButton(
                                    title: profile.name == "pass" ? "Original" : profile.name,
                                    subtitle: profile.name == "pass" ? "Direct play" : "Transcode",
                                    selected: engine.activeProfile == profile.name
                                ) { selectProfile(profile) }
                            }
                            if profiles.isEmpty {
                                Text("\(engine.activeProfile) · Direct stream")
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                    }
                }

                settingSection("Audio stream") {
                    HStack(spacing: 14) {
                        ForEach(engine.audioTracks) { track in
                            choiceButton(
                                title: track.name,
                                subtitle: nil,
                                selected: engine.selectedAudioTrackID == track.id
                            ) { engine.selectAudioTrack(track.id); noteActivity() }
                        }
                        if engine.audioTracks.isEmpty { unavailable("No audio streams reported yet") }
                    }
                }

                settingSection("Subtitles") {
                    HStack(spacing: 14) {
                        ForEach(engine.subtitleTracks) { track in
                            choiceButton(
                                title: track.name,
                                subtitle: nil,
                                selected: engine.selectedSubtitleTrackID == track.id
                            ) { engine.selectSubtitleTrack(track.id); noteActivity() }
                        }
                        if engine.subtitleTracks.isEmpty { unavailable("No subtitle streams") }
                    }
                }

                HStack(spacing: 42) {
                    delayControl(
                        title: "Audio timing",
                        value: engine.audioDelayMilliseconds,
                        change: engine.adjustAudioDelay
                    )
                    delayControl(
                        title: "Subtitle timing",
                        value: engine.subtitleDelayMilliseconds,
                        change: engine.adjustSubtitleDelay
                    )
                }
            }
        }
    }

    private var technicalDetails: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
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

    private func settingSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.bold())
                .tracking(1.3)
                .foregroundStyle(AppTheme.secondaryText)
            content()
        }
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
            action: action
        )
    }

    private func unavailable(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.white.opacity(0.62))
            .padding(.vertical, 12)
    }

    private func delayControl(
        title: String,
        value: Int,
        change: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.caption.bold())
                .tracking(1.3)
                .foregroundStyle(AppTheme.secondaryText)
            HStack(spacing: 10) {
                Button { change(-50); noteActivity() } label: { Image(systemName: "minus") }
                Text(value == 0 ? "0 ms" : String(format: "%+d ms", value))
                    .font(.headline.monospacedDigit())
                    .frame(minWidth: 110)
                Button { change(50); noteActivity() } label: { Image(systemName: "plus") }
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct PlayerChoiceButton: View {
    let title: String
    let subtitle: String?
    let selected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.headline)
                if selected { Image(systemName: "checkmark") }
            }
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            selected || isFocused ? AppTheme.focused : Color.white.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}
