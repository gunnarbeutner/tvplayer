import SwiftUI

@main
struct TVAppApp: App {
#if os(tvOS)
    @UIApplicationDelegateAdaptor(TVAppDelegate.self) private var appDelegate
#endif

    var body: some Scene {
#if os(macOS)
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--vlc-tuning-benchmark") {
                VLCTuningBenchmarkView()
                    .preferredColorScheme(.dark)
                    .frame(minWidth: 1_200, minHeight: 700)
            } else if ProcessInfo.processInfo.arguments.contains("--vlc-timeshift-benchmark") {
                VLCTimeshiftBenchmarkView()
                    .preferredColorScheme(.dark)
                    .frame(minWidth: 1_200, minHeight: 700)
            } else {
                RootTabView()
                    .preferredColorScheme(.dark)
                    .frame(minWidth: 900, minHeight: 620)
            }
        }
        .defaultSize(width: 1_280, height: 820)
        .commands {
            SidebarCommands()
        }
#else
        WindowGroup {
            RootTabView()
                .preferredColorScheme(.dark)
        }
#endif
    }
}
