import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.035, green: 0.043, blue: 0.059)
    static let chrome = Color(red: 0.065, green: 0.078, blue: 0.105)
    static let surface = Color(red: 0.125, green: 0.145, blue: 0.185)
    static let surfaceRaised = Color(red: 0.17, green: 0.195, blue: 0.245)
    static let past = Color(red: 0.085, green: 0.098, blue: 0.125)
    static let current = Color(red: 0.075, green: 0.225, blue: 0.38)
    static let focused = Color(red: 0.0, green: 0.27, blue: 0.62)
    static let focusBorder = Color(red: 0.46, green: 0.88, blue: 1.0)
    static let accent = Color(red: 0.16, green: 0.72, blue: 1.0)
    static let divider = Color.white.opacity(0.14)
    static let secondaryText = Color.white.opacity(0.76)
}

enum GuideArtworkStyle {
    // tvOS lays out full-screen content in a 1920-point coordinate space,
    // including on 4K hardware where the backing scale is higher.
    static let televisionCanvasWidth: CGFloat = 1920
    static let televisionWidth: CGFloat = 680
    static let fadeMidpoint: CGFloat = 0.14
    static let fadeCompletion: CGFloat = 0.28

    static func backgroundClearWidth(for artworkWidth: CGFloat) -> CGFloat {
        artworkWidth * (1 - fadeCompletion)
    }
}

/// The shared backdrop behind the guide's information and navigation rows.
/// Keeping the gradient at full-screen width before clipping gives both rows
/// identical color stops while leaving the artwork region untouched.
struct GuideAmbientBackground: View {
    let tint: Color?
    var trailingClearWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppTheme.background
                LinearGradient(
                    colors: [tint?.opacity(0.18) ?? .clear, AppTheme.chrome, AppTheme.chrome],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .mask(alignment: .leading) {
                Rectangle()
                    .frame(width: max(0, proxy.size.width - trailingClearWidth))
            }
        }
    }
}
