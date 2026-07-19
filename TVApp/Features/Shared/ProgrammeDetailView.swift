import SwiftUI

struct ProgrammeDetailPresentation: Identifiable {
    let id = UUID()
    let program: GuideProgram?
    let channel: GuideChannel
}

struct ProgrammeDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var playback: PlaybackCoordinator

    let presentation: ProgrammeDetailPresentation

    private var program: GuideProgram? { presentation.program }
    private var channel: GuideChannel { presentation.channel }

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()

            HStack(spacing: 54) {
                VStack(spacing: 22) {
                    ChannelBadge(channel: channel, diameter: 132)

                    Text(channel.name)
                        .font(.title2.bold())
                }
                .frame(width: 280)

                VStack(alignment: .leading, spacing: 20) {
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
                        .font(.largeTitle.bold())

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

                        Text(program.overview)
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(8)
                    } else {
                        Text("No programme metadata is available for this channel at the moment.")
                            .font(.title3)
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    HStack(spacing: 20) {
                        Button {
                            playback.start(
                                channel: channel,
                                program: program,
                                configuration: settings.configuration
                            )
                        } label: {
                            Label("Watch Live", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.focused)

                        Button("Back", action: { dismiss() })
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.surfaceRaised)
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 1_720, alignment: .leading)
            .padding(80)
        }
        .onPlayPauseCommand {
            playback.start(
                channel: channel,
                program: program,
                configuration: settings.configuration
            )
        }
    }
}
