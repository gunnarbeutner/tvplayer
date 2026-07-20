import Foundation
import XCTest
@testable import TVApp

final class TimeshiftActionTests: XCTestCase {
    func testPlayStartsNativeTimeshift() {
        let (controller, sink) = makeController()

        XCTAssertEqual(controller.perform(.play), .resume)
        XCTAssertEqual(sink.commands, [.play])
    }

    func testPauseStopsNativeTimeshiftWithoutRequestingLocalResume() {
        let (controller, sink) = makeController()

        XCTAssertEqual(controller.perform(.pause), .pause)
        XCTAssertEqual(sink.commands, [.pause])
    }

    func testSkipBackwardPausesAndSeeksUntilAcknowledged() {
        let (controller, sink) = makeController()

        XCTAssertEqual(controller.perform(.skipBackward(15)), .pauseUntilNavigationCompletes)
        XCTAssertEqual(sink.commands, [.pause, .seek(-15)])
    }

    func testSkipPausesLocalPlaybackBeforeSendingServerCommands() {
        let (controller, sink) = makeController()
        var appliedEffect: NativeTimeshiftLocalPlaybackEffect?

        controller.perform(.skipBackward(15)) { effect in
            XCTAssertEqual(sink.commands, [])
            appliedEffect = effect
        }

        XCTAssertEqual(appliedEffect, .pauseUntilNavigationCompletes)
        XCTAssertEqual(sink.commands, [.pause, .seek(-15)])
    }

    func testSkipBackwardIgnoresNonPositiveDistance() {
        let (controller, sink) = makeController()

        XCTAssertEqual(controller.perform(.skipBackward(0)), .none)
        XCTAssertEqual(controller.perform(.skipBackward(-15)), .none)
        XCTAssertEqual(sink.commands, [])
    }

    func testSkipForwardWithinBufferPausesAndSeeksUntilAcknowledged() {
        let (controller, sink) = makeController()

        XCTAssertEqual(
            controller.perform(.skipForward(15, liveDelay: 60)),
            .pauseUntilNavigationCompletes
        )
        XCTAssertEqual(sink.commands, [.pause, .seek(15)])
    }

    func testSkipForwardAtLiveEdgePausesAndReturnsLiveUntilAcknowledged() {
        let (controller, sink) = makeController()

        XCTAssertEqual(
            controller.perform(.skipForward(15, liveDelay: 15.25)),
            .pauseUntilNavigationCompletes
        )
        XCTAssertEqual(sink.commands, [.pause, .returnToLive])
    }

    func testSkipForwardBeforeFirstStatusReturnsToLive() {
        let (controller, sink) = makeController()

        XCTAssertEqual(
            controller.perform(.skipForward(15, liveDelay: 0)),
            .pauseUntilNavigationCompletes
        )
        XCTAssertEqual(sink.commands, [.pause, .returnToLive])
    }

    func testSkipForwardIgnoresNonPositiveDistance() {
        let (controller, sink) = makeController()

        XCTAssertEqual(controller.perform(.skipForward(0, liveDelay: 60)), .none)
        XCTAssertEqual(controller.perform(.skipForward(-15, liveDelay: 60)), .none)
        XCTAssertEqual(sink.commands, [])
    }

    func testReturnToLivePausesUntilTheLiveEdgeIsAcknowledged() {
        let (controller, sink) = makeController()

        XCTAssertEqual(controller.perform(.returnToLive), .pauseUntilNavigationCompletes)
        XCTAssertEqual(sink.commands, [.pause, .returnToLive])
    }

    func testKodiRecoveryScheduleRetriesImmediatelyThenBacksOff() {
        XCTAssertEqual(HTSPRecoveryPolicy.delay(beforeAttempt: 1), 0)
        for attempt in 2...6 {
            XCTAssertEqual(
                HTSPRecoveryPolicy.delay(beforeAttempt: attempt),
                HTSPRecoveryPolicy.fastRetryDelay
            )
        }
        XCTAssertEqual(
            HTSPRecoveryPolicy.delay(beforeAttempt: 7),
            HTSPRecoveryPolicy.slowRetryDelay
        )
        XCTAssertEqual(
            HTSPRecoveryPolicy.delay(beforeAttempt: 100),
            HTSPRecoveryPolicy.slowRetryDelay
        )
    }

    func testRecoveryPolicyOnlyStopsForConfigurationAndCapabilityFailures() {
        XCTAssertTrue(HTSPRecoveryPolicy.isTerminal(HTSPError.authenticationFailed))
        XCTAssertTrue(HTSPRecoveryPolicy.isTerminal(HTSPError.streamingUnavailable))
        XCTAssertTrue(HTSPRecoveryPolicy.isTerminal(HTSPError.timeshiftUnavailable))
        XCTAssertTrue(HTSPRecoveryPolicy.isTerminal(HTSPError.unsupportedStream))
        XCTAssertFalse(HTSPRecoveryPolicy.isTerminal(HTSPError.disconnected))
        XCTAssertFalse(HTSPRecoveryPolicy.isTerminal(HTSPError.readTimedOut))
        XCTAssertFalse(
            HTSPRecoveryPolicy.isTerminal(HTSPError.connectionFailed("reset"))
        )
        XCTAssertFalse(HTSPRecoveryPolicy.isTerminal(HTSPError.server("temporary")))
    }

    func testOutputWatchdogRebuildsWhenFreshInputHasNoOutputForTenSeconds() {
        var monitor = PlaybackOutputHealthMonitor()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let output = PlaybackOutputCounters(displayedPictures: 20, playedAudioBuffers: 30)

        XCTAssertEqual(
            monitor.observe(
                output: output,
                at: start,
                expectsOutput: true,
                hasFreshInput: true
            ),
            .none
        )
        XCTAssertEqual(
            monitor.observe(
                output: output,
                at: start.addingTimeInterval(9.9),
                expectsOutput: true,
                hasFreshInput: true
            ),
            .none
        )
        XCTAssertEqual(
            monitor.observe(
                output: output,
                at: start.addingTimeInterval(10),
                expectsOutput: true,
                hasFreshInput: true
            ),
            .rebuildPlayer
        )
    }

    func testOutputWatchdogIsSuppressedWhilePausedNavigatingOrInputIsStalled() {
        var monitor = PlaybackOutputHealthMonitor()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let output = PlaybackOutputCounters(displayedPictures: 20, playedAudioBuffers: 30)

        monitor.restartGracePeriod(output: output, at: start)
        XCTAssertEqual(
            monitor.observe(
                output: output,
                at: start.addingTimeInterval(30),
                expectsOutput: false,
                hasFreshInput: true
            ),
            .none
        )
        XCTAssertEqual(
            monitor.observe(
                output: output,
                at: start.addingTimeInterval(60),
                expectsOutput: true,
                hasFreshInput: false
            ),
            .none
        )
        XCTAssertEqual(
            monitor.observe(
                output: output,
                at: start.addingTimeInterval(69),
                expectsOutput: true,
                hasFreshInput: true
            ),
            .none
        )
    }

    func testOutputProgressRestartsTheWatchdogGracePeriod() {
        var monitor = PlaybackOutputHealthMonitor()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let initial = PlaybackOutputCounters(displayedPictures: 20, playedAudioBuffers: 30)
        let advanced = PlaybackOutputCounters(displayedPictures: 21, playedAudioBuffers: 30)

        monitor.restartGracePeriod(output: initial, at: start)
        XCTAssertEqual(
            monitor.observe(
                output: advanced,
                at: start.addingTimeInterval(9),
                expectsOutput: true,
                hasFreshInput: true
            ),
            .none
        )
        XCTAssertEqual(
            monitor.observe(
                output: advanced,
                at: start.addingTimeInterval(18),
                expectsOutput: true,
                hasFreshInput: true
            ),
            .none
        )
        XCTAssertEqual(
            monitor.observe(
                output: advanced,
                at: start.addingTimeInterval(19),
                expectsOutput: true,
                hasFreshInput: true
            ),
            .rebuildPlayer
        )
    }

    func testOutputWatchdogRequestsOnlyOneRecoveryUntilProgressResumes() {
        var monitor = PlaybackOutputHealthMonitor()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let stalled = PlaybackOutputCounters(displayedPictures: 20, playedAudioBuffers: 30)

        monitor.restartGracePeriod(output: stalled, at: start)
        XCTAssertEqual(
            monitor.observe(
                output: stalled,
                at: start.addingTimeInterval(10),
                expectsOutput: true,
                hasFreshInput: true
            ),
            .rebuildPlayer
        )
        XCTAssertEqual(
            monitor.observe(
                output: stalled,
                at: start.addingTimeInterval(30),
                expectsOutput: true,
                hasFreshInput: true
            ),
            .none
        )

        let resumed = PlaybackOutputCounters(displayedPictures: 21, playedAudioBuffers: 30)
        XCTAssertEqual(
            monitor.observe(
                output: resumed,
                at: start.addingTimeInterval(31),
                expectsOutput: true,
                hasFreshInput: true
            ),
            .none
        )
        XCTAssertEqual(
            monitor.observe(
                output: resumed,
                at: start.addingTimeInterval(41),
                expectsOutput: true,
                hasFreshInput: true
            ),
            .rebuildPlayer
        )
    }

    func testNativeTimeshiftIsSeekableBeforeFirstStatusUpdate() {
        XCTAssertTrue(
            PlaybackCapabilityPolicy.isSeekable(
                isLive: true,
                hasNativeTimeshift: true,
                mediaIsSeekable: false
            )
        )
        XCTAssertTrue(
            PlaybackCapabilityPolicy.canPause(
                isLive: true,
                hasNativeTimeshift: true,
                mediaCanPause: false
            )
        )
    }

    func testLiveOnlyHTTPDoesNotExposeTimeshiftActions() {
        XCTAssertFalse(
            PlaybackCapabilityPolicy.isSeekable(
                isLive: true,
                hasNativeTimeshift: false,
                mediaIsSeekable: true
            )
        )
        XCTAssertFalse(
            PlaybackCapabilityPolicy.canPause(
                isLive: true,
                hasNativeTimeshift: false,
                mediaCanPause: true
            )
        )
    }

    func testRecordingUsesMediaCapabilities() {
        XCTAssertTrue(
            PlaybackCapabilityPolicy.isSeekable(
                isLive: false,
                hasNativeTimeshift: false,
                mediaIsSeekable: true
            )
        )
        XCTAssertFalse(
            PlaybackCapabilityPolicy.canPause(
                isLive: false,
                hasNativeTimeshift: false,
                mediaCanPause: false
            )
        )
    }

    func testPausedPlaybackDateDoesNotFlapAsStatusSamplesChange() {
        var tracker = LivePlaybackPositionTracker()
        let pauseTime = Date(timeIntervalSinceReferenceDate: 10_000)
        tracker.pause(at: pauseTime, liveDelay: 7.4, bufferStartedAt: nil)

        let firstUpdate = tracker.playbackDate(
            at: pauseTime.addingTimeInterval(1),
            liveDelay: 8.6,
            bufferStartedAt: nil
        )
        let secondUpdate = tracker.playbackDate(
            at: pauseTime.addingTimeInterval(2),
            liveDelay: 9.3,
            bufferStartedAt: nil
        )

        XCTAssertEqual(firstUpdate, pauseTime.addingTimeInterval(-7.4))
        XCTAssertEqual(secondUpdate, firstUpdate)
    }

    func testRecoveryMovesTheMarkerOnceToTheNewLiveEdgeAndKeepsItFrozen() {
        var tracker = LivePlaybackPositionTracker()
        let originalPause = Date(timeIntervalSinceReferenceDate: 10_000)
        let recoveredLiveEdge = originalPause.addingTimeInterval(30)
        tracker.pause(at: originalPause, liveDelay: 5, bufferStartedAt: nil)

        tracker.recoverAtLiveEdge(recoveredLiveEdge)

        XCTAssertEqual(
            tracker.playbackDate(
                at: recoveredLiveEdge.addingTimeInterval(60),
                liveDelay: 60,
                bufferStartedAt: nil
            ),
            recoveredLiveEdge
        )
    }

    func testRepeatedPauseKeepsTheOriginalPlaybackDate() {
        var tracker = LivePlaybackPositionTracker()
        let pauseTime = Date(timeIntervalSinceReferenceDate: 10_000)
        tracker.pause(at: pauseTime, liveDelay: 5, bufferStartedAt: nil)
        tracker.pause(
            at: pauseTime.addingTimeInterval(2),
            liveDelay: 5,
            bufferStartedAt: nil
        )

        XCTAssertEqual(
            tracker.playbackDate(
                at: pauseTime.addingTimeInterval(3),
                liveDelay: 5,
                bufferStartedAt: nil
            ),
            pauseTime.addingTimeInterval(-5)
        )
    }

    func testResumedPlaybackDateTracksTheLiveDelayAgain() {
        var tracker = LivePlaybackPositionTracker()
        let pauseTime = Date(timeIntervalSinceReferenceDate: 10_000)
        tracker.pause(at: pauseTime, liveDelay: 5, bufferStartedAt: nil)
        XCTAssertTrue(
            tracker.requestResume(
                from: PlaybackOutputCounters(displayedPictures: 20, playedAudioBuffers: 30)
            )
        )
        XCTAssertTrue(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(displayedPictures: 21, playedAudioBuffers: 30),
                at: pauseTime.addingTimeInterval(1)
            )
        )
        XCTAssertTrue(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(displayedPictures: 22, playedAudioBuffers: 30),
                at: pauseTime.addingTimeInterval(3)
            )
        )

        XCTAssertEqual(
            tracker.playbackDate(
                at: pauseTime.addingTimeInterval(3),
                liveDelay: 6,
                bufferStartedAt: nil
            ),
            pauseTime.addingTimeInterval(-4)
        )
    }

    func testPlaybackMarkerFreezesDuringAStallAndIgnoresClockFlapping() {
        var tracker = LivePlaybackPositionTracker()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        tracker.pause(at: start, liveDelay: 5, bufferStartedAt: nil)
        tracker.requestResume(
            from: PlaybackOutputCounters(
                displayedPictures: 100,
                playedAudioBuffers: 100,
                playbackTimeMilliseconds: 10_000
            )
        )

        XCTAssertTrue(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(
                    displayedPictures: 101,
                    playedAudioBuffers: 101,
                    playbackTimeMilliseconds: 10_500
                ),
                at: start.addingTimeInterval(0.5)
            )
        )
        let landedDate = tracker.playbackDate(
            at: start.addingTimeInterval(0.5),
            liveDelay: 5,
            bufferStartedAt: nil
        )

        XCTAssertFalse(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(
                    displayedPictures: 102,
                    playedAudioBuffers: 102,
                    playbackTimeMilliseconds: 10_000
                ),
                at: start.addingTimeInterval(1)
            )
        )
        XCTAssertFalse(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(
                    displayedPictures: 103,
                    playedAudioBuffers: 103,
                    playbackTimeMilliseconds: 10_500
                ),
                at: start.addingTimeInterval(1.5)
            )
        )
        XCTAssertEqual(
            tracker.playbackDate(
                at: start.addingTimeInterval(30),
                liveDelay: 30,
                bufferStartedAt: nil
            ),
            landedDate
        )

        XCTAssertTrue(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(
                    displayedPictures: 104,
                    playedAudioBuffers: 104,
                    playbackTimeMilliseconds: 11_000
                ),
                at: start.addingTimeInterval(2)
            )
        )
        XCTAssertEqual(
            tracker.playbackDate(
                at: start.addingTimeInterval(2),
                liveDelay: 5,
                bufferStartedAt: nil
            ),
            landedDate.addingTimeInterval(0.5)
        )
    }

    func testResumeRequestKeepsMarkerAnchoredUntilOutputAdvances() {
        var tracker = LivePlaybackPositionTracker()
        let pauseTime = Date(timeIntervalSinceReferenceDate: 10_000)
        let output = PlaybackOutputCounters(displayedPictures: 20, playedAudioBuffers: 30)
        tracker.pause(at: pauseTime, liveDelay: 5, bufferStartedAt: nil)
        XCTAssertTrue(tracker.requestResume(from: output))

        XCTAssertFalse(tracker.observePlaybackOutput(output))
        XCTAssertEqual(
            tracker.playbackDate(
                at: pauseTime.addingTimeInterval(30),
                liveDelay: 35,
                bufferStartedAt: nil
            ),
            pauseTime.addingTimeInterval(-5)
        )
        XCTAssertTrue(tracker.isAwaitingPlaybackProgress)

        XCTAssertTrue(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(displayedPictures: 20, playedAudioBuffers: 31)
            )
        )
        XCTAssertTrue(tracker.hasAnchoredDate)
    }

    func testResumeProgressHandlesVLCCounterReset() {
        var tracker = LivePlaybackPositionTracker()
        let pauseTime = Date(timeIntervalSinceReferenceDate: 10_000)
        tracker.pause(at: pauseTime, liveDelay: 5, bufferStartedAt: nil)
        tracker.requestResume(
            from: PlaybackOutputCounters(displayedPictures: 200, playedAudioBuffers: 300)
        )

        XCTAssertFalse(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(displayedPictures: 0, playedAudioBuffers: 0)
            )
        )
        XCTAssertTrue(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(displayedPictures: 1, playedAudioBuffers: 0)
            )
        )
        XCTAssertTrue(tracker.hasAnchoredDate)
    }

    func testPausedForwardSeekMovesOnceThenWaitsForVisiblePlaybackProgress() {
        var tracker = LivePlaybackPositionTracker()
        let streamStart = Date(timeIntervalSinceReferenceDate: 10_000)
        let initialOutput = PlaybackOutputCounters(
            displayedPictures: 200,
            playedAudioBuffers: 300
        )

        // Start live, pause, and let the server-side buffer continue filling.
        tracker.pause(at: streamStart, liveDelay: 0, bufferStartedAt: streamStart)
        XCTAssertEqual(
            tracker.playbackDate(
                at: streamStart.addingTimeInterval(30),
                liveDelay: 30,
                bufferStartedAt: streamStart
            ),
            streamStart
        )

        // A single forward step updates the marker exactly once.
        tracker.moveAnchor(
            by: 15,
            at: streamStart.addingTimeInterval(30),
            bufferStartedAt: streamStart
        )
        XCTAssertEqual(
            tracker.playbackDate(
                at: streamStart.addingTimeInterval(30),
                liveDelay: 30,
                bufferStartedAt: streamStart
            ),
            streamStart.addingTimeInterval(15)
        )

        // Acknowledging the seek only requests resume. The marker remains at
        // the target while VLC is still stalled on the new stream position.
        tracker.requestResume(from: initialOutput)
        XCTAssertFalse(tracker.observePlaybackOutput(initialOutput))
        XCTAssertEqual(
            tracker.playbackDate(
                at: streamStart.addingTimeInterval(60),
                liveDelay: 45,
                bufferStartedAt: streamStart
            ),
            streamStart.addingTimeInterval(15)
        )

        // The marker is released only when VLC actually presents new output.
        XCTAssertTrue(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(displayedPictures: 201, playedAudioBuffers: 300)
            )
        )
        XCTAssertTrue(tracker.hasAnchoredDate)
    }

    func testTimeshiftStatusNormalizesShiftAndWindow() {
        let negativeShift = HTSPTimeshiftMetrics.decode(
            from: [
                "shift": .int(-15_500_000),
                "start": .int(1_000_000),
                "end": .int(61_000_000),
            ]
        )
        let positiveShift = HTSPTimeshiftMetrics.decode(from: ["shift": .int(3_000_000)])

        XCTAssertEqual(negativeShift.liveDelay, 15.5)
        XCTAssertEqual(negativeShift.window, 60)
        XCTAssertEqual(positiveShift.liveDelay, 3)
        XCTAssertEqual(positiveShift.window, 0)
    }

    func testTimeshiftStatusRejectsNegativeWindow() {
        let metrics = HTSPTimeshiftMetrics.decode(
            from: ["start": .int(10_000_000), "end": .int(5_000_000)]
        )

        XCTAssertEqual(metrics.window, 0)
    }

    func testTimeshiftStatusExposesExactServerTimeline() {
        let metrics = HTSPTimeshiftMetrics.decode(
            from: [
                "shift": .int(15_000_000),
                "start": .int(10_000_000),
                "end": .int(100_000_000),
            ]
        )

        XCTAssertEqual(metrics.startTime, 10_000_000)
        XCTAssertEqual(metrics.endTime, 100_000_000)
        XCTAssertEqual(metrics.playheadTime, 85_000_000)
    }

    func testRelativeSeekBecomesAnAbsoluteServerTarget() {
        var coordinator = HTSPAbsoluteSeekCoordinator()
        XCTAssertNil(
            coordinator.update(
                metrics: timeshiftMetrics(start: 0, end: 120, delay: 30),
                updateCurrentPosition: true
            )
        )

        XCTAssertEqual(coordinator.requestRelative(seconds: -15), 75_000_000)
        XCTAssertEqual(coordinator.inFlightTarget, 75_000_000)
    }

    func testRepeatedSeeksCoalesceToTheLatestAbsoluteTarget() {
        var coordinator = HTSPAbsoluteSeekCoordinator()
        _ = coordinator.update(
            metrics: timeshiftMetrics(start: 0, end: 120, delay: 30),
            updateCurrentPosition: true
        )

        XCTAssertEqual(coordinator.requestRelative(seconds: -15), 75_000_000)
        XCTAssertNil(coordinator.requestRelative(seconds: 15))
        XCTAssertNil(coordinator.requestRelative(seconds: 15))
        XCTAssertEqual(coordinator.desiredTarget, 105_000_000)
        XCTAssertEqual(coordinator.complete(landingTime: 75_000_000), .seek(105_000_000))

        let completion = coordinator.complete(landingTime: 104_900_000)
        XCTAssertEqual(
            completion,
            .buffer(
                HTSPNavigationResult(
                    landingTime: 104_900_000,
                    bufferStartTime: 0,
                    liveEdgeTime: 120_000_000
                )
            )
        )
    }

    func testSeekRequestedBeforeStatusWaitsForServerBounds() {
        var coordinator = HTSPAbsoluteSeekCoordinator()

        XCTAssertNil(coordinator.requestRelative(seconds: -15))
        XCTAssertEqual(
            coordinator.update(
                metrics: timeshiftMetrics(start: 10, end: 100, delay: 20),
                updateCurrentPosition: true
            ),
            65_000_000
        )
    }

    func testAbsoluteSeekClampsToBufferAndLiveEdges() {
        var coordinator = HTSPAbsoluteSeekCoordinator()
        _ = coordinator.update(
            metrics: timeshiftMetrics(start: 30, end: 100, delay: 20),
            updateCurrentPosition: true
        )

        XCTAssertEqual(coordinator.requestRelative(seconds: -90), 30_000_000)
        _ = coordinator.complete(landingTime: 30_000_000)
        XCTAssertEqual(coordinator.requestLiveEdge(), 100_000_000)
    }

    func testLiveEdgeRequestBeforeStatusIsSentWhenBoundsArrive() {
        var coordinator = HTSPAbsoluteSeekCoordinator()

        XCTAssertNil(coordinator.requestLiveEdge())
        XCTAssertEqual(
            coordinator.update(
                metrics: timeshiftMetrics(start: 10, end: 100, delay: 20),
                updateCurrentPosition: true
            ),
            100_000_000
        )
    }

    func testLiveCommandAcceptsTheServersLastReadableFrameAsTheLiveEdge() {
        var coordinator = HTSPAbsoluteSeekCoordinator()
        _ = coordinator.update(
            metrics: timeshiftMetrics(start: 0, end: 120, delay: 20),
            updateCurrentPosition: true
        )
        XCTAssertEqual(coordinator.requestLiveEdge(), 120_000_000)

        XCTAssertEqual(
            coordinator.complete(
                landingTime: 118_500_000,
                acceptsLiveEdgeLanding: true
            ),
            .buffer(
                HTSPNavigationResult(
                    landingTime: 118_500_000,
                    bufferStartTime: 0,
                    liveEdgeTime: 120_000_000
                )
            )
        )
    }

    func testAbsoluteLiveEdgeRejectionFallsBackToTheLiveCommandOnlyOnce() {
        XCTAssertTrue(
            HTSPNavigationRecoveryPolicy.shouldRetryWithLiveCommand(
                acceptsLiveEdge: false,
                targetsLiveEdge: true
            )
        )
        XCTAssertFalse(
            HTSPNavigationRecoveryPolicy.shouldRetryWithLiveCommand(
                acceptsLiveEdge: true,
                targetsLiveEdge: true
            )
        )
        XCTAssertFalse(
            HTSPNavigationRecoveryPolicy.shouldRetryWithLiveCommand(
                acceptsLiveEdge: false,
                targetsLiveEdge: false
            )
        )
    }

    func testSpeedChangesWaitForActualServerAcknowledgement() {
        var speed = HTSPSubscriptionSpeedController()

        XCTAssertNil(speed.request(100))
        XCTAssertEqual(speed.request(0), 0)
        XCTAssertNil(speed.request(400))
        XCTAssertEqual(speed.observeActual(0), 400)
        XCTAssertNil(speed.request(100))
        XCTAssertEqual(speed.observeActual(400), 100)
        XCTAssertNil(speed.observeActual(100))
    }

    func testNormalStartupDoesNotQueueALatePause() {
        var speed = HTSPSubscriptionSpeedController()

        XCTAssertEqual(speed.actualSpeed, 100)
        XCTAssertEqual(speed.desiredSpeed, 100)
        XCTAssertNil(speed.outstandingSpeed)
        XCTAssertNil(speed.request(100))
    }

    func testLiveCommandServerSpeedTransitionDoesNotQueueALatePause() {
        var speed = HTSPSubscriptionSpeedController(
            desiredSpeed: 0,
            actualSpeed: 0,
            outstandingSpeed: nil
        )

        speed.expectServerSpeed(100)

        XCTAssertNil(speed.observeActual(100))
        XCTAssertEqual(speed.desiredSpeed, 100)
        XCTAssertEqual(speed.actualSpeed, 100)
        XCTAssertNil(speed.outstandingSpeed)
    }

    func testSeekWaitsForTheServerToAcknowledgePause() {
        XCTAssertFalse(
            HTSPSeekStartPolicy.canSendSeek(
                actualSpeed: 100,
                outstandingSpeed: nil
            )
        )
        XCTAssertFalse(
            HTSPSeekStartPolicy.canSendSeek(
                actualSpeed: 100,
                outstandingSpeed: 0
            )
        )
        XCTAssertTrue(
            HTSPSeekStartPolicy.canSendSeek(
                actualSpeed: 0,
                outstandingSpeed: nil
            )
        )
    }

    func testFailedSpeedCommandStopsRetryingUntilANewRequest() {
        var speed = HTSPSubscriptionSpeedController(
            desiredSpeed: 100,
            actualSpeed: 0,
            outstandingSpeed: 100
        )

        XCTAssertNil(speed.commandFailed(100))

        XCTAssertEqual(speed.desiredSpeed, 0)
        XCTAssertNil(speed.outstandingSpeed)
        XCTAssertEqual(speed.request(100), 100)
    }

    func testFailedOldSpeedCommandContinuesWithTheNewRecoverySpeed() {
        var speed = HTSPSubscriptionSpeedController(
            desiredSpeed: 400,
            actualSpeed: 0,
            outstandingSpeed: 400
        )
        XCTAssertNil(speed.request(100))

        XCTAssertEqual(speed.commandFailed(400), 100)
        XCTAssertEqual(speed.desiredSpeed, 100)
        XCTAssertEqual(speed.outstandingSpeed, 100)
    }

    func testPostSeekBufferWaitsForVideoKeyframeAndOneSecondOfMedia() {
        var tracker = HTSPPostSeekBufferTracker()
        let result = HTSPNavigationResult(
            landingTime: 45_000_000,
            bufferStartTime: 0,
            liveEdgeTime: 120_000_000
        )
        tracker.begin(result, hasVideo: true)

        XCTAssertFalse(
            tracker.shouldAcceptPacket(
                isVideo: false,
                frameType: 0x49
            )
        )
        XCTAssertFalse(
            tracker.shouldAcceptPacket(
                isVideo: true,
                frameType: 0x50
            )
        )
        XCTAssertTrue(
            tracker.shouldAcceptPacket(
                isVideo: true,
                frameType: 0x49
            )
        )
        XCTAssertNil(tracker.observePacket(time: 45_000_000))
        XCTAssertNil(tracker.observePacket(time: 45_900_000))
        XCTAssertEqual(tracker.observePacket(time: 46_000_000), result)
        XCTAssertNil(tracker.result)
    }

    func testPostSeekBufferHasPacketCountFallbackForMissingTimestamps() {
        var tracker = HTSPPostSeekBufferTracker()
        let result = HTSPNavigationResult(
            landingTime: 0,
            bufferStartTime: nil,
            liveEdgeTime: nil
        )
        tracker.begin(result, hasVideo: false)

        for _ in 0..<(HTSPPostSeekBufferTracker.packetFallbackCount - 1) {
            XCTAssertNil(tracker.observePacket(time: nil))
        }
        XCTAssertEqual(tracker.observePacket(time: nil), result)
    }

    func testDeliveryGateDropsPacketsUntilNavigationCompletes() {
        let gate = HTSPTimeshiftDeliveryGate()

        XCTAssertTrue(gate.shouldDeliverPackets)
        gate.beginNavigation()
        XCTAssertFalse(gate.shouldDeliverPackets)
        gate.completeNavigation()
        XCTAssertTrue(gate.shouldDeliverPackets)
    }

    func testDeliveryGateCoalescesOverlappingNavigation() {
        let gate = HTSPTimeshiftDeliveryGate()

        gate.beginNavigation()
        gate.beginNavigation()
        gate.completeNavigation()
        XCTAssertTrue(gate.shouldDeliverPackets)
    }

    func testDeliveryGateCanRecoverAfterCommandFailure() {
        let gate = HTSPTimeshiftDeliveryGate()

        gate.beginNavigation()
        gate.beginNavigation()
        gate.cancelAllNavigation()

        XCTAssertTrue(gate.shouldDeliverPackets)
    }

    func testDeliveryGateCompletionIsIdempotent() {
        let gate = HTSPTimeshiftDeliveryGate()

        gate.completeNavigation()
        XCTAssertTrue(gate.shouldDeliverPackets)
    }

    func testNewSeekClosesDeliveryAgain() {
        let gate = HTSPTimeshiftDeliveryGate()

        gate.beginNavigation()
        gate.completeNavigation()
        gate.beginNavigation()

        XCTAssertFalse(gate.shouldDeliverPackets)
    }

    private func makeController() -> (NativeTimeshiftActionController, RecordingTimeshiftSink) {
        let sink = RecordingTimeshiftSink()
        return (NativeTimeshiftActionController(sink: sink), sink)
    }

    private func timeshiftMetrics(
        start: TimeInterval,
        end: TimeInterval,
        delay: TimeInterval
    ) -> HTSPTimeshiftMetrics {
        HTSPTimeshiftMetrics.decode(
            from: [
                "shift": .int(Int64(delay * 1_000_000)),
                "start": .int(Int64(start * 1_000_000)),
                "end": .int(Int64(end * 1_000_000)),
            ]
        )
    }
}

private final class RecordingTimeshiftSink: NativeTimeshiftCommandSink {
    private(set) var commands: [NativeTimeshiftServerCommand] = []

    func play() {
        commands.append(.play)
    }

    func pause() {
        commands.append(.pause)
    }

    func seek(by seconds: TimeInterval) {
        commands.append(.seek(seconds))
    }

    func returnToLive() {
        commands.append(.returnToLive)
    }
}
