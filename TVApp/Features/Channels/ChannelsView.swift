import SwiftUI

struct ChannelsView: View {
    @EnvironmentObject private var model: GuideViewModel
    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @FocusState private var focusedChannelID: GuideChannel.ID?
    @State private var detail: ProgrammeDetailPresentation?

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 500), spacing: 30),
        count: 3
    )

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CHANNELS")
                            .font(.caption.bold())
                            .tracking(2.2)
                            .foregroundStyle(AppTheme.accent)
                        Text("Watch live TV")
                            .font(.largeTitle.bold())
                    }

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                        ForEach(model.channels) { channel in
                            ChannelCard(
                                channel: channel,
                                currentProgram: currentProgram(for: channel),
                                isFocused: focusedChannelID == channel.id
                            )
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
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction {
                                detail = ProgrammeDetailPresentation(
                                    program: currentProgram(for: channel),
                                    channel: channel
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 72)
                .padding(.vertical, 34)
            }
        }
        .fullScreenCover(item: $detail) { presentation in
            ProgrammeDetailView(presentation: presentation)
        }
        .onPlayPauseCommand {
            guard let channel = focusedChannel else { return }
            playback.start(
                channel: channel,
                program: currentProgram(for: channel),
                configuration: settings.configuration
            )
        }
    }

    private var focusedChannel: GuideChannel? {
        guard let focusedChannelID else { return model.channels.first }
        return model.channels.first { $0.id == focusedChannelID }
    }

    private func currentProgram(for channel: GuideChannel) -> GuideProgram? {
        channel.programs.first { $0.isAiring(at: model.now) }
    }
}

private struct ChannelCard: View {
    let channel: GuideChannel
    let currentProgram: GuideProgram?
    let isFocused: Bool

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
        }
        .padding(24)
        .frame(height: 280, alignment: .topLeading)
        .background(isFocused ? AppTheme.focused : AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isFocused ? AppTheme.focusBorder : Color.white.opacity(0.16), lineWidth: isFocused ? 4 : 1)
        }
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Select for details. Press Play to watch live.")
    }
}
