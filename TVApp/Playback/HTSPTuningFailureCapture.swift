import Foundation
import Dispatch

struct HTSPTuningFailureCaptureLimits: Codable, Equatable, Sendable {
    static let benchmarkDefault = HTSPTuningFailureCaptureLimits(
        maximumRawPayloadBytes: 16 * 1_024 * 1_024,
        maximumTransportBytes: 16 * 1_024 * 1_024,
        maximumPacketCount: 16_384,
        maximumTransportReadCount: 16_384,
        maximumTransportChunkCount: 4_096,
        maximumStreamDeclarationCount: 32,
        maximumStreamDeclarationMetadataBytes: 1 * 1_024 * 1_024,
        maximumReaderGenerationCount: 4,
        reservedTransportBytesPerReaderGeneration: 2 * 1_024 * 1_024,
        reservedTransportChunksPerReaderGeneration: 512,
        maximumRawHTSPFrameBytes: 8 * 1_024 * 1_024,
        maximumRawHTSPFrameCount: 8_192
    )

    let maximumRawPayloadBytes: Int
    let maximumTransportBytes: Int
    let maximumPacketCount: Int
    let maximumTransportReadCount: Int
    let maximumTransportChunkCount: Int
    let maximumStreamDeclarationCount: Int
    let maximumStreamDeclarationMetadataBytes: Int
    let maximumReaderGenerationCount: Int
    let reservedTransportBytesPerReaderGeneration: Int
    let reservedTransportChunksPerReaderGeneration: Int
    let maximumRawHTSPFrameBytes: Int
    let maximumRawHTSPFrameCount: Int

    init(
        maximumRawPayloadBytes: Int,
        maximumTransportBytes: Int,
        maximumPacketCount: Int,
        maximumTransportReadCount: Int = 16_384,
        maximumTransportChunkCount: Int = 4_096,
        maximumStreamDeclarationCount: Int = 32,
        maximumStreamDeclarationMetadataBytes: Int = 1 * 1_024 * 1_024,
        maximumReaderGenerationCount: Int = 4,
        reservedTransportBytesPerReaderGeneration: Int = 0,
        reservedTransportChunksPerReaderGeneration: Int = 0,
        maximumRawHTSPFrameBytes: Int = 0,
        maximumRawHTSPFrameCount: Int = 0
    ) {
        self.maximumRawPayloadBytes = max(0, maximumRawPayloadBytes)
        self.maximumTransportBytes = max(0, maximumTransportBytes)
        self.maximumPacketCount = max(0, maximumPacketCount)
        self.maximumTransportReadCount = max(0, maximumTransportReadCount)
        self.maximumTransportChunkCount = max(0, maximumTransportChunkCount)
        self.maximumStreamDeclarationCount = max(0, maximumStreamDeclarationCount)
        self.maximumStreamDeclarationMetadataBytes = max(
            0,
            maximumStreamDeclarationMetadataBytes
        )
        self.maximumReaderGenerationCount = max(0, maximumReaderGenerationCount)
        self.reservedTransportBytesPerReaderGeneration = max(
            0,
            reservedTransportBytesPerReaderGeneration
        )
        self.reservedTransportChunksPerReaderGeneration = max(
            0,
            reservedTransportChunksPerReaderGeneration
        )
        self.maximumRawHTSPFrameBytes = max(0, maximumRawHTSPFrameBytes)
        self.maximumRawHTSPFrameCount = max(0, maximumRawHTSPFrameCount)
    }
}

struct HTSPTuningCapturedMuxPacket: Codable, Equatable, Sendable {
    let sequence: Int
    let streamDeclarationSequence: Int
    let elapsedMilliseconds: Int
    let streamIndex: Int
    let frameType: UInt8
    let presentationTime: Int64?
    let decodeTime: Int64?
    let durationMicroseconds: Int64?
    let trackKind: String
    let payload: Data
}

struct HTSPTuningCapturedStreamInfo: Codable, Equatable, Sendable {
    let index: Int
    let type: String
    let language: String?
    let metadata: Data?

    init(_ stream: HTSPStreamInfo) {
        index = stream.index
        type = stream.type
        language = stream.language
        metadata = stream.metadata
    }
}

struct HTSPTuningCapturedStreamDeclaration: Codable, Equatable, Sendable {
    let sequence: Int
    let connectionGeneration: Int
    let elapsedMilliseconds: Int
    let streams: [HTSPTuningCapturedStreamInfo]
}

struct HTSPTuningCapturedTransportRead: Codable, Equatable, Sendable {
    let sequence: Int
    let readerGeneration: Int
    let requestedByteCount: Int
    let returnedByteCount: Int
    let capturedByteCount: Int
    let elapsedMilliseconds: Int
    let waitDurationMicroseconds: Int
    let readerGenerationAccepted: Bool
}

struct HTSPTuningCapturedTransportReader: Equatable, Sendable {
    let readerGeneration: Int
    let exactData: Data
    let totalReadByteCount: Int
    let captureLimitOmittedByteCount: Int
    let readCount: Int
    let firstReadSequence: Int?
    let lastReadSequence: Int?
}

struct HTSPTuningCapturedRawHTSPFrame: Codable, Equatable, Sendable {
    let sequence: Int
    let byteOffset: Int
    let byteCount: Int
    let elapsedMilliseconds: Int
}

struct HTSPTuningFailureCaptureSnapshot: Equatable, Sendable {
    let captureID: UUID
    let channelID: UInt32
    let profile: String
    let acceptedTimeshiftPeriodSeconds: TimeInterval
    let startedAt: Date
    let lifecycle: String
    let streamDeclarations: [HTSPTuningCapturedStreamDeclaration]
    let rawHTSPFrames: [HTSPTuningCapturedRawHTSPFrame]
    let rawHTSPData: Data
    let transportReads: [HTSPTuningCapturedTransportRead]
    let transportReaders: [HTSPTuningCapturedTransportReader]
    let packets: [HTSPTuningCapturedMuxPacket]
    let totalPacketCount: Int
    let totalRawPayloadBytes: Int
    let omittedPacketCount: Int
    let omittedRawPayloadBytes: Int
    let totalStreamDeclarationCount: Int
    let omittedStreamDeclarationCount: Int
    let totalStreamDeclarationMetadataBytes: Int
    let omittedStreamDeclarationMetadataBytes: Int
    let totalRawHTSPFrameCount: Int
    let totalRawHTSPFrameBytes: Int
    let omittedRawHTSPFrameCount: Int
    let omittedRawHTSPFrameBytes: Int
    let totalTransportBytes: Int
    let captureLimitOmittedTransportBytes: Int
    let totalTransportReadCount: Int
    let omittedTransportReadCount: Int
    let totalReaderGenerationCount: Int
    let omittedReaderGenerationCount: Int
}

struct HTSPTuningFailureCaptureSessionMetadata: Codable, Equatable, Sendable {
    let formatVersion: Int
    let sessionID: String
    let createdAt: String
    let inProgressDirectory: String
    let activeAttemptFile: String
    let lastCompletedAttemptFile: String
    let spoolCreationFailuresFile: String
}

struct HTSPTuningFailureCaptureAttemptMetadata: Codable, Equatable, Sendable {
    let formatVersion: Int
    let attempt: Int
    let channelID: UInt32
    let channelName: String
    let mode: String
    let direction: String
    let startedAt: String
    var phase: String
    var completedAt: String?
    var success: Bool?
}

struct HTSPTuningFailureCaptureSpoolMetadata: Codable, Equatable, Sendable {
    struct TransportReader: Codable, Equatable, Sendable {
        let readerGeneration: Int
        let exactInputByteFile: String
        let byteExact: Bool
        let mayEndWithPartialTransportPacket: Bool
        var persistedExactInputBytes: Int
        var persistedReadCount: Int
        var firstReadSequence: Int?
        var lastReadSequence: Int?
    }

    let formatVersion: Int
    let captureID: String
    let benchmarkAttempt: Int?
    let channelID: UInt32
    let profile: String
    let startedAt: String
    let limits: HTSPTuningFailureCaptureLimits
    let rawHTSPWireFile: String
    let rawHTSPWireIndexFile: String
    let muxPacketFile: String
    let vlcReadIndexFile: String
    let byteExactTransportCapture: Bool
    let asynchronousTailTargetMilliseconds: Int
    var acceptedTimeshiftPeriodSeconds: TimeInterval
    var lifecycle: String
    var streamDeclarations: [HTSPTuningCapturedStreamDeclaration]
    var persistedRawHTSPFrameCount: Int
    var persistedRawHTSPFrameBytes: Int
    var persistedMuxPacketCount: Int
    var persistedMuxPayloadBytes: Int
    var persistedTransportReadCount: Int
    var transportReaders: [TransportReader]
    var rawHTSPCaptureLimitReached: Bool
    var muxPacketCaptureLimitReached: Bool
    var streamDeclarationCaptureLimitReached: Bool
    var transportCaptureLimitReached: Bool
    var transportReadIndexLimitReached: Bool
    var readerGenerationLimitReached: Bool
    var state: String
    var lastSynchronizedAt: String?
    var firstWriteError: String?
}

struct HTSPTuningFailureCaptureSpoolCreationFailure: Codable, Equatable, Sendable {
    let formatVersion: Int
    let createdAt: String
    let benchmarkAttempt: Int?
    let channelID: UInt32
    let errorDomain: String
    let errorCode: Int
}

/// An append-only, crash-survivable mirror of the bounded in-memory recorder.
/// Every operation is queued in the same order in which recorder admission is
/// decided. Media threads only copy already-admitted bytes into queue closures;
/// they never wait for filesystem I/O.
final class HTSPTuningFailureCaptureSpool: @unchecked Sendable {
    typealias MetadataWriter = @Sendable (
        HTSPTuningFailureCaptureSpoolMetadata,
        URL
    ) throws -> Void

    enum CaptureLimit: Sendable {
        case rawHTSP
        case muxPacket
        case streamDeclaration
        case transport
        case transportReadIndex
        case readerGeneration
    }

    static let rawHTSPWireFile = "htsp-wire.htsp"
    static let rawHTSPWireIndexFile = "htsp-wire-index.jsonl"
    static let muxPacketFile = "htsp-mux-packets.jsonl"
    static let vlcReadIndexFile = "vlc-reads.jsonl"
    static let metadataFile = "spool.json"
    static let asynchronousTailTargetMilliseconds = 250

    let directory: URL

    private let queue: DispatchQueue
    private let fileManager: FileManager
    private let metadataURL: URL
    private let metadataWriter: MetadataWriter
    private let rawHTSPHandle: FileHandle
    private let rawHTSPIndexHandle: FileHandle
    private let muxPacketHandle: FileHandle
    private let vlcReadIndexHandle: FileHandle
    private var transportReaderHandles: [Int: FileHandle] = [:]
    private var metadata: HTSPTuningFailureCaptureSpoolMetadata
    private var timer: DispatchSourceTimer?
    private var closed = false

    init(
        directory: URL,
        captureID: UUID,
        benchmarkAttempt: Int?,
        channelID: UInt32,
        profile: String,
        acceptedTimeshiftPeriodSeconds: TimeInterval,
        startedAt: Date,
        lifecycle: String,
        streamDeclarations: [HTSPTuningCapturedStreamDeclaration],
        limits: HTSPTuningFailureCaptureLimits,
        fileManager: FileManager = .default,
        metadataWriter: @escaping MetadataWriter = HTSPTuningFailureCaptureSpool.writeMetadata
    ) throws {
        self.directory = directory
        self.fileManager = fileManager
        self.metadataWriter = metadataWriter
        queue = DispatchQueue(
            label: "TVApp.HTSPTuningFailureCaptureSpool.\(captureID.uuidString)",
            qos: .utility
        )
        metadataURL = directory.appending(path: Self.metadataFile)

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        do {
            rawHTSPHandle = try Self.createFileHandle(
                at: directory.appending(path: Self.rawHTSPWireFile),
                fileManager: fileManager
            )
            rawHTSPIndexHandle = try Self.createFileHandle(
                at: directory.appending(path: Self.rawHTSPWireIndexFile),
                fileManager: fileManager
            )
            muxPacketHandle = try Self.createFileHandle(
                at: directory.appending(path: Self.muxPacketFile),
                fileManager: fileManager
            )
            vlcReadIndexHandle = try Self.createFileHandle(
                at: directory.appending(path: Self.vlcReadIndexFile),
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        metadata = HTSPTuningFailureCaptureSpoolMetadata(
            formatVersion: 2,
            captureID: captureID.uuidString.lowercased(),
            benchmarkAttempt: benchmarkAttempt,
            channelID: channelID,
            profile: profile,
            startedAt: Self.iso8601(startedAt),
            limits: limits,
            rawHTSPWireFile: Self.rawHTSPWireFile,
            rawHTSPWireIndexFile: Self.rawHTSPWireIndexFile,
            muxPacketFile: Self.muxPacketFile,
            vlcReadIndexFile: Self.vlcReadIndexFile,
            byteExactTransportCapture: true,
            asynchronousTailTargetMilliseconds: Self.asynchronousTailTargetMilliseconds,
            acceptedTimeshiftPeriodSeconds: acceptedTimeshiftPeriodSeconds,
            lifecycle: lifecycle,
            streamDeclarations: streamDeclarations,
            persistedRawHTSPFrameCount: 0,
            persistedRawHTSPFrameBytes: 0,
            persistedMuxPacketCount: 0,
            persistedMuxPayloadBytes: 0,
            persistedTransportReadCount: 0,
            transportReaders: [],
            rawHTSPCaptureLimitReached: false,
            muxPacketCaptureLimitReached: false,
            streamDeclarationCaptureLimitReached: false,
            transportCaptureLimitReached: false,
            transportReadIndexLimitReached: false,
            readerGenerationLimitReached: false,
            state: "in-progress",
            lastSynchronizedAt: nil,
            firstWriteError: nil
        )
        do {
            try persistMetadata()
        } catch {
            // All handles are initialized by this point. Close them before
            // removing the directory so a failed first metadata checkpoint
            // cannot leave an unannounced, apparently valid orphan spool.
            closeHandles()
            try? fileManager.removeItem(at: directory)
            throw error
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(Self.asynchronousTailTargetMilliseconds),
            repeating: .milliseconds(Self.asynchronousTailTargetMilliseconds)
        )
        timer.setEventHandler { [weak self] in
            self?.synchronizeAndCheckpoint()
        }
        self.timer = timer
        timer.resume()
    }

    func appendRawHTSPFrame(
        _ exactFrame: Data,
        index: HTSPTuningCapturedRawHTSPFrame
    ) {
        queue.async { [self] in
            guard !closed else { return }
            do {
                try rawHTSPHandle.write(contentsOf: exactFrame)
                try writeJSONLine(index, to: rawHTSPIndexHandle)
                metadata.persistedRawHTSPFrameCount += 1
                metadata.persistedRawHTSPFrameBytes += exactFrame.count
            } catch {
                record(error)
            }
        }
    }

    func appendMuxPacket(_ packet: HTSPTuningCapturedMuxPacket) {
        queue.async { [self] in
            guard !closed else { return }
            do {
                try writeJSONLine(packet, to: muxPacketHandle)
                metadata.persistedMuxPacketCount += 1
                metadata.persistedMuxPayloadBytes += packet.payload.count
            } catch {
                record(error)
            }
        }
    }

    func appendTransportRead(
        _ read: HTSPTuningCapturedTransportRead?,
        exactBytes: Data,
        readerGeneration: Int,
        readerGenerationAccepted: Bool
    ) {
        queue.async { [self] in
            guard !closed else { return }
            do {
                if readerGenerationAccepted {
                    let readerIndex = try ensureTransportReader(readerGeneration)
                    if !exactBytes.isEmpty {
                        guard let handle = transportReaderHandles[readerGeneration] else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                        try handle.write(contentsOf: exactBytes)
                        metadata.transportReaders[readerIndex].persistedExactInputBytes +=
                            exactBytes.count
                    }
                    if let read {
                        metadata.transportReaders[readerIndex].persistedReadCount += 1
                        metadata.transportReaders[readerIndex].firstReadSequence = min(
                            metadata.transportReaders[readerIndex].firstReadSequence
                                ?? read.sequence,
                            read.sequence
                        )
                        metadata.transportReaders[readerIndex].lastReadSequence = max(
                            metadata.transportReaders[readerIndex].lastReadSequence
                                ?? read.sequence,
                            read.sequence
                        )
                    }
                }
                if let read {
                    try writeJSONLine(read, to: vlcReadIndexHandle)
                    metadata.persistedTransportReadCount += 1
                }
            } catch {
                record(error)
            }
        }
    }

    func updateSubscriptionMetadata(
        acceptedTimeshiftPeriodSeconds: TimeInterval,
        declaration: HTSPTuningCapturedStreamDeclaration?
    ) {
        queue.async { [self] in
            guard !closed else { return }
            metadata.acceptedTimeshiftPeriodSeconds = acceptedTimeshiftPeriodSeconds
            if let declaration {
                metadata.streamDeclarations.append(declaration)
            }
        }
    }

    func appendStreamDeclaration(_ declaration: HTSPTuningCapturedStreamDeclaration) {
        queue.async { [self] in
            guard !closed else { return }
            metadata.streamDeclarations.append(declaration)
        }
    }

    func markCaptureLimitReached(_ limit: CaptureLimit) {
        queue.async { [self] in
            guard !closed else { return }
            switch limit {
            case .rawHTSP: metadata.rawHTSPCaptureLimitReached = true
            case .muxPacket: metadata.muxPacketCaptureLimitReached = true
            case .streamDeclaration: metadata.streamDeclarationCaptureLimitReached = true
            case .transport: metadata.transportCaptureLimitReached = true
            case .transportReadIndex: metadata.transportReadIndexLimitReached = true
            case .readerGeneration: metadata.readerGenerationLimitReached = true
            }
        }
    }

    /// Foreground promotion is media-critical and therefore only queues this
    /// transition. Close/seal use the synchronous variant below to drain it.
    func updateLifecycle(_ lifecycle: String) {
        queue.async { [self] in
            guard !closed else { return }
            metadata.lifecycle = lifecycle
        }
    }

    func updateLifecycleAndSynchronize(_ lifecycle: String) {
        queue.sync { [self] in
            guard !closed else { return }
            metadata.lifecycle = lifecycle
            synchronizeAndCheckpoint()
        }
    }

    func finishRetaining(lifecycle: String) {
        queue.sync { [self] in
            guard !closed else { return }
            metadata.lifecycle = lifecycle
            metadata.state = "sealed-awaiting-finalization"
            synchronizeAndCheckpoint()
            closeHandles()
        }
    }

    func synchronizeForTesting() {
        queue.sync { [self] in
            guard !closed else { return }
            synchronizeAndCheckpoint()
        }
    }

    func removeSynchronously() {
        queue.sync { [self] in
            if !closed {
                metadata.state = "discarded"
                synchronizeAndCheckpoint()
                closeHandles()
            }
            do {
                if fileManager.fileExists(atPath: directory.path) {
                    try fileManager.removeItem(at: directory)
                }
            } catch {
                // A failed cleanup must retain evidence rather than affect
                // playback or delete a partially collected parent directory.
            }
        }
    }

    private func ensureTransportReader(_ generation: Int) throws -> Int {
        if let index = metadata.transportReaders.firstIndex(where: {
            $0.readerGeneration == generation
        }) {
            return index
        }
        let file = "vlc-reader-\(generation)-input.bytes"
        let handle = try Self.createFileHandle(
            at: directory.appending(path: file),
            fileManager: fileManager
        )
        transportReaderHandles[generation] = handle
        metadata.transportReaders.append(
            .init(
                readerGeneration: generation,
                exactInputByteFile: file,
                byteExact: true,
                mayEndWithPartialTransportPacket: true,
                persistedExactInputBytes: 0,
                persistedReadCount: 0,
                firstReadSequence: nil,
                lastReadSequence: nil
            )
        )
        return metadata.transportReaders.count - 1
    }

    private func synchronizeAndCheckpoint() {
        guard !closed else { return }
        do {
            try rawHTSPHandle.synchronize()
            try rawHTSPIndexHandle.synchronize()
            try muxPacketHandle.synchronize()
            try vlcReadIndexHandle.synchronize()
            for handle in transportReaderHandles.values {
                try handle.synchronize()
            }
            metadata.lastSynchronizedAt = Self.iso8601(Date())
            try persistMetadata()
        } catch {
            record(error)
            try? persistMetadata()
        }
    }

    private func persistMetadata() throws {
        try metadataWriter(metadata, metadataURL)
    }

    private static func writeMetadata(
        _ metadata: HTSPTuningFailureCaptureSpoolMetadata,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }

    private func writeJSONLine<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func record(_ error: Error) {
        if metadata.firstWriteError == nil {
            metadata.firstWriteError = error.localizedDescription
        }
    }

    private func closeHandles() {
        timer?.cancel()
        timer = nil
        try? rawHTSPHandle.close()
        try? rawHTSPIndexHandle.close()
        try? muxPacketHandle.close()
        try? vlcReadIndexHandle.close()
        for handle in transportReaderHandles.values { try? handle.close() }
        transportReaderHandles.removeAll()
        closed = true
    }

    private static func createFileHandle(
        at url: URL,
        fileManager: FileManager
    ) throws -> FileHandle {
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try FileHandle(forWritingTo: url)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Retains only a bounded prefix of one HTSP subscription. A prefix is more
/// useful than a ring for startup failures because it preserves the exact PAT,
/// PMT, keyframe, and audio discovery sequence handed to a fresh VLC pipeline.
final class HTSPTuningFailureCaptureRecorder: @unchecked Sendable {
    private struct TransportChunk: Sendable {
        let sequence: Int
        let readerGeneration: Int
        let data: Data
    }

    private struct TransportReaderTotals: Sendable {
        var totalReadByteCount = 0
        var capturedByteCount = 0
        var readCount = 0
        var firstReadSequence: Int?
        var lastReadSequence: Int?
    }

    let captureID: UUID
    let benchmarkAttempt: Int?
    let channelID: UInt32
    let profile: String
    let startedAt: Date

    private let limits: HTSPTuningFailureCaptureLimits
    private let spool: HTSPTuningFailureCaptureSpool?
    private let lock = NSLock()
    private var packets: [HTSPTuningCapturedMuxPacket] = []
    private var acceptedTimeshiftPeriodSeconds: TimeInterval
    private var streamDeclarations: [HTSPTuningCapturedStreamDeclaration] = []
    private var rawHTSPFrames: [HTSPTuningCapturedRawHTSPFrame] = []
    private var rawHTSPData = Data()
    private var transportReads: [HTSPTuningCapturedTransportRead] = []
    private var transportChunks: [TransportChunk] = []
    private var transportReaderTotals: [Int: TransportReaderTotals] = [:]
    private var capturedTransportBytes = 0
    private var capturedRawPayloadBytes = 0
    private var totalPacketCount = 0
    private var totalRawPayloadBytes = 0
    private var omittedPacketCount = 0
    private var omittedRawPayloadBytes = 0
    private var totalTransportBytes = 0
    private var totalStreamDeclarationCount = 0
    private var omittedStreamDeclarationCount = 0
    private var capturedStreamDeclarationMetadataBytes = 0
    private var totalStreamDeclarationMetadataBytes = 0
    private var omittedStreamDeclarationMetadataBytes = 0
    private var totalRawHTSPFrameCount = 0
    private var totalRawHTSPFrameBytes = 0
    private var omittedRawHTSPFrameCount = 0
    private var omittedRawHTSPFrameBytes = 0
    private var captureLimitOmittedTransportBytes = 0
    private var totalTransportReadCount = 0
    private var omittedTransportReadCount = 0
    private var totalReaderGenerationCount = 0
    private var omittedReaderGenerationCount = 0
    private var lastRejectedReaderGeneration: Int?
    private var rawCaptureStopped = false
    private var rawHTSPCaptureStopped = false
    private var reportedMuxCaptureLimit = false
    private var reportedRawHTSPCaptureLimit = false
    private var reportedStreamDeclarationCaptureLimit = false
    private var reportedTransportCaptureLimit = false
    private var reportedTransportReadIndexLimit = false
    private var reportedReaderGenerationLimit = false
    private var currentStreamDeclarationSequence: Int
    private var lifecycle: Lifecycle
    private var sealed = false
    private var sealedSnapshot: HTSPTuningFailureCaptureSnapshot?

    private enum Lifecycle: String {
        case candidate
        case foreground
        case closedCandidate = "closed-candidate"
        case closedForeground = "closed-foreground"

        var isActiveCandidate: Bool { self == .candidate }
    }

    init(
        channelID: UInt32,
        profile: String,
        acceptedTimeshiftPeriodSeconds: TimeInterval,
        streams: [HTSPStreamInfo],
        startsAsCandidate: Bool,
        limits: HTSPTuningFailureCaptureLimits = .benchmarkDefault,
        startedAt: Date = Date(),
        captureID: UUID = UUID(),
        benchmarkAttempt: Int? = nil,
        spool: HTSPTuningFailureCaptureSpool? = nil
    ) {
        self.captureID = captureID
        self.benchmarkAttempt = benchmarkAttempt
        self.channelID = channelID
        self.profile = profile
        self.acceptedTimeshiftPeriodSeconds = acceptedTimeshiftPeriodSeconds
        self.limits = limits
        self.spool = spool
        self.startedAt = startedAt
        lifecycle = startsAsCandidate ? .candidate : .foreground
        let initialMetadataBytes = Self.metadataByteCount(in: streams)
        currentStreamDeclarationSequence = streams.isEmpty ? -1 : 0
        totalStreamDeclarationCount = streams.isEmpty ? 0 : 1
        totalStreamDeclarationMetadataBytes = initialMetadataBytes
        if !streams.isEmpty,
           limits.maximumStreamDeclarationCount > 0,
           initialMetadataBytes <= limits.maximumStreamDeclarationMetadataBytes {
            streamDeclarations.append(
                HTSPTuningCapturedStreamDeclaration(
                    sequence: 0,
                    connectionGeneration: 0,
                    elapsedMilliseconds: 0,
                    streams: streams.map(HTSPTuningCapturedStreamInfo.init)
                )
            )
            capturedStreamDeclarationMetadataBytes = initialMetadataBytes
        } else if !streams.isEmpty {
            omittedStreamDeclarationCount = 1
            omittedStreamDeclarationMetadataBytes = initialMetadataBytes
            rawCaptureStopped = true
        }
        packets.reserveCapacity(min(limits.maximumPacketCount, 2_048))
        rawHTSPFrames.reserveCapacity(min(limits.maximumRawHTSPFrameCount, 1_024))
        rawHTSPData.reserveCapacity(min(limits.maximumRawHTSPFrameBytes, 1 * 1_024 * 1_024))
        transportReads.reserveCapacity(min(limits.maximumTransportReadCount, 2_048))
        transportChunks.reserveCapacity(min(limits.maximumTransportChunkCount, 512))
        spool?.updateSubscriptionMetadata(
            acceptedTimeshiftPeriodSeconds: acceptedTimeshiftPeriodSeconds,
            declaration: streamDeclarations.first
        )
        if omittedStreamDeclarationCount > 0 {
            reportedStreamDeclarationCaptureLimit = true
            spool?.markCaptureLimitReached(.streamDeclaration)
        }
    }

    func record(
        _ packet: HTSPMuxPacket,
        isVideo: Bool,
        isAudio: Bool,
        receivedAt: Date = Date()
    ) {
        lock.withLock {
            guard !sealed else { return }
            totalPacketCount = totalPacketCount.saturatingAdd(1)
            totalRawPayloadBytes = totalRawPayloadBytes.saturatingAdd(packet.payload.count)

            let nextPayloadBytes = capturedRawPayloadBytes.addingReportingOverflow(
                packet.payload.count
            )
            guard !rawCaptureStopped,
                  packets.count < limits.maximumPacketCount,
                  !nextPayloadBytes.overflow,
                  nextPayloadBytes.partialValue <= limits.maximumRawPayloadBytes
            else {
                rawCaptureStopped = true
                if !reportedMuxCaptureLimit {
                    reportedMuxCaptureLimit = true
                    spool?.markCaptureLimitReached(.muxPacket)
                }
                omittedPacketCount = omittedPacketCount.saturatingAdd(1)
                omittedRawPayloadBytes = omittedRawPayloadBytes.saturatingAdd(
                    packet.payload.count
                )
                return
            }

            let captured = HTSPTuningCapturedMuxPacket(
                sequence: totalPacketCount - 1,
                streamDeclarationSequence: currentStreamDeclarationSequence,
                elapsedMilliseconds: elapsedMilliseconds(at: receivedAt),
                streamIndex: packet.streamIndex,
                frameType: packet.frameType,
                presentationTime: packet.presentationTime,
                decodeTime: packet.decodeTime,
                durationMicroseconds: packet.durationMicroseconds,
                trackKind: isVideo ? "video" : (isAudio ? "audio" : "other"),
                payload: packet.payload
            )
            packets.append(captured)
            capturedRawPayloadBytes = nextPayloadBytes.partialValue
            spool?.appendMuxPacket(captured)
        }
    }

    /// Records the exact HTSP wire frame, including its four-byte length
    /// prefix. No parsing or normalization is performed, so malformed frames
    /// remain suitable for independent protocol inspection.
    func recordRawHTSPMessage(
        _ exactFrame: Data,
        receivedAt: Date = Date()
    ) {
        lock.withLock {
            guard !sealed else { return }
            totalRawHTSPFrameCount = totalRawHTSPFrameCount.saturatingAdd(1)
            totalRawHTSPFrameBytes = totalRawHTSPFrameBytes.saturatingAdd(
                exactFrame.count
            )
            let nextByteCount = rawHTSPData.count.addingReportingOverflow(
                exactFrame.count
            )
            guard !rawHTSPCaptureStopped,
                  rawHTSPFrames.count < limits.maximumRawHTSPFrameCount,
                  !nextByteCount.overflow,
                  nextByteCount.partialValue <= limits.maximumRawHTSPFrameBytes
            else {
                rawHTSPCaptureStopped = true
                if !reportedRawHTSPCaptureLimit {
                    reportedRawHTSPCaptureLimit = true
                    spool?.markCaptureLimitReached(.rawHTSP)
                }
                omittedRawHTSPFrameCount = omittedRawHTSPFrameCount.saturatingAdd(1)
                omittedRawHTSPFrameBytes = omittedRawHTSPFrameBytes.saturatingAdd(
                    exactFrame.count
                )
                return
            }
            let captured = HTSPTuningCapturedRawHTSPFrame(
                sequence: totalRawHTSPFrameCount - 1,
                byteOffset: rawHTSPData.count,
                byteCount: exactFrame.count,
                elapsedMilliseconds: elapsedMilliseconds(at: receivedAt)
            )
            rawHTSPFrames.append(captured)
            rawHTSPData.append(exactFrame)
            spool?.appendRawHTSPFrame(exactFrame, index: captured)
        }
    }

    func recordStreamDeclaration(
        _ streams: [HTSPStreamInfo],
        connectionGeneration: Int,
        receivedAt: Date = Date()
    ) {
        lock.withLock {
            guard !sealed else { return }
            let declaration = recordStreamDeclarationLocked(
                streams,
                connectionGeneration: connectionGeneration,
                receivedAt: receivedAt
            )
            if let declaration { spool?.appendStreamDeclaration(declaration) }
        }
    }

    /// Fills metadata that is unavailable until `subscribe` has accepted the
    /// session. This allows the recorder and raw-wire observer to be installed
    /// before the subscription handshake starts.
    func updateSubscriptionMetadata(
        acceptedTimeshiftPeriodSeconds: TimeInterval,
        streams: [HTSPStreamInfo],
        connectionGeneration: Int = 0,
        receivedAt: Date = Date()
    ) {
        lock.withLock {
            guard !sealed else { return }
            self.acceptedTimeshiftPeriodSeconds = max(
                0,
                acceptedTimeshiftPeriodSeconds
            )
            let declaration = recordStreamDeclarationLocked(
                streams,
                connectionGeneration: connectionGeneration,
                receivedAt: receivedAt
            )
            spool?.updateSubscriptionMetadata(
                acceptedTimeshiftPeriodSeconds: self.acceptedTimeshiftPeriodSeconds,
                declaration: declaration
            )
        }
    }

    func markForeground() {
        lock.withLock {
            guard !sealed else { return }
            lifecycle = .foreground
            // Promotion happens while the input stream holds its process and
            // condition locks. Queue the diagnostic transition so filesystem
            // latency can never extend the media-critical promotion path.
            spool?.updateLifecycle(lifecycle.rawValue)
        }
    }

    func markClosed() {
        lock.withLock {
            guard !sealed else { return }
            lifecycle = lifecycle == .candidate ? .closedCandidate : .closedForeground
            spool?.updateLifecycleAndSynchronize(lifecycle.rawValue)
        }
    }

    var isActiveCandidate: Bool {
        lock.withLock { !sealed && lifecycle.isActiveCandidate }
    }

    var isSealed: Bool {
        lock.withLock { sealed }
    }

    /// Records a VLC read callback synchronously in the total order assigned by
    /// `HTSPLiveInputStream`'s source condition.
    func recordTransportRead(
        _ bytes: UnsafeRawBufferPointer,
        sequence: Int,
        readerGeneration: Int,
        requestedByteCount: Int,
        returnedByteCount: Int,
        waitDurationMicroseconds: Int,
        completedAt: Date = Date()
    ) {
        lock.withLock {
            guard !sealed else { return }

            totalTransportReadCount = totalTransportReadCount.saturatingAdd(1)
            let deliveredByteCount = max(0, returnedByteCount)
            totalTransportBytes = totalTransportBytes.saturatingAdd(deliveredByteCount)

            var readerTotals = transportReaderTotals[readerGeneration]
            let readerGenerationAccepted: Bool
            if readerTotals != nil {
                readerGenerationAccepted = true
            } else if transportReaderTotals.count < limits.maximumReaderGenerationCount {
                totalReaderGenerationCount = totalReaderGenerationCount.saturatingAdd(1)
                readerTotals = TransportReaderTotals()
                readerGenerationAccepted = true
            } else {
                if lastRejectedReaderGeneration != readerGeneration {
                    totalReaderGenerationCount = totalReaderGenerationCount.saturatingAdd(1)
                    omittedReaderGenerationCount = omittedReaderGenerationCount.saturatingAdd(1)
                    lastRejectedReaderGeneration = readerGeneration
                }
                readerGenerationAccepted = false
                if !reportedReaderGenerationLimit {
                    reportedReaderGenerationLimit = true
                    spool?.markCaptureLimitReached(.readerGeneration)
                }
            }

            if var totals = readerTotals {
                totals.totalReadByteCount = totals.totalReadByteCount.saturatingAdd(
                    deliveredByteCount
                )
                totals.readCount = totals.readCount.saturatingAdd(1)
                totals.firstReadSequence = min(totals.firstReadSequence ?? sequence, sequence)
                totals.lastReadSequence = max(totals.lastReadSequence ?? sequence, sequence)
                readerTotals = totals
            }

            let futureReaderCount = max(
                0,
                limits.maximumReaderGenerationCount - transportReaderTotals.count
                    - (transportReaderTotals[readerGeneration] == nil
                        && readerGenerationAccepted ? 1 : 0)
            )
            let reservedBytesPerFutureReader = limits.maximumReaderGenerationCount > 0
                ? min(
                    limits.reservedTransportBytesPerReaderGeneration,
                    limits.maximumTransportBytes / limits.maximumReaderGenerationCount
                )
                : 0
            let futureReservedByteCount = min(
                limits.maximumTransportBytes,
                futureReaderCount.saturatingMultiply(reservedBytesPerFutureReader)
            )
            let availableByteCount = max(
                0,
                limits.maximumTransportBytes - capturedTransportBytes
                    - futureReservedByteCount
            )
            let reservedChunksPerFutureReader = limits.maximumReaderGenerationCount > 0
                ? min(
                    limits.reservedTransportChunksPerReaderGeneration,
                    limits.maximumTransportChunkCount / limits.maximumReaderGenerationCount
                )
                : 0
            let futureReservedChunkCount = min(
                limits.maximumTransportChunkCount,
                futureReaderCount.saturatingMultiply(reservedChunksPerFutureReader)
            )
            let availableChunkCount = max(
                0,
                limits.maximumTransportChunkCount - transportChunks.count
                    - futureReservedChunkCount
            )
            let retainedByteCount = readerGenerationAccepted && availableChunkCount > 0
                ? min(availableByteCount, min(deliveredByteCount, bytes.count))
                : 0
            var retainedData = Data()
            if retainedByteCount > 0, let baseAddress = bytes.baseAddress {
                // Deliberately construct Data only after both byte and chunk
                // bounds have admitted this read. Once the byte prefix is
                // full, future callbacks retain metadata without copying the
                // VLC output buffer.
                retainedData = Data(bytes: baseAddress, count: retainedByteCount)
                transportChunks.append(
                    TransportChunk(
                        sequence: sequence,
                        readerGeneration: readerGeneration,
                        data: retainedData
                    )
                )
                capturedTransportBytes = capturedTransportBytes.saturatingAdd(
                    retainedByteCount
                )
                if var totals = readerTotals {
                    totals.capturedByteCount = totals.capturedByteCount.saturatingAdd(
                        retainedByteCount
                    )
                    readerTotals = totals
                }
            }
            if let readerTotals {
                transportReaderTotals[readerGeneration] = readerTotals
            }

            captureLimitOmittedTransportBytes =
                captureLimitOmittedTransportBytes.saturatingAdd(
                deliveredByteCount - retainedByteCount
            )
            if deliveredByteCount > retainedByteCount, !reportedTransportCaptureLimit {
                reportedTransportCaptureLimit = true
                spool?.markCaptureLimitReached(.transport)
            }
            let capturedRead: HTSPTuningCapturedTransportRead?
            if transportReads.count < limits.maximumTransportReadCount {
                let read = HTSPTuningCapturedTransportRead(
                    sequence: sequence,
                    readerGeneration: readerGeneration,
                    requestedByteCount: max(0, requestedByteCount),
                    returnedByteCount: returnedByteCount,
                    capturedByteCount: retainedByteCount,
                    elapsedMilliseconds: elapsedMilliseconds(at: completedAt),
                    waitDurationMicroseconds: max(0, waitDurationMicroseconds),
                    readerGenerationAccepted: readerGenerationAccepted
                )
                transportReads.append(read)
                capturedRead = read
            } else {
                omittedTransportReadCount = omittedTransportReadCount.saturatingAdd(1)
                capturedRead = nil
                if !reportedTransportReadIndexLimit {
                    reportedTransportReadIndexLimit = true
                    spool?.markCaptureLimitReached(.transportReadIndex)
                }
            }
            spool?.appendTransportRead(
                capturedRead,
                exactBytes: retainedData,
                readerGeneration: readerGeneration,
                readerGenerationAccepted: readerGenerationAccepted
            )
        }
    }

    /// Convenience for tests and callers that already own immutable data. It
    /// does not create an additional copy before applying the recorder bounds.
    func recordTransportRead(
        _ data: Data,
        sequence: Int,
        readerGeneration: Int,
        requestedByteCount: Int? = nil,
        returnedByteCount: Int? = nil,
        waitDurationMicroseconds: Int = 0,
        completedAt: Date = Date()
    ) {
        data.withUnsafeBytes {
            recordTransportRead(
                $0,
                sequence: sequence,
                readerGeneration: readerGeneration,
                requestedByteCount: requestedByteCount ?? data.count,
                returnedByteCount: returnedByteCount ?? data.count,
                waitDurationMicroseconds: waitDurationMicroseconds,
                completedAt: completedAt
            )
        }
    }

    func sealAndSnapshot() -> HTSPTuningFailureCaptureSnapshot {
        lock.withLock {
            if let sealedSnapshot { return sealedSnapshot }
            sealed = true
            let orderedReads = transportReads.sorted {
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                return $0.readerGeneration < $1.readerGeneration
            }
            let orderedChunks = transportChunks.sorted {
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                return $0.readerGeneration < $1.readerGeneration
            }
            let orderedReaderGenerations = transportReaderTotals.keys.sorted {
                let lhsSequence = transportReaderTotals[$0]?.firstReadSequence ?? Int.max
                let rhsSequence = transportReaderTotals[$1]?.firstReadSequence ?? Int.max
                if lhsSequence != rhsSequence { return lhsSequence < rhsSequence }
                return $0 < $1
            }
            let transportReaders: [HTSPTuningCapturedTransportReader] =
                orderedReaderGenerations.compactMap { generation in
                    guard let totals = transportReaderTotals[generation] else {
                        return nil
                    }
                    var capturedData = Data()
                    for chunk in orderedChunks where chunk.readerGeneration == generation {
                        capturedData.append(chunk.data)
                    }
                    return HTSPTuningCapturedTransportReader(
                        readerGeneration: generation,
                        exactData: capturedData,
                        totalReadByteCount: totals.totalReadByteCount,
                        captureLimitOmittedByteCount: max(
                            0,
                            totals.totalReadByteCount - capturedData.count
                        ),
                        readCount: totals.readCount,
                        firstReadSequence: totals.firstReadSequence,
                        lastReadSequence: totals.lastReadSequence
                    )
                }
            let retainedTransportByteCount = transportReaders.reduce(into: 0) {
                $0 = $0.saturatingAdd($1.exactData.count)
            }
            let snapshot = HTSPTuningFailureCaptureSnapshot(
                captureID: captureID,
                channelID: channelID,
                profile: profile,
                acceptedTimeshiftPeriodSeconds: acceptedTimeshiftPeriodSeconds,
                startedAt: startedAt,
                lifecycle: lifecycle.rawValue,
                streamDeclarations: streamDeclarations,
                rawHTSPFrames: rawHTSPFrames,
                rawHTSPData: rawHTSPData,
                transportReads: orderedReads,
                transportReaders: transportReaders,
                packets: packets,
                totalPacketCount: totalPacketCount,
                totalRawPayloadBytes: totalRawPayloadBytes,
                omittedPacketCount: omittedPacketCount,
                omittedRawPayloadBytes: omittedRawPayloadBytes,
                totalStreamDeclarationCount: totalStreamDeclarationCount,
                omittedStreamDeclarationCount: omittedStreamDeclarationCount,
                totalStreamDeclarationMetadataBytes: totalStreamDeclarationMetadataBytes,
                omittedStreamDeclarationMetadataBytes: omittedStreamDeclarationMetadataBytes,
                totalRawHTSPFrameCount: totalRawHTSPFrameCount,
                totalRawHTSPFrameBytes: totalRawHTSPFrameBytes,
                omittedRawHTSPFrameCount: omittedRawHTSPFrameCount,
                omittedRawHTSPFrameBytes: omittedRawHTSPFrameBytes,
                totalTransportBytes: totalTransportBytes,
                captureLimitOmittedTransportBytes: max(
                    captureLimitOmittedTransportBytes,
                    totalTransportBytes - retainedTransportByteCount
                ),
                totalTransportReadCount: totalTransportReadCount,
                omittedTransportReadCount: omittedTransportReadCount,
                totalReaderGenerationCount: totalReaderGenerationCount,
                omittedReaderGenerationCount: omittedReaderGenerationCount
            )
            sealedSnapshot = snapshot
            spool?.finishRetaining(lifecycle: lifecycle.rawValue)
            packets.removeAll(keepingCapacity: false)
            streamDeclarations.removeAll(keepingCapacity: false)
            rawHTSPFrames.removeAll(keepingCapacity: false)
            rawHTSPData.removeAll(keepingCapacity: false)
            transportReads.removeAll(keepingCapacity: false)
            transportChunks.removeAll(keepingCapacity: false)
            transportReaderTotals.removeAll(keepingCapacity: false)
            return snapshot
        }
    }

    func discard() {
        lock.withLock {
            sealed = true
            spool?.removeSynchronously()
            sealedSnapshot = nil
            packets.removeAll(keepingCapacity: false)
            streamDeclarations.removeAll(keepingCapacity: false)
            rawHTSPFrames.removeAll(keepingCapacity: false)
            rawHTSPData.removeAll(keepingCapacity: false)
            transportReads.removeAll(keepingCapacity: false)
            transportChunks.removeAll(keepingCapacity: false)
            transportReaderTotals.removeAll(keepingCapacity: false)
            capturedTransportBytes = 0
            capturedRawPayloadBytes = 0
            totalPacketCount = 0
            totalRawPayloadBytes = 0
            omittedPacketCount = 0
            omittedRawPayloadBytes = 0
            totalStreamDeclarationCount = 0
            omittedStreamDeclarationCount = 0
            capturedStreamDeclarationMetadataBytes = 0
            totalStreamDeclarationMetadataBytes = 0
            omittedStreamDeclarationMetadataBytes = 0
            totalRawHTSPFrameCount = 0
            totalRawHTSPFrameBytes = 0
            omittedRawHTSPFrameCount = 0
            omittedRawHTSPFrameBytes = 0
            captureLimitOmittedTransportBytes = 0
            totalTransportBytes = 0
            totalTransportReadCount = 0
            omittedTransportReadCount = 0
            totalReaderGenerationCount = 0
            omittedReaderGenerationCount = 0
        }
    }

    var spoolDirectory: URL? { spool?.directory }

    func synchronizeSpoolForTesting() {
        spool?.synchronizeForTesting()
    }

    func removeSpoolAfterSuccessfulPersistence() {
        spool?.removeSynchronously()
    }

    private func elapsedMilliseconds(at date: Date) -> Int {
        let milliseconds = max(0, date.timeIntervalSince(startedAt) * 1_000)
        guard milliseconds < Double(Int.max) else { return Int.max }
        return Int(milliseconds.rounded())
    }

    private func recordStreamDeclarationLocked(
        _ streams: [HTSPStreamInfo],
        connectionGeneration: Int,
        receivedAt: Date
    ) -> HTSPTuningCapturedStreamDeclaration? {
        currentStreamDeclarationSequence = currentStreamDeclarationSequence.saturatingAdd(1)
        totalStreamDeclarationCount = totalStreamDeclarationCount.saturatingAdd(1)
        let metadataByteCount = Self.metadataByteCount(in: streams)
        totalStreamDeclarationMetadataBytes =
            totalStreamDeclarationMetadataBytes.saturatingAdd(metadataByteCount)
        let nextMetadataByteCount = capturedStreamDeclarationMetadataBytes
            .addingReportingOverflow(metadataByteCount)
        guard streamDeclarations.count < limits.maximumStreamDeclarationCount,
              !nextMetadataByteCount.overflow,
              nextMetadataByteCount.partialValue
                <= limits.maximumStreamDeclarationMetadataBytes
        else {
            omittedStreamDeclarationCount = omittedStreamDeclarationCount.saturatingAdd(1)
            omittedStreamDeclarationMetadataBytes =
                omittedStreamDeclarationMetadataBytes.saturatingAdd(metadataByteCount)
            if !reportedStreamDeclarationCaptureLimit {
                reportedStreamDeclarationCaptureLimit = true
                spool?.markCaptureLimitReached(.streamDeclaration)
            }
            // Packet records after a missing declaration could not be
            // interpreted losslessly, so keep the decoded ES capture a
            // strict, self-describing prefix as well.
            rawCaptureStopped = true
            return nil
        }
        let declaration = HTSPTuningCapturedStreamDeclaration(
            sequence: currentStreamDeclarationSequence,
            connectionGeneration: connectionGeneration,
            elapsedMilliseconds: elapsedMilliseconds(at: receivedAt),
            streams: streams.map(HTSPTuningCapturedStreamInfo.init)
        )
        streamDeclarations.append(declaration)
        capturedStreamDeclarationMetadataBytes = nextMetadataByteCount.partialValue
        return declaration
    }

    private static func metadataByteCount(in streams: [HTSPStreamInfo]) -> Int {
        streams.reduce(into: 0) { total, stream in
            total = total.saturatingAdd(stream.metadata?.count ?? 0)
        }
    }
}

struct HTSPTuningFailureCaptureManifest: Codable, Equatable, Sendable {
    struct TransportReader: Codable, Equatable, Sendable {
        let readerGeneration: Int
        let exactInputByteFile: String
        let syncAlignedTransportStreamFile: String?
        let retainedExactInputBytes: Int
        let originalReadBytes: Int
        let captureLimitOmittedBytes: Int
        let transportCaptureTruncated: Bool
        let syncAlignedTransportBytes: Int
        let syncAlignmentDiscardedPrefixBytes: Int?
        let syncAlignmentDiscardedSuffixBytes: Int?
        let readCount: Int
        let firstReadSequence: Int?
        let lastReadSequence: Int?
    }

    struct Stream: Codable, Equatable, Sendable {
        let captureID: String
        let channelID: UInt32
        let subscriptionID: Int
        let profile: String
        let acceptedTimeshiftPeriodSeconds: TimeInterval
        let lifecycle: String
        let startedAt: String
        let streamDeclarations: [HTSPTuningCapturedStreamDeclaration]
        let rawHTSPFrameFile: String
        let rawHTSPFrameIndexFile: String
        let muxPacketFile: String
        let vlcTransportReadFile: String
        /// Byte-exact convenience for the common single-reader case.
        let vlcInputByteFile: String?
        /// Optional derived TS convenience for the common single-reader case.
        let vlcTransportStreamFile: String?
        let transportReaders: [TransportReader]
        let retainedPacketCount: Int
        let originalPacketCount: Int
        let retainedRawPayloadBytes: Int
        let originalRawPayloadBytes: Int
        let omittedPacketCount: Int
        let omittedRawPayloadBytes: Int
        let rawCaptureTruncated: Bool
        let retainedStreamDeclarationCount: Int
        let originalStreamDeclarationCount: Int
        let omittedStreamDeclarationCount: Int
        let retainedStreamDeclarationMetadataBytes: Int
        let originalStreamDeclarationMetadataBytes: Int
        let omittedStreamDeclarationMetadataBytes: Int
        let retainedRawHTSPFrameCount: Int
        let originalRawHTSPFrameCount: Int
        let retainedRawHTSPFrameBytes: Int
        let originalRawHTSPFrameBytes: Int
        let omittedRawHTSPFrameCount: Int
        let omittedRawHTSPFrameBytes: Int
        let rawHTSPCaptureTruncated: Bool
        let retainedExactInputBytes: Int
        let originalReadBytes: Int
        let captureLimitOmittedBytes: Int
        let transportCaptureTruncated: Bool
        let retainedTransportReadCount: Int
        let originalTransportReadCount: Int
        let omittedTransportReadCount: Int
        let retainedReaderGenerationCount: Int
        let originalReaderGenerationCount: Int
        let omittedReaderGenerationCount: Int
    }

    let formatVersion: Int
    let createdAt: String
    let attempt: Int
    let channelID: UInt32
    let channelName: String
    let suspiciousReasons: [String]
    let diagnosticSummary: String
    let benchmarkSampleFile: String
    let streams: [Stream]
}

enum HTSPTuningFailureCaptureWriter {
    private struct SyncAlignedTransportStream {
        let data: Data
        let discardedPrefixByteCount: Int
        let discardedSuffixByteCount: Int
    }

    private static let minimumTransportSyncRunPacketCount = 5

    static func persist(
        snapshots: [HTSPTuningFailureCaptureSnapshot],
        attempt: Int,
        channelID: UInt32,
        channelName: String,
        suspiciousReasons: [String],
        diagnosticSummary: String,
        benchmarkSample: Data,
        destinationRoot: URL,
        now: Date = Date()
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )
        let directoryName = String(
            format: "attempt-%03d-channel-%u-%@-%@",
            max(0, attempt),
            channelID,
            sanitizedPathComponent(channelName),
            UUID().uuidString.lowercased()
        )
        let captureDirectory = destinationRoot.appending(
            path: directoryName,
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: captureDirectory,
            withIntermediateDirectories: false
        )

        let benchmarkSampleFile = "benchmark-sample.json"
        try benchmarkSample.write(
            to: captureDirectory.appending(path: benchmarkSampleFile),
            options: .atomic
        )

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var streamManifests: [HTSPTuningFailureCaptureManifest.Stream] = []
        streamManifests.reserveCapacity(snapshots.count)
        for (index, snapshot) in snapshots.enumerated() {
            let stem = String(format: "stream-%03d", index + 1)
            let rawHTSPFrameFile = "\(stem)-htsp-wire.htsp"
            let rawHTSPFrameIndexFile = "\(stem)-htsp-wire-index.jsonl"
            let packetFile = "\(stem)-htsp-mux-packets.jsonl"
            let transportReadFile = "\(stem)-vlc-reads.jsonl"
            try snapshot.rawHTSPData.write(
                to: captureDirectory.appending(path: rawHTSPFrameFile),
                options: .atomic
            )
            try writeRawHTSPFrameRecords(
                snapshot.rawHTSPFrames,
                to: captureDirectory.appending(path: rawHTSPFrameIndexFile)
            )
            try writePacketRecords(
                snapshot.packets,
                to: captureDirectory.appending(path: packetFile)
            )
            try writeTransportReadRecords(
                snapshot.transportReads,
                to: captureDirectory.appending(path: transportReadFile)
            )
            let hasOneReader = snapshot.transportReaders.count == 1
            let transportReaderManifests = try snapshot.transportReaders.map { reader in
                let exactInputFile = hasOneReader
                    ? "\(stem)-vlc-input.bin"
                    : String(
                        format: "%@-vlc-reader-%03d-input.bin",
                        stem,
                        max(0, reader.readerGeneration)
                    )
                try reader.exactData.write(
                    to: captureDirectory.appending(path: exactInputFile),
                    options: .atomic
                )
                let aligned = syncAlignedTransportStream(from: reader.exactData)
                let alignedFile = aligned.map { _ in
                    hasOneReader
                        ? "\(stem)-vlc-input-aligned.ts"
                        : String(
                            format: "%@-vlc-reader-%03d-input-aligned.ts",
                            stem,
                            max(0, reader.readerGeneration)
                        )
                }
                if let aligned, let alignedFile {
                    try aligned.data.write(
                        to: captureDirectory.appending(path: alignedFile),
                        options: .atomic
                    )
                }
                return HTSPTuningFailureCaptureManifest.TransportReader(
                    readerGeneration: reader.readerGeneration,
                    exactInputByteFile: exactInputFile,
                    syncAlignedTransportStreamFile: alignedFile,
                    retainedExactInputBytes: reader.exactData.count,
                    originalReadBytes: reader.totalReadByteCount,
                    captureLimitOmittedBytes: reader.captureLimitOmittedByteCount,
                    transportCaptureTruncated: reader.captureLimitOmittedByteCount > 0,
                    syncAlignedTransportBytes: aligned?.data.count ?? 0,
                    syncAlignmentDiscardedPrefixBytes: aligned?.discardedPrefixByteCount,
                    syncAlignmentDiscardedSuffixBytes: aligned?.discardedSuffixByteCount,
                    readCount: reader.readCount,
                    firstReadSequence: reader.firstReadSequence,
                    lastReadSequence: reader.lastReadSequence
                )
            }
            let retainedExactInputBytes = snapshot.transportReaders.reduce(into: 0) {
                $0 = $0.saturatingAdd($1.exactData.count)
            }
            let capturedRawPayloadBytes = snapshot.packets.reduce(into: 0) {
                $0 = $0.saturatingAdd($1.payload.count)
            }
            streamManifests.append(
                HTSPTuningFailureCaptureManifest.Stream(
                    captureID: snapshot.captureID.uuidString.lowercased(),
                    channelID: snapshot.channelID,
                    subscriptionID: 1,
                    profile: snapshot.profile,
                    acceptedTimeshiftPeriodSeconds: snapshot.acceptedTimeshiftPeriodSeconds,
                    lifecycle: snapshot.lifecycle,
                    startedAt: dateFormatter.string(from: snapshot.startedAt),
                    streamDeclarations: snapshot.streamDeclarations,
                    rawHTSPFrameFile: rawHTSPFrameFile,
                    rawHTSPFrameIndexFile: rawHTSPFrameIndexFile,
                    muxPacketFile: packetFile,
                    vlcTransportReadFile: transportReadFile,
                    vlcInputByteFile: hasOneReader
                        ? transportReaderManifests.first?.exactInputByteFile
                        : nil,
                    vlcTransportStreamFile: hasOneReader
                        ? transportReaderManifests.first?.syncAlignedTransportStreamFile
                        : nil,
                    transportReaders: transportReaderManifests,
                    retainedPacketCount: snapshot.packets.count,
                    originalPacketCount: snapshot.totalPacketCount,
                    retainedRawPayloadBytes: capturedRawPayloadBytes,
                    originalRawPayloadBytes: snapshot.totalRawPayloadBytes,
                    omittedPacketCount: snapshot.omittedPacketCount,
                    omittedRawPayloadBytes: snapshot.omittedRawPayloadBytes,
                    rawCaptureTruncated: snapshot.omittedPacketCount > 0,
                    retainedStreamDeclarationCount: snapshot.streamDeclarations.count,
                    originalStreamDeclarationCount: snapshot.totalStreamDeclarationCount,
                    omittedStreamDeclarationCount: snapshot.omittedStreamDeclarationCount,
                    retainedStreamDeclarationMetadataBytes:
                        snapshot.totalStreamDeclarationMetadataBytes
                            - snapshot.omittedStreamDeclarationMetadataBytes,
                    originalStreamDeclarationMetadataBytes:
                        snapshot.totalStreamDeclarationMetadataBytes,
                    omittedStreamDeclarationMetadataBytes:
                        snapshot.omittedStreamDeclarationMetadataBytes,
                    retainedRawHTSPFrameCount: snapshot.rawHTSPFrames.count,
                    originalRawHTSPFrameCount: snapshot.totalRawHTSPFrameCount,
                    retainedRawHTSPFrameBytes: snapshot.rawHTSPData.count,
                    originalRawHTSPFrameBytes: snapshot.totalRawHTSPFrameBytes,
                    omittedRawHTSPFrameCount: snapshot.omittedRawHTSPFrameCount,
                    omittedRawHTSPFrameBytes: snapshot.omittedRawHTSPFrameBytes,
                    rawHTSPCaptureTruncated: snapshot.omittedRawHTSPFrameCount > 0,
                    retainedExactInputBytes: retainedExactInputBytes,
                    originalReadBytes: snapshot.totalTransportBytes,
                    captureLimitOmittedBytes: snapshot.captureLimitOmittedTransportBytes,
                    transportCaptureTruncated:
                        snapshot.captureLimitOmittedTransportBytes > 0,
                    retainedTransportReadCount: snapshot.transportReads.count,
                    originalTransportReadCount: snapshot.totalTransportReadCount,
                    omittedTransportReadCount: snapshot.omittedTransportReadCount,
                    retainedReaderGenerationCount: snapshot.transportReaders.count,
                    originalReaderGenerationCount: snapshot.totalReaderGenerationCount,
                    omittedReaderGenerationCount: snapshot.omittedReaderGenerationCount
                )
            )
        }

        let manifest = HTSPTuningFailureCaptureManifest(
            formatVersion: 3,
            createdAt: dateFormatter.string(from: now),
            attempt: attempt,
            channelID: channelID,
            channelName: channelName,
            suspiciousReasons: suspiciousReasons,
            diagnosticSummary: diagnosticSummary,
            benchmarkSampleFile: benchmarkSampleFile,
            streams: streamManifests
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: captureDirectory.appending(path: "manifest.json"),
            options: .atomic
        )
        return captureDirectory
    }

    private static func writePacketRecords(
        _ packets: [HTSPTuningCapturedMuxPacket],
        to url: URL
    ) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for packet in packets {
            try handle.write(contentsOf: encoder.encode(packet))
            try handle.write(contentsOf: Data([0x0A]))
        }
    }

    private static func writeRawHTSPFrameRecords(
        _ frames: [HTSPTuningCapturedRawHTSPFrame],
        to url: URL
    ) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for frame in frames {
            try handle.write(contentsOf: encoder.encode(frame))
            try handle.write(contentsOf: Data([0x0A]))
        }
    }

    private static func writeTransportReadRecords(
        _ reads: [HTSPTuningCapturedTransportRead],
        to url: URL
    ) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for read in reads {
            try handle.write(contentsOf: encoder.encode(read))
            try handle.write(contentsOf: Data([0x0A]))
        }
    }

    /// Derives a convenience TS file without changing the byte-exact capture.
    /// Five consecutive plausible 188-byte headers make accidental payload
    /// matches vanishingly unlikely. Only the longest uninterrupted run is
    /// emitted; discarded prefix/suffix accounting remains derivation-only.
    private static func syncAlignedTransportStream(
        from exactData: Data
    ) -> SyncAlignedTransportStream? {
        let packetSize = 188
        guard exactData.count >= packetSize * minimumTransportSyncRunPacketCount else {
            return nil
        }

        var bestStart: Int?
        var bestPacketCount = 0
        for residue in 0..<min(packetSize, exactData.count) {
            var runStart: Int?
            var runPacketCount = 0
            var position = residue
            while position + packetSize <= exactData.count {
                if looksLikeTransportPacket(exactData, at: position) {
                    runStart = runStart ?? position
                    runPacketCount += 1
                } else {
                    considerTransportRun(
                        start: runStart,
                        packetCount: runPacketCount,
                        bestStart: &bestStart,
                        bestPacketCount: &bestPacketCount
                    )
                    runStart = nil
                    runPacketCount = 0
                }
                position += packetSize
            }
            considerTransportRun(
                start: runStart,
                packetCount: runPacketCount,
                bestStart: &bestStart,
                bestPacketCount: &bestPacketCount
            )
        }
        guard let bestStart,
              bestPacketCount >= minimumTransportSyncRunPacketCount
        else { return nil }
        let end = bestStart + bestPacketCount * packetSize
        return SyncAlignedTransportStream(
            data: Data(exactData[bestStart..<end]),
            discardedPrefixByteCount: bestStart,
            discardedSuffixByteCount: exactData.count - end
        )
    }

    private static func looksLikeTransportPacket(_ data: Data, at offset: Int) -> Bool {
        guard offset >= 0, offset + 188 <= data.count, data[offset] == 0x47 else {
            return false
        }
        // adaptation_field_control == 0 is reserved and therefore cannot be a
        // valid TS header even if a payload byte happens to equal the sync byte.
        return data[offset + 3] & 0x30 != 0
    }

    private static func considerTransportRun(
        start: Int?,
        packetCount: Int,
        bestStart: inout Int?,
        bestPacketCount: inout Int
    ) {
        guard let start,
              packetCount > bestPacketCount
                || (packetCount == bestPacketCount && start < (bestStart ?? Int.max))
        else { return }
        bestStart = start
        bestPacketCount = packetCount
    }

    private static func sanitizedPathComponent(_ value: String) -> String {
        let sanitized = value.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(sanitized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String((collapsed.isEmpty ? "unknown" : collapsed).prefix(48))
    }
}

/// Process-wide only because transport-warm candidates are created before the
/// benchmark's foreground attempt owns an engine. It retains a small bounded
/// number of per-stream recorders. Disk spooling exists only in explicitly
/// opted-in benchmark sessions and is removed synchronously for healthy tunes.
final class HTSPTuningFailureCaptureRegistry: @unchecked Sendable {
    private static let sessionMetadataFile = "session.json"
    private static let activeAttemptFile = "active-attempt.json"
    private static let lastCompletedAttemptFile = "last-completed-attempt.json"
    private static let spoolCreationFailuresFile = "spool-creation-failures.json"
    private static let inProgressDirectory = "in-progress"

    static let shared = HTSPTuningFailureCaptureRegistry(
        enabled: ProcessInfo.processInfo.arguments.contains("--tuning-capture-failures")
    )

    private let enabled: Bool
    private let limits: HTSPTuningFailureCaptureLimits
    private let maximumTrackedStreams: Int
    private let lock = NSLock()
    private var recorders: [HTSPTuningFailureCaptureRecorder] = []
    private var sessionDirectory: URL?
    private var activeAttempt: HTSPTuningFailureCaptureAttemptMetadata?
    private var candidateRecorderAttempts: [UInt32: Int] = [:]
    private var spoolCreationFailures: [HTSPTuningFailureCaptureSpoolCreationFailure] = []

    init(
        enabled: Bool,
        limits: HTSPTuningFailureCaptureLimits = .benchmarkDefault,
        maximumTrackedStreams: Int = 8
    ) {
        self.enabled = enabled
        self.limits = limits
        self.maximumTrackedStreams = max(1, maximumTrackedStreams)
    }

    /// Creates the crash-survivable session before any channel request begins.
    /// The returned path lives inside the app's writable temporary container and
    /// must be announced to the external runner immediately.
    @discardableResult
    func startSession(
        in parentDirectory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date()
    ) throws -> URL? {
        guard enabled else { return nil }
        return try lock.withLock {
            if let sessionDirectory { return sessionDirectory }
            let id = UUID()
            let directory = parentDirectory.appending(
                path: "TVApp-VLC-Tuning-Capture-Session-\(id.uuidString.lowercased())",
                directoryHint: .isDirectory
            )
            let inProgress = directory.appending(
                path: Self.inProgressDirectory,
                directoryHint: .isDirectory
            )
            do {
                try FileManager.default.createDirectory(
                    at: inProgress,
                    withIntermediateDirectories: true
                )
                let metadata = HTSPTuningFailureCaptureSessionMetadata(
                    formatVersion: 1,
                    sessionID: id.uuidString.lowercased(),
                    createdAt: Self.iso8601(now),
                    inProgressDirectory: Self.inProgressDirectory,
                    activeAttemptFile: Self.activeAttemptFile,
                    lastCompletedAttemptFile: Self.lastCompletedAttemptFile,
                    spoolCreationFailuresFile: Self.spoolCreationFailuresFile
                )
                try Self.writeAtomic(
                    metadata,
                    to: directory.appending(path: Self.sessionMetadataFile)
                )
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            sessionDirectory = directory
            return directory
        }
    }

    func beginAttempt(
        attempt: Int,
        channelID: UInt32,
        channelName: String,
        mode: String,
        direction: String,
        startedAt: Date = Date()
    ) throws {
        guard enabled else { return }
        if lock.withLock({ sessionDirectory == nil }) {
            _ = try startSession()
        }
        try lock.withLock {
            guard let sessionDirectory else { throw CocoaError(.fileNoSuchFile) }
            let metadata = HTSPTuningFailureCaptureAttemptMetadata(
                formatVersion: 1,
                attempt: attempt,
                channelID: channelID,
                channelName: channelName,
                mode: mode,
                direction: direction,
                startedAt: Self.iso8601(startedAt),
                phase: "starting",
                completedAt: nil,
                success: nil
            )
            try Self.writeAtomic(
                metadata,
                to: sessionDirectory.appending(path: Self.activeAttemptFile)
            )
            activeAttempt = metadata
        }
    }

    func updateActiveAttemptPhase(_ phase: String) throws {
        guard enabled else { return }
        try lock.withLock {
            guard let sessionDirectory, var attempt = activeAttempt else { return }
            attempt.phase = phase
            try Self.writeAtomic(
                attempt,
                to: sessionDirectory.appending(path: Self.activeAttemptFile)
            )
            activeAttempt = attempt
        }
    }

    func completeAttempt(
        attempt: Int,
        success: Bool,
        completedAt: Date = Date()
    ) throws {
        guard enabled else { return }
        try lock.withLock {
            guard let sessionDirectory,
                  var completed = activeAttempt,
                  completed.attempt == attempt
            else { return }
            completed.phase = "completed"
            completed.completedAt = Self.iso8601(completedAt)
            completed.success = success
            try Self.writeAtomic(
                completed,
                to: sessionDirectory.appending(path: Self.lastCompletedAttemptFile)
            )
            let activeURL = sessionDirectory.appending(path: Self.activeAttemptFile)
            if FileManager.default.fileExists(atPath: activeURL.path) {
                try FileManager.default.removeItem(at: activeURL)
            }
            activeAttempt = nil
            candidateRecorderAttempts = candidateRecorderAttempts.filter {
                $0.value > attempt
            }
        }
    }

    /// Transport warming happens while the preceding attempt is still active.
    /// Reserve the candidate's real owner before staging so repeated channels
    /// cannot make a future recorder look like part of the current attempt.
    func associateCandidateRecorder(channelID: UInt32, withAttempt attempt: Int) {
        guard enabled else { return }
        lock.withLock {
            candidateRecorderAttempts[channelID] = attempt
        }
    }

    var sessionDirectoryForTesting: URL? {
        lock.withLock { sessionDirectory }
    }

    func makeRecorder(
        channelID: UInt32,
        profile: String,
        acceptedTimeshiftPeriodSeconds: TimeInterval,
        streams: [HTSPStreamInfo],
        startsAsCandidate: Bool
    ) -> HTSPTuningFailureCaptureRecorder? {
        guard enabled else { return nil }
        return lock.withLock {
            while recorders.count >= maximumTrackedStreams {
                guard let discardIndex = recorders.firstIndex(where: {
                    !$0.isActiveCandidate
                }) else {
                    // The bounded diagnostic must never evict a candidate that
                    // may become the next foreground tune. Skip capturing this
                    // additional stream instead.
                    return nil
                }
                let evicted = recorders.remove(at: discardIndex)
                if !evicted.isSealed {
                    evicted.discard()
                }
                // A sealed recorder whose final bundle failed to write owns a
                // closed crash spool. Releasing it without `discard()` keeps
                // that evidence in the announced session directory.
            }
            let captureID = UUID()
            let startedAt = Date()
            let benchmarkAttempt = startsAsCandidate
                ? candidateRecorderAttempts[channelID] ?? activeAttempt?.attempt
                : activeAttempt?.attempt
            var spool: HTSPTuningFailureCaptureSpool?
            if let sessionDirectory {
                let attemptPrefix = benchmarkAttempt.map { "attempt-\($0)-" } ?? ""
                do {
                    spool = try HTSPTuningFailureCaptureSpool(
                        directory: sessionDirectory
                            .appending(
                                path: Self.inProgressDirectory,
                                directoryHint: .isDirectory
                            )
                            .appending(
                                path: attemptPrefix + captureID.uuidString.lowercased(),
                                directoryHint: .isDirectory
                            ),
                        captureID: captureID,
                        benchmarkAttempt: benchmarkAttempt,
                        channelID: channelID,
                        profile: profile,
                        acceptedTimeshiftPeriodSeconds: acceptedTimeshiftPeriodSeconds,
                        startedAt: startedAt,
                        lifecycle: startsAsCandidate ? "candidate" : "foreground",
                        streamDeclarations: [],
                        limits: limits
                    )
                } catch {
                    recordSpoolCreationFailureLocked(
                        error,
                        benchmarkAttempt: benchmarkAttempt,
                        channelID: channelID,
                        sessionDirectory: sessionDirectory
                    )
                }
            }
            let recorder = HTSPTuningFailureCaptureRecorder(
                channelID: channelID,
                profile: profile,
                acceptedTimeshiftPeriodSeconds: acceptedTimeshiftPeriodSeconds,
                streams: streams,
                startsAsCandidate: startsAsCandidate,
                limits: limits,
                startedAt: startedAt,
                captureID: captureID,
                benchmarkAttempt: benchmarkAttempt,
                spool: spool
            )
            recorders.append(recorder)
            return recorder
        }
    }

    @discardableResult
    func persistSuspectAttempt(
        attempt: Int,
        channelID: UInt32,
        channelName: String,
        suspiciousReasons: [String],
        diagnosticSummary: String,
        benchmarkSample: Data,
        destinationRoot: URL
    ) throws -> URL? {
        guard enabled else { return nil }
        let matching = lock.withLock {
            recorders.filter {
                $0.benchmarkAttempt == attempt && !$0.isActiveCandidate
            }
        }
        let snapshots = matching.map { $0.sealAndSnapshot() }
        let output = try HTSPTuningFailureCaptureWriter.persist(
            snapshots: snapshots,
            attempt: attempt,
            channelID: channelID,
            channelName: channelName,
            suspiciousReasons: suspiciousReasons,
            diagnosticSummary: diagnosticSummary,
            benchmarkSample: benchmarkSample,
            destinationRoot: destinationRoot
        )
        matching.forEach { $0.removeSpoolAfterSuccessfulPersistence() }
        let capturedIDs = Set(matching.map(\.captureID))
        lock.withLock {
            recorders.removeAll { capturedIDs.contains($0.captureID) }
        }
        return output
    }

    /// Explicitly drops the completed foreground attempt while preserving an
    /// already-staged candidate for the next attempt, including same-channel
    /// benchmark loops.
    func discardFinishedAttempt(attempt: Int) {
        guard enabled else { return }
        let discarded = lock.withLock {
            let discarded = recorders.filter {
                $0.benchmarkAttempt == attempt && !$0.isActiveCandidate
            }
            let discardedIDs = Set(discarded.map(\.captureID))
            recorders.removeAll { discardedIDs.contains($0.captureID) }
            return discarded
        }
        discarded.forEach { $0.discard() }
    }

    private func recordSpoolCreationFailureLocked(
        _ error: Error,
        benchmarkAttempt: Int?,
        channelID: UInt32,
        sessionDirectory: URL
    ) {
        let nsError = error as NSError
        let failure = HTSPTuningFailureCaptureSpoolCreationFailure(
            formatVersion: 1,
            createdAt: Self.iso8601(Date()),
            benchmarkAttempt: benchmarkAttempt,
            channelID: channelID,
            errorDomain: nsError.domain,
            errorCode: nsError.code
        )
        spoolCreationFailures.append(failure)
        var markerFailure: NSError?
        do {
            try Self.writeAtomic(
                spoolCreationFailures,
                to: sessionDirectory.appending(path: Self.spoolCreationFailuresFile)
            )
        } catch {
            markerFailure = error as NSError
        }
        let attemptText = benchmarkAttempt.map(String.init) ?? "unassigned"
        var warning = "VLC_TUNING_CAPTURE_WARNING spool-create-failed "
            + "attempt=\(attemptText) channel=\(channelID) "
            + "errorDomain=\(nsError.domain) errorCode=\(nsError.code)"
        if let markerFailure {
            warning += " markerErrorDomain=\(markerFailure.domain) "
                + "markerErrorCode=\(markerFailure.code)"
        }
        print(warning)
        fflush(stdout)
    }

    private static func writeAtomic<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension Int {
    func saturatingAdd(_ other: Int) -> Int {
        let addition = addingReportingOverflow(other)
        return addition.overflow ? Int.max : addition.partialValue
    }

    func saturatingMultiply(_ other: Int) -> Int {
        let product = multipliedReportingOverflow(by: other)
        return product.overflow ? Int.max : product.partialValue
    }
}
