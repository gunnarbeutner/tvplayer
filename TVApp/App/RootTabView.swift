import SwiftUI
#if os(tvOS)
import TVServices
#endif

enum AppTab: Hashable, CaseIterable {
    case channels
    case guide
    case recordings
    case settings

    var title: String {
        switch self {
        case .channels: "Channels"
        case .guide: "Guide"
        case .recordings: "Recordings"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .channels: "play.rectangle.on.rectangle"
        case .guide: "rectangle.grid.2x2"
        case .recordings: "record.circle"
        case .settings: "gearshape"
        }
    }
}

struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab = .guide
    @StateObject private var settings: ServerSettingsStore
    @StateObject private var guide: GuideViewModel
    @StateObject private var channelPreferences: ChannelPreferencesStore
    @StateObject private var recordings = RecordingStore()
    @StateObject private var playback = PlaybackCoordinator()
    @State private var playbackAlertMessage: String?
    @State private var recordingAlertMessage: String?
    @State private var pendingRoute: AppRoute?
#if os(tvOS)
    @State private var navigationFocusRequest: AppTab?
    @State private var isSectionNavigatorFocused = false
    @State private var channelsFocusRequest: UUID?
    @State private var guideFocusRequest: UUID?
    @State private var recordingsFocusRequest: UUID?
    @State private var settingsFocusRequest: UUID?
    @State private var guideHeaderChannelID: GuideChannel.ID?
    @State private var allowsSectionNavigatorFocus = false
#endif

    init() {
        let settings = ServerSettingsStore()
        let configuration = settings.configuration
        let cachedSnapshot = if configuration.isComplete {
            GuideSnapshotStore.loadSynchronously(serverIdentifier: configuration.guideSnapshotIdentifier)
                ?? GuideSnapshotStore.loadSynchronously(
                    serverIdentifier: configuration.legacyGuideSnapshotIdentifier
                )
        } else {
            GuideSnapshotStore.loadLatestSynchronously()
        }

        _settings = StateObject(wrappedValue: settings)
        let channelPreferences = ChannelPreferencesStore()
        channelPreferences.activate(
            serverIdentifier: configuration.channelPreferencesIdentifier,
            migratingFrom: configuration.legacyChannelPreferencesIdentifier
        )
        _channelPreferences = StateObject(wrappedValue: channelPreferences)
        _guide = StateObject(
            wrappedValue: GuideViewModel(
                configuration: configuration,
                cachedSnapshot: cachedSnapshot
            )
        )
    }

    var body: some View {
        ZStack {
            // The player is a sibling layer rather than a full-screen cover,
            // so the tab content underneath stays mounted and focusable.
            // Disable it while the player is up; otherwise remote presses
            // keep driving the invisible guide instead of the player chrome.
            navigableTabs
                .disabled(playback.isPlayerPresented)

            // Keep VLC's drawable mounted while the guide is visible. A new
            // UIView on each full-screen presentation can leave VLC's audio
            // output running while its video output remains bound to the
            // dismissed surface.
            PersistentPlaybackSurface(
                engine: playback.engine,
                isPresented: playback.isPlayerPresented,
                showsGuidePreview: showsGuideLivePreview
            )
                .zIndex(
                    playback.isPlayerPresented
                        ? 10
                        : showsGuideLivePreview ? 1 : -1
                )

#if os(tvOS)
            // Keep the controls above the embedded video without placing the
            // whole guide above it. The guide header can then act as a window
            // onto the persistent VLC surface while the tabs and cog remain
            // crisp, visible, and focusable.
            sectionNavigator
                .disabled(playback.isPlayerPresented)
                .opacity(playback.isPlayerPresented ? 0 : 1)
                .zIndex(2)

            SectionFocusBridge(
                isEnabled: allowsSectionNavigatorFocus
                    && !isSectionNavigatorFocused
                    && !playback.isPlayerPresented,
                onFocused: { navigationFocusRequest = selection }
            )
            .zIndex(3)
#endif

            if playback.isPlayerPresented,
               let presentation = playback.presentation,
               playback.launchPresentation == nil
                    || playback.launchPresentation?.id == presentation.id {
                PlaybackView(
                    engine: playback.engine,
                    presentation: presentation,
                    showsVideoSurface: false,
                    retainsLivePlaybackOnDismiss: supportsGuideLivePreviewOnDismissal
                )
                .environmentObject(playback)
                .environmentObject(settings)
                .zIndex(11)
            }

            if playback.isPlayerPresented, let launch = playback.launchPresentation {
                PlaybackLaunchView(presentation: launch)
                    .environmentObject(playback)
                    .transition(.opacity)
                    .zIndex(12)
                    .task(id: launch.id) {
                        while !Task.isCancelled, playback.presentation?.id != launch.id {
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                        guard !Task.isCancelled else { return }
                        let hasOutput = await playback.engine.waitForInitialPlaybackOutput()
                        guard !Task.isCancelled else { return }
                        if hasOutput {
                            playback.playbackDidStart(presentationID: launch.id)
                        } else if case .failed = playback.engine.state {
                            playback.playbackDidFail(presentationID: launch.id)
                        } else {
                            // Do not leave an audio-only or malformed stream
                            // trapped behind the launch surface indefinitely.
                            playback.playbackDidStart(presentationID: launch.id)
                        }
                    }
            }
        }
        .animation(.easeOut(duration: 0.18), value: playback.launchPresentation?.id)
        .tint(AppTheme.accent)
#if os(macOS)
        .toolbarVisibility(
            playback.isPlayerPresented ? .hidden : .visible,
            for: .windowToolbar
        )
#endif
        .environmentObject(settings)
        .environmentObject(guide)
        .environmentObject(channelPreferences)
        .environmentObject(recordings)
        .environmentObject(playback)
        .onChange(of: playback.isPlayerPresented) { wasPresented, isPresented in
#if os(tvOS)
            if isPresented, selection == .guide {
                // Keep the header and its focus bridge out of the focus race
                // when the player later reveals the guide. GuideView enables
                // them again only after a programme card actually has focus.
                navigationFocusRequest = nil
                allowsSectionNavigatorFocus = false
            }
#endif
            if wasPresented && !isPresented { playback.playerDidDismiss() }
        }
#if os(tvOS)
        .onChange(of: scenePhase) { _, phase in
            guard !playback.pictureInPicture.isActive else { return }
            switch phase {
            case .background:
                playback.suspendForBackground()
            case .active:
                playback.resumeAfterBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
#endif
        .alert(
            "Playback unavailable",
            isPresented: Binding(
                get: { playbackAlertMessage != nil },
                set: { if !$0 { playbackAlertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playbackAlertMessage ?? "Unknown playback error")
        }
        .alert(
            "Recording unavailable",
            isPresented: Binding(
                get: { recordingAlertMessage != nil },
                set: { if !$0 { recordingAlertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recordingAlertMessage ?? "Unknown recording error")
        }
        .onChange(of: playback.errorMessage) { _, message in
            playbackAlertMessage = message
        }
        .onChange(of: playbackAlertMessage) { _, message in
            guard message == nil, playback.errorMessage != nil else { return }
            playback.errorMessage = nil
        }
        .onChange(of: recordings.errorMessage) { _, message in
            recordingAlertMessage = message
        }
        .onChange(of: recordingAlertMessage) { _, message in
            guard message == nil, recordings.errorMessage != nil else { return }
            recordings.errorMessage = nil
        }
        .onOpenURL { url in
            guard let route = AppRoute(url: url) else { return }
            pendingRoute = route
        }
#if os(tvOS)
        .onContinueUserActivity(TVUserActivityTypeBrowsingChannelGuide) { _ in
            pendingRoute = .guide
        }
#endif
        .task(id: pendingRoute) {
            guard let route = pendingRoute else { return }
            await handle(route)
            if pendingRoute == route { pendingRoute = nil }
        }
        .onAppear {
#if os(tvOS)
            TVRemoteCommandCenter.pageHandler = handlePageCommand
            TVRemoteCommandCenter.playPauseHandler = handlePlayPauseCommand
#endif
            NowPlayingCoordinator.shared.connect(to: playback)
        }
        .onDisappear {
#if os(tvOS)
            TVRemoteCommandCenter.pageHandler = nil
            TVRemoteCommandCenter.playPauseHandler = nil
#endif
            NowPlayingCoordinator.shared.disconnect()
        }
        .onChange(of: selection) { _, tab in
            guard tab == .recordings else { return }
            Task { await recordings.load(configuration: settings.configuration, force: true) }
        }
        .task(id: settings.revision) {
            channelPreferences.activate(
                serverIdentifier: settings.configuration.channelPreferencesIdentifier,
                migratingFrom: settings.configuration.legacyChannelPreferencesIdentifier
            )
            async let guideLoad: Void = guide.load(configuration: settings.configuration, force: true)
            async let recordingLoad: Void = recordings.load(configuration: settings.configuration, force: true)
            _ = await (guideLoad, recordingLoad)
#if DEBUG
            if ProcessInfo.processInfo.environment["TVPLAYER_AUTOPLAY"] == "1",
               !playback.isPlayerPresented,
               let channel = guide.channels.first {
                playback.start(
                    channel: channel,
                    program: channel.programs.first { $0.isAiring(at: guide.now) },
                    configuration: settings.configuration
                )
            }
#endif

            while !Task.isCancelled {
                try? await Task.sleep(for: recordings.recommendedRefreshInterval)
                guard !Task.isCancelled else { return }
                async let refreshedGuide: Void = guide.load(configuration: settings.configuration)
                async let refreshedRecordings: Void = recordings.load(configuration: settings.configuration)
                _ = await (refreshedGuide, refreshedRecordings)
            }
        }
#if os(tvOS)
        .task(id: topShelfRevision) {
            // Coalesce guide, recording, and favourite updates that commonly
            // arrive together during launch.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await TopShelfSnapshotPublisher.shared.publish(
                channels: channelPreferences.displayedChannels(from: guide.channels),
                favoriteChannelIDs: channelPreferences.favoriteChannelIDs,
                recordings: recordings.recordings,
                configuration: settings.configuration,
                now: guide.now
            )
        }
#endif
    }

#if os(tvOS)
    private var topShelfRevision: TopShelfPublishRevision {
        TopShelfPublishRevision(
            guide: guide.guideRevision,
            recordings: recordings.guideRevision,
            favorites: channelPreferences.revision,
            settings: settings.revision
        )
    }
#endif

    @MainActor
    private func handle(_ route: AppRoute) async {
        switch route {
        case .guide:
            if playback.isPlayerPresented {
                playback.leavePlayer(
                    retainingLivePlayback: platformSupportsGuideLivePreview
                )
            }
            selection = .guide
#if os(tvOS)
            guideFocusRequest = UUID()
#endif

        case let .playChannel(channelID):
            var channel = guide.channels.first { $0.id == channelID }
            if channel == nil {
                await guide.load(configuration: settings.configuration, force: true)
                channel = guide.channels.first { $0.id == channelID }
            }
            guard let channel else {
                playbackAlertMessage = "That channel is no longer available."
                selection = .guide
                return
            }
            playback.start(
                channel: channel,
                program: channel.programs.first { $0.isAiring(at: guide.now) },
                configuration: settings.configuration
            )

        case let .playRecording(recordingID):
            var recording = recordings.recordings.first { $0.id == recordingID && $0.isPlayable }
            if recording == nil {
                await recordings.load(configuration: settings.configuration, force: true)
                recording = recordings.recordings.first { $0.id == recordingID && $0.isPlayable }
            }
            guard let recording else {
                playbackAlertMessage = "That recording is no longer available."
                selection = .recordings
                return
            }
            playback.start(
                recording: recording,
                channel: recording.channelID.flatMap { channelID in
                    guide.channels.first { $0.id == channelID }
                },
                configuration: settings.configuration
            )
        }
    }

#if os(tvOS)
    @MainActor
    private func handlePageCommand(_ direction: TVPageDirection) -> Bool {
        if playback.isPlayerPresented {
            return playback.switchLiveChannel(
                direction: direction,
                channels: channelPreferences.displayedChannels(from: guide.channels),
                at: guide.now,
                configuration: settings.configuration
            )
        }

        let name: Notification.Name
        switch selection {
        case .guide: name = .tvGuidePageCommand
        case .channels: name = .tvChannelsPageCommand
        case .recordings: name = .tvRecordingsPageCommand
        case .settings: return false
        }
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: ["direction": direction.rawValue]
        )
        return true
    }

    @MainActor
    private func handlePlayPauseCommand() -> Bool {
        guard selection == .guide,
              !playback.isPlayerPresented,
              !playback.pictureInPicture.isActive,
              let guideHeaderChannelID,
              let channel = guide.channels.first(where: { $0.id == guideHeaderChannelID })
        else { return false }

        playback.start(
            channel: channel,
            program: channel.programs.first { $0.isAiring(at: guide.now) },
            configuration: settings.configuration
        )
        return true
    }

#endif

    @ViewBuilder
    private var navigableTabs: some View {
#if os(tvOS)
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 84)

            tabs
                .onExitCommand(perform: exitToSectionNavigator)
        }
        .background(alignment: .top) {
            GuideAmbientBackground(
                tint: guideHeaderTint,
                trailingClearWidth: guideHeaderTint == nil
                    ? 0
                    : GuideArtworkStyle.backgroundClearWidth(
                        for: GuideArtworkStyle.artworkWidth
                    )
            )
            .frame(width: GuideArtworkStyle.televisionCanvasWidth, height: 84)
        }
        .ignoresSafeArea(.container, edges: .top)
#else
        tabs
#endif
    }

#if os(tvOS)
    private var sectionNavigator: some View {
        TVSectionNavigator(
            selection: $selection,
            focusRequest: $navigationFocusRequest,
            allowsFocus: allowsSectionNavigatorFocus,
            onFocusChanged: { isSectionNavigatorFocused = $0 },
            onEnterContent: { tab in
                switch tab {
                case .channels:
                    channelsFocusRequest = UUID()
                case .guide:
                    guideFocusRequest = UUID()
                case .recordings:
                    recordingsFocusRequest = UUID()
                case .settings:
                    settingsFocusRequest = UUID()
                }
            }
        )
        .frame(height: 84)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
    }
#endif

    private var showsGuideLivePreview: Bool {
#if os(iOS)
        false
#else
        guard selection == .guide,
              !playback.isPlayerPresented,
              playback.isUserInitiatedLivePlayback,
              playback.engine.state != .paused
        else { return false }

        if playback.engine.mediaPlayer.isPlaying || playback.engine.mediaPlayer.hasVideoOut {
            return true
        }
        switch playback.engine.state {
        case .preparing, .playing, .recovering:
            return true
        case .idle, .paused, .failed:
            return false
        }
#endif
    }

    private var supportsGuideLivePreviewOnDismissal: Bool {
        platformSupportsGuideLivePreview && selection == .guide
    }

    private var platformSupportsGuideLivePreview: Bool {
#if os(iOS)
        false
#else
        true
#endif
    }

#if os(tvOS)
    private var exitToSectionNavigator: (() -> Void)? {
        guard !isSectionNavigatorFocused, !playback.isPlayerPresented else { return nil }
        return { navigationFocusRequest = selection }
    }
#endif

    @ViewBuilder
    private var tabs: some View {
#if os(macOS)
        NavigationSplitView {
            List(selection: $selection) {
                Label("Channels", systemImage: "play.rectangle.on.rectangle")
                    .tag(AppTab.channels)
                Label("Guide", systemImage: "rectangle.grid.2x2")
                    .tag(AppTab.guide)
                Label("Recordings", systemImage: "record.circle")
                    .tag(AppTab.recordings)
                Label("Settings", systemImage: "gearshape")
                    .tag(AppTab.settings)
            }
            .navigationTitle("TV Player")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            selectedContent
        }
#elseif os(tvOS)
        ZStack {
            televisionSection(.channels) {
                ChannelsView(
                    isSelected: selection == .channels,
                    onOpenSettings: { selection = .settings },
                    focusRequest: channelsFocusRequest
                )
            }

            televisionSection(.guide) {
                GuideView(
                    isSelected: selection == .guide,
                    onOpenSettings: { selection = .settings },
                    focusRequest: guideFocusRequest,
                    onPresentedChannelChange: { guideHeaderChannelID = $0 },
                    onInitialFocusResolved: { allowsSectionNavigatorFocus = true },
                    onExitToNavigator: { navigationFocusRequest = .guide }
                )
            }

            televisionSection(.recordings) {
                RecordingsView(
                    onOpenSettings: { selection = .settings },
                    focusRequest: recordingsFocusRequest
                )
            }

            televisionSection(.settings) {
                SettingsView(focusRequest: settingsFocusRequest)
            }
        }
#else
        TabView(selection: $selection) {
            ChannelsView(
                isSelected: selection == .channels,
                onOpenSettings: { selection = .settings }
            )
                .tabItem {
                    Label("Channels", systemImage: "play.rectangle.on.rectangle")
                }
                .tag(AppTab.channels)

            GuideView(
                isSelected: selection == .guide,
                onOpenSettings: { selection = .settings }
            )
                .tabItem {
                    Label("Guide", systemImage: "rectangle.grid.2x2")
                }
                .tag(AppTab.guide)

            RecordingsView(onOpenSettings: { selection = .settings })
                .tabItem {
                    Label("Recordings", systemImage: "record.circle")
                }
                .tag(AppTab.recordings)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppTab.settings)
        }
        .tabViewStyle(.sidebarAdaptable)
#endif
    }

#if os(tvOS)
    private var guideHeaderTint: Color? {
        guard selection == .guide, let guideHeaderChannelID else { return nil }
        return guide.channels.first { $0.id == guideHeaderChannelID }?.tint
    }

    private func televisionSection<Content: View>(
        _ tab: AppTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .opacity(selection == tab ? 1 : 0)
            .allowsHitTesting(selection == tab)
            .disabled(selection != tab)
            .accessibilityHidden(selection != tab)
            .zIndex(selection == tab ? 1 : 0)
    }
#endif

#if os(macOS)
    @ViewBuilder
    private var selectedContent: some View {
        switch selection {
        case .channels:
            ChannelsView(
                isSelected: true,
                onOpenSettings: { selection = .settings }
            )
        case .guide:
            GuideView(
                isSelected: true,
                onOpenSettings: { selection = .settings }
            )
        case .recordings:
            RecordingsView(onOpenSettings: { selection = .settings })
        case .settings:
            SettingsView()
        }
    }
#endif
}

#if os(tvOS)
private struct TopShelfPublishRevision: Hashable {
    let guide: Int
    let recordings: Int
    let favorites: Int
    let settings: Int
}
#endif

#if os(tvOS)
private struct SectionFocusBridge: View {
    let isEnabled: Bool
    let onFocused: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Color.clear
            .frame(height: 12)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .focusable(isEnabled)
            .focusEffectDisabled()
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                guard focused else { return }
                onFocused()
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .offset(y: 84)
            .ignoresSafeArea(.container, edges: [.top, .horizontal])
            .accessibilityHidden(true)
    }
}

private struct TVSectionNavigator: View {
    @Binding var selection: AppTab
    @Binding var focusRequest: AppTab?
    let allowsFocus: Bool
    let onFocusChanged: (Bool) -> Void
    let onEnterContent: (AppTab) -> Void

    @FocusState private var focusedTab: AppTab?
    @State private var isFocusInsideNavigator = false

    private let primaryTabs: [AppTab] = [.channels, .guide, .recordings]

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(primaryTabs, id: \.self) { tab in
                    primaryButton(for: tab)
                }
            }

            Spacer(minLength: 80)

            settingsButton
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .horizontal)
        .onChange(of: focusedTab) { previousTab, tab in
            onFocusChanged(tab != nil)
            guard let tab else {
                isFocusInsideNavigator = false
                return
            }

            // When focus arrives from the content below, geometry may point
            // at a neighbouring tab. Always enter the header on the selected
            // section; left and right remain available once focus is here.
            if previousTab == nil {
                isFocusInsideNavigator = true
                if tab != selection {
                    focusedTab = selection
                    return
                }
            }
            if selection != tab {
                selection = tab
                NavigationSoundPlayer.shared.play()
            }
        }
        .onChange(of: focusRequest) { _, requestedTab in
            guard let requestedTab else { return }
            focusedTab = requestedTab
            focusRequest = nil
        }
        .onMoveCommand { direction in
            guard direction == .down else { return }
            enterContent(from: selection)
        }
    }

    private func enterContent(from tab: AppTab) {
        onEnterContent(tab)
    }

    private func primaryButton(for tab: AppTab) -> some View {
        let isFocused = displayedFocusedTab == tab
        let isSelected = selection == tab

        return HStack(spacing: 10) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 21, weight: .semibold))
            Text(tab.title)
                .font(.system(size: 34, weight: .semibold))
                .tracking(0.2)
                .lineLimit(1)
        }
        .foregroundStyle(
            isFocused || isSelected
                ? (isSelected && !isFocused ? AppTheme.accent : Color.white)
                : Color.white.opacity(0.58)
        )
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(
            isFocused ? AppTheme.focused.opacity(0.9) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isSelected ? AppTheme.accent : Color.clear)
                .frame(height: 4)
                .padding(.horizontal, 12)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? AppTheme.focusBorder : Color.clear, lineWidth: 3)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .focusable(allowsFocus)
        .focusEffectDisabled()
        .focused($focusedTab, equals: tab)
        .onTapGesture { enterContent(from: tab) }
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .accessibilityLabel(tab.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Focus to open \(tab.title)")
        .accessibilityAddTraits(.isButton)
    }

    private var settingsButton: some View {
        let isFocused = displayedFocusedTab == .settings
        let isSelected = selection == .settings

        return Image(systemName: AppTab.settings.systemImage)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(
                isFocused
                    ? Color.white
                    : isSelected ? AppTheme.accent : Color.white.opacity(0.42)
            )
            .frame(width: 54, height: 52)
            .background(
                isFocused ? AppTheme.focused.opacity(0.9) : Color.clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isFocused ? AppTheme.focusBorder : Color.clear, lineWidth: 3)
            }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .focusable(allowsFocus)
        .focusEffectDisabled()
        .focused($focusedTab, equals: .settings)
        .onTapGesture { enterContent(from: .settings) }
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .accessibilityLabel(AppTab.settings.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Focus to open Settings")
        .accessibilityAddTraits(.isButton)
    }

    private var displayedFocusedTab: AppTab? {
        guard focusedTab != nil else { return nil }
        return isFocusInsideNavigator ? focusedTab : selection
    }
}
#endif

private struct PersistentPlaybackSurface: View {
    @ObservedObject var engine: VLCPlaybackEngine
    let isPresented: Bool
    let showsGuidePreview: Bool

    private var guidePreviewHeight: CGFloat {
        GuideArtworkStyle.previewHeight
    }

    private var guideVideoWidth: CGFloat {
        guidePreviewHeight * 16 / 9
    }

    private var guideLeadingCrop: CGFloat {
        max(0, guideVideoWidth - GuideArtworkStyle.artworkWidth)
    }

    private var ignoredSafeAreaEdges: Edge.Set {
#if os(macOS)
        isPresented ? .all : []
#else
        .all
#endif
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
#if os(tvOS)
                if engine.usesSampleBufferRendering {
                    VLCSampleBufferVideoSurface(
                        displayLayer: engine.sampleBufferBridge.displayLayer,
                        fadesLeadingEdge: showsGuidePreview,
                        leadingFadeInset: showsGuidePreview ? guideLeadingCrop : 0
                    )
                } else {
                    VLCVideoSurface(
                        mediaPlayer: engine.mediaPlayer,
                        fadesLeadingEdge: showsGuidePreview,
                        leadingFadeInset: showsGuidePreview ? guideLeadingCrop : 0
                    )
                }
#else
                VLCVideoSurface(
                    mediaPlayer: engine.mediaPlayer,
                    fadesLeadingEdge: showsGuidePreview,
                    leadingFadeInset: showsGuidePreview ? guideLeadingCrop : 0
                )
#endif
            }
            .frame(
                width: isPresented ? proxy.size.width : guideVideoWidth,
                height: isPresented ? proxy.size.height : guidePreviewHeight
            )
            // Broadcast video is normally 16:9 while the deliberately taller
            // guide artwork region is not. Render at the source aspect and
            // crop the leading side instead of asking VLC to letterbox it.
            .frame(
                width: isPresented ? proxy.size.width : GuideArtworkStyle.artworkWidth,
                height: isPresented ? proxy.size.height : guidePreviewHeight,
                alignment: .trailing
            )
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .ignoresSafeArea(.container, edges: ignoredSafeAreaEdges)
        .opacity(isPresented || showsGuidePreview ? 1 : 0)
        .allowsHitTesting(false)
    }
}
