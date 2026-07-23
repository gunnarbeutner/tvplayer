import SwiftUI
@preconcurrency import VLCKit

struct SettingsView: View {
    let focusRequest: UUID?

#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var showsServerEditor = false
    @State private var showsLicenses = false
    @FocusState private var focusedControl: FocusControl?

    private enum FocusControl: Hashable {
        case server(String)
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
                            Text("Settings")
                                .font(.largeTitle.bold())

                            Text("Manage TVHeadend connections and playback behavior.")
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

                    VStack(alignment: .leading, spacing: 14) {
                        Text("PLAYBACK")
                            .font(.caption.bold())
                            .tracking(2.2)
                            .foregroundStyle(AppTheme.accent)

                        SettingsField(
                            title: "Commercial detection",
                            hint: commercialDetectionHint
                        ) {
                            Picker(
                                "Commercial detection",
                                selection: $playback.commercialDetectionMode
                            ) {
                                ForEach(CommercialDetectionMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }

                        adaptiveLayout {
                            SettingsField(
                                title: "Preferred audio language",
                                hint: "Used when a matching audio track is available."
                            ) {
                                Picker(
                                    "Preferred audio language",
                                    selection: $playback.preferredAudioLanguage
                                ) {
                                    ForEach(PreferredAudioLanguage.allCases) { language in
                                        Text(language.title).tag(language)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .foregroundStyle(.white)
                            }

                            SettingsField(
                                title: "Subtitles",
                                hint: subtitlePreferenceHint
                            ) {
                                Picker("Subtitles", selection: $playback.subtitlePreference) {
                                    ForEach(SubtitlePreference.allCases) { preference in
                                        Text(preference.title).tag(preference)
                                    }
                                }
                                .labelsHidden()
                            }
                        }

                        SettingsField(
                            title: "On startup",
                            hint: "Choose which section opens when TV Player starts."
                        ) {
                            Picker("On startup", selection: $playback.startupBehavior) {
                                ForEach(StartupBehavior.allCases) { behavior in
                                    Text(behavior.title).tag(behavior)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 14) {
                        Text("ABOUT")
                            .font(.caption.bold())
                            .tracking(2.2)
                            .foregroundStyle(AppTheme.accent)

                        SettingsActionButton(
                            title: "About & Licenses",
                            systemImage: "info.circle",
                            style: .secondary
                        ) {
                            showsLicenses = true
                        }
                    }
                }
                .padding(.horizontal, PlatformLayout.contentPadding)
                .padding(.vertical, PlatformLayout.contentVerticalPadding)
            }
        }
        .task {
            if settings.configuration.isComplete,
               settings.connectionStatus == .notTested {
                await settings.testConnection()
            }
        }
        .modifier(ServerEditorPresentationModifier(isPresented: $showsServerEditor))
        .modifier(LicensePresentationModifier(isPresented: $showsLicenses))
        .onChange(of: showsServerEditor) { wasPresented, isPresented in
            guard wasPresented, !isPresented,
                  settings.configuration.isComplete,
                  settings.connectionStatus == .notTested
            else { return }
            Task { await settings.testConnection() }
        }
        .onChange(of: focusRequest) { _, request in
            guard request != nil else { return }
            Task { @MainActor in
                await Task.yield()
                if let activeProfileID = settings.activeProfileID {
                    focusedControl = .server(activeProfileID)
                }
            }
        }
    }

    private var commercialDetectionHint: String {
        switch playback.commercialDetectionMode {
        case .automatic:
            "Uses a second live stream on normal networks and pauses on constrained, cellular, or metered connections."
        case .always:
            "Always analyzes a second live stream, including on cellular or metered connections."
        case .off:
            "Does not analyze live video for commercial markers."
        }
    }

    private var subtitlePreferenceHint: String {
        switch playback.subtitlePreference {
        case .off:
            "Subtitles start disabled."
        case .automatic:
            "Shows matching subtitles when the selected audio is not in your preferred language."
        case .always:
            "Shows matching subtitles whenever they are available."
        }
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Servers")
                    .font(.title2.bold())
                Spacer()
                SettingsActionButton(
                    title: "Add Server",
                    systemImage: "plus",
                    style: .secondary
                ) {
                    settings.beginAddingServer()
                    showsServerEditor = true
                }
            }

            if settings.profiles.isEmpty {
                Text("No servers saved. TV Player will also add compatible servers discovered on your local network.")
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                VStack(spacing: 10) {
                    ForEach(settings.profiles) { profile in
                        ServerProfileRow(
                            profile: profile,
                            isActive: settings.activeProfileID == profile.id,
                            isOnline: settings.isOnline(profile),
                            isFocused: focusedControl == .server(profile.id)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                        .focusable()
                        .focusEffectDisabled()
                        .focused($focusedControl, equals: .server(profile.id))
                        .onTapGesture {
                            settings.selectServer(profile.id)
                            showsServerEditor = true
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Select and edit this server")
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

}

private struct LicensePresentationModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
#if os(tvOS)
        content.fullScreenCover(isPresented: $isPresented) {
            LicensesView()
        }
#else
        content.sheet(isPresented: $isPresented) {
            LicensesView()
#if os(macOS)
                .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 700)
                .presentationSizing(.fitted)
#endif
        }
#endif
    }
}

private struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var playback: PlaybackCoordinator

    private var mitLicenseText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "The MIT License text could not be loaded." }
        return text
    }

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LGPL-2.1", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "The GNU Lesser General Public License text could not be loaded." }
        return text
    }

    private var licenseParagraphs: [String] {
        licenseText
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var mitLicenseParagraphs: [String] {
        mitLicenseText
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }

    private var vlcVersion: String {
        "VLCKit 4.0-20260720-1538 · libVLC \(playback.engine.mediaPlayer.libraryInstance.version)"
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("About & Licenses")
                                .font(.largeTitle.bold())
                            Text(appVersion)
                                .foregroundStyle(AppTheme.secondaryText)
                        }

                        Spacer()

#if !os(tvOS)
                        SettingsActionButton(
                            title: "Close",
                            systemImage: "xmark",
                            style: .secondary,
                            action: { dismiss() }
                        )
#endif
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("TV Player")
                            .font(.title2.bold())
                        Text("TV Player’s source code is available under the MIT License.")
                        ForEach(Array(mitLicenseParagraphs.enumerated()), id: \.offset) { _, paragraph in
                            LicenseParagraph(text: paragraph)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("VLCKit and libVLC")
                            .font(.title2.bold())
                        Text(vlcVersion)
                            .font(.callout.monospaced())
                            .foregroundStyle(AppTheme.secondaryText)
                        Text("TV Player uses VLCKit and libVLC from the VideoLAN project. Copyright © VideoLAN and VLCKit/libVLC contributors. They are distributed under the GNU Lesser General Public License, version 2.1 or later, and are not covered by TV Player’s MIT License.")
                        Text("Source: code.videolan.org/videolan/VLCKit")
                            .foregroundStyle(AppTheme.accent)
                            .modifier(SettingsTextSelectionModifier())
                    }

                    Divider()

                    Text("GNU Lesser General Public License 2.1")
                        .font(.title2.bold())
                    Text("Swipe down to read the full license.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.secondaryText)

                    // tvOS directional focus needs the next paragraph to
                    // exist before it can scroll toward it. A lazy stack
                    // leaves the LGPL text unrealized below the viewport,
                    // trapping focus in the preceding MIT section.
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(licenseParagraphs.enumerated()), id: \.offset) { _, paragraph in
                            LicenseParagraph(text: paragraph)
                        }
                    }
                }
                .padding(.horizontal, PlatformLayout.contentPadding)
                .padding(.vertical, PlatformLayout.contentVerticalPadding)
            }
            .scrollIndicators(.visible)
        }
        .platformExitCommand { dismiss() }
    }
}

private struct LicenseParagraph: View {
    let text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(isFocused ? Color.white : AppTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
#if os(tvOS)
            .padding(14)
            .background(
                isFocused ? AppTheme.surfaceRaised : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isFocused ? AppTheme.focusBorder : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
#else
            .modifier(SettingsTextSelectionModifier())
#endif
    }
}

private struct SettingsTextSelectionModifier: ViewModifier {
    func body(content: Content) -> some View {
#if os(tvOS)
        content
#else
        content.textSelection(.enabled)
#endif
    }
}

private struct ServerEditorPresentationModifier: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
#if os(tvOS)
        content.fullScreenCover(isPresented: $isPresented) {
            ServerEditorView()
        }
#else
        content.sheet(isPresented: $isPresented) {
            ServerEditorView()
#if os(macOS)
                .frame(minWidth: 760, idealWidth: 860, minHeight: 620, idealHeight: 760)
                .presentationSizing(.fitted)
#else
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
#endif
        }
#endif
    }
}

private struct ServerEditorView: View {
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: ServerSettingsStore
    @State private var saveError: String?
    @State private var streamProfiles: [TVHeadendStreamProfile] = []
    @State private var isLoadingStreamProfiles = false

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(editorTitle)
                                .font(.largeTitle.bold())
                            Text("Configure the TVHeadend connection used by TV Player.")
                                .font(.callout)
                                .foregroundStyle(AppTheme.secondaryText)
                        }

                        Spacer()

#if !os(tvOS)
                        SettingsActionButton(
                            title: "Close",
                            systemImage: "xmark",
                            style: .secondary,
                            action: close
                        )
#endif
                    }

                    editorFields

                    actionButtons
                }
                .padding(.horizontal, PlatformLayout.contentPadding)
                .padding(.vertical, PlatformLayout.contentVerticalPadding)
            }
        }
        .platformExitCommand(close)
        .task { await loadStreamProfiles() }
    }

    private var editorFields: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsField(
                title: "Name",
                hint: "Shown only in TV Player. Discovered servers use their advertised name."
            ) {
                TextField(
                    "Name",
                    text: $settings.displayNameText,
                    prompt: settingsPrompt("e.g. Living room")
                )
            }

            SettingsField(
                title: "Server URL",
                hint: "For example: http://tvheadend.local:9981"
            ) {
                TextField(
                    "Server URL",
                    text: $settings.baseURLText,
                    prompt: settingsPrompt("e.g. http://tvheadend.local:9981")
                )
            }

            adaptiveLayout {
                SettingsField(
                    title: "Username",
                    hint: "Leave both fields empty for anonymous access"
                ) {
                    TextField(
                        "Username",
                        text: $settings.username,
                        prompt: settingsPrompt("Optional")
                    )
                }

                SettingsField(
                    title: "Password",
                    hint: "Required when a username is set"
                ) {
                    SecureField(
                        "Password",
                        text: $settings.password,
                        prompt: settingsPrompt("Optional")
                    )
                }
            }

            adaptiveLayout {
                SettingsField(
                    title: "Stream profile",
                    hint: streamProfileHint
                ) {
                    Picker("Stream profile", selection: $settings.streamProfile) {
                        ForEach(availableStreamProfiles) { profile in
                            Text(profile.name).tag(profile.key)
                        }
                    }
                    .labelsHidden()
                }

                SettingsField(
                    title: "HTSP port",
                    hint: "Native TVHeadend timeshift normally uses port 9982."
                ) {
                    TextField(
                        "HTSP port",
                        text: $settings.htspPortText,
                        prompt: settingsPrompt("Default: 9982")
                    )
                }
            }

            SettingsField(
                title: "Rich guide cache URL (optional)",
                hint: "Preferred when set. Discovery normally configures this automatically."
            ) {
                TextField(
                    "Rich guide cache URL",
                    text: $settings.guideCacheURLText,
                    prompt: settingsPrompt("Optional")
                )
            }

            SettingsField(
                title: "XMLTV URL fallback (optional)",
                hint: "Used only when no rich guide cache is configured. Leave both empty to use TVHeadend directly."
            ) {
                TextField(
                    "XMLTV URL",
                    text: $settings.xmltvURLText,
                    prompt: settingsPrompt("Optional")
                )
            }
        }
    }

    private var editorTitle: String {
        if settings.isAddingServer { return "Add server" }
        return settings.editingProfile.map { "Edit \($0.name)" } ?? "Edit server"
    }

    private var availableStreamProfiles: [TVHeadendStreamProfile] {
        var result: [TVHeadendStreamProfile] = []
        var seenKeys: Set<String> = []
        var seenNames: Set<String> = []
        let current = settings.streamProfile
        let serverContainsCurrent = streamProfiles.contains { $0.key == current }
        if !serverContainsCurrent {
            result.append(TVHeadendStreamProfile(key: current, val: current))
            seenKeys.insert(current)
            seenNames.insert(current.lowercased())
        }
        for profile in streamProfiles {
            let normalizedName = profile.name.lowercased()
            guard seenKeys.insert(profile.key).inserted,
                  seenNames.insert(normalizedName).inserted
            else { continue }
            result.append(profile)
        }
        return result
    }

    private var streamProfileHint: String {
        isLoadingStreamProfiles
            ? "Loading profiles from TVHeadend…"
            : "TVHeadend profile used for live streams."
    }

    private func settingsPrompt(_ text: String) -> Text {
        Text(text)
            .foregroundStyle(AppTheme.secondaryText.opacity(0.58))
            .italic()
    }

    private var actionButtons: some View {
        adaptiveLayout {
            SettingsActionButton(
                title: settings.isAddingServer ? "Add Server" : "Save",
                systemImage: "checkmark",
                style: .primary,
                action: save
            )

            SettingsActionButton(
                title: settings.connectionStatus == .checking ? "Checking…" : "Test Connection",
                systemImage: settings.connectionStatus == .checking
                    ? "arrow.triangle.2.circlepath" : "network",
                style: .secondary,
                isEnabled: settings.connectionStatus != .checking,
                action: testConnection
            )

            if let profile = settings.editingProfile,
               profile.origin == .discovered,
               profile.isEdited {
                SettingsActionButton(
                    title: "Use Automatic Updates",
                    systemImage: "arrow.triangle.2.circlepath",
                    style: .secondary
                ) {
                    settings.restoreAutomaticUpdates(profile.id)
                    saveError = nil
                }
            }

            if let profile = settings.editingProfile {
                SettingsActionButton(
                    title: "Forget",
                    systemImage: "trash",
                    style: .destructive,
                    isEnabled: settings.canForget(profile)
                ) {
                    settings.forget(profile.id)
                    dismiss()
                }
            }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                    .lineLimit(2)
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
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func testConnection() {
        Task {
            saveError = nil
            await settings.testConnection()
            await loadStreamProfiles()
        }
    }

    private func loadStreamProfiles() async {
        guard !isLoadingStreamProfiles,
              let configuration = try? settings.validatedDraft()
        else { return }
        isLoadingStreamProfiles = true
        defer { isLoadingStreamProfiles = false }
        do {
            streamProfiles = try await TVHeadendClient(configuration: configuration)
                .streamProfiles()
        } catch {
            // Keep the saved profile as the fallback when this optional list
            // cannot be queried yet (for example while adding a server).
        }
    }

    private func close() {
        settings.cancelEditing()
        dismiss()
    }
}

private enum SettingsActionButtonStyle {
    case primary
    case secondary
    case destructive
}

private struct SettingsActionButton: View {
    let title: String
    let systemImage: String
    let style: SettingsActionButtonStyle
    var isEnabled = true
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
#if os(tvOS)
        label
            .focusable(isEnabled)
            .focusEffectDisabled()
            .focused($isFocused)
            .onTapGesture {
                guard isEnabled else { return }
                action()
            }
            .accessibilityAddTraits(.isButton)
#else
        Button(action: action) {
            label
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
#endif
    }

    private var label: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .lineLimit(1)
            .padding(.horizontal, 18)
            .frame(minHeight: 54)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor, in: Capsule())
            .overlay {
                Capsule().strokeBorder(borderColor, lineWidth: isFocused ? 3 : 1)
            }
            .contentShape(Capsule())
            .scaleEffect(isFocused ? 1.035 : 1)
            .animation(.easeOut(duration: 0.14), value: isFocused)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityLabel(title)
    }

    private var foregroundColor: Color {
        if isFocused { return .black }
        return style == .destructive ? .red : .white
    }

    private var backgroundColor: Color {
        if isFocused { return .white }
        switch style {
        case .primary: return AppTheme.focused
        case .secondary, .destructive: return AppTheme.surfaceRaised
        }
    }

    private var borderColor: Color {
        if isFocused { return AppTheme.focusBorder }
        return style == .destructive ? .red.opacity(0.55) : .white.opacity(0.16)
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
                .foregroundStyle(isActive ? AppTheme.accent : secondaryColor)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name)
                    .font(.headline)
                Text(profile.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }

            Spacer()

            Text(ownership)
                .font(.caption.bold())
                .foregroundStyle(profile.isEdited ? .orange : secondaryColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.surface, in: Capsule())

            if profile.origin == .discovered {
                Label(isOnline ? "Online" : "Offline", systemImage: isOnline ? "wifi" : "wifi.slash")
                    .font(.caption.bold())
                    .foregroundStyle(isFocused ? .white : isOnline ? .green : AppTheme.secondaryText)
            }

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(secondaryColor)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 72)
        .background(
            isFocused ? AppTheme.surfaceRaised : AppTheme.surface.opacity(isActive ? 1 : 0.72),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isFocused ? AppTheme.focusBorder : isActive ? AppTheme.accent : Color.white.opacity(0.15),
                    lineWidth: isFocused ? 3 : isActive ? 2 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var secondaryColor: Color {
        isFocused ? .white.opacity(0.72) : AppTheme.secondaryText
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
        Label(appearance.0, systemImage: appearance.1)
            .font(.callout.bold())
            .foregroundStyle(appearance.2)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(AppTheme.surface, in: Capsule())
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
            .font(.callout.bold())
            .foregroundStyle(appearance.2)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
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
#if os(tvOS)
            content
                .textFieldStyle(.plain)
                .font(.title3)
                .frame(minHeight: 62)
#else
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
#endif
            Text(hint)
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
