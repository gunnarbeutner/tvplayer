import SwiftUI

enum PlatformMoveDirection: Equatable {
    case up
    case down
    case left
    case right
}

extension View {
    @ViewBuilder
    func televisionGuideEdges() -> some View {
#if os(tvOS)
        ignoresSafeArea(.container, edges: [.horizontal, .bottom])
#else
        self
#endif
    }

    @ViewBuilder
    func televisionFocusScope(_ namespace: Namespace.ID) -> some View {
#if os(tvOS)
        focusScope(namespace)
#else
        self
#endif
    }

    @ViewBuilder
    func televisionDefaultFocus(_ preferred: Bool, in namespace: Namespace.ID) -> some View {
#if os(tvOS)
        prefersDefaultFocus(preferred, in: namespace)
#else
        self
#endif
    }

    /// Programme and recording details are full-screen on television and use
    /// the platform's normal resizable sheet presentation elsewhere.
    @ViewBuilder
    func platformDetailPresentation<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
#if os(tvOS)
        fullScreenCover(item: item, content: content)
#elseif os(macOS)
        sheet(item: item) { value in
            content(value)
                .frame(
                    minWidth: 700,
                    idealWidth: 820,
                    maxWidth: 900,
                    maxHeight: 720
                )
                .presentationSizing(.fitted)
                .overlay(alignment: .topTrailing) {
                    Button {
                        item.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.bold())
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(.regularMaterial, in: Circle())
                            .overlay {
                                Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityLabel("Close Details")
                    .help("Close")
                    .keyboardShortcut(.cancelAction)
                    .padding(16)
                }
        }
#else
        sheet(item: item) { value in
            content(value)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
#endif
    }

    /// The Siri Remote exposes a dedicated Play/Pause command. Touch and Mac
    /// surfaces present visible transport buttons instead.
    @ViewBuilder
    func televisionPlayPauseCommand(_ action: @escaping () -> Void) -> some View {
#if os(tvOS)
        onPlayPauseCommand(perform: action)
#else
        self
#endif
    }

    /// Directional commands exist on television remotes and Mac keyboards,
    /// but not in the touch-only iOS SwiftUI surface.
    @ViewBuilder
    func platformMoveCommand(_ action: @escaping (PlatformMoveDirection) -> Void) -> some View {
#if os(tvOS) || os(macOS)
        onMoveCommand { direction in
            switch direction {
            case .up: action(.up)
            case .down: action(.down)
            case .left: action(.left)
            case .right: action(.right)
            @unknown default: break
            }
        }
#else
        self
#endif
    }

    @ViewBuilder
    func platformExitCommand(_ action: @escaping () -> Void) -> some View {
#if os(tvOS) || os(macOS)
        onExitCommand(perform: action)
#else
        self
#endif
    }
}
