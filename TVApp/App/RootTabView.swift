import SwiftUI

enum AppTab: Hashable {
    case channels
    case guide
    case recordings
    case settings
}

struct RootTabView: View {
    @State private var selection: AppTab = .guide
    @StateObject private var settings: ServerSettingsStore
    @StateObject private var guide: GuideViewModel
    @StateObject private var recordings = RecordingStore()
    @StateObject private var playback = PlaybackCoordinator()

    init() {
        let settings = ServerSettingsStore()
        let configuration = settings.configuration
        let cachedSnapshot = configuration.isComplete
            ? GuideSnapshotStore.loadSynchronously(serverIdentifier: configuration.guideSnapshotIdentifier)
            : GuideSnapshotStore.loadLatestSynchronously()

        _settings = StateObject(wrappedValue: settings)
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
            tabs
                .disabled(playback.isPlayerPresented)

            // Keep VLC's drawable mounted while the guide is visible. A new
            // UIView on each full-screen presentation can leave VLC's audio
            // output running while its video output remains bound to the
            // dismissed surface.
            PersistentPlaybackSurface(
                engine: playback.engine,
                isPresented: playback.isPlayerPresented
            )
                .zIndex(playback.isPlayerPresented ? 10 : -1)

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
        .environmentObject(recordings)
        .environmentObject(playback)
        .onChange(of: playback.isPlayerPresented) { wasPresented, isPresented in
            if wasPresented && !isPresented { playback.playerDidDismiss() }
        }
        .alert(
            "Playback unavailable",
            isPresented: Binding(
                get: { playback.errorMessage != nil },
                set: { if !$0 { playback.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { playback.errorMessage = nil }
        } message: {
            Text(playback.errorMessage ?? "Unknown playback error")
        }
        .alert(
            "Recording unavailable",
            isPresented: Binding(
                get: { recordings.errorMessage != nil },
                set: { if !$0 { recordings.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { recordings.errorMessage = nil }
        } message: {
            Text(recordings.errorMessage ?? "Unknown recording error")
        }
        .onChange(of: selection) { _, tab in
            guard tab == .recordings else { return }
            Task { await recordings.load(configuration: settings.configuration, force: true) }
        }
        .task(id: settings.revision) {
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

    private var tabs: some View {
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
    }
}

private struct PersistentPlaybackSurface: View {
    @ObservedObject var engine: VLCPlaybackEngine
    let isPresented: Bool
    @State private var attachmentRevision = 0

    var body: some View {
        VLCVideoSurface(
            mediaPlayer: engine.mediaPlayer,
            attachmentRevision: attachmentRevision
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: isPresented) { _, presented in
            if presented { attachmentRevision &+= 1 }
        }
        .onChange(of: engine.state) { _, state in
            if state == .preparing || state == .playing {
                attachmentRevision &+= 1
            }
        }
    }
}
