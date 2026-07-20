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
                PlaybackOutputCounters(displayedPictures: 21, playedAudioBuffers: 30)
            )
        )

        XCTAssertEqual(
            tracker.playbackDate(
                at: pauseTime.addingTimeInterval(3),
                liveDelay: 6,
                bufferStartedAt: nil
            ),
            pauseTime.addingTimeInterval(-3)
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
        XCTAssertFalse(tracker.hasAnchoredDate)
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
        XCTAssertFalse(tracker.hasAnchoredDate)
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
        XCTAssertFalse(tracker.hasAnchoredDate)
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

    func testDeliveryGateDropsPacketsUntilNavigationCompletes() {
        let gate = HTSPTimeshiftDeliveryGate()

        XCTAssertTrue(gate.shouldDeliverPackets)
        gate.beginNavigation()
        XCTAssertFalse(gate.shouldDeliverPackets)
        XCTAssertTrue(gate.completeNavigation())
        XCTAssertTrue(gate.shouldDeliverPackets)
        XCTAssertTrue(gate.consumePostNavigationPacket())
        XCTAssertFalse(gate.consumePostNavigationPacket())
    }

    func testDeliveryGateWaitsForEveryOverlappingNavigation() {
        let gate = HTSPTimeshiftDeliveryGate()

        gate.beginNavigation()
        gate.beginNavigation()
        XCTAssertFalse(gate.completeNavigation())
        XCTAssertFalse(gate.shouldDeliverPackets)
        XCTAssertTrue(gate.completeNavigation())
        XCTAssertTrue(gate.shouldDeliverPackets)
        XCTAssertTrue(gate.consumePostNavigationPacket())
    }

    func testDeliveryGateCanRecoverAfterCommandFailure() {
        let gate = HTSPTimeshiftDeliveryGate()

        gate.beginNavigation()
        gate.beginNavigation()
        gate.cancelAllNavigation()

        XCTAssertTrue(gate.shouldDeliverPackets)
    }

    func testDeliveryGateIgnoresAnAcknowledgementWithoutPendingNavigation() {
        let gate = HTSPTimeshiftDeliveryGate()

        XCTAssertFalse(gate.completeNavigation())
        XCTAssertFalse(gate.consumePostNavigationPacket())
        XCTAssertTrue(gate.shouldDeliverPackets)
    }

    func testNewSeekCancelsReadinessFromPreviousSeekPacket() {
        let gate = HTSPTimeshiftDeliveryGate()

        gate.beginNavigation()
        XCTAssertTrue(gate.completeNavigation())
        gate.beginNavigation()

        XCTAssertFalse(gate.consumePostNavigationPacket())
        XCTAssertFalse(gate.shouldDeliverPackets)
    }

    private func makeController() -> (NativeTimeshiftActionController, RecordingTimeshiftSink) {
        let sink = RecordingTimeshiftSink()
        return (NativeTimeshiftActionController(sink: sink), sink)
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
