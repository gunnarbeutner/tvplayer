#if os(tvOS)
import UIKit

enum TVPageDirection: Int, Sendable {
    case up = -1
    case down = 1
}

extension Notification.Name {
    static let tvGuidePageCommand = Notification.Name("TVPlayer.GuidePageCommand")
    static let tvChannelsPageCommand = Notification.Name("TVPlayer.ChannelsPageCommand")
    static let tvRecordingsPageCommand = Notification.Name("TVPlayer.RecordingsPageCommand")
}

@MainActor
enum TVRemoteCommandCenter {
    static var pageHandler: ((TVPageDirection) -> Bool)?
}

/// Captures the dedicated Page Up/Down buttons before the focus engine turns
/// them into geometry-dependent movement. Directional arrows remain entirely
/// owned by SwiftUI/UIKit focus.
@objc(TVPlayerApplication)
final class TVPlayerApplication: UIApplication {
    private var consumedTypes: Set<Int> = []

    override func sendEvent(_ event: UIEvent) {
        guard let pressesEvent = event as? UIPressesEvent else {
            super.sendEvent(event)
            return
        }

        var shouldConsume = false
        for press in pressesEvent.allPresses {
            let direction: TVPageDirection?
            switch press.type {
            case .pageUp: direction = .up
            case .pageDown: direction = .down
            default: direction = nil
            }
            guard let direction else { continue }

            let rawType = press.type.rawValue
            if press.phase == .began,
               TVRemoteCommandCenter.pageHandler?(direction) == true {
                consumedTypes.insert(rawType)
            }
            if consumedTypes.contains(rawType) { shouldConsume = true }
            if press.phase == .ended || press.phase == .cancelled {
                consumedTypes.remove(rawType)
            }
        }

        if !shouldConsume { super.sendEvent(event) }
    }
}
#endif
