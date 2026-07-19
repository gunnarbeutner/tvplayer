import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: ServerSettingsStore
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

                        ConnectionStatusView(status: settings.connectionStatus)
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

                    SettingsField(
                        title: "Stream profile",
                        hint: "TVHeadend profile used for live streams. The default is pass."
                    ) {
                        TextField("pass", text: $settings.streamProfile)
                    }

                    SettingsField(
                        title: "XMLTV URL override (optional)",
                        hint: "Leave empty to use TVHeadend’s EPG. This affects guide metadata only."
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
