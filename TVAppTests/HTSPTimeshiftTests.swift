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
        XCTAssertEqual(factory.connectionCount, 2)
        stream.close()
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

    init(streams: [HTSPStreamInfo], reads: [ScriptedHTSPRead]) {
        self.streams = streams
        self.reads = reads
    }

    var requestedSpeeds: [Int32] {
        condition.withLock { speeds }
    }

    func handshake(username: String, password: String) throws {}

    func subscribe(channelID: UInt32, profile: String) throws -> (Int64, [HTSPStreamInfo]) {
        (Int64(UInt32.max), streams)
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
            if method == "subscriptionSpeed", let speed = fields["speed"]?.intValue {
                speeds.append(Int32(clamping: speed))
            }
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
