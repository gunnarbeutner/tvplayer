import Foundation
import XCTest
@testable import TVApp

final class TimeshiftActionTests: XCTestCase {
    func testNativeTimeshiftTuningPolicyKeepsColdTuneAndPostSeekBuffersIndependent() {
        let defaults = NativeTimeshiftTuningPolicy()
        let reducedColdTuneCache = NativeTimeshiftTuningPolicy(
            vlcCacheMilliseconds: 800,
            initialHorizonMilliseconds: 650
        )
        XCTAssertEqual(reducedColdTuneCache.vlcCacheMilliseconds, 800)
        XCTAssertEqual(reducedColdTuneCache.initialHorizonMilliseconds, 650)
        XCTAssertEqual(
            reducedColdTuneCache.postSeekReserveMilliseconds,
            defaults.postSeekReserveMilliseconds
        )
    }

    func testNativeTimeshiftTuningPolicyOnlyUsesShortRevealForCurrentAlignedBatch() {
        let policy = NativeTimeshiftTuningPolicy()

        XCTAssertEqual(
            policy.revealDuration(
                for: .timestampAligned(horizonMicroseconds: 500_000),
                generation: 7,
                currentGeneration: 7
            ),
            0.5
        )
        XCTAssertEqual(
            policy.revealDuration(
                for: .timestampAligned(horizonMicroseconds: 499_999),
                generation: 7,
                currentGeneration: 7
            ),
            0.75
        )
        XCTAssertEqual(
            policy.revealDuration(
                for: .timestampAligned(horizonMicroseconds: 500_000),
                generation: 6,
                currentGeneration: 7
            ),
            0.75
        )
        XCTAssertEqual(
            policy.revealDuration(
                for: .pending,
                generation: 7,
                currentGeneration: 7
            ),
            0.75
        )
    }

    func testColdTuneOutputGateKeepsInitialBurstAndPauseConcealed() {
        var gate = PostSeekPlaybackOutputGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 500)
        let initial = PlaybackOutputCounters(
            displayedPictures: 0,
            playedAudioBuffers: 0
        )
        gate.arm(from: initial)
        gate.requireSustainedOutput(0.5)
        gate.requireFreshVideoAtReveal()
        gate.requireAudioOutput()
        gate.markPipelineRecreated()
        XCTAssertTrue(gate.beginConcealing(from: initial))

        // The first observation establishes the new pipeline's baseline. A
        // startup burst then stops for longer than the audio cadence tolerance
        // and must not dismiss the launch surface.
        XCTAssertFalse(gate.observe(initial, at: startedAt))
        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 12, playedAudioBuffers: 12),
            at: startedAt.addingTimeInterval(0.01)
        ))
        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 12, playedAudioBuffers: 12),
            at: startedAt.addingTimeInterval(0.31)
        ))

        // Once presentation resumes, the gate needs a complete fresh half
        // second of audio and a new picture on the reveal observation.
        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 13, playedAudioBuffers: 13),
            at: startedAt.addingTimeInterval(0.32)
        ))
        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 24, playedAudioBuffers: 24),
            at: startedAt.addingTimeInterval(0.819)
        ))
        XCTAssertTrue(gate.observe(
            PlaybackOutputCounters(displayedPictures: 25, playedAudioBuffers: 25),
            at: startedAt.addingTimeInterval(0.82)
        ))
    }

    func testColdTuneOutputGateAcceptsTwoFPSVideoUsingAudioClockContinuity() {
        var gate = PostSeekPlaybackOutputGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 600)
        let initial = PlaybackOutputCounters(displayedPictures: 0, playedAudioBuffers: 0)
        gate.arm(from: initial)
        gate.requireSustainedOutput(0.5)
        gate.requireFreshVideoAtReveal()
        gate.requireAudioOutput()
        gate.markPipelineRecreated()
        XCTAssertTrue(gate.beginConcealing(from: initial))
        XCTAssertFalse(gate.observe(initial, at: startedAt))

        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 1, playedAudioBuffers: 1),
            at: startedAt.addingTimeInterval(0.01)
        ))
        for step in 1...4 {
            XCTAssertFalse(gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 1,
                    playedAudioBuffers: step + 1
                ),
                at: startedAt.addingTimeInterval(0.01 + Double(step) * 0.1)
            ))
        }
        XCTAssertTrue(gate.observe(
            PlaybackOutputCounters(displayedPictures: 2, playedAudioBuffers: 5),
            at: startedAt.addingTimeInterval(0.51)
        ))
    }

    func testColdTuneOutputGateAcceptsOneFPSVideoOnlyOnFreshPicture() {
        var gate = PostSeekPlaybackOutputGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 700)
        let initial = PlaybackOutputCounters(displayedPictures: 0, playedAudioBuffers: 0)
        gate.arm(from: initial)
        gate.requireSustainedOutput(0.5)
        gate.requireFreshVideoAtReveal()
        gate.requireAudioOutput()
        gate.markPipelineRecreated()
        XCTAssertTrue(gate.beginConcealing(from: initial))
        XCTAssertFalse(gate.observe(initial, at: startedAt))

        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 1, playedAudioBuffers: 1),
            at: startedAt.addingTimeInterval(0.01)
        ))
        for step in 1...9 {
            XCTAssertFalse(gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 1,
                    playedAudioBuffers: step + 1
                ),
                at: startedAt.addingTimeInterval(0.01 + Double(step) * 0.1)
            ))
        }
        XCTAssertTrue(gate.observe(
            PlaybackOutputCounters(displayedPictures: 2, playedAudioBuffers: 10),
            at: startedAt.addingTimeInterval(1.01)
        ))
    }

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

    func testCoalescedSkipBackwardDoesNotPauseTheServerAgain() {
        let (controller, sink) = makeController()

        controller.performCoalescedNavigation(.skipBackward(15))

        XCTAssertEqual(sink.commands, [.seek(-15)])
    }

    func testCoalescedReturnToLiveDoesNotPauseTheServerAgain() {
        let (controller, sink) = makeController()

        controller.performCoalescedNavigation(.returnToLive)

        XCTAssertEqual(sink.commands, [.returnToLive])
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

    func testSkipForwardAtLiveEdgeLeavesPreferredSafetyDelay() {
        let (controller, sink) = makeController()

        XCTAssertEqual(
            controller.perform(.skipForward(15, liveDelay: 15.25)),
            .pauseUntilNavigationCompletes
        )
        XCTAssertEqual(sink.commands, [.pause, .seek(13.25)])
    }

    func testSkipForwardAtPreferredLiveDelayDoesNothing() {
        let (controller, sink) = makeController()

        XCTAssertEqual(
            controller.perform(.skipForward(15, liveDelay: 2)),
            .none
        )
        XCTAssertEqual(sink.commands, [])
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

    func testOutputWatchdogRebuildsWhenAudioStallsWhileVideoContinues() {
        var monitor = PlaybackOutputHealthMonitor()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let initial = PlaybackOutputCounters(displayedPictures: 20, playedAudioBuffers: 30)

        monitor.restartGracePeriod(output: initial, at: start)
        XCTAssertEqual(
            monitor.observe(
                output: PlaybackOutputCounters(
                    displayedPictures: 21,
                    playedAudioBuffers: 30
                ),
                at: start.addingTimeInterval(1),
                expectsOutput: true,
                hasFreshInput: true,
                expectsAudio: true
            ),
            .none
        )
        XCTAssertEqual(
            monitor.observe(
                output: PlaybackOutputCounters(
                    displayedPictures: 30,
                    playedAudioBuffers: 30
                ),
                at: start.addingTimeInterval(10),
                expectsOutput: true,
                hasFreshInput: true,
                expectsAudio: true
            ),
            .rebuildPlayer
        )
    }

    func testOutputWatchdogQuicklyRebuildsWhenStartupAudioBrieflyAdvancesThenStalls() {
        var monitor = PlaybackOutputHealthMonitor()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let initial = PlaybackOutputCounters(displayedPictures: 0, playedAudioBuffers: 0)

        monitor.restartGracePeriod(output: initial, at: start)
        XCTAssertEqual(
            monitor.observe(
                output: PlaybackOutputCounters(
                    displayedPictures: 1,
                    playedAudioBuffers: 1
                ),
                at: start.addingTimeInterval(0.1),
                expectsOutput: true,
                hasFreshInput: true,
                expectsAudio: true
            ),
            .none
        )
        XCTAssertEqual(
            monitor.observe(
                output: PlaybackOutputCounters(
                    displayedPictures: 30,
                    playedAudioBuffers: 1
                ),
                at: start.addingTimeInterval(1.59),
                expectsOutput: true,
                hasFreshInput: true,
                expectsAudio: true
            ),
            .none
        )
        XCTAssertEqual(
            monitor.observe(
                output: PlaybackOutputCounters(
                    displayedPictures: 31,
                    playedAudioBuffers: 1
                ),
                at: start.addingTimeInterval(1.61),
                expectsOutput: true,
                hasFreshInput: true,
                expectsAudio: true
            ),
            .rebuildPlayerForStartupAudioStall
        )
    }

    func testOutputWatchdogAllowsHalfSecondStartupAudioCounterGaps() {
        var monitor = PlaybackOutputHealthMonitor()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        var output = PlaybackOutputCounters(displayedPictures: 0, playedAudioBuffers: 0)

        monitor.restartGracePeriod(output: output, at: start)
        for step in 1...7 {
            output = PlaybackOutputCounters(
                displayedPictures: step * 12,
                playedAudioBuffers: step
            )
            XCTAssertEqual(
                monitor.observe(
                    output: output,
                    at: start.addingTimeInterval(Double(step) * 0.5),
                    expectsOutput: true,
                    hasFreshInput: true,
                    expectsAudio: true
                ),
                .none
            )
        }

        // Three seconds of advancing output proves the startup cadence. A
        // subsequent 1.5-second statistics gap therefore uses the normal,
        // deliberately tolerant steady-state watchdog instead.
        XCTAssertEqual(
            monitor.observe(
                output: PlaybackOutputCounters(
                    displayedPictures: 120,
                    playedAudioBuffers: output.playedAudioBuffers
                ),
                at: start.addingTimeInterval(5),
                expectsOutput: true,
                hasFreshInput: true,
                expectsAudio: true
            ),
            .none
        )
        XCTAssertEqual(
            monitor.observe(
                output: PlaybackOutputCounters(
                    displayedPictures: 300,
                    playedAudioBuffers: output.playedAudioBuffers
                ),
                at: start.addingTimeInterval(13.5),
                expectsOutput: true,
                hasFreshInput: true,
                expectsAudio: true
            ),
            .rebuildPlayer
        )
    }

    func testOutputWatchdogRebuildsWhenExpectedAudioNeverStarts() {
        var monitor = PlaybackOutputHealthMonitor()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let initial = PlaybackOutputCounters(displayedPictures: 20, playedAudioBuffers: 0)

        monitor.restartGracePeriod(output: initial, at: start)
        XCTAssertEqual(
            monitor.observe(
                output: PlaybackOutputCounters(
                    displayedPictures: 21,
                    playedAudioBuffers: 0
                ),
                at: start.addingTimeInterval(1),
                expectsOutput: true,
                hasFreshInput: true,
                expectsAudio: true
            ),
            .none
        )
        XCTAssertEqual(
            monitor.observe(
                output: PlaybackOutputCounters(
                    displayedPictures: 30,
                    playedAudioBuffers: 0
                ),
                at: start.addingTimeInterval(11),
                expectsOutput: true,
                hasFreshInput: true,
                expectsAudio: true
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

    func testCompletedRecordingSeekUsesNormalizedPosition() {
        XCTAssertEqual(
            RecordingSeekPolicy.command(
                for: .recording(isGrowing: false),
                targetSeconds: 45,
                durationSeconds: 180
            ),
            .normalizedPosition(0.25)
        )
    }

    func testGrowingRecordingSeekKeepsAbsoluteTime() {
        XCTAssertEqual(
            RecordingSeekPolicy.command(
                for: .recording(isGrowing: true),
                targetSeconds: 45,
                durationSeconds: 180
            ),
            .absoluteTime(milliseconds: 45_000)
        )
    }

    func testPendingRecordingSeekKeepsRequestedTimeUntilVLCActuallyLands() {
        let requestedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let pending = PendingRecordingSeek(targetSeconds: 45, requestedAt: requestedAt)

        XCTAssertEqual(
            pending.resolution(
                observedSeconds: 10,
                at: requestedAt.addingTimeInterval(0.5)
            ),
            .pending(displayedSeconds: 45)
        )
        XCTAssertEqual(
            pending.resolution(
                observedSeconds: 44.25,
                at: requestedAt.addingTimeInterval(0.75)
            ),
            .landed(displayedSeconds: 44.25)
        )
        XCTAssertEqual(
            pending.resolution(
                observedSeconds: 10,
                at: requestedAt.addingTimeInterval(2.5)
            ),
            .timedOut(displayedSeconds: 10)
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

    func testPlaybackMarkerUsesMediaClockDeltaWhenClockUpdatesLessOftenThanPolling() {
        var tracker = LivePlaybackPositionTracker()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        tracker.pause(at: start, liveDelay: 0, bufferStartedAt: nil)
        tracker.requestResume(
            from: PlaybackOutputCounters(
                displayedPictures: 100,
                playedAudioBuffers: 100,
                playbackTimeMilliseconds: 10_000
            )
        )

        // The first presented sample releases the resume anchor.
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

        // VLC commonly publishes the same media time across consecutive UI
        // polls. The idle poll must not discard half of the next clock delta.
        XCTAssertFalse(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(
                    displayedPictures: 102,
                    playedAudioBuffers: 102,
                    playbackTimeMilliseconds: 10_500
                ),
                at: start.addingTimeInterval(1)
            )
        )
        XCTAssertTrue(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(
                    displayedPictures: 103,
                    playedAudioBuffers: 103,
                    playbackTimeMilliseconds: 11_500
                ),
                at: start.addingTimeInterval(1.5)
            )
        )
        XCTAssertFalse(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(
                    displayedPictures: 104,
                    playedAudioBuffers: 104,
                    playbackTimeMilliseconds: 11_500
                ),
                at: start.addingTimeInterval(2)
            )
        )
        XCTAssertTrue(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(
                    displayedPictures: 105,
                    playedAudioBuffers: 105,
                    playbackTimeMilliseconds: 12_500
                ),
                at: start.addingTimeInterval(2.5)
            )
        )

        XCTAssertEqual(
            tracker.playbackDate(
                at: start.addingTimeInterval(2.5),
                liveDelay: 0,
                bufferStartedAt: nil
            ),
            start.addingTimeInterval(2)
        )
    }

    func testPlaybackMarkerRejectsImplausibleForwardMediaClockDiscontinuity() {
        var tracker = LivePlaybackPositionTracker()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        tracker.pause(at: start, liveDelay: 0, bufferStartedAt: nil)
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
        XCTAssertTrue(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(
                    displayedPictures: 102,
                    playedAudioBuffers: 102,
                    playbackTimeMilliseconds: 6_010_500
                ),
                at: start.addingTimeInterval(1)
            )
        )

        XCTAssertEqual(
            tracker.playbackDate(
                at: start.addingTimeInterval(1),
                liveDelay: 0,
                bufferStartedAt: nil
            ),
            start.addingTimeInterval(0.5)
        )
    }

    func testPlaybackDateClampsCorruptFutureAnchorToLiveEdge() {
        var tracker = LivePlaybackPositionTracker()
        let liveEdge = Date(timeIntervalSinceReferenceDate: 10_000)
        tracker.recoverAtLiveEdge(liveEdge.addingTimeInterval(6_000))

        XCTAssertEqual(
            tracker.playbackDate(
                at: liveEdge,
                liveDelay: 0,
                bufferStartedAt: liveEdge.addingTimeInterval(-60)
            ),
            liveEdge
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

    func testBackwardSeekClockResetReleasesTimelineOnAcceptedTargetFrame() {
        var tracker = LivePlaybackPositionTracker()
        let seekTime = Date(timeIntervalSinceReferenceDate: 10_000)
        tracker.pause(at: seekTime, liveDelay: 0, bufferStartedAt: nil)
        tracker.moveAnchor(
            by: -10,
            at: seekTime,
            bufferStartedAt: nil
        )
        tracker.requestResume(
            from: PlaybackOutputCounters(
                displayedPictures: 20,
                playedAudioBuffers: 30,
                playbackTimeMilliseconds: 20_000
            )
        )

        XCTAssertTrue(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(
                    displayedPictures: 21,
                    playedAudioBuffers: 31,
                    playbackTimeMilliseconds: 10_000
                ),
                at: seekTime
            )
        )
        XCTAssertFalse(tracker.isAwaitingPlaybackProgress)
        XCTAssertTrue(
            tracker.observePlaybackOutput(
                PlaybackOutputCounters(
                    displayedPictures: 22,
                    playedAudioBuffers: 32,
                    playbackTimeMilliseconds: 10_500
                ),
                at: seekTime.addingTimeInterval(0.5)
            )
        )
        XCTAssertEqual(
            tracker.playbackDate(
                at: seekTime.addingTimeInterval(0.5),
                liveDelay: 10,
                bufferStartedAt: nil
            ),
            seekTime.addingTimeInterval(-9.5)
        )
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
                    landingTime: 105_000_000,
                    serverLandingTime: 104_900_000,
                    bufferStartTime: 0,
                    liveEdgeTime: 120_000_000
                )
            )
        )
    }

    func testAbsoluteSeekPrerollsFromKeyframeToExactTarget() {
        var coordinator = HTSPAbsoluteSeekCoordinator()
        _ = coordinator.update(
            metrics: timeshiftMetrics(start: 0, end: 120, delay: 30),
            updateCurrentPosition: true
        )

        XCTAssertEqual(coordinator.requestRelative(seconds: -15), 75_000_000)
        XCTAssertEqual(
            coordinator.complete(landingTime: 74_480_000),
            .buffer(
                HTSPNavigationResult(
                    landingTime: 75_000_000,
                    serverLandingTime: 74_480_000,
                    bufferStartTime: 0,
                    liveEdgeTime: 120_000_000
                )
            )
        )
    }

    func testAbsoluteSeekRetriesEarlierWhenKeyframeIsAfterTarget() {
        var coordinator = HTSPAbsoluteSeekCoordinator()
        _ = coordinator.update(
            metrics: timeshiftMetrics(start: 0, end: 120, delay: 30),
            updateCurrentPosition: true
        )

        XCTAssertEqual(coordinator.requestRelative(seconds: -15), 75_000_000)
        XCTAssertEqual(coordinator.complete(landingTime: 75_520_000), .seek(74_000_000))
        XCTAssertEqual(
            coordinator.complete(landingTime: 73_800_000),
            .buffer(
                HTSPNavigationResult(
                    landingTime: 75_000_000,
                    serverLandingTime: 73_800_000,
                    bufferStartTime: 0,
                    liveEdgeTime: 120_000_000
                )
            )
        )
    }

    func testAbsoluteSeekAcceptsServerEarliestPositionAfterCorrectionMakesNoProgress() {
        var coordinator = HTSPAbsoluteSeekCoordinator()
        _ = coordinator.update(
            metrics: timeshiftMetrics(start: 0, end: 120, delay: 30),
            updateCurrentPosition: true
        )

        XCTAssertEqual(coordinator.requestRelative(seconds: -15), 75_000_000)
        XCTAssertEqual(coordinator.complete(landingTime: 76_000_000), .seek(74_000_000))
        XCTAssertEqual(
            coordinator.complete(landingTime: 76_000_000),
            .buffer(
                HTSPNavigationResult(
                    landingTime: 76_000_000,
                    bufferStartTime: 0,
                    liveEdgeTime: 120_000_000
                )
            )
        )
    }

    func testAbsoluteSeekAcceptsLandingWithinToleranceAfterTarget() {
        var coordinator = HTSPAbsoluteSeekCoordinator()
        _ = coordinator.update(
            metrics: timeshiftMetrics(start: 0, end: 120, delay: 30),
            updateCurrentPosition: true
        )

        XCTAssertEqual(coordinator.requestRelative(seconds: -15), 75_000_000)
        XCTAssertEqual(
            coordinator.complete(landingTime: 75_200_000),
            .buffer(
                HTSPNavigationResult(
                    landingTime: 75_000_000,
                    serverLandingTime: 75_200_000,
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

    func testDuplicateLiveEdgeRequestAfterLandingIsIdempotent() {
        var coordinator = HTSPAbsoluteSeekCoordinator()
        _ = coordinator.update(
            metrics: timeshiftMetrics(start: 0, end: 120, delay: 20),
            updateCurrentPosition: true
        )
        XCTAssertEqual(coordinator.requestLiveEdge(), 120_000_000)
        _ = coordinator.complete(landingTime: 120_000_000)

        XCTAssertNil(coordinator.requestLiveEdge())
        XCTAssertNil(coordinator.inFlightTarget)
        XCTAssertFalse(coordinator.hasPendingNavigation)
        XCTAssertFalse(coordinator.isWaitingForTimeline)
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

    func testSuccessfulPauseCommandReleasesQueuedResumeWithoutSpeedNotification() {
        var speed = HTSPSubscriptionSpeedController()

        XCTAssertEqual(speed.request(0), 0)
        XCTAssertNil(speed.request(100))
        XCTAssertEqual(speed.commandSucceeded(0), 100)
        XCTAssertNil(speed.commandSucceeded(0))
        XCTAssertNil(speed.commandSucceeded(100))
        XCTAssertEqual(speed.actualSpeed, 100)
        XCTAssertNil(speed.outstandingSpeed)
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

    func testSeekWaitsUntilTheOrderedPauseCommandHasBeenWritten() {
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

    func testPostSeekOutputGateRejectsQueuedOutputUntilFreshOutputFollowsDiscontinuity() {
        var gate = PostSeekPlaybackOutputGate()
        let beforeSeek = PlaybackOutputCounters(
            displayedPictures: 20,
            playedAudioBuffers: 30,
            demuxDiscontinuities: 4
        )
        gate.arm(from: beforeSeek)
        XCTAssertTrue(gate.beginConcealing(from: beforeSeek))

        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 21,
                    playedAudioBuffers: 31,
                    demuxDiscontinuities: 4
                )
            )
        )
        XCTAssertTrue(gate.isConcealing)

        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 21,
                    playedAudioBuffers: 31,
                    demuxDiscontinuities: 5
                )
            )
        )
        XCTAssertTrue(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 22,
                    playedAudioBuffers: 32,
                    demuxDiscontinuities: 5
                )
            )
        )
        XCTAssertFalse(gate.isArmed)
        XCTAssertFalse(gate.isConcealing)
    }

    func testPostSeekOutputGateHandlesDiscontinuityConsumedWhilePaused() {
        var gate = PostSeekPlaybackOutputGate()
        let beforeSeek = PlaybackOutputCounters(
            displayedPictures: 20,
            playedAudioBuffers: 30,
            demuxDiscontinuities: 4
        )
        let bufferedWhilePaused = PlaybackOutputCounters(
            displayedPictures: 20,
            playedAudioBuffers: 30,
            demuxDiscontinuities: 5
        )
        gate.arm(from: beforeSeek)

        XCTAssertFalse(gate.observe(bufferedWhilePaused))
        XCTAssertTrue(gate.beginConcealing(from: bufferedWhilePaused))
        XCTAssertTrue(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 21,
                    playedAudioBuffers: 31,
                    demuxDiscontinuities: 5
                )
            )
        )
    }

    func testPostSeekOutputGateAcceptsFreshPipelineWithoutDemuxDiscontinuity() {
        var gate = PostSeekPlaybackOutputGate()
        let oldPipeline = PlaybackOutputCounters(
            displayedPictures: 400,
            playedAudioBuffers: 500,
            demuxDiscontinuities: 8
        )
        gate.arm(from: oldPipeline)
        gate.requireDisplayedPictures(2)
        gate.markPipelineRecreated()

        let freshPipeline = PlaybackOutputCounters(
            displayedPictures: 0,
            playedAudioBuffers: 0,
            demuxDiscontinuities: 0
        )
        XCTAssertTrue(gate.beginConcealing(from: freshPipeline))
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 1,
                    playedAudioBuffers: 1,
                    demuxDiscontinuities: 0
                )
            )
        )
        XCTAssertTrue(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 2,
                    playedAudioBuffers: 2,
                    demuxDiscontinuities: 0
                )
            )
        )
    }

    func testPostSeekOutputGateDiagnosticsSeparateProgressAndStablePictures() {
        var gate = PostSeekPlaybackOutputGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let initial = PlaybackOutputCounters(
            displayedPictures: 0,
            playedAudioBuffers: 0,
            playbackTimeMilliseconds: 1_000
        )
        gate.arm(from: initial)
        gate.requirePrerollDuration(0.1)
        gate.requireDisplayedPictures(2)
        gate.markPipelineRecreated()
        XCTAssertTrue(gate.beginConcealing(from: initial))

        XCTAssertEqual(
            gate.diagnostics(for: initial, at: startedAt).phase,
            .waitingForSustainedOutput
        )
        let targetReached = PlaybackOutputCounters(
            displayedPictures: 1,
            playedAudioBuffers: 1,
            playbackTimeMilliseconds: 1_100
        )
        XCTAssertFalse(gate.observe(targetReached, at: startedAt))
        XCTAssertEqual(
            gate.diagnostics(
                for: targetReached,
                at: startedAt.addingTimeInterval(0.099)
            ).phase,
            .waitingForSustainedOutput
        )
        let stable = PlaybackOutputCounters(
            displayedPictures: 3,
            playedAudioBuffers: 3,
            playbackTimeMilliseconds: 1_180
        )
        let readyAt = startedAt.addingTimeInterval(0.1)
        XCTAssertEqual(gate.diagnostics(for: stable, at: readyAt).phase, .ready)
        XCTAssertTrue(gate.observe(stable, at: readyAt))
    }

    func testPostSeekOutputGateRejectsBurstUntilVideoAdvancesAfterQuarterSecond() {
        var gate = PostSeekPlaybackOutputGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        let initial = PlaybackOutputCounters(
            displayedPictures: 0,
            playedAudioBuffers: 0
        )
        gate.arm(from: initial)
        gate.requireSustainedOutput(0.25)
        gate.requireDisplayedPictures(12)
        gate.markPipelineRecreated()
        XCTAssertTrue(gate.beginConcealing(from: initial))

        let burst = PlaybackOutputCounters(
            displayedPictures: 12,
            playedAudioBuffers: 20
        )
        XCTAssertFalse(gate.observe(burst, at: startedAt))
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 13,
                    playedAudioBuffers: 21
                ),
                at: startedAt.addingTimeInterval(0.249)
            )
        )
        let quarterSecond = startedAt.addingTimeInterval(0.25)
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 13,
                    playedAudioBuffers: 21
                ),
                at: quarterSecond
            )
        )
        XCTAssertTrue(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 14,
                    playedAudioBuffers: 22
                ),
                at: quarterSecond
            )
        )
    }

    func testPostSeekOutputGateRestartsSustainedWindowAfterObservedCadenceBreak() {
        var gate = PostSeekPlaybackOutputGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_250)
        let initial = PlaybackOutputCounters(
            displayedPictures: 0,
            playedAudioBuffers: 0
        )
        gate.arm(from: initial)
        gate.requireSustainedOutput(0.25)
        gate.requireDisplayedPictures(2)
        gate.requireAudioOutput()
        gate.markPipelineRecreated()
        XCTAssertTrue(gate.beginConcealing(from: initial))

        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 1, playedAudioBuffers: 1),
            at: startedAt
        ))
        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 2, playedAudioBuffers: 2),
            at: startedAt.addingTimeInterval(0.1)
        ))

        let stalled = PlaybackOutputCounters(displayedPictures: 2, playedAudioBuffers: 10)
        XCTAssertFalse(gate.observe(
            stalled,
            at: startedAt.addingTimeInterval(0.4)
        ))
        XCTAssertEqual(
            gate.diagnostics(
                for: stalled,
                at: startedAt.addingTimeInterval(0.4)
            ).sustainedOutputMilliseconds,
            0
        )

        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 3, playedAudioBuffers: 11),
            at: startedAt.addingTimeInterval(0.41)
        ))
        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 4, playedAudioBuffers: 12),
            at: startedAt.addingTimeInterval(0.659)
        ))
        XCTAssertTrue(gate.observe(
            PlaybackOutputCounters(displayedPictures: 5, playedAudioBuffers: 13),
            at: startedAt.addingTimeInterval(0.66)
        ))
    }

    func testPostSeekOutputGateRestartsSustainedWindowWhenAudioStalls() {
        var gate = PostSeekPlaybackOutputGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_300)
        let initial = PlaybackOutputCounters(
            displayedPictures: 0,
            playedAudioBuffers: 0
        )
        gate.arm(from: initial)
        gate.requireSustainedOutput(0.25)
        gate.requireDisplayedPictures(2)
        gate.requireAudioOutput()
        gate.markPipelineRecreated()
        XCTAssertTrue(gate.beginConcealing(from: initial))

        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 1, playedAudioBuffers: 1),
            at: startedAt
        ))
        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 2, playedAudioBuffers: 2),
            at: startedAt.addingTimeInterval(0.1)
        ))

        let stalled = PlaybackOutputCounters(displayedPictures: 3, playedAudioBuffers: 2)
        XCTAssertFalse(gate.observe(
            stalled,
            at: startedAt.addingTimeInterval(0.4)
        ))
        XCTAssertEqual(
            gate.diagnostics(
                for: stalled,
                at: startedAt.addingTimeInterval(0.4)
            ).sustainedOutputMilliseconds,
            0
        )

        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 4, playedAudioBuffers: 3),
            at: startedAt.addingTimeInterval(0.41)
        ))
        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 5, playedAudioBuffers: 4),
            at: startedAt.addingTimeInterval(0.659)
        ))
        XCTAssertTrue(gate.observe(
            PlaybackOutputCounters(displayedPictures: 6, playedAudioBuffers: 5),
            at: startedAt.addingTimeInterval(0.66)
        ))
    }

    func testPostSeekOutputGateKeepsContinuityAcrossDelayedAdvancingPoll() {
        var gate = PostSeekPlaybackOutputGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_350)
        let initial = PlaybackOutputCounters(
            displayedPictures: 0,
            playedAudioBuffers: 0
        )
        gate.arm(from: initial)
        gate.requireSustainedOutput(0.25)
        gate.requireDisplayedPictures(2)
        gate.requireAudioOutput()
        gate.markPipelineRecreated()
        XCTAssertTrue(gate.beginConcealing(from: initial))

        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 1, playedAudioBuffers: 1),
            at: startedAt
        ))
        XCTAssertTrue(gate.observe(
            PlaybackOutputCounters(displayedPictures: 2, playedAudioBuffers: 2),
            at: startedAt.addingTimeInterval(0.4)
        ))
    }

    func testPostSeekOutputGateAcceptsAlternatingAudioVideoCounterUpdates() {
        var gate = PostSeekPlaybackOutputGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_400)
        let initial = PlaybackOutputCounters(
            displayedPictures: 0,
            playedAudioBuffers: 0
        )
        gate.arm(from: initial)
        gate.requireSustainedOutput(0.25)
        gate.requireDisplayedPictures(2)
        gate.requireAudioOutput()
        gate.markPipelineRecreated()
        XCTAssertTrue(gate.beginConcealing(from: initial))

        let samples: [(TimeInterval, PlaybackOutputCounters)] = [
            (0, .init(displayedPictures: 1, playedAudioBuffers: 0)),
            (0.05, .init(displayedPictures: 1, playedAudioBuffers: 1)),
            (0.10, .init(displayedPictures: 2, playedAudioBuffers: 1)),
            (0.15, .init(displayedPictures: 2, playedAudioBuffers: 2)),
            (0.20, .init(displayedPictures: 3, playedAudioBuffers: 2)),
            (0.25, .init(displayedPictures: 3, playedAudioBuffers: 3)),
        ]
        for (offset, output) in samples {
            XCTAssertFalse(gate.observe(
                output,
                at: startedAt.addingTimeInterval(offset)
            ))
        }
        XCTAssertTrue(gate.observe(
            PlaybackOutputCounters(displayedPictures: 4, playedAudioBuffers: 3),
            at: startedAt.addingTimeInterval(0.30)
        ))
    }

    func testPostSeekOutputGateRebasesContinuityWhenAudioBecomesRequired() {
        var gate = PostSeekPlaybackOutputGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_450)
        let initial = PlaybackOutputCounters(
            displayedPictures: 0,
            playedAudioBuffers: 0
        )
        gate.arm(from: initial)
        gate.requireSustainedOutput(0.25)
        gate.requireDisplayedPictures(2)
        gate.markPipelineRecreated()
        XCTAssertTrue(gate.beginConcealing(from: initial))

        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 1, playedAudioBuffers: 0),
            at: startedAt
        ))
        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 2, playedAudioBuffers: 0),
            at: startedAt.addingTimeInterval(0.2)
        ))

        gate.requireAudioOutput()
        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 3, playedAudioBuffers: 1),
            at: startedAt.addingTimeInterval(0.25)
        ))
        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 4, playedAudioBuffers: 2),
            at: startedAt.addingTimeInterval(0.499)
        ))
        XCTAssertTrue(gate.observe(
            PlaybackOutputCounters(displayedPictures: 5, playedAudioBuffers: 3),
            at: startedAt.addingTimeInterval(0.5)
        ))
    }

    func testPostSeekOutputGatePreservesPictureProgressWhenAudioBecomesRequired() {
        var gate = PostSeekPlaybackOutputGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_475)
        let initial = PlaybackOutputCounters(
            displayedPictures: 0,
            playedAudioBuffers: 0
        )
        gate.arm(from: initial)
        gate.requireSustainedOutput(0.25)
        gate.requireDisplayedPictures(12)
        gate.markPipelineRecreated()
        XCTAssertTrue(gate.beginConcealing(from: initial))

        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 10, playedAudioBuffers: 0),
            at: startedAt
        ))
        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 11, playedAudioBuffers: 0),
            at: startedAt.addingTimeInterval(0.2)
        ))

        gate.requireAudioOutput()
        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 12, playedAudioBuffers: 1),
            at: startedAt.addingTimeInterval(0.25)
        ))
        XCTAssertFalse(gate.observe(
            PlaybackOutputCounters(displayedPictures: 13, playedAudioBuffers: 2),
            at: startedAt.addingTimeInterval(0.499)
        ))
        XCTAssertTrue(gate.observe(
            PlaybackOutputCounters(displayedPictures: 14, playedAudioBuffers: 3),
            at: startedAt.addingTimeInterval(0.5)
        ))
    }

    func testPostSeekOutputGateWaitsForStableVideoAfterAudioOutputStarts() {
        var gate = PostSeekPlaybackOutputGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_500)
        let initial = PlaybackOutputCounters(
            displayedPictures: 0,
            playedAudioBuffers: 0
        )
        gate.arm(from: initial)
        gate.requireSustainedOutput(0.25)
        gate.requireDisplayedPictures(2)
        gate.requireAudioOutput()
        gate.markPipelineRecreated()
        XCTAssertTrue(gate.beginConcealing(from: initial))

        let videoOnly = PlaybackOutputCounters(
            displayedPictures: 2,
            playedAudioBuffers: 0
        )
        XCTAssertFalse(gate.observe(videoOnly, at: startedAt))
        XCTAssertEqual(
            gate.diagnostics(for: videoOnly, at: startedAt).phase,
            .waitingForAudio
        )
        let audioStarted = PlaybackOutputCounters(
            displayedPictures: 3,
            playedAudioBuffers: 1
        )
        XCTAssertFalse(
            gate.observe(audioStarted, at: startedAt.addingTimeInterval(1))
        )
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 4,
                    playedAudioBuffers: 2
                ),
                at: startedAt.addingTimeInterval(1.249)
            )
        )
        let readyAt = startedAt.addingTimeInterval(1.25)
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 4,
                    playedAudioBuffers: 2
                ),
                at: readyAt
            )
        )
        XCTAssertTrue(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 5,
                    playedAudioBuffers: 3
                ),
                at: readyAt
            )
        )
    }

    func testPostSeekOutputGatePrerollAndLateAudioStabilityRunIndependently() {
        var gate = PostSeekPlaybackOutputGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_750)
        let initial = PlaybackOutputCounters(
            displayedPictures: 0,
            playedAudioBuffers: 0
        )
        gate.arm(from: initial)
        gate.requirePrerollDuration(1.2)
        gate.requireSustainedOutput(0.25)
        gate.requireDisplayedPictures(2)
        gate.requireAudioOutput()
        gate.markPipelineRecreated()
        XCTAssertTrue(gate.beginConcealing(from: initial))

        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 2,
                    playedAudioBuffers: 0
                ),
                at: startedAt
            )
        )
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 3,
                    playedAudioBuffers: 1
                ),
                at: startedAt.addingTimeInterval(0.8)
            )
        )
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 4,
                    playedAudioBuffers: 2
                ),
                at: startedAt.addingTimeInterval(1.05)
            )
        )
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 5,
                    playedAudioBuffers: 3
                ),
                at: startedAt.addingTimeInterval(1.199)
            )
        )
        XCTAssertTrue(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 6,
                    playedAudioBuffers: 4
                ),
                at: startedAt.addingTimeInterval(1.201)
            )
        )
    }

    func testPostSeekOutputGatePrimesFreshPictureAfterImmediatePausedConcealment() {
        var gate = PostSeekPlaybackOutputGate()
        let beforeSeek = PlaybackOutputCounters(
            displayedPictures: 20,
            playedAudioBuffers: 30,
            demuxDiscontinuities: 4,
            playbackTimeMilliseconds: 10_000
        )
        let bufferedWhilePaused = PlaybackOutputCounters(
            displayedPictures: 20,
            playedAudioBuffers: 30,
            demuxDiscontinuities: 5,
            playbackTimeMilliseconds: 8_000
        )
        gate.arm(from: beforeSeek)
        gate.requireDisplayedPicture()

        XCTAssertTrue(gate.concealImmediately())
        XCTAssertFalse(gate.observe(bufferedWhilePaused))
        XCTAssertTrue(gate.beginConcealing(from: bufferedWhilePaused))
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 20,
                    playedAudioBuffers: 31,
                    demuxDiscontinuities: 5,
                    playbackTimeMilliseconds: 8_040
                )
            )
        )
        XCTAssertTrue(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 21,
                    playedAudioBuffers: 31,
                    demuxDiscontinuities: 5,
                    playbackTimeMilliseconds: 8_040
                )
            )
        )
    }

    func testPostSeekOutputGateDrainsBoundedDecodedPictureQueueAfterDiscontinuity() {
        var gate = PostSeekPlaybackOutputGate()
        let beforeSeek = PlaybackOutputCounters(
            displayedPictures: 20,
            playedAudioBuffers: 30,
            demuxDiscontinuities: 4,
            playbackTimeMilliseconds: 20_000
        )
        gate.arm(from: beforeSeek)
        gate.requireDisplayedPictures(3)
        XCTAssertTrue(gate.beginConcealing(from: beforeSeek))

        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 21,
                    playedAudioBuffers: 31,
                    demuxDiscontinuities: 5,
                    playbackTimeMilliseconds: 20_040
                )
            )
        )
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 22,
                    playedAudioBuffers: 32,
                    demuxDiscontinuities: 5,
                    playbackTimeMilliseconds: 10_000
                )
            )
        )
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 23,
                    playedAudioBuffers: 33,
                    demuxDiscontinuities: 5,
                    playbackTimeMilliseconds: 10_040
                )
            )
        )
        XCTAssertTrue(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 24,
                    playedAudioBuffers: 34,
                    demuxDiscontinuities: 5,
                    playbackTimeMilliseconds: 10_080
                )
            )
        )
    }

    func testPostSeekOutputGateDoesNotRevealQueuedVideoWithoutDiscontinuity() {
        var gate = PostSeekPlaybackOutputGate()
        let beforeResume = PlaybackOutputCounters(
            displayedPictures: 100,
            playedAudioBuffers: 200,
            demuxDiscontinuities: 5,
            playbackTimeMilliseconds: 10_000
        )
        gate.arm(from: beforeResume)
        XCTAssertTrue(gate.beginConcealing(from: beforeResume))

        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 102,
                    playedAudioBuffers: 211,
                    demuxDiscontinuities: 5,
                    playbackTimeMilliseconds: 10_499
                )
            )
        )
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 103,
                    playedAudioBuffers: 212,
                    demuxDiscontinuities: 5,
                    playbackTimeMilliseconds: 10_500
                )
            )
        )
        XCTAssertTrue(gate.isConcealing)
    }

    func testPostSeekOutputGateDoesNotRevealQueuedAudioWithoutDiscontinuity() {
        var gate = PostSeekPlaybackOutputGate()
        let beforeResume = PlaybackOutputCounters(
            displayedPictures: 0,
            playedAudioBuffers: 200,
            demuxDiscontinuities: 5,
            playbackTimeMilliseconds: 10_000
        )
        gate.arm(from: beforeResume)
        XCTAssertTrue(gate.beginConcealing(from: beforeResume))

        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 0,
                    playedAudioBuffers: 212,
                    demuxDiscontinuities: 5,
                    playbackTimeMilliseconds: 9_500
                )
            )
        )
        XCTAssertTrue(gate.isConcealing)
    }

    func testPostSeekOutputGateConcealsBeforeResumeWithoutEvaluatingQueuedOutput() {
        var gate = PostSeekPlaybackOutputGate()
        let beforeSeek = PlaybackOutputCounters(
            displayedPictures: 20,
            playedAudioBuffers: 30,
            demuxDiscontinuities: 4,
            playbackTimeMilliseconds: 10_000
        )
        gate.arm(from: beforeSeek)

        XCTAssertTrue(gate.concealImmediately())
        XCTAssertTrue(gate.isConcealing)
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 100,
                    playedAudioBuffers: 200,
                    demuxDiscontinuities: 5,
                    playbackTimeMilliseconds: 20_000
                )
            )
        )
        XCTAssertTrue(gate.isConcealing)
    }

    func testPostSeekOutputGateConcealsKeyframePrerollUntilExactTarget() {
        var gate = PostSeekPlaybackOutputGate()
        let startedAt = Date(timeIntervalSinceReferenceDate: 3_000)
        let beforeResume = PlaybackOutputCounters(
            displayedPictures: 100,
            playedAudioBuffers: 200,
            demuxDiscontinuities: 5,
            playbackTimeMilliseconds: 10_000
        )
        gate.arm(from: beforeResume)
        gate.requireSustainedOutput(0.25)
        gate.requirePrerollDuration(1.2)
        XCTAssertTrue(gate.beginConcealing(from: beforeResume))

        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 101,
                    playedAudioBuffers: 201,
                    demuxDiscontinuities: 6,
                    playbackTimeMilliseconds: 8_000
                ),
                at: startedAt
            )
        )
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 120,
                    playedAudioBuffers: 220,
                    demuxDiscontinuities: 6,
                    playbackTimeMilliseconds: 9_199
                ),
                at: startedAt
            )
        )
        XCTAssertFalse(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 121,
                    playedAudioBuffers: 221,
                    demuxDiscontinuities: 6,
                    playbackTimeMilliseconds: 9_200
                ),
                at: startedAt.addingTimeInterval(1.199)
            )
        )
        XCTAssertTrue(
            gate.observe(
                PlaybackOutputCounters(
                    displayedPictures: 122,
                    playedAudioBuffers: 222,
                    demuxDiscontinuities: 6,
                    playbackTimeMilliseconds: 9_240
                ),
                at: startedAt.addingTimeInterval(1.201)
            )
        )
    }

    func testPostSeekBufferWaitsForVideoKeyframeAndHalfSecondOfMedia() {
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
        XCTAssertNil(tracker.observePacket(time: 45_499_000))
        XCTAssertEqual(tracker.observePacket(time: 45_500_000), result)
        XCTAssertNil(tracker.result)
    }

    func testInitialTuneBufferDropsAudioBeforeFirstVideoDecodeTime() throws {
        var tracker = HTSPPostSeekBufferTracker()
        tracker.beginInitialTune(
            hasVideo: true,
            audioStreamIndexes: [2],
            requiredDuration: 500_000
        )

        XCTAssertFalse(tracker.shouldAcceptPacket(
            time: 500_000,
            duration: 20_000,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertFalse(tracker.shouldAcceptPacket(
            time: 900_000,
            decodeTime: 900_000,
            isVideo: true,
            frameType: 0x50
        ))
        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: 2_200_000,
            decodeTime: 1_000_000,
            isVideo: true,
            frameType: 0x49
        ))
        XCTAssertNil(tracker.observePacket(
            time: 2_200_000,
            decodeTime: 1_000_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x49
        ))
        XCTAssertFalse(tracker.shouldAcceptPacket(
            time: 850_000,
            duration: nil,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: 950_000,
            duration: nil,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertFalse(tracker.shouldAcceptPacket(
            time: 850_000,
            duration: 20_000,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: 990_000,
            duration: 20_000,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: 990_000,
            duration: 20_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: 2_700_000,
            decodeTime: 1_500_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x50
        ))
        let completion = try XCTUnwrap(tracker.observePacket(
            time: 1_480_000,
            duration: 20_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))

        XCTAssertEqual(completion.landingTime, 1_000_000)
        XCTAssertFalse(tracker.isActive)
        XCTAssertTrue(tracker.completionDiagnostics?.contains("droppedAudio=3") == true)
    }

    func testInitialTuneAudioOnlyAnchorsCoverageToPrimaryAudio() throws {
        var tracker = HTSPPostSeekBufferTracker()
        tracker.beginInitialTune(
            hasVideo: false,
            audioStreamIndexes: [2],
            requiredDuration: 500_000
        )

        XCTAssertNil(tracker.observePacket(
            time: 9_000_000,
            streamIndex: 3,
            isVideo: false,
            isAudio: false,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: 9_500_000,
            streamIndex: 3,
            isVideo: false,
            isAudio: false,
            frameType: 0
        ))

        XCTAssertNil(tracker.observePacket(
            time: 10_000_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: 10_499_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        let completion = try XCTUnwrap(tracker.observePacket(
            time: 10_500_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))

        XCTAssertEqual(completion.landingTime, 10_000_000)
        XCTAssertFalse(tracker.isActive)
    }

    func testInitialTuneWithoutTimestampsWaitsForBoundedOwnerFallback() {
        var tracker = HTSPPostSeekBufferTracker()
        tracker.beginInitialTune(hasVideo: false)

        for _ in 0..<100 {
            XCTAssertNil(tracker.observePacket(
                time: nil,
                streamIndex: 2,
                isVideo: false,
                isAudio: true,
                frameType: 0
            ))
        }
        XCTAssertTrue(tracker.isActive)
    }

    func testPostSeekBufferDoesNotResumeWithoutTimestampProof() {
        var tracker = HTSPPostSeekBufferTracker()
        let result = HTSPNavigationResult(
            landingTime: 0,
            bufferStartTime: nil,
            liveEdgeTime: nil
        )
        tracker.begin(result, hasVideo: false)

        for _ in 0..<100 {
            XCTAssertNil(tracker.observePacket(time: nil))
        }
        XCTAssertEqual(tracker.result, result)
    }

    func testPostSeekBufferCanCoverFullVLCStartupCache() {
        var tracker = HTSPPostSeekBufferTracker()
        let result = HTSPNavigationResult(
            landingTime: 45_000_000,
            bufferStartTime: 0,
            liveEdgeTime: 120_000_000
        )
        tracker.begin(
            result,
            hasVideo: false,
            requiredDuration: 1_500_000
        )

        XCTAssertNil(tracker.observePacket(time: 45_000_000))
        XCTAssertNil(tracker.observePacket(time: 45_500_000))
        XCTAssertNil(tracker.observePacket(time: 46_499_000))
        XCTAssertEqual(tracker.observePacket(time: 46_500_000), result)
    }

    func testPostSeekBufferReportsTrackAndFrameCoverage() {
        var tracker = HTSPPostSeekBufferTracker()
        let result = HTSPNavigationResult(
            landingTime: 45_000_000,
            bufferStartTime: 0,
            liveEdgeTime: 120_000_000
        )
        tracker.begin(
            result,
            hasVideo: true,
            audioStreamIndexes: [2],
            requiredDuration: 1_500_000
        )

        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: 45_000_000,
            isVideo: true,
            frameType: 0x49
        ))
        XCTAssertNil(tracker.observePacket(
            time: 45_000_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x49
        ))
        XCTAssertNil(tracker.observePacket(
            time: 45_020_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: 45_040_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x50
        ))
        XCTAssertNil(tracker.observePacket(
            time: 45_080_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x42
        ))
        XCTAssertNil(tracker.observePacket(
            time: 46_500_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x50
        ))
        XCTAssertEqual(tracker.observePacket(
            time: 46_500_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ), result)
        XCTAssertTrue(tracker.completionDiagnostics?.contains("video=4(I1/P2/B1)") == true)
        XCTAssertTrue(tracker.completionDiagnostics?.contains("audio=2") == true)
        XCTAssertTrue(tracker.completionDiagnostics?.contains("firstAV=20ms") == true)
    }

    func testPostSeekBufferTrimsOnlyAudioEndingBeforeVideoLeadTolerance() {
        var tracker = HTSPPostSeekBufferTracker()
        let result = HTSPNavigationResult(
            landingTime: 45_500_000,
            bufferStartTime: 0,
            liveEdgeTime: 120_000_000
        )
        tracker.begin(result, hasVideo: true, audioStreamIndexes: [2])

        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: 45_000_000,
            isVideo: true,
            frameType: 0x49
        ))
        XCTAssertNil(tracker.observePacket(
            time: 45_000_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x49
        ))
        XCTAssertFalse(tracker.shouldAcceptPacket(
            time: 44_870_000,
            duration: 20_000,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: nil,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: nil,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: 45_500_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x50
        ))
        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: 44_900_000,
            duration: 20_000,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: 44_900_000,
            duration: 20_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: 45_480_000,
            duration: 20_000,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: 45_480_000,
            duration: 20_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: 46_000_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x50
        ))
        XCTAssertEqual(tracker.observePacket(
            time: 45_980_000,
            duration: 20_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ), result)
        XCTAssertTrue(tracker.completionDiagnostics?.contains("firstAV=-100ms") == true)
        XCTAssertTrue(tracker.completionDiagnostics?.contains("droppedAudio=1") == true)
    }

    func testPostSeekBufferAnchorsAudioTrimToVideoDecodeTime() {
        var tracker = HTSPPostSeekBufferTracker()
        let result = HTSPNavigationResult(
            landingTime: 45_000_000,
            bufferStartTime: 0,
            liveEdgeTime: 120_000_000
        )
        tracker.begin(result, hasVideo: true, audioStreamIndexes: [2])

        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: 45_000_000,
            decodeTime: 43_800_000,
            isVideo: true,
            frameType: 0x49
        ))
        XCTAssertNil(tracker.observePacket(
            time: 45_000_000,
            decodeTime: 43_800_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x49
        ))
        XCTAssertFalse(tracker.shouldAcceptPacket(
            time: 43_670_000,
            duration: 20_000,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: 43_680_000,
            duration: 20_000,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: 43_680_000,
            duration: 20_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: 44_980_000,
            duration: 20_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: 46_200_000,
            decodeTime: 45_000_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x50
        ))
        XCTAssertNil(tracker.observePacket(
            time: 45_480_000,
            duration: 20_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertEqual(tracker.observePacket(
            time: 46_700_000,
            decodeTime: 45_500_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x50
        ), result)
    }

    func testPostSeekBufferRequiresCoverageFromEveryAudioStream() {
        var tracker = HTSPPostSeekBufferTracker()
        let result = HTSPNavigationResult(
            landingTime: 10_000_000,
            bufferStartTime: 0,
            liveEdgeTime: 20_000_000
        )
        tracker.begin(result, hasVideo: true, audioStreamIndexes: [2, 3])

        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: 10_000_000,
            isVideo: true,
            frameType: 0x49
        ))
        XCTAssertNil(tracker.observePacket(
            time: 10_000_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x49
        ))
        XCTAssertNil(tracker.observePacket(
            time: 10_500_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x50
        ))
        XCTAssertNil(tracker.observePacket(
            time: 10_480_000,
            duration: 20_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertEqual(tracker.observePacket(
            time: 10_480_000,
            duration: 20_000,
            streamIndex: 3,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ), result)
    }

    func testPostSeekBufferKeepsUnknownDurationAudioWithoutUsingItAsCoverage() {
        var tracker = HTSPPostSeekBufferTracker()
        let result = HTSPNavigationResult(
            landingTime: 10_000_000,
            bufferStartTime: 0,
            liveEdgeTime: 20_000_000
        )
        tracker.begin(result, hasVideo: true, audioStreamIndexes: [2])

        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: 10_000_000,
            isVideo: true,
            frameType: 0x49
        ))
        XCTAssertNil(tracker.observePacket(
            time: 10_000_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x49
        ))
        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: 9_000_000,
            duration: nil,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: 9_000_000,
            duration: nil,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))
        XCTAssertNil(tracker.observePacket(
            time: 10_500_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x50
        ))
        XCTAssertEqual(tracker.observePacket(
            time: 10_500_000,
            duration: nil,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ), result)
    }

    func testPostSeekBufferKeepsReserveAfterPrerollAndExactTarget() {
        var tracker = HTSPPostSeekBufferTracker()
        let result = HTSPNavigationResult(
            landingTime: 45_000_000,
            serverLandingTime: 43_000_000,
            bufferStartTime: 0,
            liveEdgeTime: 120_000_000
        )
        tracker.begin(result, hasVideo: false)

        XCTAssertNil(tracker.observePacket(time: 43_000_000))
        XCTAssertNil(tracker.observePacket(time: 44_500_000))
        XCTAssertNil(tracker.observePacket(time: 45_000_000))
        XCTAssertNil(tracker.observePacket(time: 45_499_000))
        XCTAssertEqual(tracker.observePacket(time: 45_500_000), result)
    }

    func testPostSeekBufferKeepsMatchingAudioAndVideoReserveAfterPreroll() {
        var tracker = HTSPPostSeekBufferTracker()
        let result = HTSPNavigationResult(
            landingTime: 45_000_000,
            serverLandingTime: 43_000_000,
            bufferStartTime: 0,
            liveEdgeTime: 120_000_000
        )
        tracker.begin(result, hasVideo: true, audioStreamIndexes: [2])

        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: 44_200_000,
            decodeTime: 43_000_000,
            isVideo: true,
            frameType: 0x49
        ))
        XCTAssertNil(tracker.observePacket(
            time: 44_200_000,
            decodeTime: 43_000_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x49
        ))
        XCTAssertNil(tracker.observePacket(
            time: 45_200_000,
            decodeTime: 45_000_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x50
        ))
        XCTAssertNil(tracker.observePacket(
            time: 44_980_000,
            duration: 20_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))

        // Reaching the requested position is not enough: the concealed
        // two-second preroll must not consume the half-second safety reserve.
        XCTAssertNil(tracker.observePacket(
            time: 45_700_000,
            decodeTime: 45_500_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x50
        ))
        XCTAssertEqual(tracker.observePacket(
            time: 45_480_000,
            duration: 20_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ), result)
    }

    func testPostSeekBufferReportsVideoBurstTail() {
        var tracker = HTSPPostSeekBufferTracker()
        let result = HTSPNavigationResult(
            landingTime: 10_000_000,
            bufferStartTime: 0,
            liveEdgeTime: 20_000_000
        )
        tracker.begin(result, hasVideo: true, audioStreamIndexes: [2])

        XCTAssertTrue(tracker.shouldAcceptPacket(
            time: 10_000_000,
            decodeTime: 10_000_000,
            isVideo: true,
            frameType: 0x49
        ))
        XCTAssertNil(tracker.observePacket(
            time: 10_000_000,
            decodeTime: 10_000_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x49
        ))
        XCTAssertNil(tracker.observePacket(
            time: 10_480_000,
            duration: 20_000,
            streamIndex: 2,
            isVideo: false,
            isAudio: true,
            frameType: 0
        ))

        // Both streams have the nominal reserve, while diagnostics retain the
        // scheduling skew that the staging reserve needs to absorb.
        XCTAssertEqual(tracker.observePacket(
            time: 12_000_000,
            decodeTime: 12_000_000,
            isVideo: true,
            isAudio: false,
            frameType: 0x50
        ), result)
        XCTAssertTrue(tracker.completionDiagnostics?.contains("audioTailLag=1500ms") == true)
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
