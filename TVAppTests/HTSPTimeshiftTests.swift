import Foundation
import XCTest
@testable import TVApp

final class HTSPTimeshiftTests: XCTestCase {
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
        XCTAssertFalse(firstPacketHasDiscontinuity(pid: 0x0101, in: muxer.mux(audio)))

        muxer.resetAfterDiscontinuity()
        XCTAssertTrue(firstPacketHasDiscontinuity(pid: 0x0100, in: muxer.mux(video)))
        XCTAssertTrue(firstPacketHasDiscontinuity(pid: 0x0101, in: muxer.mux(audio)))
    }

    func testNativeSubscriptionRequestsKodiSizedQueueAndNormalizedTimestamps() {
        let fields = HTSPConnection.subscriptionFields(channelID: 42, profile: "pass")

        XCTAssertEqual(fields["subscriptionId"], .int(1))
        XCTAssertEqual(fields["channelId"], .int(42))
        XCTAssertEqual(fields["timeshiftPeriod"], .int(Int64(UInt32.max)))
        XCTAssertEqual(fields["normts"], .int(1))
        XCTAssertEqual(fields["queueDepth"], .int(10_000_000))
        XCTAssertEqual(fields["profile"], .string("pass"))
    }

    func testControlResponseValidationRejectsRPCError() {
        XCTAssertThrowsError(
            try HTSPConnection.validate(response: ["error": .string("seek unavailable")])
        )
        XCTAssertNoThrow(try HTSPConnection.validate(response: ["seq": .int(7)]))
    }

    func testDiscoveryUsesAdvertisedHTSPPortAndDefaultsTo9982() throws {
        let requiredFields = [
            "url": Data("http://tvheadend.local:9981".utf8),
            "username": Data("viewer".utf8),
            "password": Data("secret".utf8),
        ]
        var advertisedFields = requiredFields
        advertisedFields["htsp_port"] = Data("19982".utf8)

        XCTAssertEqual(
            try XCTUnwrap(DiscoveredTVHeadendSettings(fields: requiredFields)).htspPort,
            9982
        )
        XCTAssertEqual(
            try XCTUnwrap(DiscoveredTVHeadendSettings(fields: advertisedFields)).htspPort,
            19_982
        )

        var invalidFields = requiredFields
        invalidFields["htsp_port"] = Data("70000".utf8)
        XCTAssertNil(DiscoveredTVHeadendSettings(fields: invalidFields))
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
}
