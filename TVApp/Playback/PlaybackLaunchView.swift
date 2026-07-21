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

            VStack(alignment: .leading, spacing: 14) {
                ChannelBadge(channel: presentation.channel, diameter: 112)

                Text(presentation.channel.name)
                    .font(.headline.bold())
                    .lineLimit(1)
            }
            .padding(.horizontal, 72)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
#endif
        }
        .onAppear { isFocused = true }
        .platformExitCommand { playback.leavePlayer() }
    }
}
