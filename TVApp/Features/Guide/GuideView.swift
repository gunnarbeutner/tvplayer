import SwiftUI

struct GuideView: View {
    let isSelected: Bool
    let onOpenSettings: () -> Void
    let focusRequest: UUID?
    let onPresentedChannelChange: (GuideChannel.ID?) -> Void
    let onInitialFocusResolved: () -> Void
    let onExitToNavigator: () -> Void

    init(
        isSelected: Bool,
        onOpenSettings: @escaping () -> Void,
        focusRequest: UUID? = nil,
        onPresentedChannelChange: @escaping (GuideChannel.ID?) -> Void = { _ in },
        onInitialFocusResolved: @escaping () -> Void = {},
        onExitToNavigator: @escaping () -> Void = {}
    ) {
        self.isSelected = isSelected
        self.onOpenSettings = onOpenSettings
        self.focusRequest = focusRequest
        self.onPresentedChannelChange = onPresentedChannelChange
        self.onInitialFocusResolved = onInitialFocusResolved
        self.onExitToNavigator = onExitToNavigator
    }

    @Environment(\.scenePhase) private var scenePhase
#if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
#endif
    @EnvironmentObject private var model: GuideViewModel
    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var recordings: RecordingStore
    @EnvironmentObject private var channelPreferences: ChannelPreferencesStore
#if os(tvOS)
    @Environment(\.resetFocus) private var resetFocus
#endif
    @Namespace private var guideFocusScope
    @State private var focusedProgramID: GuideProgram.ID?
    @State private var recenterRequest = UUID()
    @State private var focusRestoreRequest = UUID()
    @State private var detail: ProgrammeDetailPresentation?
    @State private var needsInitialFocus = true
    @State private var showLoadingSkeleton = false

    private var displayedChannels: [GuideChannel] {
        channelPreferences.displayedChannels(from: model.channels)
    }

    private var presentedProgram: GuideProgram? {
        if let focused = model.program(withID: focusedProgramID),
           displayedChannels.contains(where: { $0.id == focused.channelID }) {
            return focused
        }
        return displayedChannels.lazy.flatMap(\.programs).first { $0.isAiring(at: Date()) }
    }

    private var preferredFocusProgramID: GuideProgram.ID? {
        let currentDate = Date()
        return PlaybackFocusSelection.programID(
            in: displayedChannels,
            selection: playback.navigationSelection,
            at: currentDate
        ) ?? GuideFocusSelection.initialProgram(
            in: displayedChannels.first?.programs ?? [],
            at: currentDate
        )?.id
    }

    private var retainedFocusProgramID: GuideProgram.ID? {
        guard let focusedProgramID,
              let focusedProgram = model.program(withID: focusedProgramID),
              displayedChannels.contains(where: { $0.id == focusedProgram.channelID })
        else { return nil }
        return focusedProgramID
    }

    private var presentedChannelID: GuideChannel.ID? {
        model.channel(containing: presentedProgram)?.id
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            if model.isColdLoading {
                ZStack {
                    // Keep a complete loading surface behind the delayed
                    // skeleton. Previously the skeleton began transparent,
                    // exposing only the black app background between mDNS
                    // configuration and the first renderable guide snapshot.
                    TVSourceStateView(
                        state: .loading,
                        openSettings: onOpenSettings,
                        retry: {}
                    )
                    .opacity(showLoadingSkeleton ? 0 : 1)

                    GuideLoadingSkeleton(
                        channels: model.channels,
                        timeline: model.timeline
                    )
                    .opacity(showLoadingSkeleton ? 1 : 0)
                }
            } else if !model.hasUsableGuide {
                TVSourceStateView(
                    state: model.loadState,
                    openSettings: onOpenSettings,
                    retry: {
                        Task {
                            await model.load(configuration: settings.configuration, force: true)
                        }
                    }
                )
            } else {
                if usesCompactGuide {
                    CompactGuideList(
                        channels: displayedChannels,
                        now: model.now,
                        focusedProgramID: $focusedProgramID,
                        isFavorite: channelPreferences.isFavorite,
                        recordingState: { recordings.scheduledRecording(for: $0)?.state },
                        onActivate: presentDetails,
                        onPlay: play,
                        onReady: {}
                    )
                } else {
                    VStack(spacing: 0) {
                        GuideInformationPanel(
                            program: presentedProgram,
                            channel: model.channel(containing: presentedProgram),
                            now: model.now,
                            loadState: model.loadState,
                            recordingState: presentedProgram.flatMap { recordings.scheduledRecording(for: $0)?.state },
                            usesCompactLayout: usesLandscapeGuide
                        )

                        GuideGridView(
                            channels: displayedChannels,
                            timeline: model.timeline,
                            now: model.now,
                            guideRevision: model.guideRevision,
                            channelPreferencesRevision: channelPreferences.revision,
                            preferredProgramID: preferredFocusProgramID,
                            focusScope: guideFocusScope,
                            focusedProgramID: $focusedProgramID,
                            recenterRequest: recenterRequest,
                            focusRestoreRequest: focusRestoreRequest,
                            recordingsRevision: recordings.guideRevision,
                            configuration: settings.configuration,
                            isFavorite: channelPreferences.isFavorite,
                            onToggleFavorite: channelPreferences.toggleFavorite,
                            recordingState: { recordings.scheduledRecording(for: $0)?.state },
                            onActivate: presentDetails,
                            onPlay: play,
                            onReady: focusGuideAfterInitialLayout,
                            onFocusAcquired: onInitialFocusResolved,
                            onExitToNavigator: onExitToNavigator
                        )
                        .televisionDefaultFocus(true, in: guideFocusScope)
                    }
                }
            }
        }
        // The root television header reserves its own vertical region. The
        // guide can still use the full horizontal and bottom television area.
        .televisionGuideEdges()
        .platformDetailPresentation(item: $detail) { presentation in
            ProgrammeDetailView(
                presentation: presentation,
                onWatchLive: playFromDetails,
                onPlayFromBeginning: playRecordingFromDetails
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await model.load(configuration: settings.configuration)
                recenterRequest = UUID()
            }
        }
        .onAppear {
            onPresentedChannelChange(presentedChannelID)
            resolveInitialFocusWithoutGuideIfNeeded()
            requestInitialFocus()
        }
        .onChange(of: model.isColdLoading) { _, _ in
            resolveInitialFocusWithoutGuideIfNeeded()
        }
        .onChange(of: model.hasUsableGuide) { _, _ in
            resolveInitialFocusWithoutGuideIfNeeded()
        }
        .onChange(of: presentedChannelID) { _, channelID in
            onPresentedChannelChange(channelID)
        }
        .onChange(of: isSelected) { _, selected in
            guard selected else {
                playback.cancelLivePlaybackPrefetch()
                return
            }
            requestInitialFocus()
        }
        .onChange(of: preferredFocusProgramID) { _, _ in
            guard isSelected, needsInitialFocus else { return }
            applyInitialFocusIfAvailable()
        }
        .onChange(of: playback.focusReturnRevision) { _, _ in
            guard isSelected else { return }
            restorePlaybackFocusIfAvailable()
        }
        .onChange(of: focusRequest) { _, request in
            guard request != nil else { return }
            focusGuideFromNavigator()
        }
        .onChange(of: usesCompactGuide) { _, _ in
            recenterRequest = UUID()
            requestInitialFocus()
        }
        .onChange(of: channelPreferences.revision) { _, _ in
            recenterRequest = UUID()
            restoreVisibleFocusOrSelectInitial()
        }
        .televisionPlayPauseCommand {
            guard let program = presentedProgram,
                  let channel = model.channel(containing: program)
            else { return }
            playback.start(channel: channel, program: program, configuration: settings.configuration)
        }
        .onChange(of: focusedProgramID) { oldValue, newValue in
            guard let newValue, newValue != oldValue else { return }
            if isSelected { playback.cancelLivePlaybackPrefetch() }
            NavigationSoundPlayer.shared.play()
        }
        .task(id: isSelected ? focusedProgramID : nil) {
            guard isSelected,
                  let focusedProgramID,
                  let program = model.program(withID: focusedProgramID),
                  let channel = model.channel(containing: program)
            else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, isSelected else { return }
            playback.prefetchLivePlaybackRequest(
                channelID: channel.id,
                configuration: settings.configuration
            )
        }
        .task(id: model.isColdLoading) {
            guard model.isColdLoading else {
                showLoadingSkeleton = false
                return
            }

            showLoadingSkeleton = false
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, model.isColdLoading else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                showLoadingSkeleton = true
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                model.tick()
            }
        }
    }

    private func requestInitialFocus() {
        needsInitialFocus = true
        applyInitialFocusIfAvailable()
    }

    private var usesCompactGuide: Bool {
#if os(iOS)
        horizontalSizeClass == .compact && !usesLandscapeGuide
#else
        false
#endif
    }

    private var usesLandscapeGuide: Bool {
#if os(iOS)
        verticalSizeClass == .compact
#else
        false
#endif
    }

    private func presentDetails(_ program: GuideProgram) {
        guard let channel = model.channel(containing: program) else { return }
        detail = ProgrammeDetailPresentation(program: program, channel: channel)
    }

    private func play(_ program: GuideProgram) {
        guard let channel = model.channel(containing: program) else { return }
        playback.start(
            channel: channel,
            program: program,
            configuration: settings.configuration
        )
    }

    private func playFromDetails(_ channel: GuideChannel, _ program: GuideProgram?) {
        detail = nil
        Task { @MainActor in
            await Task.yield()
            playback.start(
                channel: channel,
                program: program,
                configuration: settings.configuration
            )
        }
    }

    private func playRecordingFromDetails(_ recording: TVRecording, _ channel: GuideChannel) {
        detail = nil
        Task { @MainActor in
            await Task.yield()
            playback.start(
                recording: recording,
                channel: channel,
                configuration: settings.configuration
            )
        }
    }

    private func applyInitialFocusIfAvailable() {
        guard let programID = preferredFocusProgramID else { return }

        Task { @MainActor in
            // The guide's focusable cards need one layout pass before tvOS can
            // accept a programmatic focus assignment.
            await Task.yield()
            guard isSelected, needsInitialFocus else { return }
            focusedProgramID = programID
            needsInitialFocus = false
        }
    }

    private func restorePlaybackFocusIfAvailable() {
        guard let programID = PlaybackFocusSelection.programID(
            in: displayedChannels,
            selection: playback.navigationSelection,
            at: model.now
        ) else { return }

        needsInitialFocus = false
        Task { @MainActor in
            await Task.yield()
            guard isSelected else { return }
            guideFocusLogger.debug("restorePlaybackFocus: \(programID, privacy: .public), previous=\(String(describing: focusedProgramID), privacy: .public)")
            focusedProgramID = programID
            // The played programme is usually the one that was already
            // focused, so the binding may not change. Force the grid to
            // re-request UIKit focus regardless.
            focusRestoreRequest = UUID()
#if os(tvOS)
            // Re-enabling the underlying TabView can otherwise let its tab bar
            // win the first focus update before the guide is ready. Reset the
            // guide's scope after the representable has received this request.
            await Task.yield()
            guard isSelected else { return }
            resetFocus(in: guideFocusScope)
#endif
        }
    }

    private func focusGuideFromNavigator() {
        guard let programID = retainedFocusProgramID ?? preferredFocusProgramID else { return }
        needsInitialFocus = false

        Task { @MainActor in
            await Task.yield()
            guard isSelected else { return }
            focusedProgramID = programID
            focusRestoreRequest = UUID()
#if os(tvOS)
            await Task.yield()
            guard isSelected else { return }
            resetFocus(in: guideFocusScope)
#endif
        }
    }

    private func focusGuideAfterInitialLayout() {
        Task { @MainActor in
            // The top navigator and guide are installed in the same initial
            // focus pass. Wait until the collection has applied its first
            // snapshot, then explicitly hand focus to its preferred card.
            await Task.yield()
            guard isSelected, let programID = preferredFocusProgramID else { return }
            needsInitialFocus = false
            focusedProgramID = programID
            focusRestoreRequest = UUID()
#if os(tvOS)
            await Task.yield()
            guard isSelected else { return }
            resetFocus(in: guideFocusScope)
#endif
        }
    }

    private func resolveInitialFocusWithoutGuideIfNeeded() {
        guard !model.isColdLoading, !model.hasUsableGuide else { return }
        onInitialFocusResolved()
    }

    private func restoreVisibleFocusOrSelectInitial() {
        if let focusedProgramID,
           displayedChannels.lazy.flatMap(\.programs).contains(where: { $0.id == focusedProgramID }) {
            needsInitialFocus = false
            focusRestoreRequest = UUID()
        } else {
            self.focusedProgramID = nil
            requestInitialFocus()
        }
    }
}

private struct CompactGuideList: View {
    let channels: [GuideChannel]
    let now: Date
    @Binding var focusedProgramID: GuideProgram.ID?
    let isFavorite: (GuideChannel.ID) -> Bool
    let recordingState: (GuideProgram) -> TVRecordingState?
    let onActivate: (GuideProgram) -> Void
    let onPlay: (GuideProgram) -> Void
    let onReady: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(channels) { channel in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            ChannelBadge(channel: channel, diameter: 44)
                            Text(channel.name)
                                .font(.headline)
                            if isFavorite(channel.id) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(AppTheme.accent)
                                    .accessibilityLabel("Favourite channel")
                            }
                            Spacer()
                        }

                        ForEach(upcomingPrograms(for: channel)) { program in
                            HStack(spacing: 10) {
                                Button {
                                    focusedProgramID = program.id
                                    onActivate(program)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 7) {
                                            if let state = recordingState(program) {
                                                Image(systemName: state == .recording ? "record.circle.fill" : "clock.fill")
                                                    .foregroundStyle(state == .recording ? .red : AppTheme.accent)
                                            }
                                            Text(program.title)
                                                .font(.body.weight(.semibold))
                                                .lineLimit(2)
                                        }
                                        Text("\(program.start.formatted(date: .omitted, time: .shortened))–\(program.end.formatted(date: .omitted, time: .shortened))")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(AppTheme.secondaryText)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if program.isAiring(at: now) {
                                    Button {
                                        onPlay(program)
                                    } label: {
                                        Image(systemName: "play.fill")
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityLabel("Watch \(program.title)")
                                }
                            }
                            .padding(14)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
            }
            .padding(PlatformLayout.contentPadding)
        }
        .navigationTitle("Guide")
        .onAppear(perform: onReady)
    }

    private func upcomingPrograms(for channel: GuideChannel) -> [GuideProgram] {
        Array(channel.programs.filter { $0.end > now }.prefix(4))
    }
}

private struct GuideLoadingSkeleton: View {
    let channels: [GuideChannel]
    let timeline: GuideTimeline

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
#if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
#endif
    @State private var isDimmed = false

    private var usesCompactLayout: Bool {
#if os(iOS)
        verticalSizeClass == .compact
#else
        false
#endif
    }

    private var informationPanelHeight: CGFloat {
        guard !usesCompactLayout else { return 100 }
        return GuideArtworkStyle.panelHeight
    }

    private var artworkPlaceholderWidth: CGFloat {
        GuideArtworkStyle.artworkWidth
    }

    var body: some View {
        GeometryReader { geometry in
            let rowCount = visibleRowCount(for: geometry.size.height)

            VStack(spacing: 0) {
                informationPlaceholder

                VStack(spacing: 0) {
                    timelinePlaceholder

                    ForEach(0..<rowCount, id: \.self) { index in
                        HStack(spacing: 0) {
                            channelPlaceholder(at: index)
                            programmePlaceholders(for: index)
                        }
                        .frame(height: GuideGridMetrics.rowHeight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .clipped()
                .opacity(isDimmed ? 0.48 : 0.78)
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topLeading
            )
            .background(AppTheme.background)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background.ignoresSafeArea())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading programme guide")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                isDimmed = true
            }
        }
    }

    private func visibleRowCount(for availableHeight: CGFloat) -> Int {
        let rowsHeight = max(
            0,
            availableHeight - informationPanelHeight - GuideGridMetrics.headerHeight
        )
        return max(1, Int(ceil(rowsHeight / GuideGridMetrics.rowHeight)))
    }

    private var informationPlaceholder: some View {
        HStack(spacing: usesCompactLayout ? 16 : 28) {
            Circle()
                .fill(AppTheme.surfaceRaised)
                .frame(
                    width: usesCompactLayout ? 54 : 84,
                    height: usesCompactLayout ? 54 : 84
                )

            VStack(alignment: .leading, spacing: usesCompactLayout ? 8 : 12) {
                placeholder(width: usesCompactLayout ? 260 : 520, height: usesCompactLayout ? 20 : 28)
                placeholder(width: usesCompactLayout ? 180 : 360, height: 18)
                if !usesCompactLayout {
                    placeholder(width: 440, height: 18)
                }
            }

            Spacer()

            if !usesCompactLayout {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.surfaceRaised)
                    .frame(width: artworkPlaceholderWidth, height: informationPanelHeight)
            }
        }
        .padding(.leading, usesCompactLayout ? 20 : 72)
        .frame(
            maxWidth: .infinity,
            minHeight: informationPanelHeight,
            maxHeight: informationPanelHeight
        )
        .background(AppTheme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
    }

    private var timelinePlaceholder: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                Text("NOW")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
            }
            .foregroundStyle(AppTheme.accent.opacity(0.7))
            .frame(width: GuideGridMetrics.channelWidth, height: GuideGridMetrics.headerHeight)
            .background(AppTheme.chrome)

            HStack(spacing: 0) {
                ForEach(Array(timeline.halfHourMarks.prefix(6)), id: \.self) { mark in
                    Text(mark.formatted(date: .omitted, time: .shortened))
                        .font(.headline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white.opacity(0.52))
                        .frame(width: GuideTimeline.pointsPerHour / 2, alignment: .leading)
                }
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(AppTheme.chrome)
            .clipped()
        }
        .frame(height: GuideGridMetrics.headerHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
    }

    @ViewBuilder
    private func channelPlaceholder(at index: Int) -> some View {
        if channels.indices.contains(index) {
            let channel = channels[index]
            HStack(spacing: 12) {
                ChannelBadge(channel: channel, diameter: 48)
                Text(channel.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(3)
                    .minimumScaleFactor(0.65)
                    .allowsTightening(true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(width: GuideGridMetrics.channelWidth, height: GuideGridMetrics.cardHeight)
            .background(AppTheme.chrome, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.vertical, GuideGridMetrics.rowInset)
            .background(AppTheme.chrome)
        } else {
            HStack(spacing: 12) {
                Circle()
                    .fill(AppTheme.surfaceRaised)
                    .frame(width: 48, height: 48)
                placeholder(width: 140, height: 18)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(width: GuideGridMetrics.channelWidth, height: GuideGridMetrics.cardHeight)
            .padding(.vertical, GuideGridMetrics.rowInset)
            .background(AppTheme.chrome)
        }
    }

    private func programmePlaceholders(for row: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { column in
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.surfaceRaised)
                    .frame(width: placeholderWidth(row: row, column: column))
            }
        }
        .padding(.vertical, GuideGridMetrics.rowInset)
        .padding(.leading, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(row.isMultiple(of: 2) ? AppTheme.background : AppTheme.chrome.opacity(0.42))
        .clipped()
    }

    private func placeholderWidth(row: Int, column: Int) -> CGFloat {
        let widths: [[CGFloat]] = [
            [330, 500, 260],
            [460, 310, 420],
            [250, 560, 320],
        ]
        return widths[row % widths.count][column]
    }

    private func placeholder(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(AppTheme.surfaceRaised)
            .frame(width: width, height: height)
    }
}

private struct GuideInformationPanel: View {
    let program: GuideProgram?
    let channel: GuideChannel?
    let now: Date
    let loadState: GuideLoadState
    let recordingState: TVRecordingState?
    let usesCompactLayout: Bool

    @EnvironmentObject private var playback: PlaybackCoordinator

    private var artworkURL: URL? {
        program?.metadata.imageURL.flatMap(URL.init(string:))
    }

    private var metadataDescription: String? {
        guard let metadata = program?.metadata else { return nil }
        var labels: [String] = []

        if let season = metadata.seasonNumber, let episode = metadata.episodeNumber {
            labels.append("Season \(season) · Episode \(episode)")
        } else if let season = metadata.seasonNumber {
            labels.append("Season \(season)")
        } else if let episode = metadata.episodeNumber {
            labels.append("Episode \(episode)")
        }
        if let part = metadata.partNumber { labels.append("Part \(part)") }
        labels.append(contentsOf: metadata.categories.prefix(2))
        if metadata.isNew { labels.append("New") }
        if metadata.isHD { labels.append("HD") }
        if metadata.isWidescreen { labels.append("Widescreen") }
        if metadata.isSubtitled { labels.append("Subtitles") }
        if let rating = metadata.ratingLabel ?? metadata.ageRating { labels.append(rating) }
        if let stars = metadata.starRating { labels.append("★ \(stars)") }

        return labels.isEmpty ? nil : labels.joined(separator: "  •  ")
    }

    private var status: (String, Color)? {
        switch loadState {
        case .needsConfiguration:
            return ("Configure TVHeadend in Settings", .orange)
        case .loading:
            return ("Updating guide…", AppTheme.accent)
        case .loaded:
            return nil
        case let .failed(message):
            return (message, .red)
        }
    }

    private var timingDescription: String? {
        guard let program else { return nil }

        switch program.phase(at: now) {
        case .current:
            let minutes = max(1, Int(ceil(program.end.timeIntervalSince(now) / 60)))
            let hours = minutes / 60
            let remainder = minutes % 60
            if hours > 0, remainder > 0 { return "\(hours) hr \(remainder) min left" }
            if hours > 0 { return "\(hours) hr left" }
            return "\(minutes) min left"
        case .future:
            return "Starts \(program.start.formatted(date: .omitted, time: .shortened))"
        case .past:
            return "Ended \(program.end.formatted(date: .omitted, time: .shortened))"
        }
    }

    private var regularPanelHeight: CGFloat {
        GuideArtworkStyle.panelHeight
    }

    private var regularArtworkWidth: CGFloat {
        GuideArtworkStyle.artworkWidth
    }

    private var artworkTopBleed: CGFloat {
        GuideArtworkStyle.artworkTopBleed
    }

    private var regularLeadingPadding: CGFloat {
#if os(tvOS)
        72
#else
        32
#endif
    }

    private var regularTitleFont: Font {
#if os(tvOS)
        .system(size: 30, weight: .bold)
#else
        .title2.weight(.bold)
#endif
    }

    private var regularSubtitleFont: Font {
#if os(tvOS)
        .system(size: 24, weight: .semibold)
#else
        .headline.weight(.semibold)
#endif
    }

    var body: some View {
        Group {
            if usesCompactLayout {
                compactContent
            } else {
                regularContent
            }
        }
        .background {
            GuideAmbientBackground(
                tint: channel?.tint,
                trailingClearWidth: usesCompactLayout
                    ? 0
                    : GuideArtworkStyle.backgroundClearWidth(for: regularArtworkWidth)
            )
        }
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private var compactContent: some View {
        HStack(alignment: .center, spacing: 16) {
            if let channel {
                ChannelBadge(channel: channel, diameter: 54)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(program?.title ?? "Choose a programme")
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .layoutPriority(1)

                    if let program, program.isAiring(at: now) {
                        Text("LIVE")
                            .font(.caption2.weight(.black))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .foregroundStyle(.white)
                            .background(.red, in: Capsule())
                            .accessibilityLabel("Currently airing")
                    }

                    if let recordingState {
                        Image(systemName: recordingState == .recording ? "record.circle.fill" : "clock.fill")
                            .foregroundStyle(recordingState == .recording ? .red : AppTheme.focused)
                            .accessibilityLabel(recordingState == .recording ? "Recording" : "Scheduled")
                    }
                }

                if let subtitle = program?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }

                if let program {
                    HStack(spacing: 7) {
                        if let channel {
                            Text(channel.name)
                            Text("•")
                        }
                        Text("\(program.start.formatted(date: .omitted, time: .shortened))–\(program.end.formatted(date: .omitted, time: .shortened))")
                        if let timingDescription {
                            Text("•")
                            Text(timingDescription)
                        }
                    }
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let status {
                    Text(status.0)
                        .foregroundStyle(status.1)
                } else if let overview = program?.overview, !overview.isEmpty {
                    Text(overview)
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .font(.caption)
            .lineLimit(3)
            .frame(maxWidth: 240, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 100, alignment: .leading)
    }

    private var regularContent: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 16) {
                    Group {
                        if let channel {
                            ChannelBadge(channel: channel, diameter: 64)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 64, height: 64, alignment: .topLeading)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 12) {
                            Text(program?.title ?? "Choose a programme")
                                .font(regularTitleFont)
                                .lineLimit(2)
                                .layoutPriority(1)

                            if let program, program.isAiring(at: now) {
                                Text("LIVE")
                                    .font(.caption2.weight(.black))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .foregroundStyle(.white)
                                    .background(.red, in: Capsule())
                                    .accessibilityLabel("Currently airing")
                            }

                            if let recordingState {
                                Label(
                                    recordingState == .recording ? "RECORDING" : "SCHEDULED",
                                    systemImage: recordingState == .recording ? "record.circle.fill" : "clock.fill"
                                )
                                .font(.caption2.weight(.black))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .foregroundStyle(.white)
                                .background(recordingState == .recording ? Color.red : AppTheme.focused, in: Capsule())
                            }
                        }

                        if let subtitle = program?.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(regularSubtitleFont)
                                .foregroundStyle(.white.opacity(0.88))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let program {
                    HStack(spacing: 10) {
                        if let channel {
                            Text(channel.name)
                            Text("•")
                        }
                        Text(program.start.formatted(date: .abbreviated, time: .omitted))
                        Text("•")
                        Text("\(program.start.formatted(date: .omitted, time: .shortened))–\(program.end.formatted(date: .omitted, time: .shortened))")
                        if let timingDescription {
                            Text("•")
                            Text(timingDescription)
                        }
                    }
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                }

                if let metadataDescription {
                    Text(metadataDescription)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .lineLimit(1)
                }

                if let status {
                    Text(status.0)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(status.1)
                        .lineLimit(2)
                } else {
                    Text(program?.overview ?? "Move focus into the guide to see programme information.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(5)
                        .frame(minHeight: 90, alignment: .topLeading)
                        .layoutPriority(1)
                }
            }
            .padding(.leading, regularLeadingPadding)
            .padding(.trailing, 32)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            ProgrammeArtworkView(
                url: artworkURL,
                engine: playback.engine,
                selectedChannelID: channel?.id,
                playerChannelID: playback.presentation?.channel.id,
                isPlayerPresented: playback.isPlayerPresented,
                isLivePlayback: playback.isUserInitiatedLivePlayback
            )
                .frame(
                    width: regularArtworkWidth,
                    height: regularPanelHeight + artworkTopBleed
                )
                .offset(y: -artworkTopBleed)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: regularPanelHeight,
            maxHeight: regularPanelHeight,
            alignment: .topLeading
        )
    }
}

private struct ProgrammeArtworkView: View {
    let url: URL?
    @ObservedObject var engine: VLCPlaybackEngine
    let selectedChannelID: GuideChannel.ID?
    let playerChannelID: GuideChannel.ID?
    let isPlayerPresented: Bool
    let isLivePlayback: Bool

    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @State private var loadedArtwork: ChannelLogoArtwork?
    @State private var loadedKey: String?

    private var currentKey: String? {
        url.map(ChannelLogoImageCache.cacheKey)
    }

    private var displayedArtwork: ChannelLogoArtwork? {
        if loadedKey == currentKey, let loadedArtwork { return loadedArtwork }
        guard let url else { return nil }
        return ChannelLogoImageCache.shared.memoryArtwork(for: url, kind: .programmeArtwork)
    }

    private var pausedPlayerFrame: PlatformImage? {
        guard engine.state == .paused,
              selectedChannelID != nil,
              selectedChannelID == playerChannelID
        else { return nil }
        return engine.pausedFrame
    }

    private var showsLivePlayer: Bool {
        guard !isPlayerPresented,
              isLivePlayback
        else { return false }

        // VLC can keep producing audio/video while its delegate briefly
        // reports an idle or failed transition during drawable replacement.
        // The native output flags are authoritative for the embedded preview.
        if engine.state == .paused { return false }
        if engine.mediaPlayer.isPlaying || engine.mediaPlayer.hasVideoOut {
            return true
        }

        switch engine.state {
        case .preparing, .playing, .recovering:
            return true
        case .idle, .paused, .failed:
            return false
        }
    }

    var body: some View {
        Group {
            if showsLivePlayer {
                // The single persistent VLC drawable sits behind the guide
                // and is resized to this artwork rectangle. Keeping this
                // branch transparent avoids moving a live VLC output between
                // native views, which is unreliable during playback.
#if os(macOS)
                Button(action: playback.returnToPlayer) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Return to full-screen player")
#else
                Color.clear
#endif
            } else {
                ZStack {
                    // Continue the ambient header colour through the reserved
                    // artwork area while an image is loading (or unavailable).
                    // This avoids exposing the black player layer at the point
                    // where the shared header gradient becomes transparent.
                    AppTheme.chrome

                    if let pausedPlayerFrame {
                        platformImage(pausedPlayerFrame)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    } else if let artwork = displayedArtwork {
                        platformImage(artwork.image)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    }
                }
                .mask { artworkMask }
                // A cache miss has two state changes: old artwork -> empty,
                // then empty -> newly decoded artwork. Animating both lets
                // their opacity transitions overlap and briefly brings the
                // previous channel's image back over the new one. Remove a
                // stale image immediately; animate only a ready replacement.
                .animation(
                    displayedArtwork == nil ? nil : .easeOut(duration: 0.24),
                    value: artworkTransitionKey
                )
            }
        }
        .clipped()
#if os(macOS)
        .accessibilityHidden(!showsLivePlayer)
#else
        .accessibilityHidden(true)
#endif
        .task(id: ProgrammeArtworkLoadID(url: url, settingsRevision: settings.revision)) {
            await loadArtwork()
        }
    }

    private var artworkTransitionKey: String? {
        displayedArtwork == nil ? nil : currentKey
    }

    private var artworkMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.48), location: GuideArtworkStyle.fadeMidpoint),
                .init(color: .black, location: GuideArtworkStyle.fadeCompletion),
                .init(color: .black, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func platformImage(_ image: PlatformImage) -> Image {
#if canImport(UIKit)
        return Image(uiImage: image)
#else
        return Image(nsImage: image)
#endif
    }

    @MainActor
    private func loadArtwork() async {
        guard let url else {
            loadedArtwork = nil
            loadedKey = nil
            return
        }

        let key = ChannelLogoImageCache.cacheKey(for: url)
        if let artwork = ChannelLogoImageCache.shared.memoryArtwork(
            for: url,
            kind: .programmeArtwork
        ) {
            loadedArtwork = artwork
            loadedKey = key
            return
        }

        loadedArtwork = nil
        loadedKey = nil
        do {
            let artwork = try await ChannelLogoDataLoader.shared.artwork(
                at: url,
                configuration: settings.configuration,
                kind: .programmeArtwork
            )
            guard !Task.isCancelled else { return }
            loadedArtwork = artwork
            loadedKey = key
        } catch {
            // Artwork is optional; retain the quiet placeholder on failure.
        }
    }
}

private struct ProgrammeArtworkLoadID: Hashable {
    let url: URL?
    let settingsRevision: Int
}
