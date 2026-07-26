import Foundation
import XCTest
@testable import TVPlayer

final class HTSPTuningFailureCaptureTests: XCTestCase {
    func testRecorderKeepsBoundedReplayableStartupPrefixAndSessionMetadata() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let initialStreams = [
            HTSPStreamInfo(
                index: 1,
                type: "H264",
                language: "deu",
                metadata: Data([0x01, 0x02])
            )
        ]
        let recorder = HTSPTuningFailureCaptureRecorder(
            channelID: 42,
            profile: "htsp",
            acceptedTimeshiftPeriodSeconds: 3_600,
            streams: initialStreams,
            startsAsCandidate: true,
            limits: HTSPTuningFailureCaptureLimits(
                maximumRawPayloadBytes: 3,
                maximumTransportBytes: 400,
                maximumPacketCount: 10,
                maximumReaderGenerationCount: 2,
                reservedTransportBytesPerReaderGeneration: 200
            ),
            startedAt: startedAt
        )

        recorder.record(
            packet(stream: 1, payload: [0x11, 0x12]),
            isVideo: true,
            isAudio: false,
            receivedAt: startedAt.addingTimeInterval(0.010)
        )
        recorder.record(
            packet(stream: 1, payload: [0x21, 0x22]),
            isVideo: true,
            isAudio: false,
            receivedAt: startedAt.addingTimeInterval(0.020)
        )
        recorder.recordStreamDeclaration(
            initialStreams + [
                HTSPStreamInfo(
                    index: 2,
                    type: "AAC",
                    language: "eng",
                    metadata: Data([0xaa])
                )
            ],
            connectionGeneration: 1,
            receivedAt: startedAt.addingTimeInterval(0.030)
        )
        recorder.record(
            packet(stream: 2, payload: [0x31]),
            isVideo: false,
            isAudio: true,
            receivedAt: startedAt.addingTimeInterval(0.040)
        )

        let transport = Data((0..<500).map { UInt8($0 % 251) })
        recorder.recordTransportRead(
            Data(transport.prefix(200)),
            sequence: 0,
            readerGeneration: 1,
            requestedByteCount: 32_768,
            waitDurationMicroseconds: 12_000,
            completedAt: startedAt.addingTimeInterval(0.050)
        )
        recorder.recordTransportRead(
            Data(transport.dropFirst(200).prefix(200)),
            sequence: 1,
            readerGeneration: 2,
            completedAt: startedAt.addingTimeInterval(0.060)
        )
        recorder.recordTransportRead(
            Data(transport.dropFirst(400)),
            sequence: 2,
            readerGeneration: 2,
            completedAt: startedAt.addingTimeInterval(0.070)
        )
        recorder.markForeground()
        recorder.markClosed()

        let snapshot = recorder.sealAndSnapshot()
        XCTAssertEqual(snapshot.channelID, 42)
        XCTAssertEqual(snapshot.profile, "htsp")
        XCTAssertEqual(snapshot.acceptedTimeshiftPeriodSeconds, 3_600)
        XCTAssertEqual(snapshot.lifecycle, "closed-foreground")
        XCTAssertEqual(snapshot.streamDeclarations.count, 2)
        XCTAssertEqual(snapshot.streamDeclarations[1].connectionGeneration, 1)
        XCTAssertEqual(snapshot.streamDeclarations[1].streams[1].metadata, Data([0xaa]))
        XCTAssertEqual(snapshot.packets.count, 1)
        XCTAssertEqual(snapshot.packets[0].streamDeclarationSequence, 0)
        XCTAssertEqual(snapshot.totalPacketCount, 3)
        XCTAssertEqual(snapshot.totalRawPayloadBytes, 5)
        XCTAssertEqual(snapshot.omittedPacketCount, 2)
        XCTAssertEqual(snapshot.omittedRawPayloadBytes, 3)
        XCTAssertEqual(snapshot.transportReaders.map(\.readerGeneration), [1, 2])
        XCTAssertEqual(snapshot.transportReaders.map(\.exactData.count), [200, 200])
        XCTAssertEqual(snapshot.transportReaders[0].exactData, Data(transport.prefix(200)))
        XCTAssertEqual(
            snapshot.transportReaders[1].exactData,
            Data(transport.dropFirst(200).prefix(200))
        )
        XCTAssertEqual(snapshot.totalTransportBytes, 500)
        XCTAssertEqual(snapshot.captureLimitOmittedTransportBytes, 100)
        XCTAssertEqual(snapshot.transportReads.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(snapshot.transportReads.map(\.readerGeneration), [1, 2, 2])
        XCTAssertEqual(snapshot.transportReads.map(\.capturedByteCount), [200, 200, 0])
        XCTAssertEqual(snapshot.transportReads[0].requestedByteCount, 32_768)
        XCTAssertEqual(snapshot.transportReads[0].returnedByteCount, 200)
        XCTAssertEqual(snapshot.transportReads[0].waitDurationMicroseconds, 12_000)
        XCTAssertEqual(snapshot.totalTransportReadCount, 3)
        XCTAssertEqual(snapshot.omittedTransportReadCount, 0)
    }

    func testWriterPersistsReplayablePacketAndTransportFilesWithManifestDiagnostics() throws {
        let recorder = makeRecorder(channelID: 7, startsAsCandidate: false)
        let muxPacket = packet(stream: 1, payload: [0xde, 0xad, 0xbe, 0xef])
        recorder.record(muxPacket, isVideo: true, isAudio: false)
        let transport = makeTransportStream(packetCount: 6, payloadByte: 0x41)
        recorder.recordTransportRead(transport, sequence: 0, readerGeneration: 3)
        let snapshot = recorder.sealAndSnapshot()

        let root = temporaryURL("capture-writer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try HTSPTuningFailureCaptureWriter.persist(
            snapshots: [snapshot],
            attempt: 4,
            channelID: 7,
            channelName: "Das Erste HD",
            suspiciousReasons: ["no-dwell-audio-output"],
            diagnosticSummary: "audio stopped after its first output buffer",
            benchmarkSample: Data("{\"success\":false}".utf8),
            destinationRoot: root,
            now: Date(timeIntervalSinceReferenceDate: 12_000)
        )

        let manifestData = try Data(
            contentsOf: directory.appending(path: "manifest.json")
        )
        let manifest = try JSONDecoder().decode(
            HTSPTuningFailureCaptureManifest.self,
            from: manifestData
        )
        XCTAssertEqual(manifest.formatVersion, 3)
        XCTAssertEqual(manifest.attempt, 4)
        XCTAssertEqual(manifest.channelID, 7)
        XCTAssertEqual(manifest.suspiciousReasons, ["no-dwell-audio-output"])
        XCTAssertEqual(manifest.streams.count, 1)
        let stream = try XCTUnwrap(manifest.streams.first)
        XCTAssertEqual(stream.subscriptionID, 1)
        XCTAssertEqual(stream.profile, "htsp")
        XCTAssertEqual(stream.streamDeclarations[0].streams[0].type, "H264")
        XCTAssertEqual(stream.retainedPacketCount, 1)
        XCTAssertEqual(stream.originalPacketCount, 1)
        XCTAssertEqual(stream.retainedRawPayloadBytes, 4)
        XCTAssertFalse(stream.rawCaptureTruncated)
        XCTAssertEqual(stream.retainedExactInputBytes, transport.count)
        XCTAssertEqual(stream.originalReadBytes, transport.count)
        XCTAssertEqual(stream.captureLimitOmittedBytes, 0)
        XCTAssertFalse(stream.transportCaptureTruncated)
        XCTAssertEqual(stream.transportReaders.map(\.readerGeneration), [3])
        XCTAssertEqual(stream.originalTransportReadCount, 1)
        XCTAssertEqual(stream.retainedTransportReadCount, 1)
        XCTAssertEqual(stream.omittedTransportReadCount, 0)

        let packetLines = try String(
            contentsOf: directory.appending(path: stream.muxPacketFile),
            encoding: .utf8
        ).split(whereSeparator: \.isNewline)
        XCTAssertEqual(packetLines.count, 1)
        let decodedPacket = try JSONDecoder().decode(
            HTSPTuningCapturedMuxPacket.self,
            from: Data(packetLines[0].utf8)
        )
        XCTAssertEqual(decodedPacket.payload, muxPacket.payload)
        let readLines = try String(
            contentsOf: directory.appending(path: stream.vlcTransportReadFile),
            encoding: .utf8
        ).split(whereSeparator: \.isNewline)
        XCTAssertEqual(readLines.count, 1)
        let decodedRead = try JSONDecoder().decode(
            HTSPTuningCapturedTransportRead.self,
            from: Data(readLines[0].utf8)
        )
        XCTAssertEqual(decodedRead.sequence, 0)
        XCTAssertEqual(decodedRead.readerGeneration, 3)
        let exactInputFile = try XCTUnwrap(stream.vlcInputByteFile)
        let transportFile = try XCTUnwrap(stream.vlcTransportStreamFile)
        XCTAssertEqual(
            try Data(contentsOf: directory.appending(path: exactInputFile)),
            transport
        )
        XCTAssertEqual(
            try Data(contentsOf: directory.appending(path: transportFile)),
            transport
        )
        XCTAssertEqual(
            try Data(contentsOf: directory.appending(path: manifest.benchmarkSampleFile)),
            Data("{\"success\":false}".utf8)
        )
    }

    func testConcurrentTransportCaptureIsReorderedByReadSequence() {
        let recorder = makeRecorder(channelID: 8, startsAsCandidate: false)
        let first = Data(repeating: 0x11, count: 188)
        let second = Data(repeating: 0x22, count: 188)
        let allowFirst = DispatchSemaphore(value: 0)
        let firstFinished = expectation(description: "first read recorded")
        let secondFinished = expectation(description: "second read recorded")

        DispatchQueue.global(qos: .userInitiated).async {
            allowFirst.wait()
            recorder.recordTransportRead(first, sequence: 0, readerGeneration: 4)
            firstFinished.fulfill()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            recorder.recordTransportRead(second, sequence: 1, readerGeneration: 4)
            secondFinished.fulfill()
            allowFirst.signal()
        }

        wait(for: [secondFinished, firstFinished], timeout: 2)
        let snapshot = recorder.sealAndSnapshot()
        XCTAssertEqual(snapshot.transportReads.map(\.sequence), [0, 1])
        XCTAssertEqual(
            snapshot.transportReaders.first?.exactData,
            first + second
        )
    }

    func testWriterPersistsOneReplayableTransportFilePerReaderGeneration() throws {
        let generationOne = makeTransportStream(packetCount: 5, payloadByte: 0x31)
        let generationTwo = makeTransportStream(packetCount: 6, payloadByte: 0x32)
        let recorder = HTSPTuningFailureCaptureRecorder(
            channelID: 10,
            profile: "htsp",
            acceptedTimeshiftPeriodSeconds: 60,
            streams: streams,
            startsAsCandidate: false,
            limits: HTSPTuningFailureCaptureLimits(
                maximumRawPayloadBytes: 1_024,
                maximumTransportBytes: generationOne.count + generationTwo.count,
                maximumPacketCount: 32,
                maximumReaderGenerationCount: 2,
                reservedTransportBytesPerReaderGeneration: generationTwo.count
            )
        )
        recorder.recordTransportRead(generationOne, sequence: 0, readerGeneration: 1)
        recorder.recordTransportRead(generationTwo, sequence: 1, readerGeneration: 2)

        let root = temporaryURL("capture-multiple-readers")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try HTSPTuningFailureCaptureWriter.persist(
            snapshots: [recorder.sealAndSnapshot()],
            attempt: 1,
            channelID: 10,
            channelName: "Reader rebuild",
            suspiciousReasons: ["reader-rebuilt"],
            diagnosticSummary: "VLC reader generation changed",
            benchmarkSample: Data("{}".utf8),
            destinationRoot: root
        )
        let manifest = try JSONDecoder().decode(
            HTSPTuningFailureCaptureManifest.self,
            from: Data(contentsOf: directory.appending(path: "manifest.json"))
        )
        let stream = try XCTUnwrap(manifest.streams.first)
        XCTAssertNil(stream.vlcTransportStreamFile)
        XCTAssertEqual(stream.transportReaders.map(\.readerGeneration), [1, 2])
        XCTAssertEqual(
            try Data(
                contentsOf: directory.appending(
                    path: stream.transportReaders[0].exactInputByteFile
                )
            ),
            generationOne
        )
        XCTAssertEqual(
            try Data(
                contentsOf: directory.appending(
                    path: stream.transportReaders[1].exactInputByteFile
                )
            ),
            generationTwo
        )
        let alignedOne = try XCTUnwrap(
            stream.transportReaders[0].syncAlignedTransportStreamFile
        )
        let alignedTwo = try XCTUnwrap(
            stream.transportReaders[1].syncAlignedTransportStreamFile
        )
        XCTAssertNotEqual(alignedOne, alignedTwo)
        XCTAssertEqual(
            try Data(contentsOf: directory.appending(path: alignedOne)),
            generationOne
        )
        XCTAssertEqual(
            try Data(contentsOf: directory.appending(path: alignedTwo)),
            generationTwo
        )
    }

    func testTransportReadAndChunkCollectionsStayBounded() {
        let recorder = HTSPTuningFailureCaptureRecorder(
            channelID: 11,
            profile: "htsp",
            acceptedTimeshiftPeriodSeconds: 60,
            streams: streams,
            startsAsCandidate: false,
            limits: HTSPTuningFailureCaptureLimits(
                maximumRawPayloadBytes: 0,
                maximumTransportBytes: 188,
                maximumPacketCount: 0,
                maximumTransportReadCount: 2,
                maximumTransportChunkCount: 1
            )
        )
        let packet = Data(repeating: 0x47, count: 188)
        recorder.recordTransportRead(packet, sequence: 0, readerGeneration: 1)
        recorder.recordTransportRead(packet, sequence: 1, readerGeneration: 1)
        recorder.recordTransportRead(packet, sequence: 2, readerGeneration: 1)

        let snapshot = recorder.sealAndSnapshot()
        XCTAssertEqual(snapshot.totalTransportReadCount, 3)
        XCTAssertEqual(snapshot.transportReads.map(\.sequence), [0, 1])
        XCTAssertEqual(snapshot.omittedTransportReadCount, 1)
        XCTAssertEqual(snapshot.totalTransportBytes, 188 * 3)
        XCTAssertEqual(snapshot.transportReaders.first?.exactData.count, 188)
        XCTAssertEqual(snapshot.captureLimitOmittedTransportBytes, 188 * 2)
    }

    func testWriterPreservesExactReaderBytesAndDerivesAlignedTransportRun() throws {
        let transport = makeTransportStream(packetCount: 6, payloadByte: 0x55)
        let leadingPartial = Data(repeating: 0xa1, count: 17)
        let trailingPartial = Data(repeating: 0xa2, count: 23)
        let exactInput = leadingPartial + transport + trailingPartial
        let recorder = HTSPTuningFailureCaptureRecorder(
            channelID: 12,
            profile: "htsp",
            acceptedTimeshiftPeriodSeconds: 60,
            streams: streams,
            startsAsCandidate: false,
            limits: HTSPTuningFailureCaptureLimits(
                maximumRawPayloadBytes: 0,
                maximumTransportBytes: exactInput.count,
                maximumPacketCount: 0,
                maximumReaderGenerationCount: 1
            )
        )
        recorder.recordTransportRead(exactInput, sequence: 0, readerGeneration: 7)

        let root = temporaryURL("capture-partial-reader")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try HTSPTuningFailureCaptureWriter.persist(
            snapshots: [recorder.sealAndSnapshot()],
            attempt: 1,
            channelID: 12,
            channelName: "Partial reader",
            suspiciousReasons: ["reader-rebuilt"],
            diagnosticSummary: "reader began between TS packets",
            benchmarkSample: Data("{}".utf8),
            destinationRoot: root
        )
        let manifest = try JSONDecoder().decode(
            HTSPTuningFailureCaptureManifest.self,
            from: Data(contentsOf: directory.appending(path: "manifest.json"))
        )
        let reader = try XCTUnwrap(manifest.streams.first?.transportReaders.first)
        XCTAssertEqual(
            try Data(contentsOf: directory.appending(path: reader.exactInputByteFile)),
            exactInput
        )
        let alignedFile = try XCTUnwrap(reader.syncAlignedTransportStreamFile)
        XCTAssertEqual(
            try Data(contentsOf: directory.appending(path: alignedFile)),
            transport
        )
        XCTAssertEqual(reader.syncAlignmentDiscardedPrefixBytes, leadingPartial.count)
        XCTAssertEqual(reader.syncAlignmentDiscardedSuffixBytes, trailingPartial.count)
        XCTAssertEqual(reader.captureLimitOmittedBytes, 0)
        XCTAssertFalse(reader.transportCaptureTruncated)
    }

    func testWriterDoesNotClaimTransportAlignmentWithoutRobustSyncRun() throws {
        let shortInput = makeTransportStream(packetCount: 4, payloadByte: 0x61)
        let recorder = HTSPTuningFailureCaptureRecorder(
            channelID: 17,
            profile: "htsp",
            acceptedTimeshiftPeriodSeconds: 60,
            streams: streams,
            startsAsCandidate: false,
            limits: HTSPTuningFailureCaptureLimits(
                maximumRawPayloadBytes: 0,
                maximumTransportBytes: shortInput.count,
                maximumPacketCount: 0,
                maximumReaderGenerationCount: 1
            )
        )
        recorder.recordTransportRead(shortInput, sequence: 0, readerGeneration: 1)

        let root = temporaryURL("capture-no-sync-run")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try HTSPTuningFailureCaptureWriter.persist(
            snapshots: [recorder.sealAndSnapshot()],
            attempt: 1,
            channelID: 17,
            channelName: "Short input",
            suspiciousReasons: ["no-video-output"],
            diagnosticSummary: "less than five TS packets",
            benchmarkSample: Data("{}".utf8),
            destinationRoot: root
        )
        let manifest = try JSONDecoder().decode(
            HTSPTuningFailureCaptureManifest.self,
            from: Data(contentsOf: directory.appending(path: "manifest.json"))
        )
        let stream = try XCTUnwrap(manifest.streams.first)
        let reader = try XCTUnwrap(stream.transportReaders.first)
        XCTAssertNil(reader.syncAlignedTransportStreamFile)
        XCTAssertNil(stream.vlcTransportStreamFile)
        XCTAssertEqual(
            try Data(contentsOf: directory.appending(path: reader.exactInputByteFile)),
            shortInput
        )
    }

    func testSnapshotIsIdempotent() {
        let recorder = makeRecorder(channelID: 13, startsAsCandidate: false)
        recorder.record(
            packet(stream: 1, payload: [0x01, 0x02]),
            isVideo: true,
            isAudio: false
        )
        let transport = makeTransportStream(packetCount: 5, payloadByte: 0x33)
        recorder.recordTransportRead(transport, sequence: 0, readerGeneration: 1)

        let first = recorder.sealAndSnapshot()
        let second = recorder.sealAndSnapshot()
        XCTAssertEqual(first, second)
        XCTAssertEqual(second.packets.count, 1)
        XCTAssertEqual(second.transportReaders.first?.exactData, transport)
    }

    func testReaderCapacityReservesUsefulPrefixForLaterGenerations() {
        let packetBytes = 188
        let recorder = HTSPTuningFailureCaptureRecorder(
            channelID: 14,
            profile: "htsp",
            acceptedTimeshiftPeriodSeconds: 60,
            streams: streams,
            startsAsCandidate: false,
            limits: HTSPTuningFailureCaptureLimits(
                maximumRawPayloadBytes: 0,
                maximumTransportBytes: packetBytes * 12,
                maximumPacketCount: 0,
                maximumTransportReadCount: 16,
                maximumTransportChunkCount: 16,
                maximumReaderGenerationCount: 3,
                reservedTransportBytesPerReaderGeneration: packetBytes * 2,
                reservedTransportChunksPerReaderGeneration: 1
            )
        )
        recorder.recordTransportRead(
            makeTransportStream(packetCount: 8, payloadByte: 0x41),
            sequence: 0,
            readerGeneration: 1
        )
        recorder.recordTransportRead(
            makeTransportStream(packetCount: 4, payloadByte: 0x42),
            sequence: 1,
            readerGeneration: 2
        )
        recorder.recordTransportRead(
            makeTransportStream(packetCount: 3, payloadByte: 0x43),
            sequence: 2,
            readerGeneration: 3
        )
        recorder.recordTransportRead(
            makeTransportStream(packetCount: 1, payloadByte: 0x44),
            sequence: 3,
            readerGeneration: 4
        )

        let snapshot = recorder.sealAndSnapshot()
        XCTAssertEqual(snapshot.transportReaders.map(\.readerGeneration), [1, 2, 3])
        XCTAssertEqual(
            snapshot.transportReaders.map { $0.exactData.count / packetBytes },
            [8, 2, 2]
        )
        XCTAssertEqual(snapshot.totalReaderGenerationCount, 4)
        XCTAssertEqual(snapshot.omittedReaderGenerationCount, 1)
        XCTAssertEqual(snapshot.captureLimitOmittedTransportBytes, packetBytes * 4)
    }

    func testStreamDeclarationsAndMetadataAreBounded() {
        let recorder = HTSPTuningFailureCaptureRecorder(
            channelID: 15,
            profile: "htsp",
            acceptedTimeshiftPeriodSeconds: 60,
            streams: streams,
            startsAsCandidate: false,
            limits: HTSPTuningFailureCaptureLimits(
                maximumRawPayloadBytes: 64,
                maximumTransportBytes: 0,
                maximumPacketCount: 8,
                maximumStreamDeclarationCount: 2,
                maximumStreamDeclarationMetadataBytes: 2
            )
        )
        recorder.recordStreamDeclaration(streams, connectionGeneration: 1)
        recorder.recordStreamDeclaration(streams, connectionGeneration: 2)
        recorder.record(
            packet(stream: 1, payload: [0x01]),
            isVideo: true,
            isAudio: false
        )

        let snapshot = recorder.sealAndSnapshot()
        XCTAssertEqual(snapshot.streamDeclarations.count, 2)
        XCTAssertEqual(snapshot.totalStreamDeclarationCount, 3)
        XCTAssertEqual(snapshot.omittedStreamDeclarationCount, 1)
        XCTAssertEqual(snapshot.totalStreamDeclarationMetadataBytes, 3)
        XCTAssertEqual(snapshot.omittedStreamDeclarationMetadataBytes, 1)
        XCTAssertEqual(snapshot.totalPacketCount, 1)
        XCTAssertEqual(snapshot.omittedPacketCount, 1)
    }

    func testRawHTSPCapturePreservesArbitraryMalformedFramesExactly() throws {
        let startedAt = Date(timeIntervalSinceReferenceDate: 20_000)
        let recorder = HTSPTuningFailureCaptureRecorder(
            channelID: 16,
            profile: "htsp",
            acceptedTimeshiftPeriodSeconds: 0,
            streams: [],
            startsAsCandidate: false,
            limits: HTSPTuningFailureCaptureLimits(
                maximumRawPayloadBytes: 0,
                maximumTransportBytes: 0,
                maximumPacketCount: 0,
                maximumRawHTSPFrameBytes: 16,
                maximumRawHTSPFrameCount: 2
            ),
            startedAt: startedAt
        )
        // Deliberately inconsistent/invalid length prefixes; the recorder must
        // preserve observer bytes rather than interpreting them.
        let malformed = Data([0, 0, 0, 9, 0xff, 0x00])
        let arbitrary = Data([0xff, 0xff, 0xff, 0xff, 0x01])
        let omitted = Data(repeating: 0x7f, count: 8)
        recorder.recordRawHTSPMessage(
            malformed,
            receivedAt: startedAt.addingTimeInterval(0.010)
        )
        recorder.recordRawHTSPMessage(
            arbitrary,
            receivedAt: startedAt.addingTimeInterval(0.020)
        )
        recorder.recordRawHTSPMessage(omitted)
        recorder.updateSubscriptionMetadata(
            acceptedTimeshiftPeriodSeconds: 60,
            streams: streams,
            receivedAt: startedAt.addingTimeInterval(0.030)
        )

        let snapshot = recorder.sealAndSnapshot()
        XCTAssertEqual(snapshot.acceptedTimeshiftPeriodSeconds, 60)
        XCTAssertEqual(snapshot.streamDeclarations.first?.sequence, 0)
        XCTAssertEqual(snapshot.rawHTSPData, malformed + arbitrary)
        XCTAssertEqual(snapshot.rawHTSPFrames.map(\.byteOffset), [0, malformed.count])
        XCTAssertEqual(snapshot.totalRawHTSPFrameCount, 3)
        XCTAssertEqual(snapshot.omittedRawHTSPFrameCount, 1)
        XCTAssertEqual(snapshot.omittedRawHTSPFrameBytes, omitted.count)

        let root = temporaryURL("capture-raw-htsp")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try HTSPTuningFailureCaptureWriter.persist(
            snapshots: [snapshot],
            attempt: 1,
            channelID: 16,
            channelName: "Malformed HTSP",
            suspiciousReasons: ["prepare-failed"],
            diagnosticSummary: "malformed wire frame",
            benchmarkSample: Data("{}".utf8),
            destinationRoot: root
        )
        let manifest = try JSONDecoder().decode(
            HTSPTuningFailureCaptureManifest.self,
            from: Data(contentsOf: directory.appending(path: "manifest.json"))
        )
        let stream = try XCTUnwrap(manifest.streams.first)
        XCTAssertEqual(
            try Data(contentsOf: directory.appending(path: stream.rawHTSPFrameFile)),
            malformed + arbitrary
        )
        XCTAssertTrue(stream.rawHTSPCaptureTruncated)
        XCTAssertEqual(stream.originalRawHTSPFrameCount, 3)
        XCTAssertEqual(stream.retainedRawHTSPFrameCount, 2)
    }

    func testFinishedAttemptDiscardPreservesSameChannelActiveCandidate() throws {
        let parent = temporaryURL("capture-attempt-ownership")
        defer { try? FileManager.default.removeItem(at: parent) }
        let registry = HTSPTuningFailureCaptureRegistry(
            enabled: true,
            limits: smallLimits,
            maximumTrackedStreams: 2
        )
        _ = try registry.startSession(in: parent)
        try registry.beginAttempt(
            attempt: 1,
            channelID: 9,
            channelName: "Repeated channel",
            mode: "transport-warm",
            direction: "up"
        )
        let foreground = registry.makeRecorder(
            channelID: 9,
            profile: "htsp",
            acceptedTimeshiftPeriodSeconds: 60,
            streams: streams,
            startsAsCandidate: false
        )
        registry.associateCandidateRecorder(channelID: 9, withAttempt: 2)
        let nextCandidate = registry.makeRecorder(
            channelID: 9,
            profile: "htsp",
            acceptedTimeshiftPeriodSeconds: 60,
            streams: streams,
            startsAsCandidate: true
        )
        XCTAssertNotNil(foreground)
        XCTAssertNotNil(nextCandidate)
        XCTAssertEqual(foreground?.benchmarkAttempt, 1)
        XCTAssertEqual(nextCandidate?.benchmarkAttempt, 2)
        foreground?.record(packet(stream: 1, payload: [1]), isVideo: true, isAudio: false)
        nextCandidate?.record(packet(stream: 1, payload: [2]), isVideo: true, isAudio: false)

        registry.discardFinishedAttempt(attempt: 1)
        nextCandidate?.record(packet(stream: 1, payload: [3]), isVideo: true, isAudio: false)

        XCTAssertEqual(foreground?.sealAndSnapshot().packets.count, 0)
        XCTAssertEqual(nextCandidate?.sealAndSnapshot().packets.map(\.payload), [Data([2]), Data([3])])
    }

    func testRegistryNeverEvictsAnActiveWarmCandidateAtItsBound() {
        let registry = HTSPTuningFailureCaptureRegistry(
            enabled: true,
            limits: smallLimits,
            maximumTrackedStreams: 1
        )
        let candidate = registry.makeRecorder(
            channelID: 1,
            profile: "htsp",
            acceptedTimeshiftPeriodSeconds: 60,
            streams: streams,
            startsAsCandidate: true
        )
        let overflow = registry.makeRecorder(
            channelID: 2,
            profile: "htsp",
            acceptedTimeshiftPeriodSeconds: 60,
            streams: streams,
            startsAsCandidate: false
        )

        XCTAssertNotNil(candidate)
        XCTAssertNil(overflow)
        candidate?.record(packet(stream: 1, payload: [0x44]), isVideo: true, isAudio: false)
        XCTAssertEqual(candidate?.sealAndSnapshot().packets.count, 1)
    }

    func testRepeatedChannelFinalizationSelectsOnlyMatchingAttempt() throws {
        let parent = temporaryURL("capture-repeated-channel-attempt")
        defer { try? FileManager.default.removeItem(at: parent) }
        let registry = HTSPTuningFailureCaptureRegistry(
            enabled: true,
            limits: spoolingLimits,
            maximumTrackedStreams: 3
        )
        _ = try registry.startSession(in: parent)
        try registry.beginAttempt(
            attempt: 1,
            channelID: 31,
            channelName: "Repeated",
            mode: "cold",
            direction: "up"
        )
        let first = try XCTUnwrap(
            registry.makeRecorder(
                channelID: 31,
                profile: "htsp",
                acceptedTimeshiftPeriodSeconds: 60,
                streams: streams,
                startsAsCandidate: false
            )
        )
        first.record(
            packet(stream: 1, payload: [0x01]),
            isVideo: true,
            isAudio: false
        )

        try registry.beginAttempt(
            attempt: 2,
            channelID: 31,
            channelName: "Repeated",
            mode: "cold",
            direction: "up"
        )
        let second = try XCTUnwrap(
            registry.makeRecorder(
                channelID: 31,
                profile: "htsp",
                acceptedTimeshiftPeriodSeconds: 60,
                streams: streams,
                startsAsCandidate: false
            )
        )
        second.record(
            packet(stream: 1, payload: [0x02]),
            isVideo: true,
            isAudio: false
        )

        let finalized = try XCTUnwrap(
            registry.persistSuspectAttempt(
                attempt: 2,
                channelID: 31,
                channelName: "Repeated",
                suspiciousReasons: ["no-audio-output"],
                diagnosticSummary: "second attempt only",
                benchmarkSample: Data("{}".utf8),
                destinationRoot: parent.appending(path: "finalized")
            )
        )
        let manifest = try JSONDecoder().decode(
            HTSPTuningFailureCaptureManifest.self,
            from: Data(contentsOf: finalized.appending(path: "manifest.json"))
        )
        XCTAssertEqual(manifest.streams.count, 1)
        let packetFile = try XCTUnwrap(manifest.streams.first?.muxPacketFile)
        let finalizedPackets: [HTSPTuningCapturedMuxPacket] = try decodeJSONLines(
            at: finalized.appending(path: packetFile)
        )
        XCTAssertEqual(finalizedPackets.map(\.payload), [Data([0x02])])
        XCTAssertEqual(first.sealAndSnapshot().packets.map(\.payload), [Data([0x01])])
        registry.discardFinishedAttempt(attempt: 1)
    }

    func testSpoolInitialMetadataFailureRemovesTransactionalDirectory() throws {
        enum SimulatedFailure: Error { case metadata }
        let parent = temporaryURL("capture-spool-transaction")
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appending(path: "spool", directoryHint: .isDirectory)

        XCTAssertThrowsError(
            try HTSPTuningFailureCaptureSpool(
                directory: directory,
                captureID: UUID(),
                benchmarkAttempt: 1,
                channelID: 32,
                profile: "htsp",
                acceptedTimeshiftPeriodSeconds: 0,
                startedAt: Date(),
                lifecycle: "foreground",
                streamDeclarations: [],
                limits: spoolingLimits,
                metadataWriter: { _, _ in throw SimulatedFailure.metadata }
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSpoolCreationFailureWritesSessionDiagnosticMarker() throws {
        let parent = temporaryURL("capture-spool-creation-failure")
        defer { try? FileManager.default.removeItem(at: parent) }
        let registry = HTSPTuningFailureCaptureRegistry(
            enabled: true,
            limits: spoolingLimits,
            maximumTrackedStreams: 1
        )
        let session = try XCTUnwrap(try registry.startSession(in: parent))
        try registry.beginAttempt(
            attempt: 4,
            channelID: 33,
            channelName: "Spool failure",
            mode: "cold",
            direction: "up"
        )
        let inProgress = session.appending(path: "in-progress")
        try FileManager.default.removeItem(at: inProgress)
        XCTAssertTrue(
            FileManager.default.createFile(atPath: inProgress.path, contents: Data([0x01]))
        )

        let recorder = try XCTUnwrap(
            registry.makeRecorder(
                channelID: 33,
                profile: "profile-without-credentials",
                acceptedTimeshiftPeriodSeconds: 0,
                streams: [],
                startsAsCandidate: false
            )
        )
        XCTAssertNil(recorder.spoolDirectory)
        let sessionMetadata = try JSONDecoder().decode(
            HTSPTuningFailureCaptureSessionMetadata.self,
            from: Data(contentsOf: session.appending(path: "session.json"))
        )
        let failures = try JSONDecoder().decode(
            [HTSPTuningFailureCaptureSpoolCreationFailure].self,
            from: Data(
                contentsOf: session.appending(
                    path: sessionMetadata.spoolCreationFailuresFile
                )
            )
        )
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.benchmarkAttempt, 4)
        XCTAssertEqual(failures.first?.channelID, 33)
        XCTAssertFalse(failures.first?.errorDomain.isEmpty ?? true)
        registry.discardFinishedAttempt(attempt: 4)
    }

    func testCrashSpoolPersistsAcceptedWireMuxAndVLCBytesInCallbackOrder() throws {
        let parent = temporaryURL("capture-spool-order")
        defer { try? FileManager.default.removeItem(at: parent) }
        let limits = HTSPTuningFailureCaptureLimits(
            maximumRawPayloadBytes: 1_024,
            maximumTransportBytes: 1_024,
            maximumPacketCount: 16,
            maximumTransportReadCount: 16,
            maximumTransportChunkCount: 16,
            maximumReaderGenerationCount: 2,
            maximumRawHTSPFrameBytes: 1_024,
            maximumRawHTSPFrameCount: 16
        )
        let registry = HTSPTuningFailureCaptureRegistry(
            enabled: true,
            limits: limits,
            maximumTrackedStreams: 2
        )
        let session = try XCTUnwrap(try registry.startSession(in: parent))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: session.appending(path: "session.json").path
            )
        )
        try registry.beginAttempt(
            attempt: 1,
            channelID: 21,
            channelName: "Spool order",
            mode: "cold",
            direction: "up"
        )
        let recorder = try XCTUnwrap(
            registry.makeRecorder(
                channelID: 21,
                profile: "htsp",
                acceptedTimeshiftPeriodSeconds: 60,
                streams: streams,
                startsAsCandidate: false
            )
        )
        let spool = try XCTUnwrap(recorder.spoolDirectory)
        let firstFrame = Data([0, 0, 0, 2, 0x11, 0x12])
        let secondFrame = Data([0, 0, 0, 1, 0x21])
        recorder.recordRawHTSPMessage(firstFrame)
        recorder.recordRawHTSPMessage(secondFrame)
        recorder.record(
            packet(stream: 1, payload: [0xaa, 0xbb]),
            isVideo: true,
            isAudio: false
        )
        let firstRead = Data([0x47, 0x01, 0x02])
        let secondRead = Data([0x03, 0x04, 0x05, 0x06])
        recorder.recordTransportRead(firstRead, sequence: 0, readerGeneration: 3)
        recorder.recordTransportRead(secondRead, sequence: 1, readerGeneration: 3)
        recorder.markClosed()

        XCTAssertEqual(
            try Data(
                contentsOf: spool.appending(
                    path: HTSPTuningFailureCaptureSpool.rawHTSPWireFile
                )
            ),
            firstFrame + secondFrame
        )
        let rawIndex: [HTSPTuningCapturedRawHTSPFrame] = try decodeJSONLines(
            at: spool.appending(
                path: HTSPTuningFailureCaptureSpool.rawHTSPWireIndexFile
            )
        )
        XCTAssertEqual(rawIndex.map(\.sequence), [0, 1])
        XCTAssertEqual(rawIndex.map(\.byteOffset), [0, firstFrame.count])
        let muxPackets: [HTSPTuningCapturedMuxPacket] = try decodeJSONLines(
            at: spool.appending(path: HTSPTuningFailureCaptureSpool.muxPacketFile)
        )
        XCTAssertEqual(muxPackets.map(\.payload), [Data([0xaa, 0xbb])])
        let reads: [HTSPTuningCapturedTransportRead] = try decodeJSONLines(
            at: spool.appending(path: HTSPTuningFailureCaptureSpool.vlcReadIndexFile)
        )
        XCTAssertEqual(reads.map(\.sequence), [0, 1])
        XCTAssertEqual(
            try Data(contentsOf: spool.appending(path: "vlc-reader-3-input.bytes")),
            firstRead + secondRead
        )
        let metadata = try decodeSpoolMetadata(at: spool)
        XCTAssertTrue(metadata.byteExactTransportCapture)
        XCTAssertEqual(metadata.benchmarkAttempt, 1)
        XCTAssertEqual(metadata.persistedRawHTSPFrameCount, 2)
        XCTAssertEqual(metadata.persistedMuxPacketCount, 1)
        XCTAssertEqual(metadata.persistedTransportReadCount, 2)
        XCTAssertEqual(metadata.transportReaders.first?.persistedExactInputBytes, 7)
        XCTAssertEqual(metadata.transportReaders.first?.firstReadSequence, 0)
        XCTAssertEqual(metadata.transportReaders.first?.lastReadSequence, 1)
        XCTAssertTrue(metadata.transportReaders.first?.mayEndWithPartialTransportPacket == true)

        registry.discardFinishedAttempt(attempt: 1)
    }

    func testHealthyDiscardSynchronouslyRemovesRecorderSpool() throws {
        let parent = temporaryURL("capture-spool-discard")
        defer { try? FileManager.default.removeItem(at: parent) }
        let registry = HTSPTuningFailureCaptureRegistry(
            enabled: true,
            limits: spoolingLimits,
            maximumTrackedStreams: 1
        )
        _ = try registry.startSession(in: parent)
        try registry.beginAttempt(
            attempt: 1,
            channelID: 22,
            channelName: "Healthy cleanup",
            mode: "cold",
            direction: "up"
        )
        let recorder = try XCTUnwrap(
            registry.makeRecorder(
                channelID: 22,
                profile: "htsp",
                acceptedTimeshiftPeriodSeconds: 60,
                streams: streams,
                startsAsCandidate: false
            )
        )
        let spool = try XCTUnwrap(recorder.spoolDirectory)
        recorder.recordRawHTSPMessage(Data([0, 0, 0, 1, 0x33]))

        registry.discardFinishedAttempt(attempt: 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path))
    }

    func testFailedFinalWriterAndUnfinishedAttemptRetainDurableSpool() throws {
        let parent = temporaryURL("capture-spool-retained")
        defer { try? FileManager.default.removeItem(at: parent) }
        let registry = HTSPTuningFailureCaptureRegistry(
            enabled: true,
            limits: spoolingLimits,
            maximumTrackedStreams: 1
        )
        _ = try registry.startSession(in: parent)
        try registry.beginAttempt(
            attempt: 1,
            channelID: 23,
            channelName: "Writer failure",
            mode: "cold",
            direction: "up"
        )
        let recorder = try XCTUnwrap(
            registry.makeRecorder(
                channelID: 23,
                profile: "htsp",
                acceptedTimeshiftPeriodSeconds: 60,
                streams: streams,
                startsAsCandidate: false
            )
        )
        let spool = try XCTUnwrap(recorder.spoolDirectory)
        let exactRead = Data([0x47, 0x10, 0x20, 0x30])
        recorder.recordTransportRead(exactRead, sequence: 0, readerGeneration: 1)
        recorder.synchronizeSpoolForTesting()
        XCTAssertEqual(
            try Data(contentsOf: spool.appending(path: "vlc-reader-1-input.bytes")),
            exactRead
        )
        XCTAssertEqual(try decodeSpoolMetadata(at: spool).state, "in-progress")

        let blockedDestination = parent.appending(path: "not-a-directory")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: blockedDestination.path,
                contents: Data([0x01])
            )
        )
        XCTAssertThrowsError(
            try registry.persistSuspectAttempt(
                attempt: 1,
                channelID: 23,
                channelName: "Writer failure",
                suspiciousReasons: ["prepare-failed"],
                diagnosticSummary: "simulated final writer failure",
                benchmarkSample: Data("{}".utf8),
                destinationRoot: blockedDestination
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.path))
        XCTAssertEqual(
            try decodeSpoolMetadata(at: spool).state,
            "sealed-awaiting-finalization"
        )
        XCTAssertEqual(
            try Data(contentsOf: spool.appending(path: "vlc-reader-1-input.bytes")),
            exactRead
        )

        // Capacity churn must release the sealed in-memory recorder without
        // deleting the only durable evidence of the failed final writer.
        try registry.beginAttempt(
            attempt: 2,
            channelID: 230,
            channelName: "Replacement",
            mode: "cold",
            direction: "up"
        )
        let replacement = registry.makeRecorder(
            channelID: 230,
            profile: "htsp",
            acceptedTimeshiftPeriodSeconds: 60,
            streams: streams,
            startsAsCandidate: false
        )
        XCTAssertNotNil(replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool.path))
        registry.discardFinishedAttempt(attempt: 2)
    }

    func testSuccessfulFinalWriterRemovesRecorderSpoolAfterBundleIsDurable() throws {
        let parent = temporaryURL("capture-spool-finalized")
        defer { try? FileManager.default.removeItem(at: parent) }
        let registry = HTSPTuningFailureCaptureRegistry(
            enabled: true,
            limits: spoolingLimits,
            maximumTrackedStreams: 1
        )
        _ = try registry.startSession(in: parent)
        try registry.beginAttempt(
            attempt: 1,
            channelID: 25,
            channelName: "Finalized failure",
            mode: "cold",
            direction: "up"
        )
        let recorder = try XCTUnwrap(
            registry.makeRecorder(
                channelID: 25,
                profile: "htsp",
                acceptedTimeshiftPeriodSeconds: 60,
                streams: streams,
                startsAsCandidate: false
            )
        )
        let spool = try XCTUnwrap(recorder.spoolDirectory)
        recorder.recordRawHTSPMessage(Data([0, 0, 0, 1, 0x55]))
        let finalizedRoot = parent.appending(path: "finalized", directoryHint: .isDirectory)

        let finalized = try XCTUnwrap(
            registry.persistSuspectAttempt(
                attempt: 1,
                channelID: 25,
                channelName: "Finalized failure",
                suspiciousReasons: ["no-audio-output"],
                diagnosticSummary: "simulated suspect tune",
                benchmarkSample: Data("{}".utf8),
                destinationRoot: finalizedRoot
            )
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: finalized.appending(path: "manifest.json").path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.path))
    }

    func testActiveAttemptMetadataIsAtomicAndClearedAfterCompletion() throws {
        let parent = temporaryURL("capture-session-attempt")
        defer { try? FileManager.default.removeItem(at: parent) }
        let registry = HTSPTuningFailureCaptureRegistry(enabled: true)
        let session = try XCTUnwrap(
            try registry.startSession(
                in: parent,
                now: Date(timeIntervalSinceReferenceDate: 30_000)
            )
        )
        try registry.beginAttempt(
            attempt: 7,
            channelID: 77,
            channelName: "Test Channel",
            mode: "cold",
            direction: "down",
            startedAt: Date(timeIntervalSinceReferenceDate: 30_001)
        )
        let activeURL = session.appending(path: "active-attempt.json")
        var active = try JSONDecoder().decode(
            HTSPTuningFailureCaptureAttemptMetadata.self,
            from: Data(contentsOf: activeURL)
        )
        XCTAssertEqual(active.attempt, 7)
        XCTAssertEqual(active.channelID, 77)
        XCTAssertEqual(active.phase, "starting")
        XCTAssertNil(active.completedAt)

        try registry.updateActiveAttemptPhase("prepare")
        active = try JSONDecoder().decode(
            HTSPTuningFailureCaptureAttemptMetadata.self,
            from: Data(contentsOf: activeURL)
        )
        XCTAssertEqual(active.phase, "prepare")

        try registry.completeAttempt(
            attempt: 7,
            success: false,
            completedAt: Date(timeIntervalSinceReferenceDate: 30_002)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeURL.path))
        let completed = try JSONDecoder().decode(
            HTSPTuningFailureCaptureAttemptMetadata.self,
            from: Data(contentsOf: session.appending(path: "last-completed-attempt.json"))
        )
        XCTAssertEqual(completed.phase, "completed")
        XCTAssertEqual(completed.success, false)
        XCTAssertNotNil(completed.completedAt)
    }

    func testCrashSpoolHonorsRecorderBoundsAndLabelsTruncation() throws {
        let parent = temporaryURL("capture-spool-bounds")
        defer { try? FileManager.default.removeItem(at: parent) }
        let limits = HTSPTuningFailureCaptureLimits(
            maximumRawPayloadBytes: 2,
            maximumTransportBytes: 5,
            maximumPacketCount: 1,
            maximumTransportReadCount: 1,
            maximumTransportChunkCount: 1,
            maximumReaderGenerationCount: 1,
            maximumRawHTSPFrameBytes: 6,
            maximumRawHTSPFrameCount: 1
        )
        let registry = HTSPTuningFailureCaptureRegistry(
            enabled: true,
            limits: limits,
            maximumTrackedStreams: 1
        )
        _ = try registry.startSession(in: parent)
        try registry.beginAttempt(
            attempt: 1,
            channelID: 24,
            channelName: "Bounds",
            mode: "cold",
            direction: "up"
        )
        let recorder = try XCTUnwrap(
            registry.makeRecorder(
                channelID: 24,
                profile: "htsp",
                acceptedTimeshiftPeriodSeconds: 60,
                streams: streams,
                startsAsCandidate: false
            )
        )
        let spool = try XCTUnwrap(recorder.spoolDirectory)
        recorder.recordRawHTSPMessage(Data([0, 0, 0, 2, 0x01, 0x02]))
        recorder.recordRawHTSPMessage(Data([0, 0, 0, 1, 0x03]))
        recorder.record(
            packet(stream: 1, payload: [0x01, 0x02]),
            isVideo: true,
            isAudio: false
        )
        recorder.record(
            packet(stream: 1, payload: [0x03]),
            isVideo: true,
            isAudio: false
        )
        recorder.recordTransportRead(
            Data([0x47, 1, 2, 3, 4, 5, 6]),
            sequence: 0,
            readerGeneration: 1
        )
        recorder.recordTransportRead(
            Data([0x47]),
            sequence: 1,
            readerGeneration: 2
        )
        recorder.markClosed()

        XCTAssertEqual(
            try Data(
                contentsOf: spool.appending(
                    path: HTSPTuningFailureCaptureSpool.rawHTSPWireFile
                )
            ).count,
            6
        )
        XCTAssertEqual(
            try Data(contentsOf: spool.appending(path: "vlc-reader-1-input.bytes")).count,
            5
        )
        let metadata = try decodeSpoolMetadata(at: spool)
        XCTAssertTrue(metadata.rawHTSPCaptureLimitReached)
        XCTAssertTrue(metadata.muxPacketCaptureLimitReached)
        XCTAssertTrue(metadata.transportCaptureLimitReached)
        XCTAssertTrue(metadata.transportReadIndexLimitReached)
        XCTAssertTrue(metadata.readerGenerationLimitReached)
        XCTAssertLessThanOrEqual(metadata.persistedRawHTSPFrameBytes, limits.maximumRawHTSPFrameBytes)
        XCTAssertLessThanOrEqual(
            metadata.transportReaders.reduce(0) { $0 + $1.persistedExactInputBytes },
            limits.maximumTransportBytes
        )

        registry.discardFinishedAttempt(attempt: 1)
    }

    private var streams: [HTSPStreamInfo] {
        [HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: Data([0x01]))]
    }

    private var smallLimits: HTSPTuningFailureCaptureLimits {
        HTSPTuningFailureCaptureLimits(
            maximumRawPayloadBytes: 1_024,
            maximumTransportBytes: 188 * 8,
            maximumPacketCount: 32
        )
    }

    private var spoolingLimits: HTSPTuningFailureCaptureLimits {
        HTSPTuningFailureCaptureLimits(
            maximumRawPayloadBytes: 1_024,
            maximumTransportBytes: 1_024,
            maximumPacketCount: 32,
            maximumTransportReadCount: 32,
            maximumTransportChunkCount: 32,
            maximumReaderGenerationCount: 2,
            maximumRawHTSPFrameBytes: 1_024,
            maximumRawHTSPFrameCount: 32
        )
    }

    private func makeRecorder(
        channelID: UInt32,
        startsAsCandidate: Bool
    ) -> HTSPTuningFailureCaptureRecorder {
        HTSPTuningFailureCaptureRecorder(
            channelID: channelID,
            profile: "htsp",
            acceptedTimeshiftPeriodSeconds: 60,
            streams: streams,
            startsAsCandidate: startsAsCandidate,
            limits: smallLimits
        )
    }

    private func packet(stream: Int, payload: [UInt8]) -> HTSPMuxPacket {
        HTSPMuxPacket(
            streamIndex: stream,
            frameType: 0x49,
            presentationTime: 1_000_000,
            decodeTime: 1_000_000,
            durationMicroseconds: 40_000,
            payload: Data(payload)
        )
    }

    private func makeTransportStream(
        packetCount: Int,
        payloadByte: UInt8
    ) -> Data {
        var result = Data()
        for packetIndex in 0..<packetCount {
            var packet = Data(repeating: payloadByte, count: 188)
            packet[0] = 0x47
            packet[1] = 0x40
            packet[2] = UInt8(truncatingIfNeeded: packetIndex)
            packet[3] = 0x10 | UInt8(truncatingIfNeeded: packetIndex & 0x0f)
            result.append(packet)
        }
        return result
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "TVPlayerTests-\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func decodeSpoolMetadata(
        at directory: URL
    ) throws -> HTSPTuningFailureCaptureSpoolMetadata {
        try JSONDecoder().decode(
            HTSPTuningFailureCaptureSpoolMetadata.self,
            from: Data(
                contentsOf: directory.appending(
                    path: HTSPTuningFailureCaptureSpool.metadataFile
                )
            )
        )
    }

    private func decodeJSONLines<T: Decodable>(at url: URL) throws -> [T] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { line in
                try JSONDecoder().decode(T.self, from: Data(line.utf8))
            }
    }
}
