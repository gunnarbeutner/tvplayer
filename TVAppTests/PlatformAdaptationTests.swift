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

    func testTimelineScrubbingClampsRecordingTargetsToAvailableContent() {
        XCTAssertEqual(
            TimelineScrubbing.recordingTarget(
                at: -20,
                width: 200,
                availableDuration: 600
            ),
            0
        )
        XCTAssertEqual(
            TimelineScrubbing.recordingTarget(
                at: 100,
                width: 200,
                availableDuration: 600
            ),
            300
        )
        XCTAssertEqual(
            TimelineScrubbing.recordingTarget(
                at: 250,
                width: 200,
                availableDuration: 600
            ),
            600
        )
    }

    func testTimelineScrubbingClampsLiveTargetsToTimeshiftAvailability() {
        let programStart = Date(timeIntervalSinceReferenceDate: 1_000)
        let programEnd = programStart.addingTimeInterval(1_000)
        let availableStart = programStart.addingTimeInterval(200)
        let availableEnd = programStart.addingTimeInterval(800)

        XCTAssertEqual(
            TimelineScrubbing.liveTarget(
                at: 0,
                width: 100,
                rangeStart: programStart,
                rangeEnd: programEnd,
                availableStart: availableStart,
                availableEnd: availableEnd
            ),
            availableStart
        )
        XCTAssertEqual(
            TimelineScrubbing.liveTarget(
                at: 50,
                width: 100,
                rangeStart: programStart,
                rangeEnd: programEnd,
                availableStart: availableStart,
                availableEnd: availableEnd
            ),
            programStart.addingTimeInterval(500)
        )
        XCTAssertEqual(
            TimelineScrubbing.liveTarget(
                at: 100,
                width: 100,
                rangeStart: programStart,
                rangeEnd: programEnd,
                availableStart: availableStart,
                availableEnd: availableEnd
            ),
            availableEnd
        )
    }

    func testPlayerNavigationUsesSystemSkipInterval() {
        XCTAssertEqual(PlayerNavigationPolicy.skipInterval, 10)
    }

    func testRemoteSeekRevealsTimelineAndSeeksOnFirstPress() {
        XCTAssertEqual(
            PlayerRemoteSeekPolicy.plan(
                interval: -PlayerNavigationPolicy.skipInterval,
                chromeIsHidden: true,
                panelIsPresented: false,
                isRecording: false,
                isSeekable: true
            ),
            PlayerRemoteSeekPlan(
                handlesPress: true,
                revealsTimeline: true,
                operation: .live(-10)
            )
        )
    }

    func testRemoteSeekHandlesRecordingsOnFirstPress() {
        XCTAssertEqual(
            PlayerRemoteSeekPolicy.plan(
                interval: PlayerNavigationPolicy.skipInterval,
                chromeIsHidden: true,
                panelIsPresented: false,
                isRecording: true,
                isSeekable: true
            ),
            PlayerRemoteSeekPlan(
                handlesPress: true,
                revealsTimeline: true,
                operation: .recording(10)
            )
        )
    }

    func testRemoteSeekOnlyRevealsTimelineWhenPlaybackIsNotSeekable() {
        XCTAssertEqual(
            PlayerRemoteSeekPolicy.plan(
                interval: -PlayerNavigationPolicy.skipInterval,
                chromeIsHidden: true,
                panelIsPresented: false,
                isRecording: false,
                isSeekable: false
            ),
            PlayerRemoteSeekPlan(
                handlesPress: true,
                revealsTimeline: true,
                operation: .none
            )
        )
    }

    func testRemoteSeekLeavesDirectionalNavigationToOpenPanel() {
        XCTAssertEqual(
            PlayerRemoteSeekPolicy.plan(
                interval: PlayerNavigationPolicy.skipInterval,
                chromeIsHidden: false,
                panelIsPresented: true,
                isRecording: false,
                isSeekable: true
            ),
            PlayerRemoteSeekPlan(
                handlesPress: false,
                revealsTimeline: false,
                operation: .none
            )
        )
    }

    func testRemoteSeekPreservesHoldRepeatTiming() {
        XCTAssertEqual(PlayerRemoteSeekPolicy.initialRepeatDelayMilliseconds, 450)
        XCTAssertEqual(PlayerRemoteSeekPolicy.repeatIntervalMilliseconds, 180)
    }

    func testRemoteForwardSeekShowsLiveEdgeFeedbackWhenMovementIsBlocked() {
        let feedback = PlayerRemoteSeekPolicy.boundaryFeedback(
            for: PlayerNavigationPolicy.skipInterval
        )

        XCTAssertEqual(feedback, .liveEdge)
        XCTAssertEqual(feedback?.label, "Live")
        XCTAssertEqual(feedback?.accessibilityAnnouncement, "Already live")
    }

    func testPlaybackExitPassesThroughOutsidePlayer() {
        XCTAssertEqual(
            PlaybackExitCommandPolicy.action(
                isPlayerPresented: false,
                hasLaunchPresentation: false,
                hasPlayerHandler: false
            ),
            .passThrough
        )
    }

    func testPlaybackExitCancelsLaunchBeforeOrAbovePlayerFocus() {
        for hasPlayerHandler in [false, true] {
            XCTAssertEqual(
                PlaybackExitCommandPolicy.action(
                    isPlayerPresented: true,
                    hasLaunchPresentation: true,
                    hasPlayerHandler: hasPlayerHandler
                ),
                .cancelLaunch
            )
        }
    }

    func testPlaybackExitDismissesPresentationTransitionWithoutPlayerHandler() {
        XCTAssertEqual(
            PlaybackExitCommandPolicy.action(
                isPlayerPresented: true,
                hasLaunchPresentation: false,
                hasPlayerHandler: false
            ),
            .dismissTransition
        )
    }

    func testPlaybackExitDelegatesAfterPlayerHandlerIsInstalled() {
        XCTAssertEqual(
            PlaybackExitCommandPolicy.action(
                isPlayerPresented: true,
                hasLaunchPresentation: false,
                hasPlayerHandler: true
            ),
            .delegateToPlayer
        )
    }

    func testLiveTimelinePositionNeverEscapesAvailableWindow() {
        let liveEdge = Date(timeIntervalSinceReferenceDate: 20_000)
        let bufferStart = liveEdge.addingTimeInterval(-120)

        XCTAssertEqual(
            LiveTimelinePosition.clampedDate(
                liveEdge.addingTimeInterval(6_000),
                liveEdge: liveEdge,
                bufferStartedAt: bufferStart
            ),
            liveEdge
        )
        XCTAssertEqual(
            LiveTimelinePosition.clampedDate(
                bufferStart.addingTimeInterval(-60),
                liveEdge: liveEdge,
                bufferStartedAt: bufferStart
            ),
            bufferStart
        )
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
