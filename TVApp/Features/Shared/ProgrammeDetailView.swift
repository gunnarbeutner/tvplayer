import SwiftUI

struct ProgrammeDetailPresentation: Identifiable {
    let id = UUID()
    let program: GuideProgram?
    let channel: GuideChannel
}

struct ProgrammeDetailView: View {
    @Environment(\.dismiss) private var dismiss
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
#endif
    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var recordings: RecordingStore
    @State private var confirmRecordingAction: RecordingConfirmation?

    let presentation: ProgrammeDetailPresentation

    private var program: GuideProgram? { presentation.program }
    private var channel: GuideChannel { presentation.channel }
    private var existingRecording: TVRecording? {
        program.flatMap(recordings.scheduledRecording(for:))
    }
    private var recordOnceActionKey: String? {
        program.map { "program:\($0.id)" }
    }
    private var recordAllActionKey: String? {
        program.map { "series:\($0.id)" }
    }
    private var metadataLabels: [String] {
        guard let metadata = program?.metadata else { return [] }
        var labels: [String] = []

        if let season = metadata.seasonNumber, let episode = metadata.episodeNumber {
            labels.append("Season \(season) · Episode \(episode)")
        } else if let episode = metadata.episodeNumber {
            labels.append("Episode \(episode)")
        }
        if let part = metadata.partNumber { labels.append("Part \(part)") }
        labels.append(contentsOf: metadata.categories.prefix(2))
        if metadata.isNew { labels.append("New") }
        if metadata.isHD { labels.append("HD") }
        if metadata.isWidescreen { labels.append("Widescreen") }
        if metadata.isSubtitled { labels.append("Subtitles") }
        if let rating = metadata.ratingLabel ?? metadata.ageRating {
            labels.append(rating)
        }
        if let stars = metadata.starRating { labels.append("★ \(stars)") }
        return labels
    }

    private var detailLayout: AnyLayout {
        usesCompactLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
            : AnyLayout(HStackLayout(alignment: .top, spacing: detailColumnSpacing))
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

    private var detailColumnSpacing: CGFloat {
#if os(macOS)
        32
#else
        54
#endif
    }

    private var channelBadgeDiameter: CGFloat {
#if os(macOS)
        104
#else
        132
#endif
    }

    private var channelColumnWidth: CGFloat {
#if os(macOS)
        180
#else
        280
#endif
    }

    private var detailMaximumWidth: CGFloat {
#if os(macOS)
        840
#else
        1_720
#endif
    }

    private var titleFont: Font {
#if os(macOS)
        .title.bold()
#else
        .largeTitle.bold()
#endif
    }

    private var overviewFont: Font {
#if os(macOS)
        .body
#else
        .title3
#endif
    }

    private var actionColumns: [GridItem] {
#if os(macOS)
        [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12, alignment: .leading)]
#else
        [GridItem(.adaptive(minimum: 170), spacing: 14, alignment: .leading)]
#endif
    }

    private let metadataColumns = [
        GridItem(.adaptive(minimum: 90, maximum: 190), spacing: 8, alignment: .leading)
    ]

    private enum RecordingConfirmation: String, Identifiable {
        case cancel = "Cancel Recording"
        case stop = "Stop Recording"
        var id: Self { self }
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                detailLayout {
                VStack(spacing: 22) {
                    ChannelBadge(channel: channel, diameter: channelBadgeDiameter)

                    Text(channel.name)
                        .font(.title2.bold())
                }
                .frame(width: usesCompactLayout ? nil : channelColumnWidth)

                VStack(alignment: .leading, spacing: usesCompactLayout ? 20 : 16) {
                    if let program, program.isAiring(at: Date()) {
                        Text("LIVE NOW")
                            .font(.caption.bold())
                            .tracking(1.8)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.red, in: Capsule())
                    }

                    Text(program?.title ?? channel.name)
                        .font(titleFont)

                    if let subtitle = program?.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    if let program {
                        Label(
                            "\(program.start.formatted(date: .abbreviated, time: .shortened))–\(program.end.formatted(date: .omitted, time: .shortened))",
                            systemImage: "clock"
                        )
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(AppTheme.secondaryText)

                        if !metadataLabels.isEmpty {
#if os(macOS)
                            LazyVGrid(columns: metadataColumns, alignment: .leading, spacing: 8) {
                                ForEach(metadataLabels, id: \.self) { label in
                                    metadataBadge(label)
                                }
                            }
#else
                            HStack(spacing: 10) {
                                ForEach(metadataLabels, id: \.self) { label in
                                    metadataBadge(label)
                                }
                            }
                            .lineLimit(1)
#endif
                        }

                        Text(program.overview)
                            .font(overviewFont)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(8)
                    } else {
                        Text("No programme metadata is available for this channel at the moment.")
                            .font(.title3)
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    LazyVGrid(columns: actionColumns, alignment: .leading, spacing: 14) {
                        Button {
                            watchLive()
                        } label: {
                            Label("Watch Live", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.focused)

                        if let program, program.phase(at: Date()) != .past {
                            if let existingRecording {
                                if existingRecording.state == .recording {
                                    Button {
                                        playFromBeginning(existingRecording)
                                    } label: {
                                        Label("Play from Beginning", systemImage: "backward.end.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(AppTheme.surfaceRaised)
                                }

                                Button {
                                    confirmRecordingAction = existingRecording.state == .recording ? .stop : .cancel
                                } label: {
                                    Label(
                                        existingRecording.state == .recording ? "Stop Recording" : "Cancel Recording",
                                        systemImage: existingRecording.state == .recording ? "stop.fill" : "xmark"
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red.opacity(0.82))
                            } else {
                                Button {
                                    Task {
                                        await recordings.recordOnce(program, configuration: settings.configuration)
                                    }
                                } label: {
                                    if recordOnceActionKey.map(recordings.isPerforming) == true {
                                        Label("Scheduling…", systemImage: "hourglass")
                                    } else {
                                        Label("Record Once", systemImage: "record.circle")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(AppTheme.surfaceRaised)
                                .disabled(recordOnceActionKey.map(recordings.isPerforming) == true)

                            }

                            if !recordings.hasRecordAllRule(for: program) {
                                Button {
                                    Task {
                                        await recordings.recordAll(program, configuration: settings.configuration)
                                    }
                                } label: {
                                    if recordAllActionKey.map(recordings.isPerforming) == true {
                                        Label("Scheduling…", systemImage: "hourglass")
                                    } else {
                                        Label("Record All", systemImage: "rectangle.stack.badge.plus")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(AppTheme.surfaceRaised)
                                .disabled(recordAllActionKey.map(recordings.isPerforming) == true)
                            } else {
                                Label("Recording All", systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .foregroundStyle(AppTheme.accent)
                                    .padding(.horizontal, 16)
                            }
                        }

                    }
                    .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: detailMaximumWidth, alignment: .leading)
                .padding(detailPadding)
            }
        }
        .programmeDetailWindowSizing()
        .televisionPlayPauseCommand {
            watchLive()
        }
        .platformExitCommand { dismiss() }
        .confirmationDialog(
            confirmRecordingAction?.rawValue ?? "Confirm",
            isPresented: Binding(
                get: { confirmRecordingAction != nil },
                set: { if !$0 { confirmRecordingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = confirmRecordingAction {
                Button(action.rawValue, role: .destructive) {
                    guard let existingRecording else { return }
                    Task {
                        if action == .stop {
                            await recordings.stop(existingRecording, configuration: settings.configuration)
                        } else {
                            await recordings.cancel(existingRecording, configuration: settings.configuration)
                        }
                    }
                }
            }
            Button("Keep Recording", role: .cancel) {}
        }
        .alert(
            "Recording unavailable",
            isPresented: Binding(
                get: { recordings.errorMessage != nil },
                set: { if !$0 { recordings.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { recordings.errorMessage = nil }
        } message: {
            Text(recordings.errorMessage ?? "Unknown recording error")
        }
        .task {
            playback.prewarm(
                channel: channel,
                program: program,
                configuration: settings.configuration
            )
        }
        .onDisappear {
            playback.endPrewarming(channelID: channel.id)
        }
    }

    private func watchLive() {
        playback.start(
            channel: channel,
            program: program,
            configuration: settings.configuration
        )
        dismiss()
    }

    private func playFromBeginning(_ recording: TVRecording) {
        playback.start(
            recording: recording,
            channel: channel,
            configuration: settings.configuration
        )
        dismiss()
    }

    private func metadataBadge(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(AppTheme.surfaceRaised, in: Capsule())
    }
}

private extension View {
    @ViewBuilder
    func programmeDetailWindowSizing() -> some View {
#if os(macOS)
        frame(width: 900, height: 620)
#else
        self
#endif
    }
}
