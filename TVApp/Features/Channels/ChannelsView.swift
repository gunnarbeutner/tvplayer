import SwiftUI

struct ChannelsView: View {
    let isSelected: Bool
    let onOpenSettings: () -> Void
    let focusRequest: UUID?

    init(
        isSelected: Bool,
        onOpenSettings: @escaping () -> Void,
        focusRequest: UUID? = nil
    ) {
        self.isSelected = isSelected
        self.onOpenSettings = onOpenSettings
        self.focusRequest = focusRequest
    }

    @EnvironmentObject private var model: GuideViewModel
    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var channelPreferences: ChannelPreferencesStore
    @FocusState private var focusedChannelID: GuideChannel.ID?
    @State private var detail: ProgrammeDetailPresentation?
    @State private var reorderedChannelID: GuideChannel.ID?

    private let columns = [
        GridItem(
            .adaptive(minimum: PlatformLayout.channelCardMinimumWidth),
            spacing: PlatformLayout.gridSpacing
        )
    ]

    private var displayedChannels: [GuideChannel] {
        channelPreferences.displayedChannels(from: model.channels)
    }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            if model.channels.isEmpty {
                TVSourceStateView(
                    state: model.loadState,
                    openSettings: onOpenSettings,
                    retry: {
                        Task {
                            await model.load(configuration: settings.configuration, force: true)
                        }
                    },
                    focusRequest: focusRequest
                )
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                            ForEach(displayedChannels) { channel in
                                ChannelCard(
                                    channel: channel,
                                    currentProgram: currentProgram(for: channel),
                                    isFavorite: channelPreferences.isFavorite(channel.id),
                                    isFocused: focusedChannelID == channel.id,
                                    isPlaying: playback.presentation?.recording == nil
                                        && playback.presentation?.channel.id == channel.id,
                                    onWatch: {
                                        playback.start(
                                            channel: channel,
                                            program: currentProgram(for: channel),
                                            configuration: settings.configuration
                                        )
                                    }
                                )
                                .id(channel.id)
                                .contentShape(RoundedRectangle(cornerRadius: 14))
                                .focusable()
                                .focused($focusedChannelID, equals: channel.id)
                                .focusEffectDisabled()
                                .onTapGesture {
                                    detail = ProgrammeDetailPresentation(
                                        program: currentProgram(for: channel),
                                        channel: channel
                                    )
                                }
                                .contextMenu {
                                    Button {
                                        toggleFavorite(channel.id)
                                    } label: {
                                        Label(
                                            channelPreferences.isFavorite(channel.id)
                                                ? "Remove Channel from Favourites"
                                                : "Add Channel to Favourites",
                                            systemImage: channelPreferences.isFavorite(channel.id)
                                                ? "star.slash"
                                                : "star"
                                        )
                                    }
                                }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction {
                                    detail = ProgrammeDetailPresentation(
                                        program: currentProgram(for: channel),
                                        channel: channel
                                    )
                                }
                                .accessibilityAction(
                                    named: channelPreferences.isFavorite(channel.id)
                                        ? "Remove Channel from Favourites"
                                        : "Add Channel to Favourites"
                                ) {
                                    toggleFavorite(channel.id)
                                }
                            }
                        }
                        .padding(.horizontal, PlatformLayout.contentPadding)
                        .padding(.vertical, PlatformLayout.contentVerticalPadding)
                    }
                    .onChange(of: channelPreferences.revision) { _, _ in
                        revealReorderedChannel(using: scrollProxy)
                    }
                }
            }
        }
        .platformDetailPresentation(item: $detail) { presentation in
            ProgrammeDetailView(
                presentation: presentation,
                onWatchLive: playFromDetails,
                onPlayFromBeginning: playRecordingFromDetails
            )
        }
        .televisionPlayPauseCommand {
            guard let channel = focusedChannel else { return }
            playback.start(
                channel: channel,
                program: currentProgram(for: channel),
                configuration: settings.configuration
            )
        }
        .onChange(of: focusedChannelID) { oldValue, newValue in
            guard let newValue, newValue != oldValue else { return }
            if isSelected { playback.cancelLivePlaybackPrefetch() }
            NavigationSoundPlayer.shared.play()
        }
        .onAppear { restorePlaybackFocusIfAvailable() }
        .onChange(of: isSelected) { _, selected in
            guard selected else {
                playback.cancelLivePlaybackPrefetch()
                return
            }
            restorePlaybackFocusIfAvailable()
        }
        .onChange(of: playback.focusReturnRevision) { _, _ in
            guard isSelected else { return }
            restorePlaybackFocusIfAvailable()
        }
        .onChange(of: focusRequest) { _, request in
            guard request != nil else { return }
            focusFirstChannel()
        }
        .onChange(of: channelPreferences.revision) { _, _ in
            guard let focusedChannelID,
                  !displayedChannels.contains(where: { $0.id == focusedChannelID })
            else { return }
            self.focusedChannelID = displayedChannels.first?.id
        }
#if os(tvOS)
        .onReceive(NotificationCenter.default.publisher(for: .tvChannelsPageCommand)) { note in
            guard isSelected,
                  let raw = note.userInfo?["direction"] as? Int,
                  let direction = TVPageDirection(rawValue: raw)
            else { return }
            pageChannels(direction)
        }
#endif
        .task(id: isSelected ? focusedChannelID : nil) {
            guard isSelected, let channel = focusedChannel else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, isSelected else { return }
            playback.prefetchLivePlaybackRequest(
                channelID: channel.id,
                configuration: settings.configuration
            )
        }
    }

    private var focusedChannel: GuideChannel? {
        guard let focusedChannelID else { return displayedChannels.first }
        return displayedChannels.first { $0.id == focusedChannelID }
    }

    private func currentProgram(for channel: GuideChannel) -> GuideProgram? {
        channel.programs.first { $0.isAiring(at: model.now) }
    }

    private func toggleFavorite(_ channelID: GuideChannel.ID) {
        reorderedChannelID = channelID
        channelPreferences.toggleFavorite(channelID)
    }

    private func revealReorderedChannel(using scrollProxy: ScrollViewProxy) {
        guard let channelID = reorderedChannelID else { return }
        reorderedChannelID = nil
        Task { @MainActor in
            // Let the LazyVGrid apply its new favourites-first ordering before
            // resolving the channel ID to a scroll position.
            await Task.yield()
            guard displayedChannels.contains(where: { $0.id == channelID }) else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                scrollProxy.scrollTo(channelID, anchor: .center)
            }
            focusedChannelID = channelID
        }
    }

    private func playFromDetails(_ channel: GuideChannel, _ program: GuideProgram?) {
        detail = nil
        playback.startAfterDetailDismissal(
            channel: channel,
            program: program,
            configuration: settings.configuration
        )
    }

    private func playRecordingFromDetails(_ recording: TVRecording, _ channel: GuideChannel) {
        detail = nil
        playback.startAfterDetailDismissal(
            recording: recording,
            channel: channel,
            configuration: settings.configuration
        )
    }

    private func restorePlaybackFocusIfAvailable() {
        guard let channelID = PlaybackFocusSelection.channelID(
            in: displayedChannels,
            selection: playback.navigationSelection
        ) else { return }

        Task { @MainActor in
            await Task.yield()
            guard isSelected else { return }
            focusedChannelID = channelID
        }
    }

    private func focusFirstChannel() {
        let channelID = PlaybackFocusSelection.channelID(
            in: displayedChannels,
            selection: playback.navigationSelection
        ) ?? displayedChannels.first?.id
        guard let channelID else { return }

        Task { @MainActor in
            await Task.yield()
            guard isSelected else { return }
            focusedChannelID = channelID
        }
    }

#if os(tvOS)
    private func pageChannels(_ direction: TVPageDirection) {
        guard !displayedChannels.isEmpty else { return }
        let current = focusedChannelID.flatMap { id in
            displayedChannels.firstIndex { $0.id == id }
        } ?? 0
        let target = min(max(0, current + direction.rawValue * 6), displayedChannels.count - 1)
        focusedChannelID = displayedChannels[target].id
    }
#endif
}

private struct ChannelCard: View {
    let channel: GuideChannel
    let currentProgram: GuideProgram?
    let isFavorite: Bool
    let isFocused: Bool
    let isPlaying: Bool
    let onWatch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                ChannelBadge(channel: channel, diameter: 78)

                Text(channel.name)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)

                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityLabel("Favourite channel")
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)

            Text(currentProgram?.title ?? "No guide information")
                .font(.title3.weight(.semibold))
                .foregroundStyle(isFocused ? .white : AppTheme.secondaryText)
                .lineLimit(4)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

#if !os(tvOS)
            Spacer(minLength: 0)
            Button(action: onWatch) {
                Label("Watch Live", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
#endif
        }
        .padding(24)
        .frame(height: cardHeight, alignment: .topLeading)
        .background(
            isFocused ? AppTheme.focused : (isPlaying ? AppTheme.playing : AppTheme.surface),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isFocused ? AppTheme.focusBorder : Color.white.opacity(0.16), lineWidth: isFocused ? 4 : 1)
        }
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Select for details. Press Play to watch live.")
    }

    private var cardHeight: CGFloat {
#if os(tvOS)
        280
#else
        240
#endif
    }
}
