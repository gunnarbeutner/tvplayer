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
