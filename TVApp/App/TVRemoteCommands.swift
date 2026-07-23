#if os(tvOS)
import GameController
import OSLog
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

/// Receives physical Siri Remote and keyboard button transitions directly.
/// SwiftUI's application lifecycle installs its own UIApplication subclass, so
/// an NSPrincipalClass/sendEvent override never receives these events.
@MainActor
final class TVRemoteSeekInputBridge: NSObject {
    static let shared = TVRemoteSeekInputBridge()

    private var isActive = false
    private let logger = Logger(
        subsystem: "de.beutner.TVPlayer",
        category: "RemoteSeekInput"
    )

    func start() {
        guard !isActive else { return }
        isActive = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidConnect(_:)),
            name: .GCControllerDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardDidConnect(_:)),
            name: .GCKeyboardDidConnect,
            object: nil
        )
        GCController.controllers().forEach(attach)
        attachKeyboard(GCKeyboard.coalesced)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        NotificationCenter.default.removeObserver(self)
        GCController.controllers().forEach(detach)
        detachKeyboard(GCKeyboard.coalesced)
    }

    @objc private func controllerDidConnect(_ notification: Notification) {
        guard isActive, let controller = notification.object as? GCController else { return }
        attach(controller)
    }

    @objc private func keyboardDidConnect(_ notification: Notification) {
        guard isActive, let keyboard = notification.object as? GCKeyboard else { return }
        attachKeyboard(keyboard)
    }

    private func attach(_ controller: GCController) {
        controller.handlerQueue = .main
        if let dpad = cardinalDpad(for: controller) {
            installHandlers(
                backward: dpad.left,
                forward: dpad.right
            )
            logger.debug(
                "Attached cardinal D-pad for \(controller.productCategory, privacy: .public)"
            )
        } else if let gamepad = controller.microGamepad {
            installHandlers(
                backward: gamepad.dpad.left,
                forward: gamepad.dpad.right
            )
        } else if let gamepad = controller.extendedGamepad {
            installHandlers(
                backward: gamepad.dpad.left,
                forward: gamepad.dpad.right
            )
        }
    }

    private func detach(_ controller: GCController) {
        if let dpad = cardinalDpad(for: controller) {
            removeHandlers(backward: dpad.left, forward: dpad.right)
        }
        if let gamepad = controller.microGamepad {
            removeHandlers(backward: gamepad.dpad.left, forward: gamepad.dpad.right)
        }
        if let gamepad = controller.extendedGamepad {
            removeHandlers(backward: gamepad.dpad.left, forward: gamepad.dpad.right)
        }
    }

    private func cardinalDpad(for controller: GCController) -> GCControllerDirectionPad? {
        let name = GCDirectionPadElementName(rawValue: GCInputDirectionalCardinalDpad)
        return controller.physicalInputProfile.dpads[name.rawValue]
    }

    private func attachKeyboard(_ keyboard: GCKeyboard?) {
        guard let input = keyboard?.keyboardInput else { return }
        installHandlers(
            backward: input.button(forKeyCode: .leftArrow),
            forward: input.button(forKeyCode: .rightArrow)
        )
    }

    private func detachKeyboard(_ keyboard: GCKeyboard?) {
        guard let input = keyboard?.keyboardInput else { return }
        removeHandlers(
            backward: input.button(forKeyCode: .leftArrow),
            forward: input.button(forKeyCode: .rightArrow)
        )
    }

    private func installHandlers(
        backward: GCControllerButtonInput?,
        forward: GCControllerButtonInput?
    ) {
        backward?.pressedChangedHandler = { _, _, isPressed in
            Self.send(.backward, isPressed: isPressed)
        }
        forward?.pressedChangedHandler = { _, _, isPressed in
            Self.send(.forward, isPressed: isPressed)
        }
    }

    private nonisolated static func send(
        _ direction: TVPlayerSeekDirection,
        isPressed: Bool
    ) {
        Task { @MainActor in
            guard shared.isActive else { return }
            shared.logger.debug(
                "\(String(describing: direction), privacy: .public) pressed=\(isPressed)"
            )
            _ = TVRemoteCommandCenter.seekHoldHandler?(direction, isPressed)
        }
    }

    private func removeHandlers(
        backward: GCControllerButtonInput?,
        forward: GCControllerButtonInput?
    ) {
        backward?.pressedChangedHandler = nil
        forward?.pressedChangedHandler = nil
    }
}
#endif
