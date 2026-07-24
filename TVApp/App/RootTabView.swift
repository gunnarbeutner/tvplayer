import SwiftUI
#if os(tvOS)
import TVServices
#endif

private let initialGuideLogoPreloadLimit = 12

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

enum PlaybackExitCommandAction: Equatable {
    case passThrough
    case cancelLaunch
    case dismissTransition
    case delegateToPlayer
}

enum PlaybackExitCommandPolicy {
    static func action(
        isPlayerPresented: Bool,
        hasLaunchPresentation: Bool,
        hasPlayerHandler: Bool
    ) -> PlaybackExitCommandAction {
        guard isPlayerPresented else { return .passThrough }
        if hasLaunchPresentation { return .cancelLaunch }
        return hasPlayerHandler ? .delegateToPlayer : .dismissTransition
    }
}

#if os(tvOS)
private enum StartupRoutePhase: Equatable {
    case awaitingOpenURL
    case launchingPlayback
    case normal
}
#endif

private struct LiveChannelOrderSynchronization: ViewModifier {
    @ObservedObject var guide: GuideViewModel
    @ObservedObject var channelPreferences: ChannelPreferencesStore
    @ObservedObject var playback: PlaybackCoordinator
    @ObservedObject var settings: ServerSettingsStore

    func body(content: Content) -> some View {
        content
            .onChange(of: guide.guideRevision, initial: true) { _, _ in
                synchronize()
            }
            .onChange(of: channelPreferences.revision, initial: true) { _, _ in
                synchronize()
            }
            .onChange(of: playback.presentation?.id) { _, _ in
                synchronize()
            }
    }

    private func synchronize() {
        playback.updateLiveChannelOrder(
            channelPreferences.displayedChannels(from: guide.channels),
            configuration: settings.configuration
        )
    }
}

struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: AppTab
    @StateObject private var settings: ServerSettingsStore
    @StateObject private var guide: GuideViewModel
    @StateObject private var channelPreferences: ChannelPreferencesStore
    @StateObject private var recordings = RecordingStore()
    @StateObject private var playback: PlaybackCoordinator
    @State private var playbackAlertMessage: String?
    @State private var recordingAlertMessage: String?
    @State private var pendingRoute: AppRoute?
    @State private var guideDetailRequest: ProgrammeDetailPresentation?
    @State private var recordingDetailRequest: RecordingDetailRequest?
#if os(tvOS)
    @State private var startupRoutePhase: StartupRoutePhase
    @State private var startupPlaybackRoute: AppRoute?
    @State private var topShelfLaunchItem: TopShelfSnapshot.Item?
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
        let playback = PlaybackCoordinator()
        _playback = StateObject(wrappedValue: playback)
#if os(tvOS)
        _startupRoutePhase = State(initialValue: .awaitingOpenURL)
        _startupPlaybackRoute = State(initialValue: nil)
        _topShelfLaunchItem = State(initialValue: nil)
#endif
        _selection = State(
            initialValue: TVGuideAutomation.isEnabled
                ? .guide
                : Self.appTab(for: playback.initialStartupSection)
        )
        let settings = ServerSettingsStore()
        let configuration = settings.configuration
        let startupDate = Date()
        let cachedSnapshot = if let automationSnapshot =
            TVGuideAutomation.guideSnapshot(at: startupDate) {
            PersistedGuideSnapshot(
                serverIdentifier: configuration.guideSnapshotIdentifier,
                channelPreferencesIdentifier: configuration.channelPreferencesIdentifier,
                serverName: automationSnapshot.serverName,
                savedAt: startupDate,
                guideCoverageEnd: automationSnapshot.channels.lazy
                    .flatMap(\.programs)
                    .map(\.end)
                    .max(),
                channels: automationSnapshot.channels
            )
        } else if configuration.isComplete {
            GuideSnapshotStore.loadSynchronously(serverIdentifier: configuration.guideSnapshotIdentifier)
                ?? GuideSnapshotStore.loadSynchronously(
                    serverIdentifier: configuration.legacyGuideSnapshotIdentifier
                )
        } else {
            GuideSnapshotStore.loadLatestSynchronously()
        }

        _settings = StateObject(wrappedValue: settings)
        let channelPreferences: ChannelPreferencesStore
        if TVGuideAutomation.usesFixture,
           let automationDefaults = UserDefaults(
                suiteName: TVGuideAutomation.preferencesSuiteName
           ) {
            automationDefaults.removePersistentDomain(
                forName: TVGuideAutomation.preferencesSuiteName
            )
            channelPreferences = ChannelPreferencesStore(defaults: automationDefaults)
        } else {
            channelPreferences = ChannelPreferencesStore()
        }
        channelPreferences.activate(
            serverIdentifier: configuration.channelPreferencesIdentifier
                ?? cachedSnapshot?.startupChannelPreferencesIdentifier,
            migratingFrom: configuration.legacyChannelPreferencesIdentifier
        )
        if let cachedSnapshot {
            let favoriteChannels = cachedSnapshot.channels.filter {
                channelPreferences.isFavorite($0.id)
            }
            let otherChannels = cachedSnapshot.channels.filter {
                !channelPreferences.isFavorite($0.id)
            }
            let initialLogoURLs = (favoriteChannels + otherChannels)
                .prefix(initialGuideLogoPreloadLimit)
                .compactMap(\.iconURL)
            ChannelLogoImageCache.shared.warmMemoryFromDisk(for: initialLogoURLs)

            let startupTimeline = GuideTimeline.surrounding(startupDate)
            let initialPrograms = (favoriteChannels + otherChannels).first?.programs.filter {
                $0.end > startupTimeline.start && $0.start < startupTimeline.end
            } ?? []
            if let artworkURL = GuideFocusSelection
                .initialProgram(in: initialPrograms, at: startupDate)?
                .metadata.imageURL
                .flatMap(URL.init(string:)) {
                ChannelLogoImageCache.shared.warmMemoryFromDisk(
                    for: [artworkURL],
                    kind: .programmeArtwork
                )
            }
        }
        _channelPreferences = StateObject(wrappedValue: channelPreferences)
        _guide = StateObject(
            wrappedValue: GuideViewModel(
                configuration: configuration,
                cachedSnapshot: cachedSnapshot
            )
        )
    }

    private static func appTab(for section: AppStartupSection) -> AppTab {
        switch section {
        case .guide: .guide
        case .channels: .channels
        case .recordings: .recordings
        }
    }

    private static func startupSection(for tab: AppTab) -> AppStartupSection? {
        switch tab {
        case .guide: .guide
        case .channels: .channels
        case .recordings: .recordings
        case .settings: nil
        }
    }

    var body: some View {
        ZStack {
            // The commercial analyser follows the live edge independently of
            // the visible player. Keep a tiny native drawable mounted so VLC
            // can retain hardware decoding while snapshots are sampled.
            VLCVideoSurface(mediaPlayer: playback.commercialAnalyzer.mediaPlayer)
                .frame(width: 160, height: 90)
                .opacity(0.001)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(-2)

            // The player is a sibling layer rather than a full-screen cover,
            // so the tab content underneath stays mounted and focusable.
            // Disable it while the player is up; otherwise remote presses
            // keep driving the invisible guide instead of the player chrome.
            if mountsNavigation {
                navigableTabs
                    .disabled(playback.isPlayerPresented)
            } else {
                // SwiftUI delivers a cold-launch URL after constructing the
                // scene. Keep focusable navigation out of the hierarchy until
                // that delivery turn has completed, so Top Shelf cannot show
                // or move the guide before playback's launch surface appears.
                Color.black
                    .ignoresSafeArea()
            }

            // In compact portrait the persistent video occupies a 16:9 hero
            // rather than the full screen. Obscure the still-mounted guide
            // beneath it so the remainder of the player stays visually
            // isolated without placing an opaque layer over VLC's drawable.
            if playback.isPlayerPresented {
                Color.black
                    .ignoresSafeArea()
                    .zIndex(9)
            }

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
            if mountsNavigation {
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
            }

            if startupRoutePhase == .launchingPlayback,
               !playback.isPlayerPresented,
               playback.launchPresentation == nil,
               let topShelfLaunchItem {
                TopShelfStartupLaunchView(item: topShelfLaunchItem)
                    .zIndex(11.5)
            }
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(11)
            }

            if playback.isPlayerPresented, let launch = playback.launchPresentation {
                PlaybackLaunchView(
                    presentation: launch,
                    engine: playback.engine
                )
                    .environmentObject(playback)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        } else {
                            let message: String
                            if case let .failed(engineMessage) = playback.engine.state {
                                message = engineMessage
                            } else {
                                message = "No audio or video was received from this channel."
                                playback.engine.reportFailure(message)
                            }
                            playback.playbackDidFail(
                                presentationID: launch.id,
                                message: message
                            )
                        }
                    }
            }

#if DEBUG && os(tvOS)
            if TVPlaybackAutomation.isEnabled {
                TVPlaybackAutomationProbe(
                    playback: playback,
                    showsGuidePreview: showsGuideLivePreview
                )
                .zIndex(100)
            }
            if TVGuideAutomation.isEnabled {
                TVGuideAutomationProbe()
                    .zIndex(100)
            }
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .modifier(LiveChannelOrderSynchronization(
            guide: guide,
            channelPreferences: channelPreferences,
            playback: playback,
            settings: settings
        ))
        .onChange(of: playback.isPlayerPresented) { wasPresented, isPresented in
#if os(tvOS)
            if isPresented {
                // The cached Top Shelf bridge is only for route resolution.
                // Once PlaybackLaunchView takes over, discard it permanently
                // so it cannot reappear above video when that view clears.
                topShelfLaunchItem = nil
            }
            if isPresented, selection == .guide {
                // Keep the header and its focus bridge out of the focus race
                // when the player later reveals the guide. GuideView enables
                // them again only after a programme card actually has focus.
                navigationFocusRequest = nil
                allowsSectionNavigatorFocus = false
            }
#endif
            if wasPresented && !isPresented {
#if os(tvOS)
                finishStartupPlaybackRouting()
#endif
                playback.playerDidDismiss()
            }
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
            receive(route)
        }
#if os(tvOS)
        .onContinueUserActivity(TVUserActivityTypeBrowsingChannelGuide) { _ in
            receive(.guide)
        }
#endif
        .task(id: pendingRoute) {
            guard let route = pendingRoute else { return }
            await handle(route)
            if pendingRoute == route {
                pendingRoute = nil
#if os(tvOS)
                if startupPlaybackRoute == route, !playback.isPlayerPresented {
                    finishStartupPlaybackRouting()
                }
#endif
            }
        }
#if os(tvOS)
        .task {
            // onOpenURL arrives after SwiftUI has constructed the scene. Keep
            // navigation unmounted through the system's cold-launch delivery
            // window so a Top Shelf item cannot flash or focus the guide.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, startupRoutePhase == .awaitingOpenURL else { return }
            startupRoutePhase = .normal
        }
#endif
        .onAppear {
#if os(tvOS)
            TVRemoteCommandCenter.exitHandler = handlePlaybackExitCommand
            TVRemoteCommandCenter.pageHandler = handlePageCommand
            TVRemoteCommandCenter.playPauseHandler = handlePlayPauseCommand
#endif
            NowPlayingCoordinator.shared.connect(to: playback)
        }
        .onDisappear {
#if os(tvOS)
            TVRemoteCommandCenter.exitHandler = nil
            TVRemoteCommandCenter.pageHandler = nil
            TVRemoteCommandCenter.playPauseHandler = nil
#endif
            NowPlayingCoordinator.shared.disconnect()
        }
        .onChange(of: selection) { _, tab in
            if let startupSection = Self.startupSection(for: tab) {
                playback.recordVisitedSection(startupSection)
            }
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
                now: guide.now,
                guideCoverageEnd: guide.guideCoverageEnd
            )
        }
#endif
    }

    private var mountsNavigation: Bool {
#if os(tvOS)
        startupRoutePhase == .normal
#else
        true
#endif
    }

    @MainActor
    private func receive(_ route: AppRoute) {
#if os(tvOS)
        if startupRoutePhase == .launchingPlayback,
           startupPlaybackRoute == route {
            // UIKit launch options and SwiftUI onOpenURL may both report the
            // same cold-launch URL. It represents one playback intent.
            return
        }
        if route.opensPlayback {
            // Also cover a Top Shelf selection delivered after the initial
            // connection turn, or while a warm scene is showing navigation.
            startupRoutePhase = .launchingPlayback
            startupPlaybackRoute = route
            topShelfLaunchItem = Self.topShelfItem(for: route)
        } else if startupRoutePhase == .awaitingOpenURL {
            startupRoutePhase = .normal
        }
#endif
        pendingRoute = route
    }

#if os(tvOS)
    private static func topShelfItem(for route: AppRoute) -> TopShelfSnapshot.Item? {
        guard route.opensPlayback, let snapshot = TopShelfSnapshotStore.load() else { return nil }
        return (snapshot.onNow + snapshot.recordings).first { item in
            URL(string: item.routeURL).flatMap(AppRoute.init(url:)) == route
        }
    }

    @MainActor
    private func finishStartupPlaybackRouting() {
        guard startupRoutePhase == .launchingPlayback else { return }
        startupRoutePhase = .normal
        startupPlaybackRoute = nil
        topShelfLaunchItem = nil
    }
#endif

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

        case let .showChannelDetails(channelID, programID):
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
            let program = programID.flatMap { programID in
                channel.programs.first { $0.id == programID }
            } ?? channel.programs.first { $0.isAiring(at: guide.now) }
            selection = .guide
            guideDetailRequest = ProgrammeDetailPresentation(
                program: program,
                channel: channel
            )

        case let .showRecordingDetails(recordingID):
            var recording = recordings.recordings.first { $0.id == recordingID }
            if recording == nil {
                await recordings.load(configuration: settings.configuration, force: true)
                recording = recordings.recordings.first { $0.id == recordingID }
            }
            guard let recording else {
                recordingAlertMessage = "That recording is no longer available."
                selection = .recordings
                return
            }
            selection = .recordings
            recordingDetailRequest = RecordingDetailRequest(recording: recording)

        case let .playChannel(channelID, topShelfContext):
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
            let currentProgram = channel.programs.first { $0.isAiring(at: guide.now) }
            let program = topShelfContext.flatMap { context in
                channel.programs.first {
                    $0.id == context.programID && $0.isAiring(at: guide.now)
                }
            } ?? currentProgram
            hydrateTopShelfArtwork(for: program, context: topShelfContext)
            playback.start(
                channel: channel,
                program: program,
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

    private func hydrateTopShelfArtwork(
        for program: GuideProgram?,
        context: TopShelfLaunchContext?
    ) {
        guard let program,
              let context,
              program.id == context.programID,
              let filename = context.artworkFilename,
              let cachedURL = TopShelfSnapshotStore.cachedArtworkURL(for: filename),
              let artworkURL = program.metadata.imageURL.flatMap(URL.init(string:)),
              let data = try? Data(contentsOf: cachedURL)
        else { return }

        // Top Shelf has already persisted this image. Decode it before
        // presenting playback so the loading view can render it immediately.
        ChannelLogoImageCache.shared.store(
            data: data,
            for: artworkURL,
            kind: .programmeArtwork
        )
    }

#if os(tvOS)
    @MainActor
    private func handlePlaybackExitCommand() -> Bool {
        let action = PlaybackExitCommandPolicy.action(
            isPlayerPresented: playback.isPlayerPresented,
            hasLaunchPresentation: playback.launchPresentation != nil,
            hasPlayerHandler: TVRemoteCommandCenter.playerExitHandler != nil
        )
        switch action {
        case .passThrough:
            return false
        case .cancelLaunch:
            playback.leavePlayer()
            return true
        case .dismissTransition:
            playback.leavePlayer(
                retainingLivePlayback: supportsGuideLivePreviewOnDismissal
            )
            return true
        case .delegateToPlayer:
            guard let handler = TVRemoteCommandCenter.playerExitHandler else {
                playback.leavePlayer(
                    retainingLivePlayback: supportsGuideLivePreviewOnDismissal
                )
                return true
            }
            return handler()
        }
    }

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
                    detailRequest: $guideDetailRequest,
                    onPresentedChannelChange: { guideHeaderChannelID = $0 },
                    onInitialFocusResolved: { allowsSectionNavigatorFocus = true },
                    onExitToNavigator: { navigationFocusRequest = .guide }
                )
            }

            televisionSection(.recordings) {
                RecordingsView(
                    onOpenSettings: { selection = .settings },
                    focusRequest: recordingsFocusRequest,
                    detailRequest: $recordingDetailRequest
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
                onOpenSettings: { selection = .settings },
                detailRequest: $guideDetailRequest
            )
                .tabItem {
                    Label("Guide", systemImage: "rectangle.grid.2x2")
                }
                .tag(AppTab.guide)

            RecordingsView(
                onOpenSettings: { selection = .settings },
                detailRequest: $recordingDetailRequest
            )
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
                onOpenSettings: { selection = .settings },
                detailRequest: $guideDetailRequest
            )
        case .recordings:
            RecordingsView(
                onOpenSettings: { selection = .settings },
                detailRequest: $recordingDetailRequest
            )
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
private struct TopShelfStartupLaunchView: View {
    let item: TopShelfSnapshot.Item
    private let artwork: UIImage?

    init(item: TopShelfSnapshot.Item) {
        self.item = item
        artwork = item.artworkFilename
            .flatMap { TopShelfSnapshotStore.cachedArtworkURL(for: $0) }
            .flatMap { UIImage(contentsOfFile: $0.path) }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let artwork {
                GeometryReader { geometry in
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()

                    RadialGradient(
                        stops: [
                            .init(color: .clear, location: 0.56),
                            .init(color: .black.opacity(0.28), location: 1),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: max(geometry.size.width, geometry.size.height) * 0.72
                    )

                    LinearGradient(
                        colors: [.black.opacity(0.62), .clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                }
                .ignoresSafeArea()
            }

            Text(item.title)
                .font(.headline.bold())
                .lineLimit(2)
                .foregroundStyle(.white)
                .padding(48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityLabel("Opening \(item.title)")
    }
}

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
#if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var wasBackgrounded = false
#endif

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

    private var usesCompactPortraitPlayer: Bool {
#if os(iOS)
        isPresented
            && horizontalSizeClass == .compact
            && verticalSizeClass != .compact
#else
        false
#endif
    }

    var body: some View {
        GeometryReader { proxy in
            let presentedHeight = usesCompactPortraitPlayer
                ? proxy.size.width * 9 / 16
                : proxy.size.height

            Group {
#if os(tvOS)
                if engine.usesSampleBufferRendering {
                    VLCSampleBufferVideoSurface(
                        displayLayer: engine.sampleBufferBridge.displayLayer,
                        fadesLeadingEdge: showsGuidePreview,
                        leadingFadeInset: showsGuidePreview ? guideLeadingCrop : 0,
                        isOutputConcealed: isPresented && engine.isPlaybackOutputConcealed,
                        concealmentImage: isPresented ? engine.pausedFrame : nil
                    )
                } else {
                    VLCVideoSurface(
                        mediaPlayer: engine.mediaPlayer,
                        fadesLeadingEdge: showsGuidePreview,
                        leadingFadeInset: showsGuidePreview ? guideLeadingCrop : 0,
                        isOutputConcealed: isPresented && engine.isPlaybackOutputConcealed,
                        concealmentImage: isPresented ? engine.pausedFrame : nil
                    )
                }
#else
                VLCVideoSurface(
                    mediaPlayer: engine.mediaPlayer,
                    fadesLeadingEdge: showsGuidePreview,
                    leadingFadeInset: showsGuidePreview ? guideLeadingCrop : 0,
                    isOutputConcealed: isPresented && engine.isPlaybackOutputConcealed,
                    concealmentImage: isPresented ? engine.pausedFrame : nil
                )
#endif
            }
            .frame(
                width: isPresented ? proxy.size.width : guideVideoWidth,
                height: isPresented ? presentedHeight : guidePreviewHeight
            )
            // Broadcast video is normally 16:9 while the deliberately taller
            // guide artwork region is not. Render at the source aspect and
            // crop the leading side instead of asking VLC to letterbox it.
            .frame(
                width: isPresented ? proxy.size.width : GuideArtworkStyle.artworkWidth,
                height: isPresented ? presentedHeight : guidePreviewHeight,
                alignment: .trailing
            )
            .clipped()
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: usesCompactPortraitPlayer ? .center : .topTrailing
            )
        }
        .ignoresSafeArea(.container, edges: ignoredSafeAreaEdges)
        .opacity(isPresented || showsGuidePreview ? 1 : 0)
        .allowsHitTesting(false)
#if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasBackgrounded = true
            case .active:
                guard wasBackgrounded else { return }
                wasBackgrounded = false
                // iOS marks an interrupted sample-buffer renderer as requiring
                // a flush. Healthy renderers are left completely untouched.
                engine.recoverVideoOutputAfterForegrounding()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
#endif
    }
}
