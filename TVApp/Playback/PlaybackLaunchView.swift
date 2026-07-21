import SwiftUI

struct PlaybackLaunchView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @FocusState private var isFocused: Bool
    @State private var artwork: ChannelLogoArtwork?

    let presentation: PlaybackLaunchPresentation

    init(presentation: PlaybackLaunchPresentation) {
        self.presentation = presentation
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
                    platformImage(artwork.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .ignoresSafeArea()
            }

            LinearGradient(
                colors: artwork == nil
                    ? [presentation.channel.tint.opacity(0.34), AppTheme.background, .black]
                    : [.black.opacity(0.3), .black.opacity(0.66), .black.opacity(0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                ChannelBadge(channel: presentation.channel, diameter: 156)
                    .scaleEffect(isFocused ? 1.02 : 1)
                    .animation(
                        .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                        value: isFocused
                    )

                Text(presentation.channel.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            .padding(48)

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .accessibilityLabel("Opening \(presentation.channel.name)")

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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
#endif
        }
        .onAppear { isFocused = true }
        .platformExitCommand { playback.leavePlayer() }
    }
}
