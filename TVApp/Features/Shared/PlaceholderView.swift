import SwiftUI

struct PlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        title: String,
        systemImage: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: systemImage)
                    .font(.system(size: 72, weight: .medium))
                    .foregroundStyle(AppTheme.accent)

                Text(title)
                    .font(.largeTitle.bold())

                Text(message)
                    .font(.title3)
                    .foregroundStyle(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680)

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.focused)
                }
            }
        }
    }
}

struct TVSourceStateView: View {
    let state: GuideLoadState
    let openSettings: () -> Void
    let retry: () -> Void

    private var content: (title: String, image: String, message: String) {
        switch state {
        case .needsConfiguration:
            return (
                "Connect to TVHeadend",
                "server.rack",
                "Enter your TVHeadend server address and credentials in Settings to load channels and guide data."
            )
        case .loading:
            return ("Loading TVHeadend", "arrow.triangle.2.circlepath", "Fetching channels and guide data…")
        case let .failed(message):
            return ("TVHeadend unavailable", "exclamationmark.triangle", message)
        case .loaded:
            return ("No channels", "tv.slash", "TVHeadend did not return any channels.")
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            if state == .loading {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: content.image)
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(state.isFailure ? Color.orange : AppTheme.accent)
            }

            Text(content.title)
                .font(.largeTitle.bold())

            Text(content.message)
                .font(.title3)
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)

            if state != .loading {
                HStack(spacing: 18) {
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.focused)

                    if state.isFailure {
                        Button("Try Again", action: retry)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
    }
}

private extension GuideLoadState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
