import SwiftUI

enum AppTab: Hashable {
    case channels
    case guide
    case recordings
    case settings
}

struct RootTabView: View {
    @State private var selection: AppTab = .guide
    @StateObject private var settings = ServerSettingsStore()
    @StateObject private var guide = GuideViewModel()
    @StateObject private var recordings = RecordingStore()
    @StateObject private var playback = PlaybackCoordinator()

    var body: some View {
        TabView(selection: $selection) {
            ChannelsView(onOpenSettings: { selection = .settings })
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
        .tint(AppTheme.accent)
        .environmentObject(settings)
        .environmentObject(guide)
        .environmentObject(recordings)
        .environmentObject(playback)
        .fullScreenCover(isPresented: $playback.isPlayerPresented) {
            if let presentation = playback.presentation {
                PlaybackView(engine: playback.engine, presentation: presentation)
                    .environmentObject(playback)
                    .environmentObject(settings)
            }
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
}
