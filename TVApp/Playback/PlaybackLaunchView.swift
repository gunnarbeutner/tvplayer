import SwiftUI

struct PlaybackLaunchView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @ObservedObject var engine: VLCPlaybackEngine
    @FocusState private var isFocused: Bool
    @State private var artwork: ChannelLogoArtwork?
    @State private var showsTuningIndicator = false

    let presentation: PlaybackLaunchPresentation

    init(
        presentation: PlaybackLaunchPresentation,
        engine: VLCPlaybackEngine
    ) {
        self.presentation = presentation
        self.engine = engine
        let url = presentation.program?.metadata.imageURL.flatMap(URL.init(string:))
        _artwork = State(initialValue: url.flatMap {
            ChannelLogoImageCache.shared.memoryArtwork(for: $0, kind: .programmeArtwork)
        })
    }

    private func platformImage(_ image: PlatformImage) -> Image {
#if canImport(UIKit)
        Image(uiImage: image)
#else
        Image(nsImage: image)
#endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let artwork {
                GeometryReader { geometry in
                    let edgeRadius = max(geometry.size.width, geometry.size.height) * 0.72
                    let labelRadius = max(geometry.size.width, geometry.size.height) * 0.56

                    ZStack {
                        platformImage(artwork.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()

                        RadialGradient(
                            stops: [
                                .init(color: .clear, location: 0.56),
                                .init(color: .black.opacity(0.28), location: 1),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: edgeRadius
                        )

                        RadialGradient(
                            colors: [
                                .black.opacity(0.58),
                                .black.opacity(0.24),
                                .clear,
                            ],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: labelRadius
                        )
                    }
                }
                .ignoresSafeArea()
            } else {
                LinearGradient(
                    colors: [presentation.channel.tint.opacity(0.34), AppTheme.background, .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 14) {
                ChannelBadge(channel: presentation.channel, diameter: 112)

                Text(presentation.channel.name)
                    .font(.headline.bold())
                    .lineLimit(1)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            launchStatus

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .accessibilityLabel(accessibilityStatus)

#if !os(tvOS)
            Button {
                playback.leavePlayer()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.72), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel Playback")
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
#endif
        }
        .onAppear { isFocused = true }
        .task(id: presentation.id) {
            showsTuningIndicator = false
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                showsTuningIndicator = true
            }
        }
        .platformExitCommand { playback.leavePlayer() }
    }

    @ViewBuilder
    private var launchStatus: some View {
        if let message = failureMessage {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.orange)

                Text("Unable to Play This Channel")
                    .font(.title2.bold())

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(maxWidth: 520)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
            .padding(40)
        } else if showsTuningIndicator {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(loadingMessage)
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var loadingMessage: String {
        if case let .recovering(reason, _) = engine.state {
            return reason.message
        }
        return "Tuning \(presentation.channel.name)…"
    }

    private var accessibilityStatus: String {
        if let message = failureMessage {
            return "Unable to play \(presentation.channel.name). \(message)"
        }
        return "Opening \(presentation.channel.name)"
    }

    private var failureMessage: String? {
        if let message = playback.launchFailureMessage { return message }
        if case let .failed(message) = engine.state { return message }
        return nil
    }
}
