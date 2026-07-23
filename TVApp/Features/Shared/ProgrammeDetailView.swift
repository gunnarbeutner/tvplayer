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
    let onWatchLive: (GuideChannel, GuideProgram?) -> Void
    let onPlayFromBeginning: (TVRecording, GuideChannel) -> Void

    private var program: GuideProgram? { presentation.program }
    private var channel: GuideChannel { presentation.channel }
    private var canWatchLive: Bool {
        program?.isAiring(at: Date()) ?? true
    }
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
        program?.metadata.displayLabels ?? []
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

    private enum RecordingConfirmation: String, Identifiable {
        case cancel = "Cancel Recording"
        case stop = "Stop Recording"
        var id: Self { self }
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

#if os(tvOS)
            GeometryReader { geometry in
                ScrollView {
                    detailContent
                        .frame(minHeight: geometry.size.height, alignment: .center)
                }
            }
#else
            ScrollView {
                detailContent
            }
#endif
        }
        .televisionPlayPauseCommand {
            if canWatchLive {
                watchLive()
            }
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

    private var detailContent: some View {
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
                        ProgrammeMetadataFlowLayout(spacing: 8) {
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

                    if !program.metadata.displayFacts.isEmpty {
                        Text(program.metadata.displayFacts.joined(separator: "  •  "))
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    Text(program.overview)
                        .font(overviewFont)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(8)

                    ForEach(
                        program.metadata.supplementaryDescriptions(
                            excluding: program.overview
                        ),
                        id: \.self
                    ) { description in
                        Text(description)
                            .font(overviewFont)
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(6)
                    }
                } else {
                    Text("No programme metadata is available for this channel at the moment.")
                        .font(.title3)
                        .foregroundStyle(AppTheme.secondaryText)
                }

                actionLayout
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: detailMaximumWidth, alignment: .leading)
        .padding(detailPadding)
    }

    @ViewBuilder
    private var actionLayout: some View {
#if os(tvOS)
        HStack(spacing: 20) {
            actionButtons
        }
#else
        LazyVGrid(columns: actionColumns, alignment: .leading, spacing: 14) {
            actionButtons
        }
#endif
    }

    @ViewBuilder
    private var actionButtons: some View {
        if canWatchLive {
            Button {
                watchLive()
            } label: {
                Label("Watch Live", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.focused)
        }

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

    private func watchLive() {
        guard canWatchLive else { return }
        onWatchLive(channel, program)
    }

    private func playFromBeginning(_ recording: TVRecording) {
        onPlayFromBeginning(recording, channel)
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

#if os(macOS)
/// A compact wrapping row for metadata pills. Adaptive grids force every pill
/// into an equal-width column, which truncates useful labels in narrow sheets.
private struct ProgrammeMetadataFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? .greatestFiniteMagnitude
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var usedHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width

            if rowWidth > 0, nextWidth > availableWidth {
                usedWidth = max(usedWidth, rowWidth)
                usedHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = nextWidth
                rowHeight = max(rowHeight, size.height)
            }
        }

        usedWidth = max(usedWidth, rowWidth)
        usedHeight += rowHeight
        return CGSize(
            width: proposal.width ?? usedWidth,
            height: usedHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var point = bounds.origin
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x > bounds.minX, point.x + size.width > bounds.maxX {
                point.x = bounds.minX
                point.y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(
                at: point,
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            point.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
