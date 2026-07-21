import XCTest
#if os(macOS)
import SwiftUI
#endif
@testable import TVApp

final class PlatformAdaptationTests: XCTestCase {
    func testAdaptiveCardMetricsRemainUsableOnCurrentPlatform() {
        XCTAssertGreaterThanOrEqual(PlatformLayout.channelCardMinimumWidth, 280)
        XCTAssertGreaterThanOrEqual(PlatformLayout.recordingCardMinimumWidth, 280)
        XCTAssertGreaterThanOrEqual(PlatformLayout.contentPadding, 20)
    }

    func testPlatformMoveDirectionsAreDistinct() {
        let directions: Set<String> = [
            String(describing: PlatformMoveDirection.up),
            String(describing: PlatformMoveDirection.down),
            String(describing: PlatformMoveDirection.left),
            String(describing: PlatformMoveDirection.right),
        ]
        XCTAssertEqual(directions.count, 4)
    }

#if os(macOS)
    func testMacOSPlayerPlaybackShortcuts() {
        XCTAssertEqual(
            MacOSPlayerKeyboardShortcuts.command(for: .space),
            .togglePlayback
        )
        XCTAssertEqual(
            MacOSPlayerKeyboardShortcuts.command(for: KeyEquivalent("k")),
            .togglePlayback
        )
        XCTAssertEqual(
            MacOSPlayerKeyboardShortcuts.command(for: KeyEquivalent("K"), modifiers: .shift),
            .togglePlayback
        )
    }

    func testMacOSPlayerArrowKeysSeekFiveSeconds() {
        XCTAssertEqual(
            MacOSPlayerKeyboardShortcuts.command(for: .leftArrow),
            .seekBackward(5)
        )
        XCTAssertEqual(
            MacOSPlayerKeyboardShortcuts.command(for: .rightArrow),
            .seekForward(5)
        )
    }

    func testMacOSPlayerLetterKeysSeekTenSeconds() {
        XCTAssertEqual(
            MacOSPlayerKeyboardShortcuts.command(for: KeyEquivalent("j")),
            .seekBackward(10)
        )
        XCTAssertEqual(
            MacOSPlayerKeyboardShortcuts.command(for: KeyEquivalent("l")),
            .seekForward(10)
        )
    }

    func testMacOSPlayerShortcutsIgnoreReservedModifiers() {
        XCTAssertNil(
            MacOSPlayerKeyboardShortcuts.command(for: .leftArrow, modifiers: .command)
        )
        XCTAssertNil(
            MacOSPlayerKeyboardShortcuts.command(for: KeyEquivalent("k"), modifiers: .option)
        )
        XCTAssertNil(
            MacOSPlayerKeyboardShortcuts.command(for: .space, modifiers: .control)
        )
    }

    func testOnlyMacOSPlayerSeekingShortcutsRepeat() {
        XCTAssertFalse(MacOSPlayerKeyboardCommand.togglePlayback.isRepeatable)
        XCTAssertTrue(MacOSPlayerKeyboardCommand.seekBackward(5).isRepeatable)
        XCTAssertTrue(MacOSPlayerKeyboardCommand.seekForward(5).isRepeatable)
    }
#endif
}
