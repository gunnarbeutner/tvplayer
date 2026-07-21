import SwiftUI

struct SettingsView: View {
    let focusRequest: UUID?

#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var saveError: String?
    @FocusState private var focusedControl: FocusControl?

    private enum FocusControl: Hashable {
        case server(String)
        case serverURL
    }

    init(focusRequest: UUID? = nil) {
        self.focusRequest = focusRequest
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    adaptiveLayout {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TVHEADEND")
                                .font(.caption.bold())
                                .tracking(2.2)
                                .foregroundStyle(AppTheme.accent)

                            Text("TVHeadend servers")
                                .font(.largeTitle.bold())

                            Text("Choose one active server for channels, guide, recordings, and playback. Passwords are stored in this device's Keychain.")
                                .font(.callout)
                                .foregroundStyle(AppTheme.secondaryText)
                        }

                        Spacer()

                        if !settings.isAddingServer {
                            VStack(alignment: .trailing, spacing: 10) {
                                ConnectionStatusView(status: settings.connectionStatus)
                                TimeshiftStatusView(
                                    status: settings.timeshiftStatus,
                                    engine: playback.engine
                                )
                            }
                        }
                    }

                    serverList

                    Divider()

                    Text(settings.isAddingServer ? "Add server" : "Edit server")
                        .font(.title2.bold())

                    SettingsField(
                        title: "Name",
                        hint: "Shown only in TV Player. Discovered servers use their advertised name."
                    ) {
                        TextField("Living room", text: $settings.displayNameText)
                    }

                    SettingsField(
                        title: "Server URL",
                        hint: "For example: http://tvheadend.local:9981"
                    ) {
                        TextField("http://tvheadend.local:9981", text: $settings.baseURLText)
                            .focused($focusedControl, equals: .serverURL)
                    }

                    adaptiveLayout {
                        SettingsField(title: "Username", hint: "TVHeadend account") {
                            TextField("Username", text: $settings.username)
                        }

                        SettingsField(title: "Password", hint: "Saved securely in Keychain") {
                            SecureField("Password", text: $settings.password)
                        }
                    }

                    adaptiveLayout {
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

                    adaptiveLayout {
                        Button {
                            save()
                        } label: {
                            Label(settings.isAddingServer ? "Add Server" : "Save", systemImage: "checkmark")
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

                        if settings.isAddingServer, !settings.profiles.isEmpty {
                            Button("Cancel", role: .cancel) {
                                settings.cancelEditing()
                                saveError = nil
                            }
                            .buttonStyle(.bordered)
                        }

                        if let profile = settings.editingProfile,
                           profile.origin == .discovered,
                           profile.isEdited {
                            Button {
                                settings.restoreAutomaticUpdates(profile.id)
                                saveError = nil
                            } label: {
                                Label("Use Automatic Updates", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.bordered)
                        }

                        if let profile = settings.editingProfile {
                            Button(role: .destructive) {
                                settings.forget(profile.id)
                                saveError = nil
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!settings.canForget(profile))
                        }

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
                .padding(.horizontal, PlatformLayout.contentPadding)
                .padding(.vertical, PlatformLayout.contentVerticalPadding)
            }
        }
        .task {
            if settings.editingProfileID == settings.activeProfileID,
               settings.configuration.isComplete,
               settings.connectionStatus == .notTested {
                await settings.testConnection()
            }
        }
        .onChange(of: focusRequest) { _, request in
            guard request != nil else { return }
            Task { @MainActor in
                await Task.yield()
                if let activeProfileID = settings.activeProfileID {
                    focusedControl = .server(activeProfileID)
                } else {
                    focusedControl = .serverURL
                }
            }
        }
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Servers")
                    .font(.title2.bold())
                Spacer()
                Button {
                    settings.beginAddingServer()
                    saveError = nil
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            if settings.profiles.isEmpty {
                Text("No servers saved. TV Player will also add compatible servers discovered on your local network.")
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                VStack(spacing: 10) {
                    ForEach(settings.profiles) { profile in
                        Button {
                            settings.selectServer(profile.id)
                            saveError = nil
                        } label: {
                            ServerProfileRow(
                                profile: profile,
                                isActive: settings.activeProfileID == profile.id,
                                isOnline: settings.isOnline(profile),
                                isFocused: focusedControl == .server(profile.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .focused($focusedControl, equals: .server(profile.id))
                        .focusEffectDisabled()
                    }
                }
            }
        }
    }

    private var adaptiveLayout: AnyLayout {
        usesVerticalLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
    }

    private var usesVerticalLayout: Bool {
#if os(iOS)
        horizontalSizeClass == .compact
#else
        false
#endif
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

private struct ServerProfileRow: View {
    let profile: TVHeadendServerProfile
    let isActive: Bool
    let isOnline: Bool
    let isFocused: Bool

    private var ownership: String {
        switch (profile.origin, profile.isEdited) {
        case (.manual, _): "Manual"
        case (.discovered, false): "Automatic"
        case (.discovered, true): "Edited"
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isActive ? AppTheme.accent : AppTheme.secondaryText)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name)
                    .font(.headline)
                Text(profile.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Text(ownership)
                .font(.caption.bold())
                .foregroundStyle(profile.isEdited ? .orange : AppTheme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.surface, in: Capsule())

            if profile.origin == .discovered {
                Label(isOnline ? "Online" : "Offline", systemImage: isOnline ? "wifi" : "wifi.slash")
                    .font(.caption.bold())
                    .foregroundStyle(isOnline ? .green : AppTheme.secondaryText)
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 72)
        .background(
            isFocused ? AppTheme.focused : AppTheme.surface.opacity(isActive ? 1 : 0.72),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isFocused ? Color.white.opacity(0.85) : isActive ? AppTheme.accent : Color.white.opacity(0.15),
                    lineWidth: isFocused ? 4 : isActive ? 2 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
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
