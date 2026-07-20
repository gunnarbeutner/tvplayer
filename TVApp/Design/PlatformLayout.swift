import SwiftUI

enum PlatformLayout {
#if os(tvOS)
    static let contentPadding: CGFloat = 72
    static let contentVerticalPadding: CGFloat = 34
    static let gridSpacing: CGFloat = 30
    static let channelCardMinimumWidth: CGFloat = 500
    static let recordingCardMinimumWidth: CGFloat = 420
#elseif os(macOS)
    static let contentPadding: CGFloat = 28
    static let contentVerticalPadding: CGFloat = 24
    static let gridSpacing: CGFloat = 18
    static let channelCardMinimumWidth: CGFloat = 300
    static let recordingCardMinimumWidth: CGFloat = 300
#else
    static let contentPadding: CGFloat = 20
    static let contentVerticalPadding: CGFloat = 20
    static let gridSpacing: CGFloat = 16
    static let channelCardMinimumWidth: CGFloat = 280
    static let recordingCardMinimumWidth: CGFloat = 280
#endif
}
