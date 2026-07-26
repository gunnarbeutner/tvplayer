import QuartzCore
import SwiftUI

enum AppTheme {
    static let background = Color(red: 0.035, green: 0.043, blue: 0.059)
    static let chrome = Color(red: 0.065, green: 0.078, blue: 0.105)
    static let surface = Color(red: 0.125, green: 0.145, blue: 0.185)
    static let surfaceRaised = Color(red: 0.17, green: 0.195, blue: 0.245)
    static let past = Color(red: 0.085, green: 0.098, blue: 0.125)
    static let current = Color(red: 0.075, green: 0.225, blue: 0.38)
    static let playing = Color(red: 0.055, green: 0.315, blue: 0.255)
    static let focusedPlaying = Color(red: 0.035, green: 0.43, blue: 0.335)
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
#if os(tvOS)
    static let artworkWidth: CGFloat = 680
    static let panelHeight: CGFloat = 340
    static let artworkTopBleed: CGFloat = 84
#else
    static let artworkWidth: CGFloat = 440
    static let panelHeight: CGFloat = 270
    static let artworkTopBleed: CGFloat = 0
#endif
    static let previewHeight = panelHeight + artworkTopBleed
    static let fadeMidpoint: CGFloat = 0.14
    static let fadeCompletion: CGFloat = 0.28

    static func backgroundClearWidth(for artworkWidth: CGFloat) -> CGFloat {
        artworkWidth * (1 - fadeCompletion)
    }

    static func applyLeadingFadeMask(
        _ mask: CAGradientLayer,
        to layer: CALayer,
        bounds: CGRect,
        leadingInset: CGFloat,
        clearColor: CGColor,
        translucentColor: CGColor,
        opaqueColor: CGColor
    ) {
        mask.frame = bounds
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [clearColor, translucentColor, opaqueColor, opaqueColor]
        let width = max(1, bounds.width)
        let visibleWidth = max(1, width - leadingInset)
        let start = min(1, max(0, leadingInset / width))
        let midpoint = min(1, max(
            start,
            (leadingInset + visibleWidth * fadeMidpoint) / width
        ))
        let completion = min(1, max(
            midpoint,
            (leadingInset + visibleWidth * fadeCompletion) / width
        ))
        mask.locations = [
            NSNumber(value: Double(start)),
            NSNumber(value: Double(midpoint)),
            NSNumber(value: Double(completion)),
            1,
        ]
        layer.mask = mask
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
