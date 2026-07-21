import SwiftUI

struct RecordingsView: View {
    let onOpenSettings: () -> Void
    let focusRequest: UUID?

    init(onOpenSettings: @escaping () -> Void, focusRequest: UUID? = nil) {
        self.onOpenSettings = onOpenSettings
        self.focusRequest = focusRequest
    }

    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var guide: GuideViewModel
    @EnvironmentObject private var playback: PlaybackCoordinator
    @FocusState private var focusedRecordingID: TVRecording.ID?
    @State private var selectedRecording: TVRecording?
    @State private var ruleToDelete: TVRecordingRule?

    private let columns = [
        GridItem(
            .adaptive(minimum: PlatformLayout.recordingCardMinimumWidth),
            spacing: PlatformLayout.gridSpacing
        )
    ]

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            if store.recordings.isEmpty, store.rules.isEmpty {
                emptyContent
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 38) {
                        recordingSection("RECORDING NOW", entries: store.recordingNow)
                        recordingSection("UPCOMING", entries: store.upcoming)
                        recordingSection("RECORDED", entries: store.completed)
                        recordingSection("FAILED", entries: store.failed)
                        rulesSection
                    }
                    .padding(.horizontal, PlatformLayout.contentPadding)
                    .padding(.vertical, PlatformLayout.contentVerticalPadding)
                }
                .refreshable {
                    await store.load(configuration: settings.configuration, force: true)
                }
            }
        }
        .platformDetailPresentation(item: $selectedRecording) { recording in
            RecordingDetailView(recordingID: recording.id)
        }
        .confirmationDialog(
            "Stop recording all future showings?",
            isPresented: Binding(
                get: { ruleToDelete != nil },
                set: { if !$0 { ruleToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let rule = ruleToDelete {
                Button("Remove “\(rule.name)”", role: .destructive) {
                    Task { await store.delete(rule, configuration: settings.configuration) }
                    ruleToDelete = nil
                }
            }
            Button("Keep Rule", role: .cancel) { ruleToDelete = nil }
        } message: {
            Text("The rule and its upcoming recordings will be cancelled. Existing recordings will be kept.")
        }
        .televisionPlayPauseCommand {
            guard let id = focusedRecordingID,
                  let recording = store.recordings.first(where: { $0.id == id }),
                  recording.isPlayable
            else { return }
            playback.start(
                recording: recording,
                channel: channel(for: recording),
                configuration: settings.configuration
            )
        }
        .onChange(of: focusRequest) { _, request in
            guard request != nil else { return }
            focusFirstRecordingElement()
        }
#if os(tvOS)
        .onReceive(NotificationCenter.default.publisher(for: .tvRecordingsPageCommand)) { note in
            guard let raw = note.userInfo?["direction"] as? Int,
                  let direction = TVPageDirection(rawValue: raw)
            else { return }
            pageRecordings(direction)
        }
#endif
    }

    @ViewBuilder
    private var emptyContent: some View {
        switch store.loadState {
        case .needsConfiguration:
            PlaceholderView(
                title: "Configure TVheadend",
                systemImage: "record.circle",
                message: "Add a TVheadend server in Settings before using recordings.",
                actionTitle: "Open Settings",
                action: onOpenSettings
            )
        case .loading:
            ProgressView("Loading recordings…")
                .font(.title2)
        case .loaded:
            PlaceholderView(
                title: "No recordings yet",
                systemImage: "record.circle",
                message: "Choose a programme in the guide to record it once or record all future showings."
            )
        case let .failed(message):
            PlaceholderView(
                title: "Recordings unavailable",
                systemImage: "exclamationmark.triangle",
                message: message,
                actionTitle: "Try Again",
                action: {
                    Task { await store.load(configuration: settings.configuration, force: true) }
                }
            )
        }
    }

    @ViewBuilder
    private func recordingSection(_ title: String, entries: [TVRecording]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                Text(title)
                    .font(.caption.bold())
                    .tracking(2.1)
                    .foregroundStyle(title == "RECORDING NOW" ? .red : AppTheme.accent)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    ForEach(entries) { recording in
                        RecordingCard(
                            recording: recording,
                            isFocused: focusedRecordingID == recording.id,
                            onPlay: {
                                playback.start(
                                    recording: recording,
                                    channel: channel(for: recording),
                                    configuration: settings.configuration
                                )
                            }
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                        .focusable()
                        .focused($focusedRecordingID, equals: recording.id)
                        .focusEffectDisabled()
                        .onTapGesture { selectedRecording = recording }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(recording.isPlayable
                            ? "Select for details. Press Play to start playback."
                            : "Select for recording details.")
                        .accessibilityAction { selectedRecording = recording }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var rulesSection: some View {
        if !store.rules.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                Text("RECORD ALL RULES")
                    .font(.caption.bold())
                    .tracking(2.1)
                    .foregroundStyle(AppTheme.accent)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    ForEach(store.rules) { rule in
                        Button {
                            ruleToDelete = rule
                        } label: {
                            HStack(spacing: 18) {
                                Image(systemName: rule.enabled ? "record.circle.fill" : "record.circle")
                                    .font(.system(size: 36))
                                    .foregroundStyle(rule.enabled ? .red : AppTheme.secondaryText)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(rule.name)
                                        .font(.title3.bold())
                                        .lineLimit(2)
                                    Text(ruleChannelName(rule))
                                        .font(.callout)
                                        .foregroundStyle(AppTheme.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "trash")
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            .padding(22)
                            .frame(height: 150)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .focused($focusedRecordingID, equals: "rule:\(rule.id)")
                    }
                }
            }
        }
    }

    private func channel(for recording: TVRecording) -> GuideChannel? {
        if let channelID = recording.channelID,
           let channel = guide.channels.first(where: { $0.id == channelID }) {
            return channel
        }
        return guide.channels.first { $0.name == recording.channelName }
    }

    private func ruleChannelName(_ rule: TVRecordingRule) -> String {
        if let channelName = rule.channelName, !channelName.isEmpty { return channelName }
        if let channelID = rule.channelID,
           let channel = guide.channels.first(where: { $0.id == channelID }) {
            return channel.name
        }
        return rule.seriesLink == nil ? "Selected channel" : "Series link"
    }

    private func focusFirstRecordingElement() {
        // Match the order rendered above rather than the store's underlying
        // aggregate order, which can put the second visible card first.
        let target = store.recordingNow.first?.id
            ?? store.upcoming.first?.id
            ?? store.completed.first?.id
            ?? store.failed.first?.id
            ?? store.rules.first.map { "rule:\($0.id)" }
        guard let target else { return }

        Task { @MainActor in
            await Task.yield()
            focusedRecordingID = target
        }
    }

#if os(tvOS)
    private func pageRecordings(_ direction: TVPageDirection) {
        let identifiers = store.recordingNow.map(\.id)
            + store.upcoming.map(\.id)
            + store.completed.map(\.id)
            + store.failed.map(\.id)
            + store.rules.map { "rule:\($0.id)" }
        guard !identifiers.isEmpty else { return }
        let current = focusedRecordingID.flatMap { identifiers.firstIndex(of: $0) } ?? 0
        let target = min(max(0, current + direction.rawValue * 4), identifiers.count - 1)
        focusedRecordingID = identifiers[target]
    }
#endif
}

private struct RecordingCard: View {
    let recording: TVRecording
    let isFocused: Bool
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(recording.state.label, systemImage: statusImage)
                    .font(.caption.bold())
                    .foregroundStyle(statusColor)
                Spacer()
                Text(recording.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Text(recording.title)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .lineLimit(2)

            if let subtitle = recording.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            if recording.state == .failed,
               let status = recording.statusText,
               !status.isEmpty {
                Label(status, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack {
                Text(recording.channelName)
                    .lineLimit(1)
                Spacer()
                if recording.fileSize > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: recording.fileSize, countStyle: .file))
                }
            }
            .font(.callout)
            .foregroundStyle(AppTheme.secondaryText)

#if !os(tvOS)
            if recording.isPlayable {
                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
#endif
        }
        .padding(22)
        .frame(height: cardHeight, alignment: .topLeading)
        .background(isFocused ? AppTheme.focused : AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isFocused ? AppTheme.focusBorder : Color.white.opacity(0.14), lineWidth: isFocused ? 4 : 1)
        }
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .accessibilityElement(children: .combine)
    }

    private var cardHeight: CGFloat {
#if os(tvOS)
        290
#else
        280
#endif
    }

    private var statusImage: String {
        switch recording.state {
        case .recording: "record.circle.fill"
        case .upcoming: "clock"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .removed: "trash"
        }
    }

    private var statusColor: Color {
        switch recording.state {
        case .recording: .red
        case .failed: .orange
        default: AppTheme.accent
        }
    }
}

private struct RecordingDetailView: View {
    @Environment(\.dismiss) private var dismiss
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var guide: GuideViewModel
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var confirmAction: ConfirmAction?

    let recordingID: TVRecording.ID

    private enum ConfirmAction: String, Identifiable {
        case cancel = "Cancel Recording"
        case stop = "Stop Recording"
        case delete = "Delete Recording"
        var id: Self { self }
    }

    private var recording: TVRecording? {
        store.recordings.first { $0.id == recordingID }
    }

    private var channel: GuideChannel? {
        guard let recording else { return nil }
        if let channelID = recording.channelID,
           let channel = guide.channels.first(where: { $0.id == channelID }) {
            return channel
        }
        return guide.channels.first { $0.name == recording.channelName }
    }

    private var detailLayout: AnyLayout {
        usesCompactLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 54))
    }

    private var usesCompactLayout: Bool {
#if os(iOS)
        horizontalSizeClass == .compact
#else
        false
#endif
    }

    private var detailPadding: CGFloat {
#if os(tvOS)
        80
#else
        PlatformLayout.contentPadding
#endif
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            if let recording {
                ScrollView {
                    detailLayout {
                    VStack(spacing: 22) {
                        if let channel {
                            ChannelBadge(channel: channel, diameter: 132)
                        } else {
                            Image(systemName: "record.circle.fill")
                                .font(.system(size: 112))
                                .foregroundStyle(.red)
                        }
                        Text(recording.channelName)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: usesCompactLayout ? nil : 280)

                    VStack(alignment: .leading, spacing: 18) {
                        Label(recording.state.label.uppercased(), systemImage: recording.state == .recording ? "record.circle.fill" : "video.fill")
                            .font(.caption.bold())
                            .tracking(1.8)
                            .foregroundStyle(recording.state == .recording ? .red : AppTheme.accent)

                        Text(recording.title)
                            .font(.largeTitle.bold())

                        if let subtitle = recording.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(AppTheme.secondaryText)
                        }

                        Label(
                            "\(recording.start.formatted(date: .abbreviated, time: .shortened))–\(recording.end.formatted(date: .omitted, time: .shortened))",
                            systemImage: "clock"
                        )
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryText)

                        Text(recording.overview)
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(7)

                        if let warning = recording.warningText {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }

                        if recording.errorCount + recording.dataErrorCount > 0 {
                            Label(
                                "\(recording.errorCount) recording errors · \(recording.dataErrorCount) data errors",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                        } else if recording.warningText == nil,
                                  let status = recording.statusText,
                                  !status.isEmpty {
                            Text(status).foregroundStyle(AppTheme.secondaryText)
                        }

                        actionButtons(recording)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: 1_720, alignment: .leading)
                    .padding(detailPadding)
                }
            } else {
                PlaceholderView(
                    title: "Recording no longer available",
                    systemImage: "questionmark.folder",
                    message: "It may have been removed on the TVheadend server.",
                    actionTitle: "Back",
                    action: { dismiss() }
                )
            }
        }
        .confirmationDialog(
            confirmAction?.rawValue ?? "Confirm",
            isPresented: Binding(
                get: { confirmAction != nil },
                set: { if !$0 { confirmAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = confirmAction {
                Button(action.rawValue, role: .destructive) {
                guard let recording else { return }
                Task {
                    switch action {
                    case .cancel: await store.cancel(recording, configuration: settings.configuration)
                    case .stop: await store.stop(recording, configuration: settings.configuration)
                    case .delete: await store.delete(recording, configuration: settings.configuration)
                    }
                    if action != .stop { dismiss() }
                }
            }
            }
            Button("Keep Recording", role: .cancel) {}
        }
        .televisionPlayPauseCommand {
            guard let recording, recording.isPlayable else { return }
            play(recording)
        }
    }

    @ViewBuilder
    private func actionButtons(_ recording: TVRecording) -> some View {
#if os(tvOS)
        HStack(spacing: 20) {
            actionButtonContents(recording)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
#else
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 170), spacing: 14, alignment: .leading)],
            alignment: .leading,
            spacing: 14
        ) {
            actionButtonContents(recording)
        }
#endif
    }

    @ViewBuilder
    private func actionButtonContents(_ recording: TVRecording) -> some View {
            if recording.isPlayable {
                Button { play(recording) } label: {
                    recordingActionLabel(
                        "Play from Beginning",
                        systemImage: "play.fill",
                        minimumWidth: 270
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.focused)
            }

            if recording.state == .recording, let channel {
                Button {
                    playback.start(
                        channel: channel,
                        program: channel.programs.first { $0.isAiring(at: Date()) },
                        configuration: settings.configuration
                    )
                } label: {
                    recordingActionLabel(
                        "Watch Live",
                        systemImage: "dot.radiowaves.left.and.right",
                        minimumWidth: 220
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.surfaceRaised)
            }

            switch recording.state {
            case .upcoming:
                destructiveButton("Cancel Recording", image: "xmark", action: .cancel)
            case .recording:
                destructiveButton("Stop Recording", image: "stop.fill", action: .stop)
            case .completed, .failed:
                destructiveButton("Delete", image: "trash", action: .delete)
            case .removed:
                EmptyView()
            }

    }

    private func destructiveButton(_ title: String, image: String, action: ConfirmAction) -> some View {
        Button { confirmAction = action } label: {
            recordingActionLabel(title, systemImage: image, minimumWidth: 230)
        }
            .buttonStyle(.borderedProminent)
            .tint(.red.opacity(0.8))
    }

    private func recordingActionLabel(
        _ title: String,
        systemImage: String,
        minimumWidth: CGFloat
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .lineLimit(1)
#if os(tvOS)
            .frame(minWidth: minimumWidth, minHeight: 64)
#endif
    }

    private func play(_ recording: TVRecording) {
        playback.start(
            recording: recording,
            channel: channel,
            configuration: settings.configuration
        )
    }
}
