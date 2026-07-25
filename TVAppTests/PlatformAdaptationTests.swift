import XCTest
#if os(macOS)
import SwiftUI
#endif
@testable import TVApp

final class PlatformAdaptationTests: XCTestCase {
    func testGuideHeaderBadgesRetainSingleLineIntrinsicWidth() {
        XCTAssertEqual(GuideHeaderBadgeLayout.lineLimit, 1)
        XCTAssertTrue(GuideHeaderBadgeLayout.usesFixedHorizontalSize)
    }

    func testGuideArtworkTunesOnlyCurrentlyAiringProgrammes() {
        let now = Date(timeIntervalSince1970: 10_000)
        let current = GuideProgram(
            id: "current",
            channelID: "channel",
            title: "Current",
            subtitle: nil,
            overview: "",
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(60)
        )
        let past = GuideProgram(
            id: "past",
            channelID: "channel",
            title: "Past",
            subtitle: nil,
            overview: "",
            start: now.addingTimeInterval(-120),
            end: now
        )
        let future = GuideProgram(
            id: "future",
            channelID: "channel",
            title: "Future",
            subtitle: nil,
            overview: "",
            start: now.addingTimeInterval(60),
            end: now.addingTimeInterval(120)
        )

        XCTAssertEqual(
            GuideArtworkActivationPolicy.action(for: current, at: now),
            .tuneChannel
        )
        XCTAssertEqual(
            GuideArtworkActivationPolicy.action(for: past, at: now),
            .showDetails
        )
        XCTAssertEqual(
            GuideArtworkActivationPolicy.action(for: future, at: now),
            .showDetails
        )
    }

    func testIPadNavigationUsesTabBarInsteadOfSidebar() {
        XCTAssertEqual(IOSRootTabPresentation.preferred, .tabBar)
    }

    func testIPadUsesWideMiniPlayerOutsideGuide() {
        for tab in AppTab.allCases where tab != .guide {
            XCTAssertEqual(
                IOSMiniPlayerLayoutPolicy.layout(isPad: true, selectedTab: tab),
                .wideBanner
            )
        }
    }

    func testIPadGuideKeepsExistingFloatingMiniPlayer() {
        XCTAssertEqual(
            IOSMiniPlayerLayoutPolicy.layout(isPad: true, selectedTab: .guide),
            .floatingOverlay
        )
    }

    func testIPhoneKeepsCompactMiniPlayerAcrossTabs() {
        for tab in AppTab.allCases {
            XCTAssertEqual(
                IOSMiniPlayerLayoutPolicy.layout(isPad: false, selectedTab: tab),
                .compactBanner
            )
        }
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

    func testTouchHoldSeekVelocityUsesDeadZoneAndAcceleratesTowardEdges() {
        XCTAssertEqual(
            HoldSeekVelocityPolicy.touchRate(translation: 16, playerWidth: 1_000),
            0
        )
        XCTAssertEqual(
            HoldSeekVelocityPolicy.touchRate(translation: 400, playerWidth: 1_000),
            HoldSeekVelocityPolicy.maximumRate,
            accuracy: 0.001
        )
        XCTAssertEqual(
            HoldSeekVelocityPolicy.touchRate(translation: -400, playerWidth: 1_000),
            -HoldSeekVelocityPolicy.maximumRate,
            accuracy: 0.001
        )
        let middleRate = HoldSeekVelocityPolicy.touchRate(
            translation: 208,
            playerWidth: 1_000
        )
        XCTAssertGreaterThan(middleRate, 1)
        XCTAssertLessThan(middleRate, HoldSeekVelocityPolicy.maximumRate / 2)
    }

    func testHoldSeekTargetAdvancesByRateAndClampsToAvailability() {
        XCTAssertEqual(
            HoldSeekVelocityPolicy.advancedTarget(
                100,
                rate: 20,
                elapsed: 0.5,
                lowerBound: 0,
                upperBound: 200
            ),
            110
        )
        XCTAssertEqual(
            HoldSeekVelocityPolicy.advancedTarget(
                190,
                rate: 120,
                elapsed: 1,
                lowerBound: 0,
                upperBound: 200
            ),
            200
        )
        XCTAssertEqual(
            HoldSeekVelocityPolicy.advancedTarget(
                10,
                rate: -120,
                elapsed: 1,
                lowerBound: 0,
                upperBound: 200
            ),
            0
        )
    }

#if os(tvOS)
    func testRemoteHoldSeekVelocityRampsToMaximumInThreeSeconds() {
        XCTAssertEqual(
            HoldSeekVelocityPolicy.remoteRate(direction: .forward, heldFor: 0),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            HoldSeekVelocityPolicy.remoteRate(direction: .backward, heldFor: 3),
            -HoldSeekVelocityPolicy.maximumRate,
            accuracy: 0.001
        )
        XCTAssertEqual(
            HoldSeekVelocityPolicy.remoteRate(direction: .forward, heldFor: 30),
            HoldSeekVelocityPolicy.maximumRate,
            accuracy: 0.001
        )
    }

    func testRemoteSeekReleaseDistinguishesQuickSkipNudgeAndContinuingPreview() {
        XCTAssertEqual(
            RemoteSeekPreviewPolicy.releaseAction(
                previewWasActive: false,
                holdActivated: false
            ),
            .commitQuickSkip
        )
        XCTAssertEqual(
            RemoteSeekPreviewPolicy.releaseAction(
                previewWasActive: true,
                holdActivated: false
            ),
            .nudgePreview
        )
        XCTAssertEqual(
            RemoteSeekPreviewPolicy.releaseAction(
                previewWasActive: true,
                holdActivated: true
            ),
            .continuePreview
        )
    }
#endif

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

    func testLiveTimelineUserSeekStopsBeforeTheActualLiveEdge() {
        let liveEdge = Date(timeIntervalSinceReferenceDate: 20_000)
        let bufferStart = liveEdge.addingTimeInterval(-120)
        let preferredLivePosition = liveEdge.addingTimeInterval(-2)

        XCTAssertEqual(
            LiveTimelinePosition.userSeekableLiveEdge(at: liveEdge),
            preferredLivePosition
        )
        XCTAssertEqual(
            LiveTimelinePosition.clampedUserSeekDate(
                liveEdge,
                liveEdge: liveEdge,
                bufferStartedAt: bufferStart
            ),
            preferredLivePosition
        )
    }

    func testGoLiveButtonVisibilityIgnoresNearLiveDelayJitter() {
        var isVisible = false

        for liveDelay in [2.3, 2.7, 2.9, 2.4] {
            isVisible = GoLiveButtonVisibilityPolicy.isVisible(
                liveDelay: liveDelay,
                wasVisible: isVisible
            )
            XCTAssertFalse(isVisible)
        }

        isVisible = GoLiveButtonVisibilityPolicy.isVisible(
            liveDelay: 3.1,
            wasVisible: isVisible
        )
        XCTAssertTrue(isVisible)

        isVisible = GoLiveButtonVisibilityPolicy.isVisible(
            liveDelay: 2.5,
            wasVisible: isVisible
        )
        XCTAssertTrue(isVisible)

        isVisible = GoLiveButtonVisibilityPolicy.isVisible(
            liveDelay: 2.2,
            wasVisible: isVisible
        )
        XCTAssertFalse(isVisible)
    }

    func testRetainedPlaybackUsesOnlyAnAvailablePresentationSurface() {
        XCTAssertEqual(
            RetainedPlaybackPresentationPolicy.presentation(
                isPlayerPresented: true,
                hasPlayback: true,
                showsGuidePreview: false,
                allowsMiniPlayer: false
            ),
            .fullPlayer
        )
        XCTAssertEqual(
            RetainedPlaybackPresentationPolicy.presentation(
                isPlayerPresented: false,
                hasPlayback: true,
                showsGuidePreview: true,
                allowsMiniPlayer: false
            ),
            .guidePreview
        )
        XCTAssertEqual(
            RetainedPlaybackPresentationPolicy.presentation(
                isPlayerPresented: false,
                hasPlayback: true,
                showsGuidePreview: false,
                allowsMiniPlayer: true
            ),
            .miniPlayer
        )
        XCTAssertEqual(
            RetainedPlaybackPresentationPolicy.presentation(
                isPlayerPresented: false,
                hasPlayback: false,
                showsGuidePreview: false,
                allowsMiniPlayer: true
            ),
            .hidden
        )
        XCTAssertEqual(
            RetainedPlaybackPresentationPolicy.presentation(
                isPlayerPresented: false,
                hasPlayback: true,
                showsGuidePreview: false,
                allowsMiniPlayer: false
            ),
            .hidden
        )
    }

    func testTVSectionNavigatorEntersVisibleMiniPlayerBeforeContent() {
        XCTAssertEqual(
            TVSectionDownFocusPolicy.destination(hasMiniPlayer: true),
            .miniPlayer
        )
        XCTAssertEqual(
            TVSectionDownFocusPolicy.destination(hasMiniPlayer: false),
            .content
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
