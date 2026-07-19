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
    @StateObject private var playback = PlaybackCoordinator()

    var body: some View {
        TabView(selection: $selection) {
            ChannelsView()
                .tabItem {
                    Label("Channels", systemImage: "play.rectangle.on.rectangle")
                }
                .tag(AppTab.channels)

            GuideView()
                .tabItem {
                    Label("Guide", systemImage: "rectangle.grid.2x2")
                }
                .tag(AppTab.guide)

            RecordingsView()
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
        .environmentObject(playback)
        .fullScreenCover(item: $playback.presentation) { presentation in
            PlaybackView(presentation: presentation)
                .environmentObject(playback)
                .environmentObject(settings)
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
        .task(id: settings.revision) {
            await guide.load(configuration: settings.configuration, force: true)

#if DEBUG
            if ProcessInfo.processInfo.environment["TVPLAYER_AUTOPLAY"] == "1",
               playback.presentation == nil,
               let channel = guide.channels.first {
                playback.start(
                    channel: channel,
                    program: channel.programs.first { $0.isAiring(at: guide.now) },
                    configuration: settings.configuration
                )
            }
#endif

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await guide.load(configuration: settings.configuration)
            }
        }
    }
}
