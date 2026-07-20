import SwiftUI

@main
struct TVAppApp: App {
    var body: some Scene {
#if os(macOS)
        WindowGroup {
            RootTabView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 620)
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
