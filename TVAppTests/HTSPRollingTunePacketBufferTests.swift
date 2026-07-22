import Foundation
import XCTest
@testable import TVApp

final class HTSPRollingTunePacketBufferTests: XCTestCase {
    func testFreshAlignedWindowClaimsReadySnapshot() {
        var buffer = makeBuffer()
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)

        appendAlignedWindow(
            to: &buffer,
            anchorTime: 1_000_000,
            tags: (videoKeyframe: 1, videoTail: 2, audioTail: 3),
            startedAt: startedAt
        )

        XCTAssertTrue(buffer.isReady)
        guard case let .ready(snapshot) = buffer.claim(
            at: startedAt.addingTimeInterval(0.3),
            maximumAlignedAge: 0.5
        ) else {
            return XCTFail("A fresh timestamp-aligned window should be claimable.")
        }
        XCTAssertEqual(packetTags(snapshot.orderedPackets), [1, 3, 2])
        XCTAssertEqual(snapshot.payloadByteCount, 3)
        XCTAssertEqual(snapshot.commonHorizonMicroseconds, 500_000)
        XCTAssertEqual(snapshot.readyAt, startedAt.addingTimeInterval(0.2))
        XCTAssertEqual(snapshot.lastAlignedOutputAt, startedAt.addingTimeInterval(0.2))
        XCTAssertFalse(buffer.isReady)
        XCTAssertEqual(buffer.payloadByteCount, 0)
    }

    func testReadyWindowRemainsClaimableWhileNewKeyframeWindowIsIncomplete() {
        var buffer = makeBuffer()
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        appendAlignedWindow(
            to: &buffer,
            anchorTime: 1_000_000,
            tags: (videoKeyframe: 1, videoTail: 2, audioTail: 3),
            startedAt: startedAt
        )
        XCTAssertTrue(buffer.isReady)

        let replacementStartedAt = startedAt.addingTimeInterval(0.3)
        buffer.append(
            packet(
                stream: 1,
                frameType: 0x49,
                presentationTime: 2_000_000,
                decodeTime: 2_000_000,
                tag: 4
            ),
            isVideo: true,
            isAudio: false,
            at: replacementStartedAt
        )
        XCTAssertTrue(buffer.isReady)
        XCTAssertEqual(buffer.payloadByteCount, 4)

        guard case let .ready(snapshot) = buffer.claim(
            at: replacementStartedAt.addingTimeInterval(0.05),
            maximumAlignedAge: 0.5
        ) else {
            return XCTFail("The last complete window must remain claimable during replacement.")
        }
        XCTAssertEqual(packetTags(snapshot.orderedPackets), [1, 3, 2])
    }

    func testReadyWindowIsAtomicallyReplacedAfterNewWindowAligns() {
        var buffer = makeBuffer(maximumPayloadBytes: 6)
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_100)
        appendAlignedWindow(
            to: &buffer,
            anchorTime: 1_000_000,
            tags: (videoKeyframe: 1, videoTail: 2, audioTail: 3),
            startedAt: startedAt
        )

        let replacementStartedAt = startedAt.addingTimeInterval(0.3)
        buffer.append(
            packet(
                stream: 1,
                frameType: 0x49,
                presentationTime: 2_000_000,
                decodeTime: 2_000_000,
                tag: 4
            ),
            isVideo: true,
            isAudio: false,
            at: replacementStartedAt
        )
        XCTAssertTrue(buffer.isReady)
        XCTAssertLessThanOrEqual(buffer.payloadByteCount, 6)

        buffer.append(
            packet(
                stream: 1,
                frameType: 0x50,
                presentationTime: 2_500_000,
                decodeTime: 2_500_000,
                tag: 5
            ),
            isVideo: true,
            isAudio: false,
            at: replacementStartedAt.addingTimeInterval(0.1)
        )
        XCTAssertTrue(buffer.isReady)
        XCTAssertLessThanOrEqual(buffer.payloadByteCount, 6)

        buffer.append(
            packet(
                stream: 2,
                presentationTime: 2_480_000,
                decodeTime: nil,
                duration: 20_000,
                tag: 6
            ),
            isVideo: false,
            isAudio: true,
            at: replacementStartedAt.addingTimeInterval(0.2)
        )
        XCTAssertTrue(buffer.isReady)
        XCTAssertLessThanOrEqual(buffer.payloadByteCount, 6)

        guard case let .ready(snapshot) = buffer.claim(
            at: replacementStartedAt.addingTimeInterval(0.3),
            maximumAlignedAge: 0.5
        ) else {
            return XCTFail("The replacement keyframe window should become ready.")
        }
        XCTAssertEqual(packetTags(snapshot.orderedPackets), [4, 6, 5])
        XCTAssertFalse(packetTags(snapshot.orderedPackets).contains(where: { $0 < 4 }))
        XCTAssertEqual(snapshot.readyAt, replacementStartedAt.addingTimeInterval(0.2))
    }

    func testStaleSnapshotIsRejectedWhileIncompleteWindowReturnsPartialStager() {
        var buffer = makeBuffer()
        let startedAt = Date(timeIntervalSinceReferenceDate: 3_000)
        appendAlignedWindow(
            to: &buffer,
            anchorTime: 1_000_000,
            tags: (videoKeyframe: 1, videoTail: 2, audioTail: 3),
            startedAt: startedAt
        )
        let partialStartedAt = startedAt.addingTimeInterval(0.6)
        buffer.append(
            packet(
                stream: 1,
                frameType: 0x49,
                presentationTime: 2_000_000,
                decodeTime: 2_000_000,
                tag: 4
            ),
            isVideo: true,
            isAudio: false,
            at: partialStartedAt
        )
        guard case var .partial(partial) = buffer.claim(
            at: startedAt.addingTimeInterval(1),
            maximumAlignedAge: 0.5
        ) else {
            return XCTFail("A stale committed window should yield its reusable replacement stager.")
        }
        XCTAssertTrue(partial.isActive)
        XCTAssertFalse(buffer.isReady)
        XCTAssertEqual(buffer.payloadByteCount, 0)

        _ = partial.append(
            packet(
                stream: 1,
                frameType: 0x50,
                presentationTime: 2_500_000,
                decodeTime: 2_500_000,
                tag: 5
            ),
            isVideo: true,
            isAudio: false,
            at: partialStartedAt.addingTimeInterval(0.2)
        )
        let completion = partial.append(
            packet(
                stream: 2,
                presentationTime: 2_480_000,
                decodeTime: nil,
                duration: 20_000,
                tag: 6
            ),
            isVideo: false,
            isAudio: true,
            at: partialStartedAt.addingTimeInterval(0.3)
        )
        guard case let .ready(batch, _, _, _) = completion else {
            return XCTFail("The claimed partial stager should preserve its keyframe state.")
        }
        XCTAssertEqual(packetTags(batch.interleavedPackets), [4, 6, 5])
    }

    func testPartialClaimReceivesFullForegroundPayloadBudget() {
        var buffer = makeBuffer(maximumPayloadBytes: 4)
        let startedAt = Date(timeIntervalSinceReferenceDate: 3_100)
        appendAlignedWindow(
            to: &buffer,
            anchorTime: 1_000_000,
            tags: (videoKeyframe: 1, videoTail: 2, audioTail: 3),
            startedAt: startedAt
        )

        let replacementStartedAt = startedAt.addingTimeInterval(0.3)
        buffer.append(
            packet(
                stream: 1,
                frameType: 0x49,
                presentationTime: 2_000_000,
                decodeTime: 2_000_000,
                tag: 4
            ),
            isVideo: true,
            isAudio: false,
            at: replacementStartedAt
        )
        XCTAssertEqual(buffer.payloadByteCount, 4)

        guard case var .partial(partial) = buffer.claim(
            at: replacementStartedAt.addingTimeInterval(0.01),
            maximumAlignedAge: 0
        ) else {
            return XCTFail("A stale committed window should yield its partial replacement.")
        }
        guard case .waiting = partial.append(
            packet(
                stream: 1,
                frameType: 0x50,
                presentationTime: 2_500_000,
                decodeTime: 2_500_000,
                tag: 5
            ),
            isVideo: true,
            isAudio: false,
            at: replacementStartedAt.addingTimeInterval(0.1)
        ) else {
            return XCTFail("Promotion should replace the candidate's one-byte residual budget.")
        }
        let completion = partial.append(
            packet(
                stream: 2,
                presentationTime: 2_480_000,
                decodeTime: nil,
                duration: 20_000,
                tag: 6
            ),
            isVideo: false,
            isAudio: true,
            at: replacementStartedAt.addingTimeInterval(0.2)
        )
        guard case let .ready(batch, _, _, _) = completion else {
            return XCTFail("The promoted partial should finish a full aligned A/V window.")
        }
        XCTAssertEqual(packetTags(batch.interleavedPackets), [4, 6, 5])
    }

    func testPartialClaimReceivesFreshForegroundDeadline() {
        var buffer = makeBuffer()
        let startedAt = Date(timeIntervalSinceReferenceDate: 3_200)
        appendAlignedWindow(
            to: &buffer,
            anchorTime: 1_000_000,
            tags: (videoKeyframe: 1, videoTail: 2, audioTail: 3),
            startedAt: startedAt
        )

        let replacementStartedAt = startedAt.addingTimeInterval(0.3)
        buffer.append(
            packet(
                stream: 1,
                frameType: 0x49,
                presentationTime: 2_000_000,
                decodeTime: 2_000_000,
                tag: 4
            ),
            isVideo: true,
            isAudio: false,
            at: replacementStartedAt
        )
        let promotedAt = replacementStartedAt.addingTimeInterval(3)
        guard case var .partial(partial) = buffer.claim(
            at: promotedAt,
            maximumAlignedAge: 0.5
        ) else {
            return XCTFail("An old partial replacement should still be reusable at promotion.")
        }

        guard case .waiting = partial.append(
            packet(
                stream: 1,
                frameType: 0x50,
                presentationTime: 2_500_000,
                decodeTime: 2_500_000,
                tag: 5
            ),
            isVideo: true,
            isAudio: false,
            at: promotedAt.addingTimeInterval(0.1)
        ) else {
            return XCTFail("The post-keyframe deadline should restart when promotion begins.")
        }
        let completion = partial.append(
            packet(
                stream: 2,
                presentationTime: 2_480_000,
                decodeTime: nil,
                duration: 20_000,
                tag: 6
            ),
            isVideo: false,
            isAudio: true,
            at: promotedAt.addingTimeInterval(0.2)
        )
        guard case let .ready(batch, _, _, _) = completion else {
            return XCTFail("The refreshed partial should complete before its new deadline.")
        }
        XCTAssertEqual(packetTags(batch.interleavedPackets), [4, 6, 5])
    }

    func testPayloadLimitFreezesRatherThanInvalidatesReadyWindow() {
        var buffer = makeBuffer(maximumPayloadBytes: 3)
        let startedAt = Date(timeIntervalSinceReferenceDate: 4_000)
        appendAlignedWindow(
            to: &buffer,
            anchorTime: 1_000_000,
            tags: (videoKeyframe: 1, videoTail: 2, audioTail: 3),
            startedAt: startedAt
        )
        XCTAssertTrue(buffer.isReady)
        XCTAssertEqual(buffer.payloadByteCount, 3)

        buffer.append(
            packet(
                stream: 1,
                frameType: 0x50,
                presentationTime: 1_600_000,
                decodeTime: 1_600_000,
                tag: 4
            ),
            isVideo: true,
            isAudio: false,
            at: startedAt.addingTimeInterval(0.3)
        )

        XCTAssertTrue(buffer.isReady)
        XCTAssertEqual(buffer.payloadByteCount, 3)
        guard case let .ready(snapshot) = buffer.claim(
            at: startedAt.addingTimeInterval(0.4)
        ) else {
            return XCTFail("Reaching the payload bound must preserve the ready snapshot.")
        }
        XCTAssertEqual(packetTags(snapshot.orderedPackets), [1, 3, 2])
    }

    func testCommittedAndPendingWindowsSharePayloadBound() {
        var buffer = makeBuffer(maximumPayloadBytes: 4)
        let startedAt = Date(timeIntervalSinceReferenceDate: 4_100)
        appendAlignedWindow(
            to: &buffer,
            anchorTime: 1_000_000,
            tags: (videoKeyframe: 1, videoTail: 2, audioTail: 3),
            startedAt: startedAt
        )

        let replacementStartedAt = startedAt.addingTimeInterval(0.3)
        buffer.append(
            packet(
                stream: 1,
                frameType: 0x49,
                presentationTime: 2_000_000,
                decodeTime: 2_000_000,
                tag: 4
            ),
            isVideo: true,
            isAudio: false,
            at: replacementStartedAt
        )
        XCTAssertEqual(buffer.payloadByteCount, 4)

        buffer.append(
            packet(
                stream: 1,
                frameType: 0x50,
                presentationTime: 2_500_000,
                decodeTime: 2_500_000,
                tag: 5
            ),
            isVideo: true,
            isAudio: false,
            at: replacementStartedAt.addingTimeInterval(0.1)
        )

        XCTAssertLessThanOrEqual(buffer.payloadByteCount, 4)
        XCTAssertTrue(buffer.isReady)
        guard case let .ready(snapshot) = buffer.claim(
            at: replacementStartedAt.addingTimeInterval(0.2),
            maximumAlignedAge: 0.5
        ) else {
            return XCTFail("A replacement that cannot fit must leave the committed window intact.")
        }
        XCTAssertEqual(packetTags(snapshot.orderedPackets), [1, 3, 2])
    }

    private func makeBuffer(
        maximumPayloadBytes: Int = .max
    ) -> HTSPRollingTunePacketBuffer {
        var buffer = HTSPRollingTunePacketBuffer()
        buffer.begin(
            hasVideo: true,
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2,
            requiredDuration: 500_000,
            maximumPayloadBytes: maximumPayloadBytes
        )
        return buffer
    }

    private func appendAlignedWindow(
        to buffer: inout HTSPRollingTunePacketBuffer,
        anchorTime: Int64,
        tags: (videoKeyframe: UInt8, videoTail: UInt8, audioTail: UInt8),
        startedAt: Date
    ) {
        buffer.append(
            packet(
                stream: 1,
                frameType: 0x49,
                presentationTime: anchorTime,
                decodeTime: anchorTime,
                tag: tags.videoKeyframe
            ),
            isVideo: true,
            isAudio: false,
            at: startedAt
        )
        buffer.append(
            packet(
                stream: 1,
                frameType: 0x50,
                presentationTime: anchorTime + 500_000,
                decodeTime: anchorTime + 500_000,
                tag: tags.videoTail
            ),
            isVideo: true,
            isAudio: false,
            at: startedAt.addingTimeInterval(0.1)
        )
        buffer.append(
            packet(
                stream: 2,
                presentationTime: anchorTime + 480_000,
                decodeTime: nil,
                duration: 20_000,
                tag: tags.audioTail
            ),
            isVideo: false,
            isAudio: true,
            at: startedAt.addingTimeInterval(0.2)
        )
    }

    private func packet(
        stream: Int,
        frameType: UInt8 = 0,
        presentationTime: Int64?,
        decodeTime: Int64?,
        duration: Int64? = nil,
        tag: UInt8
    ) -> HTSPMuxPacket {
        HTSPMuxPacket(
            streamIndex: stream,
            frameType: frameType,
            presentationTime: presentationTime,
            decodeTime: decodeTime,
            durationMicroseconds: duration,
            payload: Data([tag])
        )
    }

    private func packetTags(_ packets: [HTSPMuxPacket]) -> [UInt8] {
        packets.compactMap { $0.payload.first }
    }
}
