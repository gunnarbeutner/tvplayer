import SwiftUI

struct PlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?
    let focusRequest: UUID?

    @FocusState private var isActionFocused: Bool

    init(
        title: String,
        systemImage: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        focusRequest: UUID? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.focusRequest = focusRequest
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
                        .focused($isActionFocused)
                }
            }
        }
        .onChange(of: focusRequest) { _, request in
            guard request != nil, action != nil else { return }
            Task { @MainActor in
                await Task.yield()
                isActionFocused = true
            }
        }
    }
}

struct TVSourceStateView: View {
    let state: GuideLoadState
    let openSettings: () -> Void
    let retry: () -> Void
    let focusRequest: UUID?

    @FocusState private var focusedAction: Action?

    private enum Action: Hashable {
        case openSettings
        case retry
    }

    init(
        state: GuideLoadState,
        openSettings: @escaping () -> Void,
        retry: @escaping () -> Void,
        focusRequest: UUID? = nil
    ) {
        self.state = state
        self.openSettings = openSettings
        self.retry = retry
        self.focusRequest = focusRequest
    }

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
                        .focused($focusedAction, equals: .openSettings)

                    if state.isFailure {
                        Button("Try Again", action: retry)
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.surfaceRaised)
                            .focused($focusedAction, equals: .retry)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
        .onChange(of: focusRequest) { _, request in
            guard request != nil, state != .loading else { return }
            Task { @MainActor in
                await Task.yield()
                focusedAction = .openSettings
            }
        }
    }
}

private extension GuideLoadState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
