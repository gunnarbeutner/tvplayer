import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var saveError: String?

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TVHEADEND")
                                .font(.caption.bold())
                                .tracking(2.2)
                                .foregroundStyle(AppTheme.accent)

                            Text("Server settings")
                                .font(.largeTitle.bold())

                            Text("The password is stored in the Apple TV Keychain. Other settings use app preferences.")
                                .font(.callout)
                                .foregroundStyle(AppTheme.secondaryText)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 10) {
                            ConnectionStatusView(status: settings.connectionStatus)
                            TimeshiftStatusView(
                                status: settings.timeshiftStatus,
                                engine: playback.engine
                            )
                        }
                    }

                    SettingsField(
                        title: "Server URL",
                        hint: "For example: http://tvheadend.local:9981"
                    ) {
                        TextField("http://tvheadend.local:9981", text: $settings.baseURLText)
                    }

                    HStack(alignment: .top, spacing: 24) {
                        SettingsField(title: "Username", hint: "TVHeadend account") {
                            TextField("Username", text: $settings.username)
                        }

                        SettingsField(title: "Password", hint: "Saved securely in Keychain") {
                            SecureField("Password", text: $settings.password)
                        }
                    }

                    HStack(alignment: .top, spacing: 24) {
                        SettingsField(
                            title: "Stream profile",
                            hint: "TVHeadend profile used for live streams. The default is pass."
                        ) {
                            TextField("pass", text: $settings.streamProfile)
                        }

                        SettingsField(
                            title: "HTSP port",
                            hint: "Native TVHeadend timeshift normally uses port 9982."
                        ) {
                            TextField("9982", text: $settings.htspPortText)
                        }
                    }

                    SettingsField(
                        title: "Rich guide cache URL (optional)",
                        hint: "Preferred when set. Discovery normally configures this automatically."
                    ) {
                        TextField("http://tvheadend.local:49382/guide.json", text: $settings.guideCacheURLText)
                    }

                    SettingsField(
                        title: "XMLTV URL fallback (optional)",
                        hint: "Used only when no rich guide cache is configured. Leave both empty to use TVHeadend directly."
                    ) {
                        TextField("https://example.net/guide.xml", text: $settings.xmltvURLText)
                    }

                    HStack(spacing: 20) {
                        Button {
                            save()
                        } label: {
                            Label("Save", systemImage: "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.focused)

                        Button {
                            testConnection()
                        } label: {
                            if settings.connectionStatus == .checking {
                                ProgressView()
                                    .frame(width: 150)
                            } else {
                                Label("Test Connection", systemImage: "network")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(settings.connectionStatus == .checking)

                        if let saveError {
                            Label(
                                saveError,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.headline)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                        }
                    }
                }
                .padding(.horizontal, 90)
                .padding(.vertical, 44)
            }
        }
        .task {
            if settings.configuration.isComplete,
               settings.connectionStatus == .notTested {
                await settings.testConnection()
            }
        }
    }

    private func save() {
        do {
            try settings.save()
            saveError = nil
            Task { await settings.testConnection() }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func testConnection() {
        Task {
            saveError = nil
            await settings.testConnection()
        }
    }
}

private struct TimeshiftStatusView: View {
    let status: TVHeadendTimeshiftStatus
    @ObservedObject var engine: VLCPlaybackEngine

    private var appearance: (String, String, Color, String) {
        if let mode = engine.activeLivePlaybackMode {
            switch mode {
            case .tvHeadend:
                return (
                    "Timeshift · TVHeadend",
                    "clock.arrow.circlepath",
                    .green,
                    "TVHeadend timeshift is active for the current live stream."
                )
            case let .liveOnly(reason):
                return (
                    "Timeshift · Unavailable",
                    "clock.badge.exclamationmark",
                    .orange,
                    reason ?? "The current live stream has no timeshift support."
                )
            }
        }

        switch status {
        case .notTested:
            return ("Timeshift · Not tested", "questionmark.circle.fill", AppTheme.secondaryText, "Test the connection to check native timeshift.")
        case .checking:
            return ("Timeshift · Checking…", "arrow.triangle.2.circlepath", AppTheme.accent, "Checking TVHeadend's HTSP service.")
        case .ready:
            return ("Timeshift · TVHeadend", "clock.arrow.circlepath", .green, "Native timeshift will be used for live TV.")
        case let .unavailable(reason):
            return ("Timeshift · Unavailable", "clock.badge.exclamationmark", .orange, reason)
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Label(appearance.0, systemImage: appearance.1)
                .font(.headline)
                .foregroundStyle(appearance.2)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(AppTheme.surface, in: Capsule())
            Text(appearance.3)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .frame(maxWidth: 420, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeshift: \(appearance.0). \(appearance.3)")
    }
}

private struct ConnectionStatusView: View {
    let status: ServerConnectionStatus

    private var appearance: (String, String, Color) {
        switch status {
        case .notTested:
            return ("Not tested", "questionmark.circle.fill", AppTheme.secondaryText)
        case .checking:
            return ("Checking…", "arrow.triangle.2.circlepath", AppTheme.accent)
        case let .connected(server):
            return ("Connected · \(server)", "checkmark.circle.fill", .green)
        case let .failed(message):
            return ("Failed · \(message)", "xmark.octagon.fill", .red)
        }
    }

    var body: some View {
        Label(appearance.0, systemImage: appearance.1)
            .font(.headline)
            .foregroundStyle(appearance.2)
            .lineLimit(2)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(AppTheme.surface, in: Capsule())
            .accessibilityLabel("TVHeadend connection: \(appearance.0)")
    }
}

private struct SettingsField<Content: View>: View {
    let title: String
    let hint: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
            content
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(.horizontal, 18)
                .frame(height: 62)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                }
            Text(hint)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
