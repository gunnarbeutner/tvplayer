#if os(tvOS)
import UIKit

enum TVPageDirection: Int, Sendable {
    case up = -1
    case down = 1
}

enum TVPlayerSeekDirection: Sendable {
    case backward
    case forward
}

extension Notification.Name {
    static let tvGuidePageCommand = Notification.Name("TVPlayer.GuidePageCommand")
    static let tvChannelsPageCommand = Notification.Name("TVPlayer.ChannelsPageCommand")
    static let tvRecordingsPageCommand = Notification.Name("TVPlayer.RecordingsPageCommand")
}

@MainActor
enum TVRemoteCommandCenter {
    static var exitHandler: (() -> Bool)?
    static var playerExitHandler: (() -> Bool)?
    static var pageHandler: ((TVPageDirection) -> Bool)?
    static var playPauseHandler: (() -> Bool)?
    static var seekHoldHandler: ((TVPlayerSeekDirection, Bool) -> Bool)?
}

/// Captures app-level remote commands before the focus engine turns them into
/// geometry-dependent movement. Back is intercepted while playback is being
/// presented so it cannot escape through a focus-tree transition and minimize
/// the app. Directional arrows are intercepted only while the player installs
/// a seek-hold handler.
@objc(TVPlayerApplication)
final class TVPlayerApplication: UIApplication {
    private var consumedTypes: Set<Int> = []
    private var consumedDirectionalTypes: Set<Int> = []

    override func sendEvent(_ event: UIEvent) {
        guard let pressesEvent = event as? UIPressesEvent else {
            super.sendEvent(event)
            return
        }

        var shouldConsume = false
        for press in pressesEvent.allPresses {
            if press.type == .menu {
                let rawType = press.type.rawValue
                if press.phase == .began,
                   !consumedTypes.contains(rawType),
                   TVRemoteCommandCenter.exitHandler?() == true {
                    consumedTypes.insert(rawType)
                }
                if consumedTypes.contains(rawType) { shouldConsume = true }
                if press.phase == .ended || press.phase == .cancelled {
                    consumedTypes.remove(rawType)
                }
                continue
            }

            if let direction = seekDirection(for: press) {
                let rawType = press.type.rawValue
                if press.phase == .began,
                   !consumedDirectionalTypes.contains(rawType),
                   TVRemoteCommandCenter.seekHoldHandler?(direction, true) == true {
                    consumedDirectionalTypes.insert(rawType)
                }
                if consumedDirectionalTypes.contains(rawType) {
                    shouldConsume = true
                    if press.phase == .ended || press.phase == .cancelled {
                        _ = TVRemoteCommandCenter.seekHoldHandler?(direction, false)
                        consumedDirectionalTypes.remove(rawType)
                    }
                }
                continue
            }

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

    private func seekDirection(for press: UIPress) -> TVPlayerSeekDirection? {
        switch press.type {
        case .leftArrow: return .backward
        case .rightArrow: return .forward
        default:
            switch press.key?.keyCode {
            case .keyboardLeftArrow: return .backward
            case .keyboardRightArrow: return .forward
            default: return nil
            }
        }
    }
}
#endif
