import SwiftUI

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
    @State private var selection: AppTab = .guide
    @StateObject private var settings: ServerSettingsStore
    @StateObject private var guide: GuideViewModel
    @StateObject private var channelPreferences: ChannelPreferencesStore
    @StateObject private var recordings = RecordingStore()
    @StateObject private var playback = PlaybackCoordinator()
    @State private var playbackAlertMessage: String?
    @State private var recordingAlertMessage: String?
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
        let cachedSnapshot = configuration.isComplete
            ? GuideSnapshotStore.loadSynchronously(serverIdentifier: configuration.guideSnapshotIdentifier)
            : GuideSnapshotStore.loadLatestSynchronously()

        _settings = StateObject(wrappedValue: settings)
        let channelPreferences = ChannelPreferencesStore()
        channelPreferences.activate(serverIdentifier: configuration.channelPreferencesIdentifier)
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
                isEnabled: allowsSectionNavigatorFocus && !playback.isPlayerPresented,
                onFocused: { navigationFocusRequest = selection }
            )
            .zIndex(3)
#endif

            if playback.isPlayerPresented, let presentation = playback.presentation {
                PlaybackView(
                    engine: playback.engine,
                    presentation: presentation,
                    showsVideoSurface: false
                )
                .environmentObject(playback)
                .environmentObject(settings)
                .zIndex(11)
            }
        }
        .tint(AppTheme.accent)
        .environmentObject(settings)
        .environmentObject(guide)
        .environmentObject(channelPreferences)
        .environmentObject(recordings)
        .environmentObject(playback)
        .onChange(of: playback.isPlayerPresented) { wasPresented, isPresented in
            if wasPresented && !isPresented { playback.playerDidDismiss() }
        }
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
        .onChange(of: selection) { _, tab in
            guard tab == .recordings else { return }
            Task { await recordings.load(configuration: settings.configuration, force: true) }
        }
        .task(id: settings.revision) {
            channelPreferences.activate(
                serverIdentifier: settings.configuration.channelPreferencesIdentifier
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
    }

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
                        for: GuideArtworkStyle.televisionWidth
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

    private var showsGuideLivePreview: Bool {
        guard selection == .guide,
              !playback.isPlayerPresented,
              playback.presentation?.isRecording == false,
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
    }

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
                .font(.headline.weight(.semibold))
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
    @State private var attachmentRevision = 0

    private let guidePreviewHeight: CGFloat = 424

    private var guideVideoWidth: CGFloat {
        guidePreviewHeight * 16 / 9
    }

    private var guideLeadingCrop: CGFloat {
        max(0, guideVideoWidth - GuideArtworkStyle.televisionWidth)
    }

    var body: some View {
        GeometryReader { proxy in
            VLCVideoSurface(
                mediaPlayer: engine.mediaPlayer,
                attachmentRevision: attachmentRevision,
                fadesLeadingEdge: showsGuidePreview,
                leadingFadeInset: showsGuidePreview ? guideLeadingCrop : 0
            )
            .frame(
                width: isPresented ? proxy.size.width : guideVideoWidth,
                height: isPresented ? proxy.size.height : guidePreviewHeight
            )
            // Broadcast video is normally 16:9 while the deliberately taller
            // guide artwork region is not. Render at the source aspect and
            // crop the leading side instead of asking VLC to letterbox it.
            .frame(
                width: isPresented ? proxy.size.width : GuideArtworkStyle.televisionWidth,
                height: isPresented ? proxy.size.height : guidePreviewHeight,
                alignment: .trailing
            )
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .ignoresSafeArea()
        .opacity(isPresented || showsGuidePreview ? 1 : 0)
        .allowsHitTesting(false)
        .onChange(of: isPresented) { _, presented in
            if presented { attachmentRevision &+= 1 }
        }
        .onChange(of: engine.state) { _, state in
            if isPresented && (state == .preparing || state == .playing) {
                attachmentRevision &+= 1
            }
        }
    }
}
