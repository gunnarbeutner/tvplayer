import Foundation
import XCTest
@testable import TVApp

final class HTSPTimeshiftTests: XCTestCase {
    private static var candidateConfiguration: TVHeadendConfiguration {
        TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.local:9981"),
            username: "viewer",
            password: "secret",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )
    }

    private static var alignedCandidateReads: [ScriptedHTSPRead] {
        [
            .message([
                "method": .string("subscriptionStart"),
                "streams": .list([
                    .map(["index": .int(1), "type": .string("H264")]),
                    .map([
                        "index": .int(2),
                        "type": .string("AAC"),
                        "language": .string("eng"),
                    ]),
                ]),
            ]),
            .message([
                "method": .string("muxpkt"),
                "stream": .int(1),
                "frametype": .int(73),
                "pts": .int(1_000_000),
                "dts": .int(1_000_000),
                "payload": .data(Data([0, 0, 0, 1, 0x65, 0x88, 0x84])),
            ]),
            .message([
                "method": .string("muxpkt"),
                "stream": .int(1),
                "frametype": .int(80),
                "pts": .int(1_500_000),
                "dts": .int(1_500_000),
                "payload": .data(Data([0, 0, 0, 1, 0x41, 0x9a])),
            ]),
            .message([
                "method": .string("muxpkt"),
                "stream": .int(2),
                "pts": .int(1_480_000),
                "duration": .int(20_000),
                "payload": .data(Data([0x11, 0x22, 0x33])),
            ]),
        ]
    }

    func testHTSPMessageCodecRoundTripsProtocolValues() throws {
        let message: [String: HTSPValue] = [
            "method": .string("subscriptionSkip"),
            "time": .int(-15_000_000),
            "enabled": .bool(true),
            "challenge": .data(Data([0x01, 0x7f, 0xff])),
            "streams": .list([
                .map([
                    "index": .int(3),
                    "type": .string("H264"),
                ]),
            ]),
        ]

        let encoded = try HTSPMessageCodec.encode(message)
        let payloadLength = Int(HTSPMessageCodec.readBigEndianUInt32(encoded, at: 0))

        XCTAssertEqual(payloadLength, encoded.count - 4)
        XCTAssertEqual(
            try HTSPMessageCodec.decodePayload(Data(encoded.dropFirst(4))),
            message
        )
    }

    func testCanonicalStreamURLProvidesNumericHTSPChannelID() throws {
        let url = try XCTUnwrap(
            URL(string: "http://tvheadend.local:9981/stream/channelid/42?ticket=temporary")
        )

        XCTAssertEqual(TVHeadendClient.numericChannelID(from: url), 42)
        XCTAssertNil(
            TVHeadendClient.numericChannelID(
                from: try XCTUnwrap(URL(string: "http://tvheadend.local:9981/stream/channel/uuid"))
            )
        )
    }

    func testServerInfoDecodesTimeshiftCapability() throws {
        let data = Data(
            #"{"name":"Tvheadend","sw_version":"4.3","capabilities":["timeshift","trace"]}"#.utf8
        )

        let info = try JSONDecoder().decode(TVHeadendServerInfo.self, from: data)

        XCTAssertEqual(info.name, "Tvheadend")
        XCTAssertEqual(info.version, "4.3")
        XCTAssertEqual(info.capabilities, ["timeshift", "trace"])
    }

    func testTransportMuxerProducesAlignedPacketsAndDiscontinuity() throws {
        let muxer = try MPEGTransportStreamMuxer(
            streams: [
                HTSPStreamInfo(
                    index: 1,
                    type: "H264",
                    language: nil,
                    metadata: nil
                ),
            ]
        )
        let packet = HTSPMuxPacket(
            streamIndex: 1,
            frameType: 73,
            presentationTime: 1_000_000,
            decodeTime: 1_000_000,
            payload: Data([0, 0, 0, 1, 0x65, 0x88, 0x84])
        )

        let output = muxer.mux(packet)

        XCTAssertEqual(output.count % 188, 0)
        for offset in stride(from: 0, to: output.count, by: 188) {
            XCTAssertEqual(output[offset], 0x47)
        }
        XCTAssertGreaterThanOrEqual(output.count, 3 * 188)
        let firstElementaryPacket = 2 * 188
        XCTAssertEqual(output[firstElementaryPacket + 3] & 0x20, 0x20)
        XCTAssertEqual(output[firstElementaryPacket + 5] & 0x80, 0x80)
        XCTAssertEqual(output[3] & 0x20, 0x20)
        XCTAssertEqual(output[5] & 0x80, 0x80)
        XCTAssertEqual(output[188 + 3] & 0x20, 0x20)
        XCTAssertEqual(output[188 + 5] & 0x80, 0x80)

        muxer.resetAfterDiscontinuity()
        let resumed = muxer.mux(packet)
        XCTAssertEqual(resumed[2 * 188 + 5] & 0x80, 0x80)
    }

    func testTransportMuxerReportsAudioTracksForDiagnostics() throws {
        let muxer = try MPEGTransportStreamMuxer(
            streams: [
                HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil),
                HTSPStreamInfo(index: 2, type: "AAC", language: "eng", metadata: nil),
                HTSPStreamInfo(index: 3, type: "AC3", language: "deu", metadata: nil),
            ]
        )

        XCTAssertEqual(muxer.audioStreamTypes, ["AAC", "AC3"])
        XCTAssertEqual(muxer.primaryAudioStreamIndex, 2)
        XCTAssertFalse(muxer.isAudioStream(1))
        XCTAssertTrue(muxer.isAudioStream(2))
        XCTAssertTrue(muxer.isAudioStream(3))
        XCTAssertFalse(muxer.isAudioStream(99))

        _ = muxer.mux(
            HTSPMuxPacket(
                streamIndex: 2,
                frameType: 0,
                presentationTime: 1_000_000,
                decodeTime: 1_000_000,
                payload: Data([0xff, 0xf1, 0x50, 0x80])
            )
        )
        _ = muxer.mux(
            HTSPMuxPacket(
                streamIndex: 1,
                frameType: 0x49,
                presentationTime: 1_040_000,
                decodeTime: 1_040_000,
                payload: Data([0, 0, 0, 1, 0x65])
            )
        )

        let startup = muxer.startupSnapshot
        XCTAssertTrue(startup.trackLayout.contains("101=AAC:eng"))
        XCTAssertTrue(startup.packetOrder.hasPrefix("a101@0"))
        XCTAssertEqual(startup.audioVideoTimestampDeltaMilliseconds, -40)
        XCTAssertNotEqual(startup.patPrefix, "unseen")
        XCTAssertNotEqual(startup.pmtPrefix, "unseen")
        XCTAssertTrue(startup.audioPESPrefixes.contains("101:000001c0"))
    }

    func testTransportMuxerMarksEveryElementaryPIDAfterASeek() throws {
        let muxer = try MPEGTransportStreamMuxer(
            streams: [
                HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil),
                HTSPStreamInfo(index: 2, type: "AAC", language: "eng", metadata: nil),
            ]
        )
        let video = HTSPMuxPacket(
            streamIndex: 1,
            frameType: 0x49,
            presentationTime: 1_000_000,
            decodeTime: 1_000_000,
            payload: Data([0, 0, 0, 1, 0x65])
        )
        let audio = HTSPMuxPacket(
            streamIndex: 2,
            frameType: 0,
            presentationTime: 1_000_000,
            decodeTime: 1_000_000,
            payload: Data([0xff, 0xf1, 0x50, 0x80])
        )

        let firstVideo = muxer.mux(video)
        let firstAudio = muxer.mux(audio)

        XCTAssertTrue(firstPacketHasDiscontinuity(pid: 0x0100, in: firstVideo))
        XCTAssertTrue(firstPacketHasDiscontinuity(pid: 0x0101, in: firstAudio))
        XCTAssertFalse(firstPacketHasVLCDiscontinuity(pid: 0x0100, in: firstVideo))
        XCTAssertFalse(firstPacketHasVLCDiscontinuity(pid: 0x0101, in: firstAudio))
        XCTAssertFalse(firstPacketHasDiscontinuity(pid: 0x0101, in: muxer.mux(audio)))

        muxer.resetAfterDiscontinuity()
        let resumedVideo = muxer.mux(video)
        let resumedAudio = muxer.mux(audio)
        XCTAssertTrue(firstPacketHasDiscontinuity(pid: 0x0100, in: resumedVideo))
        XCTAssertTrue(firstPacketHasDiscontinuity(pid: 0x0101, in: resumedAudio))
        XCTAssertTrue(firstPacketHasVLCDiscontinuity(pid: 0x0100, in: resumedVideo))
        XCTAssertTrue(firstPacketHasVLCDiscontinuity(pid: 0x0101, in: resumedAudio))
    }

    func testTransportMuxerStartsFreshPipelineWithoutDecoderFlushMarker() throws {
        let muxer = try MPEGTransportStreamMuxer(
            streams: [
                HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil),
                HTSPStreamInfo(index: 2, type: "AAC", language: "eng", metadata: nil),
            ]
        )
        let video = HTSPMuxPacket(
            streamIndex: 1,
            frameType: 0x49,
            presentationTime: 30_000_000,
            decodeTime: 29_980_000,
            payload: Data([0, 0, 0, 1, 0x65])
        )
        let audio = HTSPMuxPacket(
            streamIndex: 2,
            frameType: 0,
            presentationTime: 30_000_000,
            decodeTime: 30_000_000,
            payload: Data([0xff, 0xf1, 0x50, 0x80])
        )

        _ = muxer.mux(video)
        _ = muxer.mux(audio)
        muxer.resetForFreshPipeline()

        let resumedVideo = muxer.mux(video)
        let resumedAudio = muxer.mux(audio)
        XCTAssertTrue(firstPacketHasDiscontinuity(pid: 0x0100, in: resumedVideo))
        XCTAssertTrue(firstPacketHasDiscontinuity(pid: 0x0101, in: resumedAudio))
        XCTAssertFalse(firstPacketHasVLCDiscontinuity(pid: 0x0100, in: resumedVideo))
        XCTAssertFalse(firstPacketHasVLCDiscontinuity(pid: 0x0101, in: resumedAudio))
        XCTAssertTrue(firstPacketHasPCR(pid: 0x0100, in: resumedVideo))
    }

    func testPostSeekInterleaverPinsVideoKeyframeAheadOfEarlierAudio() {
        var stager = HTSPPostSeekPacketStager()
        stager.begin(pinsInitialVideoKeyframe: true)
        XCTAssertTrue(stager.append(
            taggedPacket(stream: 1, frameType: 0x49, pts: 2_200_000, dts: 1_000_000, tag: 1),
            isVideo: true,
            maximumPayloadBytes: .max
        ))
        XCTAssertTrue(stager.append(
            taggedPacket(stream: 2, pts: 950_000, dts: nil, tag: 2),
            isVideo: false,
            maximumPayloadBytes: .max
        ))
        XCTAssertTrue(stager.append(
            taggedPacket(stream: 1, frameType: 0x50, pts: 1_040_000, dts: 1_040_000, tag: 3),
            isVideo: true,
            maximumPayloadBytes: .max
        ))

        XCTAssertEqual(
            stager.finish().interleavedPackets.map { $0.payload[0] },
            [1, 2, 3]
        )
    }

    func testPostSeekInterleaverUsesDTSAcrossStreamsWithoutReorderingAStream() {
        var stager = HTSPPostSeekPacketStager()
        stager.begin(pinsInitialVideoKeyframe: true)
        let packets: [(HTSPMuxPacket, Bool)] = [
            (taggedPacket(stream: 1, frameType: 0x49, pts: 2_000_000, dts: 1_000_000, tag: 1), true),
            // Its PTS precedes audio, but its decode time does not.
            (taggedPacket(stream: 1, frameType: 0x50, pts: 1_010_000, dts: 1_080_000, tag: 2), true),
            (taggedPacket(stream: 2, pts: 1_020_000, dts: nil, tag: 3), false),
            // Preserve known-good arrival order inside video PID 1 despite
            // this timestamp inversion.
            (taggedPacket(stream: 1, frameType: 0x42, pts: 1_200_000, dts: 1_040_000, tag: 4), true),
        ]
        for (packet, isVideo) in packets {
            XCTAssertTrue(stager.append(
                packet,
                isVideo: isVideo,
                maximumPayloadBytes: .max
            ))
        }

        XCTAssertEqual(
            stager.finish().interleavedPackets.map { $0.payload[0] },
            [1, 3, 2, 4]
        )
    }

    func testPostSeekInterleaverUsesArrivalOrderForTimestampTiesAndMissingTimes() {
        var stager = HTSPPostSeekPacketStager()
        stager.begin(pinsInitialVideoKeyframe: true)
        let packets: [(HTSPMuxPacket, Bool)] = [
            (taggedPacket(stream: 1, frameType: 0x49, pts: 1_000_000, dts: 1_000_000, tag: 1), true),
            (taggedPacket(stream: 2, pts: 1_040_000, dts: nil, tag: 2), false),
            (taggedPacket(stream: 1, frameType: 0x50, pts: 1_040_000, dts: 1_040_000, tag: 3), true),
            (taggedPacket(stream: 3, pts: nil, dts: nil, tag: 4), false),
        ]
        for (packet, isVideo) in packets {
            XCTAssertTrue(stager.append(
                packet,
                isVideo: isVideo,
                maximumPayloadBytes: .max
            ))
        }

        XCTAssertEqual(
            stager.finish().interleavedPackets.map { $0.payload[0] },
            [1, 2, 3, 4]
        )
        XCTAssertFalse(stager.isActive)
        XCTAssertEqual(stager.payloadByteCount, 0)
    }

    func testInitialTuneStagerDropsOldAudioAndPublishesBalancedAV() throws {
        var stager = HTSPInitialTunePacketStager()
        stager.begin(
            hasVideo: true,
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2,
            requiredDuration: 500_000,
            maximumPayloadBytes: .max
        )

        let inputs: [(HTSPMuxPacket, Bool, Bool)] = [
            (taggedPacket(stream: 2, pts: 300_000, dts: nil, duration: 20_000, tag: 1), false, true),
            (taggedPacket(stream: 1, frameType: 0x50, pts: 900_000, dts: 900_000, tag: 2), true, false),
            (taggedPacket(stream: 2, pts: 850_000, dts: nil, duration: 20_000, tag: 4), false, true),
            (taggedPacket(stream: 2, pts: 990_000, dts: nil, duration: 20_000, tag: 5), false, true),
            (taggedPacket(stream: 3, pts: 995_000, dts: nil, tag: 8), false, false),
            (taggedPacket(stream: 1, frameType: 0x49, pts: 2_200_000, dts: 1_000_000, tag: 3), true, false),
            (taggedPacket(stream: 3, pts: -500_000, dts: nil, tag: 9), false, false),
            (taggedPacket(stream: 1, frameType: 0x50, pts: 2_700_000, dts: 1_500_000, tag: 6), true, false),
            (taggedPacket(stream: 2, pts: 1_480_000, dts: nil, duration: 20_000, tag: 7), false, true),
        ]
        var readyBatch: HTSPPostSeekPacketStager.Batch?
        var diagnostics = ""
        for (packet, isVideo, isAudio) in inputs {
            switch stager.append(packet, isVideo: isVideo, isAudio: isAudio) {
            case let .ready(batch, video, audio, detail):
                readyBatch = batch
                diagnostics = detail
                XCTAssertEqual(video, 1)
                XCTAssertEqual(audio, 2)
            case .passthrough, .overflow, .failure:
                XCTFail("Initial tune staging ended unexpectedly.")
            case .waiting:
                break
            }
        }

        let batch = try XCTUnwrap(readyBatch)
        var interleaver = HTSPPostSeekTailInterleaver(
            batch: batch,
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2
        )
        let outputTags = interleaver.drainAvailable().map { $0.payload[0] }
        XCTAssertEqual(outputTags, [3, 5, 8, 7, 6])
        XCTAssertFalse(outputTags.contains(1))
        XCTAssertFalse(outputTags.contains(2))
        XCTAssertFalse(outputTags.contains(4))
        XCTAssertFalse(outputTags.contains(9))
        XCTAssertTrue(diagnostics.contains("droppedAudio=2"))
        XCTAssertFalse(stager.isActive)
    }

    func testInitialTuneStagerBypassesSingleTrackStreams() {
        var stager = HTSPInitialTunePacketStager()
        stager.begin(
            hasVideo: true,
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: nil,
            requiredDuration: 500_000,
            maximumPayloadBytes: .max
        )

        let video = taggedPacket(
            stream: 1,
            frameType: 0x50,
            pts: 900_000,
            dts: 900_000,
            tag: 1
        )
        guard case let .passthrough(passthroughVideo) = stager.append(
            video,
            isVideo: true,
            isAudio: false
        ) else { return XCTFail("Video-only streams should preserve their existing path.") }
        XCTAssertEqual(passthroughVideo.payload, video.payload)
        XCTAssertFalse(stager.isActive)

        stager.begin(
            hasVideo: false,
            primaryVideoStreamIndex: nil,
            primaryAudioStreamIndex: 2,
            maximumPayloadBytes: .max
        )
        let audio = taggedPacket(stream: 2, pts: 1_000_000, dts: nil, tag: 2)
        guard case let .passthrough(passthroughAudio) = stager.append(
            audio,
            isVideo: false,
            isAudio: true
        ) else { return XCTFail("Audio-only streams should preserve their existing path.") }
        XCTAssertEqual(passthroughAudio.payload, audio.payload)
        XCTAssertFalse(stager.isActive)
    }

    func testInitialTuneTimestampFallbackDoesNotLoseTriggeringPacket() throws {
        var stager = HTSPInitialTunePacketStager()
        stager.begin(
            hasVideo: true,
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2,
            maximumPayloadBytes: .max,
            maximumWaitAfterVideoKeyframe: 1
        )
        let started = Date(timeIntervalSinceReferenceDate: 100)
        let keyframe = taggedPacket(
            stream: 1,
            frameType: 0x49,
            pts: nil,
            dts: nil,
            tag: 1
        )
        if case .waiting = stager.append(
            keyframe,
            isVideo: true,
            isAudio: false,
            at: started
        ) {} else { XCTFail("A timestamp-less keyframe still needs a bounded wait.") }

        let audio = taggedPacket(stream: 2, pts: nil, dts: nil, tag: 2)
        let overflow = stager.append(
            audio,
            isVideo: false,
            isAudio: true,
            at: started.addingTimeInterval(1)
        )
        guard case let .overflow(batch, trailingPacket, containsPrimaryAudio, _) = overflow else {
            return XCTFail("The elapsed-time cap should trigger the fallback.")
        }
        XCTAssertEqual(batch.interleavedPackets.map { $0.payload[0] }, [1, 2])
        XCTAssertNil(trailingPacket)
        XCTAssertTrue(containsPrimaryAudio)
        XCTAssertFalse(stager.isActive)

        let next = taggedPacket(stream: 2, pts: nil, dts: nil, tag: 3)
        guard case let .passthrough(packet) = stager.append(
            next,
            isVideo: false,
            isAudio: true
        ) else { return XCTFail("Packets after fallback must pass through.") }
        XCTAssertEqual(packet.payload[0], 3)
    }

    func testInitialTuneTimestampFallbackRetainsProvisionalPrimaryAudio() {
        var stager = HTSPInitialTunePacketStager()
        stager.begin(
            hasVideo: true,
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2,
            maximumPayloadBytes: .max,
            maximumWaitAfterVideoKeyframe: 1
        )
        let started = Date(timeIntervalSinceReferenceDate: 150)
        _ = stager.append(
            taggedPacket(stream: 2, pts: nil, dts: nil, tag: 1),
            isVideo: false,
            isAudio: true,
            at: started
        )
        _ = stager.append(
            taggedPacket(stream: 1, frameType: 0x49, pts: nil, dts: nil, tag: 2),
            isVideo: true,
            isAudio: false,
            at: started
        )
        let result = stager.append(
            taggedPacket(stream: 1, frameType: 0x50, pts: nil, dts: nil, tag: 3),
            isVideo: true,
            isAudio: false,
            at: started.addingTimeInterval(1)
        )
        guard case let .overflow(batch, trailingPacket, containsPrimaryAudio, _) = result else {
            return XCTFail("Timestamp-less A/V must reach the bounded fallback.")
        }
        XCTAssertNil(trailingPacket)
        XCTAssertTrue(containsPrimaryAudio)
        XCTAssertTrue(batch.containsInitialVideoKeyframe)
        XCTAssertEqual(batch.interleavedPackets.map { $0.payload[0] }, [2, 1, 3])
    }

    func testInitialTuneFailsWhenNoPrimaryVideoKeyframeArrives() {
        var stager = HTSPInitialTunePacketStager()
        stager.begin(
            hasVideo: true,
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2,
            maximumPayloadBytes: .max,
            maximumWaitBeforeVideoKeyframe: 1
        )
        let started = Date(timeIntervalSinceReferenceDate: 200)
        if case .waiting = stager.append(
            taggedPacket(stream: 1, frameType: 0x50, pts: 0, dts: 0, tag: 1),
            isVideo: true,
            isAudio: false,
            at: started
        ) {} else { XCTFail("The initial P-frame should wait for a keyframe.") }

        guard case .failure = stager.append(
            taggedPacket(stream: 2, pts: 1_000_000, dts: nil, tag: 2),
            isVideo: false,
            isAudio: true,
            at: started.addingTimeInterval(1)
        ) else { return XCTFail("A continuously active stream must not wait forever for an I-frame.") }
        XCTAssertFalse(stager.isActive)
    }

    func testInitialTuneKeyframeWinsAtPreKeyframeDeadline() {
        var stager = HTSPInitialTunePacketStager()
        stager.begin(
            hasVideo: true,
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2,
            maximumPayloadBytes: .max,
            maximumWaitBeforeVideoKeyframe: 1
        )
        let started = Date(timeIntervalSinceReferenceDate: 250)
        _ = stager.append(
            taggedPacket(stream: 2, pts: 900_000, dts: nil, tag: 1),
            isVideo: false,
            isAudio: true,
            at: started
        )
        guard case .waiting = stager.append(
            taggedPacket(stream: 1, frameType: 0x49, pts: 2_200_000, dts: 1_000_000, tag: 2),
            isVideo: true,
            isAudio: false,
            at: started.addingTimeInterval(1)
        ) else { return XCTFail("A keyframe arriving at the deadline must start the A/V window.") }
        XCTAssertTrue(stager.isActive)
    }

    func testInitialTuneDeadlineDropsRejectedOldAudioWithoutLosingBatch() throws {
        var stager = HTSPInitialTunePacketStager()
        stager.begin(
            hasVideo: true,
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2,
            maximumPayloadBytes: .max,
            maximumWaitAfterVideoKeyframe: 1
        )
        let started = Date(timeIntervalSinceReferenceDate: 300)
        _ = stager.append(
            taggedPacket(stream: 1, frameType: 0x49, pts: 1_000_000, dts: 1_000_000, tag: 1),
            isVideo: true,
            isAudio: false,
            at: started
        )
        let result = stager.append(
            taggedPacket(stream: 2, pts: 300_000, dts: nil, duration: 20_000, tag: 2),
            isVideo: false,
            isAudio: true,
            at: started.addingTimeInterval(1)
        )
        guard case let .overflow(batch, trailingPacket, containsPrimaryAudio, _) = result else {
            return XCTFail("Rejected packets must not bypass the elapsed-time bound.")
        }
        XCTAssertEqual(batch.interleavedPackets.map { $0.payload[0] }, [1])
        XCTAssertNil(trailingPacket)
        XCTAssertFalse(containsPrimaryAudio)
    }

    func testInitialTuneCompletionWinsAtDeadline() throws {
        var stager = HTSPInitialTunePacketStager()
        stager.begin(
            hasVideo: true,
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2,
            requiredDuration: 500_000,
            maximumPayloadBytes: .max,
            maximumWaitAfterVideoKeyframe: 1
        )
        let started = Date(timeIntervalSinceReferenceDate: 400)
        _ = stager.append(
            taggedPacket(stream: 1, frameType: 0x49, pts: 2_200_000, dts: 1_000_000, tag: 1),
            isVideo: true,
            isAudio: false,
            at: started
        )
        _ = stager.append(
            taggedPacket(stream: 1, frameType: 0x50, pts: 2_700_000, dts: 1_500_000, tag: 2),
            isVideo: true,
            isAudio: false,
            at: started.addingTimeInterval(0.5)
        )
        let result = stager.append(
            taggedPacket(stream: 2, pts: 1_480_000, dts: nil, duration: 20_000, tag: 3),
            isVideo: false,
            isAudio: true,
            at: started.addingTimeInterval(1)
        )
        guard case let .ready(batch, _, _, _) = result else {
            return XCTFail("A packet proving balanced coverage must beat the fallback deadline.")
        }
        XCTAssertEqual(batch.interleavedPackets.map { $0.payload[0] }, [1, 3, 2])
    }

    func testInitialTunePayloadOverflowMergesTriggeringAudioByTimestamp() {
        var stager = HTSPInitialTunePacketStager()
        stager.begin(
            hasVideo: true,
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2,
            requiredDuration: 500_000,
            maximumPayloadBytes: 2
        )
        _ = stager.append(
            taggedPacket(stream: 1, frameType: 0x49, pts: 2_200_000, dts: 1_000_000, tag: 1),
            isVideo: true,
            isAudio: false
        )
        _ = stager.append(
            taggedPacket(stream: 1, frameType: 0x50, pts: 2_700_000, dts: 1_500_000, tag: 2),
            isVideo: true,
            isAudio: false
        )
        let result = stager.append(
            taggedPacket(stream: 2, pts: 1_480_000, dts: nil, duration: 20_000, tag: 3),
            isVideo: false,
            isAudio: true
        )
        guard case let .overflow(batch, trailingPacket, containsPrimaryAudio, _) = result else {
            return XCTFail("The payload cap should publish one final merged batch.")
        }
        XCTAssertNil(trailingPacket)
        XCTAssertTrue(containsPrimaryAudio)
        XCTAssertEqual(batch.interleavedPackets.map { $0.payload[0] }, [1, 3, 2])
    }

    func testPostSeekTailInterleaverReleasesOnlyCommonAudioVideoHorizon() {
        var stager = HTSPPostSeekPacketStager()
        stager.begin(pinsInitialVideoKeyframe: true)
        let initialPackets: [(HTSPMuxPacket, Bool)] = [
            (taggedPacket(stream: 1, frameType: 0x49, pts: 1_000, dts: 1_000, tag: 1), true),
            (taggedPacket(stream: 1, frameType: 0x50, pts: 1_040, dts: 1_040, tag: 2), true),
            (taggedPacket(stream: 1, frameType: 0x50, pts: 1_080, dts: 1_080, tag: 3), true),
            (taggedPacket(stream: 2, pts: 1_020, dts: nil, duration: 20, tag: 4), false),
        ]
        for (packet, isVideo) in initialPackets {
            XCTAssertTrue(stager.append(
                packet,
                isVideo: isVideo,
                maximumPayloadBytes: .max
            ))
        }

        var interleaver = HTSPPostSeekTailInterleaver(
            batch: stager.finish(),
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2
        )
        XCTAssertEqual(
            interleaver.drainAvailable().map { $0.payload[0] },
            [1, 4, 2]
        )
        XCTAssertEqual(interleaver.queuedPayloadByteCount, 1)

        interleaver.append(
            taggedPacket(stream: 2, pts: 1_060, dts: nil, duration: 20, tag: 5)
        )
        XCTAssertEqual(
            interleaver.drainAvailable().map { $0.payload[0] },
            [5, 3]
        )
        XCTAssertEqual(interleaver.queuedPayloadByteCount, 0)
    }

    func testTailCatchUpDrainCanBringQueueBackBelowPayloadLimit() {
        var stager = HTSPPostSeekPacketStager()
        stager.begin(pinsInitialVideoKeyframe: true)
        XCTAssertTrue(stager.append(
            taggedPacket(
                stream: 1,
                frameType: 0x49,
                pts: 1_000,
                dts: 1_000,
                tag: 1
            ),
            isVideo: true,
            maximumPayloadBytes: .max
        ))
        XCTAssertTrue(stager.append(
            HTSPMuxPacket(
                streamIndex: 1,
                frameType: 0x50,
                presentationTime: 2_000,
                decodeTime: 2_000,
                payload: Data(repeating: 2, count: 8 * 1_024 * 1_024 + 1)
            ),
            isVideo: true,
            maximumPayloadBytes: .max
        ))
        XCTAssertTrue(stager.append(
            taggedPacket(
                stream: 2,
                pts: 1_000,
                dts: nil,
                duration: 100,
                tag: 3
            ),
            isVideo: false,
            maximumPayloadBytes: .max
        ))

        var interleaver = HTSPPostSeekTailInterleaver(
            batch: stager.finish(),
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2
        )
        XCTAssertEqual(interleaver.drainAvailable().map { $0.payload[0] }, [1, 3])
        XCTAssertTrue(interleaver.hasExceededPayloadLimit)

        interleaver.append(
            taggedPacket(
                stream: 2,
                pts: 2_000,
                dts: nil,
                duration: 20,
                tag: 4
            )
        )
        XCTAssertEqual(interleaver.drainAvailable().map { $0.payload[0] }, [2, 4])
        XCTAssertFalse(interleaver.hasExceededPayloadLimit)
        XCTAssertTrue(interleaver.isEmpty)
    }

    func testPostSeekTailInterleaverIgnoresAlternateAudioWatermark() {
        var stager = HTSPPostSeekPacketStager()
        stager.begin(pinsInitialVideoKeyframe: true)
        let initialPackets: [(HTSPMuxPacket, Bool)] = [
            (taggedPacket(stream: 1, frameType: 0x49, pts: 1_000, dts: 1_000, tag: 1), true),
            (taggedPacket(stream: 1, frameType: 0x50, pts: 1_120, dts: 1_120, tag: 2), true),
            (taggedPacket(stream: 2, pts: 1_060, dts: nil, duration: 20, tag: 3), false),
        ]
        for (packet, isVideo) in initialPackets {
            XCTAssertTrue(stager.append(
                packet,
                isVideo: isVideo,
                maximumPayloadBytes: .max
            ))
        }
        var interleaver = HTSPPostSeekTailInterleaver(
            batch: stager.finish(),
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2
        )
        XCTAssertEqual(interleaver.drainAvailable().map { $0.payload[0] }, [1, 3])

        interleaver.append(
            taggedPacket(stream: 3, pts: 1_200, dts: nil, duration: 20, tag: 4)
        )
        XCTAssertTrue(interleaver.drainAvailable().isEmpty)

        interleaver.append(
            taggedPacket(stream: 2, pts: 1_100, dts: nil, duration: 20, tag: 5)
        )
        XCTAssertEqual(
            interleaver.drainAvailable().map { $0.payload[0] },
            [5, 2]
        )
        // Alternate audio remains queued until the common primary horizon
        // reaches its timestamp.
        XCTAssertEqual(interleaver.queuedPayloadByteCount, 1)
    }

    func testTimestampLessPrimaryAudioDoesNotAdvanceTailWatermark() {
        var stager = HTSPPostSeekPacketStager()
        stager.begin(pinsInitialVideoKeyframe: true)
        let initialPackets: [(HTSPMuxPacket, Bool)] = [
            (taggedPacket(stream: 1, frameType: 0x49, pts: 1_000, dts: 1_000, tag: 1), true),
            (taggedPacket(stream: 1, frameType: 0x50, pts: 1_500, dts: 1_500, tag: 2), true),
            (taggedPacket(stream: 1, frameType: 0x50, pts: 2_000, dts: 2_000, tag: 3), true),
            (taggedPacket(stream: 2, pts: nil, dts: nil, tag: 4), false),
        ]
        for (packet, isVideo) in initialPackets {
            XCTAssertTrue(stager.append(
                packet,
                isVideo: isVideo,
                maximumPayloadBytes: .max
            ))
        }
        var interleaver = HTSPPostSeekTailInterleaver(
            batch: stager.finish(),
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2
        )

        XCTAssertEqual(interleaver.drainAvailable().map { $0.payload[0] }, [1])
        interleaver.append(
            taggedPacket(stream: 2, pts: 1_400, dts: nil, duration: 100, tag: 5)
        )
        XCTAssertEqual(
            interleaver.drainAvailable().map { $0.payload[0] },
            [4, 5, 2]
        )
        XCTAssertEqual(interleaver.queuedPayloadByteCount, 1)
    }

    func testKnownAudioResolvesLeadingUnknownTimeWhenKeyframeHasNoTimestamp() {
        var stager = HTSPPostSeekPacketStager()
        stager.begin(pinsInitialVideoKeyframe: true)
        let initialPackets: [(HTSPMuxPacket, Bool)] = [
            (taggedPacket(stream: 1, frameType: 0x49, pts: nil, dts: nil, tag: 1), true),
            (taggedPacket(stream: 1, frameType: 0x50, pts: 1_500, dts: 1_500, tag: 2), true),
            (taggedPacket(stream: 2, pts: nil, dts: nil, tag: 3), false),
        ]
        for (packet, isVideo) in initialPackets {
            XCTAssertTrue(stager.append(
                packet,
                isVideo: isVideo,
                maximumPayloadBytes: .max
            ))
        }
        var interleaver = HTSPPostSeekTailInterleaver(
            batch: stager.finish(),
            primaryVideoStreamIndex: 1,
            primaryAudioStreamIndex: 2
        )

        XCTAssertEqual(interleaver.drainAvailable().map { $0.payload[0] }, [1])
        interleaver.append(
            taggedPacket(stream: 2, pts: 1_400, dts: nil, duration: 100, tag: 4)
        )
        XCTAssertEqual(
            interleaver.drainAvailable().map { $0.payload[0] },
            [3, 4, 2]
        )
    }

    func testInterleavedPostSeekBatchStartsWithTablesAndVideoPCR() throws {
        let muxer = try MPEGTransportStreamMuxer(
            streams: [
                HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil),
                HTSPStreamInfo(index: 2, type: "AAC", language: "eng", metadata: nil),
            ]
        )
        var stager = HTSPPostSeekPacketStager()
        stager.begin(pinsInitialVideoKeyframe: true)
        XCTAssertTrue(stager.append(
            HTSPMuxPacket(
                streamIndex: 1,
                frameType: 0x49,
                presentationTime: 2_000_000,
                decodeTime: 1_000_000,
                payload: Data([0, 0, 0, 1, 0x65])
            ),
            isVideo: true,
            maximumPayloadBytes: .max
        ))
        XCTAssertTrue(stager.append(
            HTSPMuxPacket(
                streamIndex: 2,
                frameType: 0,
                presentationTime: 950_000,
                decodeTime: nil,
                payload: Data([0xff, 0xf1, 0x50, 0x80])
            ),
            isVideo: false,
            maximumPayloadBytes: .max
        ))

        muxer.resetForFreshPipeline()
        var transport = Data()
        for packet in stager.finish().interleavedPackets {
            transport.append(muxer.mux(packet))
        }

        XCTAssertEqual(Array(packetPIDs(in: transport).prefix(3)), [0x0000, 0x1000, 0x0100])
        XCTAssertTrue(firstPacketHasDiscontinuity(pid: 0x0000, in: transport))
        XCTAssertTrue(firstPacketHasDiscontinuity(pid: 0x1000, in: transport))
        XCTAssertTrue(firstPacketHasDiscontinuity(pid: 0x0100, in: transport))
        XCTAssertTrue(firstPacketHasDiscontinuity(pid: 0x0101, in: transport))
        XCTAssertTrue(firstPacketHasPCR(pid: 0x0100, in: transport))
        XCTAssertFalse(firstPacketHasVLCDiscontinuity(pid: 0x0100, in: transport))
        XCTAssertFalse(firstPacketHasVLCDiscontinuity(pid: 0x0101, in: transport))
    }

    func testMuxTimestampsRemainContinuousAcrossForwardAndBackwardSeeks() {
        var continuity = MPEGTimestampContinuity()

        let initial = continuity.normalize(
            presentationTime: 1_000_000,
            decodeTime: 980_000
        )
        XCTAssertEqual(initial.presentationTime, 1_000_000)
        XCTAssertEqual(initial.decodeTime, 980_000)

        continuity.beginNewEpoch()
        let forward = continuity.normalize(
            presentationTime: 30_000_000,
            decodeTime: 29_980_000
        )
        XCTAssertEqual(forward.presentationTime, 1_060_000)
        XCTAssertEqual(forward.decodeTime, 1_040_000)

        continuity.beginNewEpoch()
        let backward = continuity.normalize(
            presentationTime: 500_000,
            decodeTime: 480_000
        )
        XCTAssertEqual(backward.presentationTime, 1_120_000)
        XCTAssertEqual(backward.decodeTime, 1_100_000)
    }

    func testNativeSubscriptionRequestsKodiSizedQueueAndNormalizedTimestamps() {
        let fields = HTSPConnection.subscriptionFields(
            channelID: 42,
            profile: "pass",
            weight: 100
        )

        XCTAssertEqual(fields["subscriptionId"], .int(1))
        XCTAssertEqual(fields["channelId"], .int(42))
        XCTAssertEqual(fields["weight"], .int(100))
        XCTAssertEqual(fields["timeshiftPeriod"], .int(Int64(UInt32.max)))
        XCTAssertEqual(fields["normts"], .int(1))
        XCTAssertEqual(fields["queueDepth"], .int(10_000_000))
        XCTAssertEqual(fields["profile"], .string("pass"))
    }

    func testHTSPAuthenticationSupportsAnonymousOrCompleteCredentials() throws {
        XCTAssertNil(try HTSPConnection.authenticationFields(
            username: "",
            password: "",
            challenge: nil
        ))

        let fields = try XCTUnwrap(HTSPConnection.authenticationFields(
            username: "viewer",
            password: "secret",
            challenge: Data(repeating: 0x2a, count: 32)
        ))
        XCTAssertEqual(fields["username"], .string("viewer"))
        XCTAssertNotNil(fields["digest"]?.dataValue)

        XCTAssertThrowsError(try HTSPConnection.authenticationFields(
            username: "viewer",
            password: "",
            challenge: Data(repeating: 0x2a, count: 32)
        ))
    }

    func testControlResponseValidationRejectsRPCError() {
        XCTAssertThrowsError(
            try HTSPConnection.validate(response: ["error": .string("seek unavailable")])
        )
        XCTAssertNoThrow(try HTSPConnection.validate(response: ["seq": .int(7)]))
    }

    func testDiscoveryUsesAdvertisedHTSPPortAndDefaultsTo9982() throws {
        let requiredFields = [
            "txtvers": Data("1".utf8),
            "id": Data("server-0123".utf8),
            "scheme": Data("http".utf8),
            "path": Data("/".utf8),
            "username": Data("viewer".utf8),
            "password": Data("secret".utf8),
        ]
        var advertisedFields = requiredFields
        advertisedFields["htsp_port"] = Data("19982".utf8)

        XCTAssertEqual(
            try XCTUnwrap(DiscoveredTVHeadendSettings(
                fields: requiredFields,
                hostName: "tvheadend.local.",
                port: 9981
            )).htspPort,
            9982
        )
        XCTAssertEqual(
            try XCTUnwrap(DiscoveredTVHeadendSettings(
                fields: advertisedFields,
                hostName: "tvheadend.local.",
                port: 9981
            )).htspPort,
            19_982
        )

        var invalidFields = requiredFields
        invalidFields["htsp_port"] = Data("70000".utf8)
        XCTAssertNil(DiscoveredTVHeadendSettings(
            fields: invalidFields,
            hostName: "tvheadend.local.",
            port: 9981
        ))
    }

    func testLiveStreamHealthPublishesCurrentTimestampAlignedInitialTuneQuality() async throws {
        let connection = ScriptedHTSPConnection(
            streams: [
                HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil),
                HTSPStreamInfo(index: 2, type: "AAC", language: "eng", metadata: nil),
            ],
            reads: [
                .message([
                    "method": .string("muxpkt"),
                    "stream": .int(1),
                    "frametype": .int(73),
                    "pts": .int(2_200_000),
                    "dts": .int(1_000_000),
                    "payload": .data(Data([0, 0, 0, 1, 0x65])),
                ]),
                .message([
                    "method": .string("muxpkt"),
                    "stream": .int(1),
                    "frametype": .int(80),
                    "pts": .int(2_900_000),
                    "dts": .int(1_700_000),
                    "payload": .data(Data([0, 0, 0, 1, 0x41])),
                ]),
                .message([
                    "method": .string("muxpkt"),
                    "stream": .int(2),
                    "pts": .int(1_680_000),
                    "duration": .int(20_000),
                    "payload": .data(Data([0x11, 0x22])),
                ]),
            ]
        )
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.local:9981"),
            username: "viewer",
            password: "secret",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )
        let policy = NativeTimeshiftTuningPolicy(initialHorizonMilliseconds: 700)
        let stream = try await HTSPLiveInputStream.connect(
            configuration: configuration,
            channelID: 42,
            profile: "pass",
            tuningPolicy: policy,
            connectionFactory: { connection }
        )
        defer { stream.close() }
        let stagingGeneration = stream.healthSnapshot.initialTuneStagingGeneration
        XCTAssertGreaterThan(stagingGeneration, 0)
        XCTAssertEqual(stream.healthSnapshot.initialTuneStagingQuality, .pending)

        stream.open()
        for _ in 0..<100
        where stream.healthSnapshot.initialTuneStagingQuality == .pending {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let health = stream.healthSnapshot
        XCTAssertEqual(
            health.initialTuneStagingQuality,
            .timestampAligned(horizonMicroseconds: 700_000)
        )
        XCTAssertEqual(health.initialTuneStagingGeneration, stagingGeneration)
    }

    func testLiveStreamHealthMarksBoundedInitialTuneFallback() async throws {
        let connection = ScriptedHTSPConnection(
            streams: [
                HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil),
                HTSPStreamInfo(index: 2, type: "AAC", language: "eng", metadata: nil),
            ],
            reads: [
                .message([
                    "method": .string("muxpkt"),
                    "stream": .int(1),
                    "frametype": .int(73),
                    "payload": .data(Data([0, 0, 0, 1, 0x65])),
                ]),
                .message([
                    "method": .string("muxpkt"),
                    "stream": .int(2),
                    "payload": .data(Data([0x11, 0x22])),
                ]),
            ]
        )
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.local:9981"),
            username: "viewer",
            password: "secret",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )
        let stream = try await HTSPLiveInputStream.connect(
            configuration: configuration,
            channelID: 42,
            profile: "pass",
            tuningPolicy: NativeTimeshiftTuningPolicy(initialStageTimeout: 0),
            connectionFactory: { connection }
        )
        defer { stream.close() }
        let stagingGeneration = stream.healthSnapshot.initialTuneStagingGeneration

        stream.open()
        for _ in 0..<100
        where stream.healthSnapshot.initialTuneStagingQuality == .pending {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let health = stream.healthSnapshot
        XCTAssertEqual(health.initialTuneStagingQuality, .fallback)
        XCTAssertEqual(health.initialTuneStagingGeneration, stagingGeneration)
    }

    func testDroppedSubscriptionReconnectsWithoutClosingTheInputStream() async throws {
        let streams = [
            HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil),
        ]
        let first = ScriptedHTSPConnection(
            streams: streams,
            reads: [.failure(.disconnected)]
        )
        let second = ScriptedHTSPConnection(
            streams: streams,
            reads: [
                .message([
                    "method": .string("muxpkt"),
                    "stream": .int(1),
                    "frametype": .int(73),
                    "pts": .int(1_000_000),
                    "dts": .int(1_000_000),
                    "payload": .data(Data([0, 0, 0, 1, 0x65, 0x88, 0x84])),
                ]),
            ]
        )
        let factory = ScriptedHTSPConnectionFactory([first, second])
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.local:9981"),
            username: "viewer",
            password: "secret",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )
        let stream = try await HTSPLiveInputStream.connect(
            configuration: configuration,
            channelID: 42,
            profile: "pass",
            connectionFactory: { try factory.makeConnection() }
        )
        let events = LockedLifecycleEvents()
        let recovered = expectation(description: "replacement subscription became readable")
        stream.setLifecycleHandler { event in
            events.append(event)
            if event == .readyAfterRecovery { recovered.fulfill() }
        }

        // A paused viewer still needs one decodable packet from the replacement
        // subscription before the server-side pause is restored.
        stream.pause()
        stream.open()
        await fulfillment(of: [recovered], timeout: 2)

        XCTAssertEqual(stream.streamStatus.rawValue, Stream.Status.open.rawValue)
        XCTAssertNil(stream.streamError)
        XCTAssertFalse(stream.healthSnapshot.isRecovering)
        XCTAssertEqual(stream.healthSnapshot.desiredSpeed, 0)
        XCTAssertTrue(
            events.values.contains {
                if case .reconnecting(_, attempt: 1) = $0 { return true }
                return false
            }
        )

        for _ in 0..<100 where !second.requestedSpeeds.contains(0) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(second.requestedSpeeds.contains(0))
        XCTAssertEqual(first.subscribedWeights, [100])
        XCTAssertEqual(second.subscribedWeights, [100])
        XCTAssertEqual(factory.connectionCount, 2)
        stream.close()
    }

    func testSubscriptionWeightChangeUsesSequencedSubscriptionRPC() async throws {
        let connection = ScriptedHTSPConnection(
            streams: [
                HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil),
            ],
            reads: []
        )
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.local:9981"),
            username: "viewer",
            password: "secret",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )
        let stream = try await HTSPLiveInputStream.connect(
            configuration: configuration,
            channelID: 42,
            profile: "pass",
            connectionFactory: { connection }
        )
        let changed = expectation(description: "subscription weight changed")

        stream.open()
        stream.changeSubscriptionWeight(to: 100) { result in
            if case let .failure(error) = result {
                XCTFail("Weight change failed: \(error.localizedDescription)")
            }
            changed.fulfill()
        }
        for _ in 0..<100 where connection.requestedWeightChanges != [100] {
            try? await Task.sleep(for: .milliseconds(10))
        }
        connection.enqueue(.message(["seq": .int(1)]))

        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(connection.subscribedWeights, [100])
        XCTAssertEqual(connection.requestedWeightChanges, [100])
        XCTAssertEqual(connection.weightChangeIncludesSubscriptionID, [true])
        stream.close()
    }

    func testCandidatePromotionRaisesWeightBeforePublishingBufferedOutput() async throws {
        let connection = ScriptedHTSPConnection(
            streams: [
                HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil),
                HTSPStreamInfo(index: 2, type: "AAC", language: "eng", metadata: nil),
            ],
            reads: Self.alignedCandidateReads
        )
        let configuration = Self.candidateConfiguration
        let stream = try await HTSPLiveInputStream.connectCandidate(
            configuration: configuration,
            channelID: 42,
            profile: "pass",
            connectionFactory: { connection }
        )
        defer { stream.close() }

        for _ in 0..<100 where !stream.candidateIsReady {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(stream.candidateIsReady)
        XCTAssertEqual(connection.subscribedWeights, [1])
        XCTAssertEqual(stream.queuedByteCount, 0)

        let promotionTask = Task { try await stream.promoteCandidate() }
        for _ in 0..<100 where connection.requestedWeightChanges != [100] {
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(connection.requestedWeightChanges, [100])
        XCTAssertEqual(connection.weightChangeIncludesSubscriptionID, [true])
        XCTAssertEqual(
            stream.queuedByteCount,
            0,
            "Staged bytes must remain hidden until TVHeadend acknowledges foreground priority."
        )

        connection.enqueue(.message(["seq": .int(1)]))
        let promotion = try await promotionTask.value

        XCTAssertTrue(promotion.usedAlignedWindow)
        XCTAssertGreaterThan(promotion.payloadByteCount, 0)
        let queuedByteCount = Int(stream.queuedByteCount)
        XCTAssertGreaterThan(queuedByteCount, 0)

        var bytes = [UInt8](repeating: 0, count: queuedByteCount)
        let readCount = bytes.withUnsafeMutableBufferPointer {
            stream.read($0.baseAddress!, maxLength: $0.count)
        }
        XCTAssertEqual(readCount, queuedByteCount)
        XCTAssertEqual(readCount % 188, 0)
        XCTAssertEqual(bytes.first, 0x47)
    }

    func testCandidatePoolOnlyConsumesAnExactMatchAndCancellationClosesIt() async throws {
        let connection = ScriptedHTSPConnection(
            streams: [
                HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil),
            ],
            reads: []
        )
        let expected = HTSPLiveCandidateDescriptor(
            configuration: Self.candidateConfiguration,
            channelID: 42,
            profile: "pass"
        )
        let mismatch = HTSPLiveCandidateDescriptor(
            configuration: Self.candidateConfiguration,
            channelID: 43,
            profile: "pass"
        )
        let pool = HTSPLiveCandidatePool { descriptor in
            try await HTSPLiveInputStream.connectCandidate(
                configuration: descriptor.configuration,
                channelID: descriptor.channelID,
                profile: descriptor.profile,
                tuningPolicy: descriptor.tuningPolicy,
                connectionFactory: { connection }
            )
        }

        await pool.stage(expected)
        for _ in 0..<100 where connection.subscribedWeights != [1] {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(connection.subscribedWeights, [1])
        let containsExpected = await pool.contains(expected)
        XCTAssertTrue(containsExpected)

        let mismatchedClaim = try await pool.take(matching: mismatch)
        XCTAssertNil(mismatchedClaim)
        let stillContainsExpected = await pool.contains(expected)
        XCTAssertTrue(stillContainsExpected)

        await pool.cancel()
        for _ in 0..<100 where !connection.isClosed {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(connection.isClosed)
        let containsAfterCancellation = await pool.contains(expected)
        XCTAssertFalse(containsAfterCancellation)
    }

    func testCandidatePoolIgnoresCancellationFromSupersededGeneration() async throws {
        let first = ScriptedHTSPConnection(
            streams: [HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil)],
            reads: []
        )
        let second = ScriptedHTSPConnection(
            streams: [HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil)],
            reads: []
        )
        let factory = ScriptedHTSPConnectionFactory([first, second])
        let firstDescriptor = HTSPLiveCandidateDescriptor(
            configuration: Self.candidateConfiguration,
            channelID: 42,
            profile: "pass"
        )
        let secondDescriptor = HTSPLiveCandidateDescriptor(
            configuration: Self.candidateConfiguration,
            channelID: 43,
            profile: "pass"
        )
        let pool = HTSPLiveCandidatePool { descriptor in
            try await HTSPLiveInputStream.connectCandidate(
                configuration: descriptor.configuration,
                channelID: descriptor.channelID,
                profile: descriptor.profile,
                tuningPolicy: descriptor.tuningPolicy,
                connectionFactory: { try factory.makeConnection() }
            )
        }
        let firstGeneration = UUID()
        let secondGeneration = UUID()

        await pool.stage(firstDescriptor, generation: firstGeneration)
        for _ in 0..<100 where first.subscribedWeights != [1] {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await pool.stage(secondDescriptor, generation: secondGeneration)
        for _ in 0..<100 where second.subscribedWeights != [1] {
            try? await Task.sleep(for: .milliseconds(5))
        }

        await pool.cancel(generation: firstGeneration)

        let containsSecond = await pool.contains(secondDescriptor)
        XCTAssertTrue(containsSecond)
        XCTAssertFalse(second.isClosed)

        await pool.cancel(generation: secondGeneration)
        for _ in 0..<100 where !second.isClosed {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(second.isClosed)
    }

    func testCandidatePoolCancellationWhileTakingClosesLateStream() async throws {
        let connection = ScriptedHTSPConnection(
            streams: [HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil)],
            reads: []
        )
        let descriptor = HTSPLiveCandidateDescriptor(
            configuration: Self.candidateConfiguration,
            channelID: 42,
            profile: "pass"
        )
        let pool = HTSPLiveCandidatePool { descriptor in
            // Model a connector that finishes despite cancellation, as a
            // blocking socket handshake can do in production.
            try? await Task.sleep(for: .milliseconds(100))
            return try await HTSPLiveInputStream.connectCandidate(
                configuration: descriptor.configuration,
                channelID: descriptor.channelID,
                profile: descriptor.profile,
                tuningPolicy: descriptor.tuningPolicy,
                connectionFactory: { connection }
            )
        }

        await pool.stage(descriptor, generation: UUID())
        let take = Task { try await pool.take(matching: descriptor) }
        try? await Task.sleep(for: .milliseconds(10))
        take.cancel()

        do {
            _ = try await take.value
            XCTFail("A cancelled candidate claim must not succeed.")
        } catch is CancellationError {
            // Expected.
        }
        for _ in 0..<100 where !connection.isClosed {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(connection.isClosed)
        let containsAfterCancelledTake = await pool.contains(descriptor)
        XCTAssertFalse(containsAfterCancelledTake)
    }

    func testCandidatePoolRestagesSameDescriptorAfterConnectedStreamFails() async throws {
        let failed = ScriptedHTSPConnection(
            streams: [HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil)],
            reads: [.failure(.disconnected)]
        )
        let replacement = ScriptedHTSPConnection(
            streams: [HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil)],
            reads: []
        )
        let factory = ScriptedHTSPConnectionFactory([failed, replacement])
        let descriptor = HTSPLiveCandidateDescriptor(
            configuration: Self.candidateConfiguration,
            channelID: 42,
            profile: "pass"
        )
        let pool = HTSPLiveCandidatePool { descriptor in
            try await HTSPLiveInputStream.connectCandidate(
                configuration: descriptor.configuration,
                channelID: descriptor.channelID,
                profile: descriptor.profile,
                tuningPolicy: descriptor.tuningPolicy,
                connectionFactory: { try factory.makeConnection() }
            )
        }

        await pool.stage(descriptor)
        for _ in 0..<100 where !failed.isClosed {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(failed.isClosed)
        let containsFailedCandidate = await pool.contains(descriptor)
        XCTAssertTrue(containsFailedCandidate)

        await pool.stage(descriptor)
        for _ in 0..<100 where replacement.subscribedWeights != [1] {
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(factory.connectionCount, 2)
        XCTAssertEqual(replacement.subscribedWeights, [1])
        await pool.cancel()
    }

    func testPauseRPCAcknowledgementReleasesResumeWithoutSpeedNotification() async throws {
        let connection = ScriptedHTSPConnection(
            streams: [
                HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil),
            ],
            reads: [
                .message(["seq": .int(1)]),
                .message(["seq": .int(2)]),
            ]
        )
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.local:9981"),
            username: "viewer",
            password: "secret",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )
        let stream = try await HTSPLiveInputStream.connect(
            configuration: configuration,
            channelID: 42,
            profile: "pass",
            connectionFactory: { connection }
        )

        stream.pause()
        stream.play()
        stream.open()

        for _ in 0..<100 where connection.requestedSpeeds != [0, 100] {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(connection.requestedSpeeds, [0, 100])
        XCTAssertEqual(stream.healthSnapshot.desiredSpeed, 100)
        stream.close()
    }

    func testPauseRPCAcknowledgementStartsPendingSeekWithoutSpeedNotification() async throws {
        let connection = ScriptedHTSPConnection(
            streams: [
                HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil),
            ],
            reads: [
                .message([
                    "method": .string("timeshiftStatus"),
                    "start": .int(0),
                    "end": .int(30_000_000),
                    "shift": .int(0),
                ]),
            ]
        )
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.local:9981"),
            username: "viewer",
            password: "secret",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )
        let stream = try await HTSPLiveInputStream.connect(
            configuration: configuration,
            channelID: 42,
            profile: "pass",
            connectionFactory: { connection }
        )
        stream.open()
        for _ in 0..<100 where stream.timeshiftWindowSeconds == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        stream.pause()
        stream.seek(by: -10)
        for _ in 0..<100 where connection.requestedSpeeds != [0] {
            try? await Task.sleep(for: .milliseconds(10))
        }
        connection.enqueue(.message(["seq": .int(1)]))

        for _ in 0..<100 where !connection.requestedMethods.contains("subscriptionSkip") {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(connection.requestedSpeeds, [0])
        XCTAssertTrue(connection.requestedMethods.contains("subscriptionSkip"))
        stream.close()
    }

    private func firstPacketHasDiscontinuity(pid: UInt16, in data: Data) -> Bool {
        for offset in stride(from: 0, to: data.count, by: 188) {
            guard offset + 188 <= data.count, data[offset] == 0x47 else { continue }
            let packetPID = UInt16(data[offset + 1] & 0x1f) << 8 | UInt16(data[offset + 2])
            guard packetPID == pid else { continue }
            guard data[offset + 3] & 0x20 != 0 else { return false }
            let adaptationLength = Int(data[offset + 4])
            return adaptationLength > 0 && data[offset + 5] & 0x80 != 0
        }
        return false
    }

    private func taggedPacket(
        stream: Int,
        frameType: UInt8 = 0,
        pts: Int64?,
        dts: Int64?,
        duration: Int64? = nil,
        tag: UInt8
    ) -> HTSPMuxPacket {
        HTSPMuxPacket(
            streamIndex: stream,
            frameType: frameType,
            presentationTime: pts,
            decodeTime: dts,
            durationMicroseconds: duration,
            payload: Data([tag])
        )
    }

    private func packetPIDs(in data: Data) -> [UInt16] {
        stride(from: 0, to: data.count, by: 188).compactMap { offset in
            guard offset + 188 <= data.count, data[offset] == 0x47 else { return nil }
            return UInt16(data[offset + 1] & 0x1f) << 8 | UInt16(data[offset + 2])
        }
    }

    private func firstPacketHasVLCDiscontinuity(pid: UInt16, in data: Data) -> Bool {
        let marker = Data("VLC_DISCONTINU".utf8)
        for offset in stride(from: 0, to: data.count, by: 188) {
            guard offset + 188 <= data.count, data[offset] == 0x47 else { continue }
            let packetPID = UInt16(data[offset + 1] & 0x1f) << 8 | UInt16(data[offset + 2])
            guard packetPID == pid else { continue }
            guard data[offset + 3] & 0x20 != 0,
                  Int(data[offset + 4]) >= marker.count + 2,
                  data[offset + 5] == 0x82,
                  Int(data[offset + 6]) == marker.count
            else { return false }
            return Data(data[(offset + 7)..<(offset + 7 + marker.count)]) == marker
        }
        return false
    }

    private func firstPacketHasPCR(pid: UInt16, in data: Data) -> Bool {
        for offset in stride(from: 0, to: data.count, by: 188) {
            guard offset + 188 <= data.count, data[offset] == 0x47 else { continue }
            let packetPID = UInt16(data[offset + 1] & 0x1f) << 8 | UInt16(data[offset + 2])
            guard packetPID == pid else { continue }
            guard data[offset + 3] & 0x20 != 0 else { return false }
            return data[offset + 4] >= 7 && data[offset + 5] & 0x10 != 0
        }
        return false
    }
}

private enum ScriptedHTSPRead: Sendable {
    case message([String: HTSPValue])
    case failure(HTSPError)
}

private final class ScriptedHTSPConnection: HTSPConnectionTransport, @unchecked Sendable {
    let capabilities: Set<String> = ["timeshift"]

    private let condition = NSCondition()
    private let streams: [HTSPStreamInfo]
    private var reads: [ScriptedHTSPRead]
    private var closed = false
    private var nextSequence: Int64 = 1
    private var speeds: [Int32] = []
    private var methods: [String] = []
    private var subscribeWeights: [UInt32] = []
    private var changedWeights: [UInt32] = []
    private var weightChangeSubscriptionIDFlags: [Bool] = []

    init(streams: [HTSPStreamInfo], reads: [ScriptedHTSPRead]) {
        self.streams = streams
        self.reads = reads
    }

    var requestedSpeeds: [Int32] {
        condition.withLock { speeds }
    }

    var requestedMethods: [String] {
        condition.withLock { methods }
    }

    var subscribedWeights: [UInt32] {
        condition.withLock { subscribeWeights }
    }

    var requestedWeightChanges: [UInt32] {
        condition.withLock { changedWeights }
    }

    var weightChangeIncludesSubscriptionID: [Bool] {
        condition.withLock { weightChangeSubscriptionIDFlags }
    }

    var isClosed: Bool {
        condition.withLock { closed }
    }

    func handshake(username: String, password: String) throws {}

    func subscribe(
        channelID: UInt32,
        profile: String,
        weight: UInt32
    ) throws -> (Int64, [HTSPStreamInfo]) {
        condition.withLock { subscribeWeights.append(weight) }
        return (Int64(UInt32.max), streams)
    }

    func reserveSequence() -> Int64 {
        condition.withLock {
            defer { nextSequence += 1 }
            return nextSequence
        }
    }

    func sendRequest(
        method: String,
        sequence: Int64,
        fields: [String: HTSPValue],
        includesSubscriptionID: Bool
    ) throws {
        condition.withLock {
            methods.append(method)
            if method == "subscriptionSpeed", let speed = fields["speed"]?.intValue {
                speeds.append(Int32(clamping: speed))
            }
            if method == "subscriptionChangeWeight",
               let weight = fields["weight"]?.intValue {
                changedWeights.append(UInt32(clamping: weight))
                weightChangeSubscriptionIDFlags.append(includesSubscriptionID)
            }
        }
    }

    func enqueue(_ read: ScriptedHTSPRead) {
        condition.withLock {
            reads.append(read)
            condition.broadcast()
        }
    }

    func readMessage() throws -> [String: HTSPValue] {
        condition.lock()
        while reads.isEmpty, !closed { condition.wait() }
        guard !closed else {
            condition.unlock()
            throw HTSPError.disconnected
        }
        let read = reads.removeFirst()
        condition.unlock()
        switch read {
        case let .message(message): return message
        case let .failure(error): throw error
        }
    }

    func close() {
        condition.withLock {
            closed = true
            condition.broadcast()
        }
    }
}

private final class ScriptedHTSPConnectionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [ScriptedHTSPConnection]
    private var madeConnectionCount = 0

    init(_ connections: [ScriptedHTSPConnection]) {
        self.connections = connections
    }

    var connectionCount: Int {
        lock.withLock { madeConnectionCount }
    }

    func makeConnection() throws -> any HTSPConnectionTransport {
        try lock.withLock {
            guard !connections.isEmpty else { throw HTSPError.disconnected }
            madeConnectionCount += 1
            return connections.removeFirst()
        }
    }
}

private final class LockedLifecycleEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HTSPStreamLifecycleEvent] = []

    var values: [HTSPStreamLifecycleEvent] {
        lock.withLock { events }
    }

    func append(_ event: HTSPStreamLifecycleEvent) {
        lock.withLock { events.append(event) }
    }
}

#if os(tvOS)
@MainActor
final class VLCTimeshiftIntegrationTests: XCTestCase {
    private struct Sample {
        let requestedDelta: TimeInterval
        let discontinuityMilliseconds: Double
        let firstVideoMilliseconds: Double
        let firstAudioMilliseconds: Double?
        let playingMilliseconds: Double
        let liveDelay: TimeInterval
    }

    func testRepeatedSeeksThroughRealVLCPlayer() async throws {
#if !LIVE_TIMESHIFT_BENCHMARK
        throw XCTSkip("Run Scripts/benchmark-vlc-timeshift.swift to enable this integration benchmark.")
#endif
        let configuration = try XCTUnwrap(
            SharedTVHeadendConfigurationStore().read(),
            "No shared TVHeadend configuration is available in the simulator Keychain."
        )
        let channelID = try await firstNumericChannelID(configuration: configuration)
        let streamURL = try XCTUnwrap(
            configuration.baseURL?.appending(path: "stream/channelid/\(channelID)")
        )
        let request = LiveStreamRequest(
            url: streamURL,
            networkCachingMilliseconds: 1_500,
            profile: configuration.streamProfile,
            kind: .live(
                .nativeTimeshift(
                    HTSPPlaybackConfiguration(
                        configuration: configuration,
                        channelID: channelID
                    )
                )
            )
        )

        let engine = VLCPlaybackEngine()
        let drawable = UIView(frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        engine.mediaPlayer.drawable = drawable
        defer { engine.stop() }

        try await engine.prepare(request)
        XCTAssertEqual(engine.activeLivePlaybackMode, .tvHeadend)
        engine.play()
        let playbackStarted = await engine.waitForPlaybackStart()
        XCTAssertTrue(playbackStarted, "VLC did not begin playback.")

        print("VLC_TIMESHIFT filling buffer through the real player for up to 45 seconds")
        try await waitUntil(timeout: 45) {
            engine.refreshPlaybackInformation()
            return engine.timeshiftWindowSeconds >= 35
        }
        print(String(format: "VLC_TIMESHIFT available window %.2fs", engine.timeshiftWindowSeconds))

        var samples: [Sample] = []
        for (index, delta) in [-25.0, 15.0, -15.0, 15.0, -15.0, 15.0].enumerated() {
            let sample = try await measureSeek(delta: delta, engine: engine)
            samples.append(sample)
            print(
                String(
                    format: "VLC_TIMESHIFT %d delta %+.0fs discontinuity %.1fms video %.1fms audio %@ playing %.1fms delay %.2fs",
                    index + 1,
                    delta,
                    sample.discontinuityMilliseconds,
                    sample.firstVideoMilliseconds,
                    sample.firstAudioMilliseconds.map { String(format: "%.1fms", $0) } ?? "n/a",
                    sample.playingMilliseconds,
                    sample.liveDelay
                )
            )
        }

        printSummary("discontinuity", samples.map(\.discontinuityMilliseconds))
        printSummary("video", samples.map(\.firstVideoMilliseconds))
        printSummary("playing", samples.map(\.playingMilliseconds))
        let audio = samples.compactMap(\.firstAudioMilliseconds)
        if !audio.isEmpty { printSummary("audio", audio) }
    }

    private func measureSeek(delta: TimeInterval, engine: VLCPlaybackEngine) async throws -> Sample {
        engine.refreshPlaybackInformation()
        let baseline = counters(engine)
        let started = ProcessInfo.processInfo.systemUptime
        if delta < 0 {
            engine.skipBackward(by: -delta)
        } else {
            _ = engine.skipForward(by: delta)
        }

        var discontinuityAt: Double?
        var videoAt: Double?
        var audioAt: Double?
        var countersAtDiscontinuity: PlaybackOutputCounters?
        let deadline = started + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            engine.refreshPlaybackInformation()
            let now = ProcessInfo.processInfo.systemUptime
            let current = counters(engine)
            if discontinuityAt == nil,
               current.demuxDiscontinuities > baseline.demuxDiscontinuities {
                discontinuityAt = now
                countersAtDiscontinuity = current
            }
            if let countersAtDiscontinuity {
                if videoAt == nil,
                   current.displayedPictures > countersAtDiscontinuity.displayedPictures {
                    videoAt = now
                }
                if audioAt == nil,
                   current.playedAudioBuffers > countersAtDiscontinuity.playedAudioBuffers {
                    audioAt = now
                }
            }
            if let discontinuityAt, let videoAt,
               engine.state == .playing,
               !engine.isPlaybackOutputConcealed {
                return Sample(
                    requestedDelta: delta,
                    discontinuityMilliseconds: (discontinuityAt - started) * 1_000,
                    firstVideoMilliseconds: (videoAt - started) * 1_000,
                    firstAudioMilliseconds: audioAt.map { ($0 - started) * 1_000 },
                    playingMilliseconds: (now - started) * 1_000,
                    liveDelay: engine.liveDelaySeconds
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(
            "VLC did not produce post-discontinuity video within 10 seconds "
                + "(state: \(engine.state), concealed: \(engine.isPlaybackOutputConcealed), "
                + "baseline: \(baseline), current: \(counters(engine)))."
        )
        throw BenchmarkFailure.timedOut
    }

    private func counters(_ engine: VLCPlaybackEngine) -> PlaybackOutputCounters {
        let statistics = engine.mediaPlayer.media?.statistics
        return PlaybackOutputCounters(
            displayedPictures: Int(statistics?.displayedPictures ?? 0),
            playedAudioBuffers: Int(statistics?.playedAudioBuffers ?? 0),
            demuxDiscontinuities: Int(statistics?.demuxDiscontinuity ?? 0),
            playbackTimeMilliseconds: engine.mediaPlayer.time.intValue > 0
                ? Int64(engine.mediaPlayer.time.intValue)
                : nil
        )
    }

    private func waitUntil(
        timeout: TimeInterval,
        predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BenchmarkFailure.timedOut
    }

    private func firstNumericChannelID(
        configuration: TVHeadendConfiguration
    ) async throws -> UInt32 {
        guard let baseURL = configuration.baseURL else { throw BenchmarkFailure.invalidConfiguration }
        let playlistURL = baseURL
            .appending(path: "playlist/ticket/channels")
            .appending(queryItems: [URLQueryItem(name: "profile", value: configuration.streamProfile)])
        let delegate = BenchmarkAuthenticationDelegate(configuration: configuration)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: playlistURL)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let playlist = String(data: data, encoding: .utf8)
        else { throw BenchmarkFailure.invalidPlaylist }
        for line in playlist.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            guard let url = URL(string: String(line)),
                  let channelID = TVHeadendClient.numericChannelID(from: url)
            else { continue }
            return channelID
        }
        throw BenchmarkFailure.invalidPlaylist
    }

    private func printSummary(_ name: String, _ values: [Double]) {
        let sorted = values.sorted()
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
        let p95 = sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        print(
            String(
                format: "VLC_TIMESHIFT_SUMMARY %@ min %.1fms median %.1fms p95 %.1fms max %.1fms",
                name,
                sorted.first ?? 0,
                median,
                p95,
                sorted.last ?? 0
            )
        )
    }

    private enum BenchmarkFailure: Error {
        case invalidConfiguration
        case invalidPlaylist
        case timedOut
    }
}

private final class BenchmarkAuthenticationDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: TVHeadendConfiguration

    init(configuration: TVHeadendConfiguration) {
        self.configuration = configuration
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodHTTPDigest
            || method == NSURLAuthenticationMethodHTTPBasic {
            completionHandler(
                .useCredential,
                URLCredential(
                    user: configuration.username,
                    password: configuration.password,
                    persistence: .forSession
                )
            )
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
#endif
