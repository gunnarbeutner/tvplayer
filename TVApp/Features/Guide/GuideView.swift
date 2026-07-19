import SwiftUI

struct GuideView: View {
    let onOpenSettings: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: GuideViewModel
    @EnvironmentObject private var settings: ServerSettingsStore
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var recordings: RecordingStore
    @FocusState private var focusedProgramID: GuideProgram.ID?
    @State private var recenterRequest = UUID()
    @State private var detail: ProgrammeDetailPresentation?

    private var presentedProgram: GuideProgram? {
        model.program(withID: focusedProgramID) ?? model.firstCurrentProgram
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
                    }
                )
            } else {
                VStack(spacing: 0) {
                    GuideInformationPanel(
                        program: presentedProgram,
                        channel: model.channel(containing: presentedProgram),
                        now: model.now,
                        loadState: model.loadState,
                        recordingState: presentedProgram.flatMap { recordings.scheduledRecording(for: $0)?.state }
                    )

                    GuideGridView(
                        channels: model.channels,
                        timeline: model.timeline,
                        now: model.now,
                        focusedProgramID: $focusedProgramID,
                        recenterRequest: recenterRequest,
                        recordingState: { recordings.scheduledRecording(for: $0)?.state },
                        onActivate: { program in
                            guard let channel = model.channel(containing: program) else { return }
                            detail = ProgrammeDetailPresentation(program: program, channel: channel)
                        }
                    )
                }
            }
        }
        .fullScreenCover(item: $detail) { presentation in
            ProgrammeDetailView(presentation: presentation)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await model.load(configuration: settings.configuration)
                recenterRequest = UUID()
            }
        }
        .onPlayPauseCommand {
            guard let program = presentedProgram,
                  let channel = model.channel(containing: program)
            else { return }
            playback.start(channel: channel, program: program, configuration: settings.configuration)
        }
        .onChange(of: focusedProgramID) { oldValue, newValue in
            guard let newValue, newValue != oldValue else { return }
            NavigationSoundPlayer.shared.play()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                model.tick()
            }
        }
    }
}

private struct GuideInformationPanel: View {
    let program: GuideProgram?
    let channel: GuideChannel?
    let now: Date
    let loadState: GuideLoadState
    let recordingState: TVRecordingState?

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

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 10) {
                if let channel {
                    ChannelBadge(channel: channel, diameter: 84)

                    Text(channel.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            // Keep the channel identity anchored independently of the
            // selected programme's title, subtitle, and metadata lengths.
            .frame(width: 150, height: 126, alignment: .top)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Text(program?.title ?? "Choose a programme")
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

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
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }

                if let program {
                    HStack(spacing: 10) {
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

            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(program?.overview ?? "Move focus into the guide to see programme information.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(3)
                .frame(width: 400, alignment: .leading)

        }
        .padding(.horizontal, 72)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 154, maxHeight: 154, alignment: .topLeading)
        .background {
            LinearGradient(
                colors: [channel?.tint.opacity(0.18) ?? .clear, AppTheme.chrome, AppTheme.chrome],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .overlay(alignment: .topTrailing) {
            if let status {
                Text(status.0)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(status.1)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 360, alignment: .trailing)
                    .padding(.top, 16)
                    .padding(.trailing, 72)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(AppTheme.divider).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}
