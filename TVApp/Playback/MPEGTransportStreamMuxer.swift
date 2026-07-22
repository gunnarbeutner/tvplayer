import Foundation

struct HTSPMuxPacket: Sendable {
    let streamIndex: Int
    let frameType: UInt8
    let presentationTime: Int64?
    let decodeTime: Int64?
    let durationMicroseconds: Int64?
    let payload: Data

    init(
        streamIndex: Int,
        frameType: UInt8,
        presentationTime: Int64?,
        decodeTime: Int64?,
        durationMicroseconds: Int64? = nil,
        payload: Data
    ) {
        self.streamIndex = streamIndex
        self.frameType = frameType
        self.presentationTime = presentationTime
        self.decodeTime = decodeTime
        self.durationMicroseconds = durationMicroseconds
        self.payload = payload
    }
}

/// Holds the raw HTSP packets collected while a timeshift destination is being
/// prepared. TVHeadend may deliver several seconds of one elementary stream
/// before another. Feeding that burst order directly to a fresh VLC pipeline
/// can fill the video decoder before VLC has even discovered enough audio.
///
/// The completed batch is merged by decode time across stream queues while
/// retaining the exact arrival order within every stream. The first accepted
/// video keyframe stays first so that the muxer emits PAT/PMT, bootstrap data,
/// and the first PCR before any other elementary stream.
struct HTSPPostSeekPacketStager: Sendable {
    struct Batch: Sendable {
        fileprivate let entries: [Entry]
        fileprivate let pinsInitialVideoKeyframe: Bool

        var payloadByteCount: Int {
            entries.reduce(into: 0) { $0 += $1.packet.payload.count }
        }

        var containsInitialVideoKeyframe: Bool {
            entries.contains { $0.isVideo && $0.packet.frameType == 0x49 }
        }

        func containsPacket(streamIndex: Int) -> Bool {
            entries.contains { $0.packet.streamIndex == streamIndex }
        }

        var interleavedPackets: [HTSPMuxPacket] {
            guard !entries.isEmpty else { return [] }

            let pinnedOrdinal: Int?
            if pinsInitialVideoKeyframe {
                pinnedOrdinal = entries.first(where: {
                    $0.isVideo && $0.packet.frameType == 0x49
                })?.ordinal
            } else {
                pinnedOrdinal = nil
            }
            let pinnedEntry = pinnedOrdinal.flatMap { ordinal in
                entries.first(where: { $0.ordinal == ordinal })
            }
            let anchorTime = pinnedEntry?.decodeTime

            // HTSP arrival order is already a valid decoder order for an
            // individual PID. Only choose between the heads of those FIFO
            // queues; a flat timestamp sort could reorder dependent H.264
            // access units within one stream.
            var previousTimeByStream: [Int: Int64] = [:]
            if let pinnedEntry, let anchorTime {
                previousTimeByStream[pinnedEntry.packet.streamIndex] = anchorTime
            }
            var queues: [Int: [OrderedEntry]] = [:]
            for entry in entries where entry.ordinal != pinnedOrdinal {
                let streamIndex = entry.packet.streamIndex
                let rawTime = entry.decodeTime
                let previousTime = previousTimeByStream[streamIndex]
                let time: Int64?
                if let rawTime, let previousTime {
                    time = max(previousTime, rawTime)
                } else {
                    time = rawTime ?? previousTime
                }
                if let time { previousTimeByStream[streamIndex] = time }
                queues[streamIndex, default: []].append(
                    OrderedEntry(entry: entry, decodeTime: time)
                )
            }

            var queueOffsets = Dictionary(
                uniqueKeysWithValues: queues.keys.map { ($0, 0) }
            )
            var result: [HTSPMuxPacket] = []
            result.reserveCapacity(entries.count)
            if let pinnedEntry { result.append(pinnedEntry.packet) }

            while result.count < entries.count {
                var selectedStream: Int?
                var selectedEntry: OrderedEntry?
                for (streamIndex, queue) in queues {
                    let offset = queueOffsets[streamIndex] ?? 0
                    guard offset < queue.count else { continue }
                    let candidate = queue[offset]
                    if selectedEntry.map({ candidate.precedes($0) }) ?? true {
                        selectedStream = streamIndex
                        selectedEntry = candidate
                    }
                }
                guard let selectedStream, let selectedEntry else { break }
                result.append(selectedEntry.entry.packet)
                queueOffsets[selectedStream, default: 0] += 1
            }
            return result
        }
    }

    fileprivate struct Entry: Sendable {
        let packet: HTSPMuxPacket
        let isVideo: Bool
        let ordinal: Int

        var decodeTime: Int64? {
            isVideo
                ? (packet.decodeTime ?? packet.presentationTime)
                : (packet.presentationTime ?? packet.decodeTime)
        }
    }

    private struct OrderedEntry {
        let entry: Entry
        let decodeTime: Int64?

        func precedes(_ other: OrderedEntry) -> Bool {
            switch (decodeTime, other.decodeTime) {
            case let (lhs?, rhs?) where lhs != rhs:
                return lhs < rhs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return entry.ordinal < other.entry.ordinal
            }
        }
    }

    private(set) var isActive = false
    private var pinsInitialVideoKeyframe = false
    private var entries: [Entry] = []
    private(set) var payloadByteCount = 0

    mutating func begin(pinsInitialVideoKeyframe: Bool) {
        isActive = true
        self.pinsInitialVideoKeyframe = pinsInitialVideoKeyframe
        entries.removeAll(keepingCapacity: true)
        payloadByteCount = 0
    }

    @discardableResult
    mutating func append(
        _ packet: HTSPMuxPacket,
        isVideo: Bool,
        maximumPayloadBytes: Int
    ) -> Bool {
        guard isActive else { return false }
        let addition = payloadByteCount.addingReportingOverflow(packet.payload.count)
        guard !addition.overflow, addition.partialValue <= maximumPayloadBytes else {
            return false
        }
        entries.append(
            Entry(packet: packet, isVideo: isVideo, ordinal: entries.count)
        )
        payloadByteCount = addition.partialValue
        return true
    }

    mutating func finish() -> Batch {
        let batch = Batch(
            entries: entries,
            pinsInitialVideoKeyframe: pinsInitialVideoKeyframe
        )
        cancel()
        return batch
    }

    mutating func cancel() {
        isActive = false
        pinsInitialVideoKeyframe = false
        entries.removeAll(keepingCapacity: true)
        payloadByteCount = 0
    }
}

/// Collects the first decodable, timestamp-aligned A/V window of a new live
/// subscription before any bytes are exposed to VLC. TVHeadend can begin a
/// subscription with audio that predates the first video keyframe by more than
/// a second; handing that backlog straight to VLC makes it display the
/// keyframe as preroll and then hold video while its audio clock catches up.
struct HTSPInitialTunePacketStager: Sendable {
    enum Disposition: Sendable {
        case passthrough(HTSPMuxPacket)
        case waiting
        case ready(
            batch: HTSPPostSeekPacketStager.Batch,
            primaryVideoStreamIndex: Int?,
            primaryAudioStreamIndex: Int?,
            diagnostics: String
        )
        case overflow(
            batch: HTSPPostSeekPacketStager.Batch,
            trailingPacket: HTSPMuxPacket?,
            containsPrimaryAudio: Bool,
            diagnostics: String
        )
        case failure(String)
    }

    private struct ProvisionalPacket: Sendable {
        let packet: HTSPMuxPacket
        let isAudio: Bool
    }

    private var coverage = HTSPPostSeekBufferTracker()
    private var packets = HTSPPostSeekPacketStager()
    private var maximumPayloadBytes = 0
    private var primaryVideoStreamIndex: Int?
    private var primaryAudioStreamIndex: Int?
    private var provisionalPackets: [ProvisionalPacket] = []
    private var provisionalPayloadBytes = 0
    private var stagingStartedAt: Date?
    private var acceptedVideoKeyframeAt: Date?
    private var acceptedVideoAnchorTime: Int64?
    private var maximumWaitBeforeVideoKeyframe: TimeInterval = 3
    private var maximumWaitAfterVideoKeyframe: TimeInterval = 2
    private(set) var isActive = false

    var payloadByteCount: Int {
        packets.payloadByteCount + provisionalPayloadBytes
    }

    mutating func begin(
        hasVideo: Bool,
        primaryVideoStreamIndex: Int?,
        primaryAudioStreamIndex: Int?,
        requiredDuration: Int64 = HTSPPostSeekBufferTracker.minimumRequiredDuration,
        maximumPayloadBytes: Int,
        maximumWaitBeforeVideoKeyframe: TimeInterval = 3,
        maximumWaitAfterVideoKeyframe: TimeInterval = 2
    ) {
        cancel()
        guard hasVideo,
              primaryVideoStreamIndex != nil,
              primaryAudioStreamIndex != nil
        else { return }
        self.maximumPayloadBytes = max(1, maximumPayloadBytes)
        self.primaryVideoStreamIndex = primaryVideoStreamIndex
        self.primaryAudioStreamIndex = primaryAudioStreamIndex
        self.maximumWaitBeforeVideoKeyframe = max(0, maximumWaitBeforeVideoKeyframe)
        self.maximumWaitAfterVideoKeyframe = max(0, maximumWaitAfterVideoKeyframe)
        coverage.beginInitialTune(
            hasVideo: hasVideo,
            audioStreamIndexes: primaryAudioStreamIndex.map { [$0] } ?? [],
            requiredDuration: requiredDuration
        )
        packets.begin(pinsInitialVideoKeyframe: hasVideo)
        isActive = true
    }

    mutating func append(
        _ packet: HTSPMuxPacket,
        isVideo: Bool,
        isAudio: Bool,
        at date: Date = Date()
    ) -> Disposition {
        guard isActive else { return .passthrough(packet) }
        stagingStartedAt = stagingStartedAt ?? date
        let packetTime = packet.presentationTime ?? packet.decodeTime
        let isPrimaryVideo = isVideo
            && primaryVideoStreamIndex.map { $0 == packet.streamIndex } != false

        if acceptedVideoKeyframeAt == nil {
            if let stagingStartedAt,
               date.timeIntervalSince(stagingStartedAt) >= maximumWaitBeforeVideoKeyframe,
               !(isPrimaryVideo && packet.frameType == 0x49) {
                return finishFailure(
                    "No primary video keyframe arrived during initial A/V staging."
                )
            }
            guard isPrimaryVideo, packet.frameType == 0x49 else {
                if !isVideo { retainProvisional(packet, isAudio: isAudio) }
                return .waiting
            }

            trimProvisionalPacketsToMakeRoom(for: packet.payload.count)
            guard packets.append(
                packet,
                isVideo: true,
                maximumPayloadBytes: maximumPayloadBytes
            ) else {
                if packets.append(packet, isVideo: true, maximumPayloadBytes: .max) {
                    return finishOverflow(trailingPacket: nil)
                }
                return finishOverflow(trailingPacket: packet)
            }
            guard coverage.shouldAcceptPacket(
                time: packetTime,
                decodeTime: packet.decodeTime,
                duration: packet.durationMicroseconds,
                isVideo: true,
                isAudio: false,
                frameType: packet.frameType
            ) else { return .waiting }
            acceptedVideoKeyframeAt = date
            acceptedVideoAnchorTime = packet.decodeTime ?? packet.presentationTime
            _ = coverage.observePacket(
                time: packetTime,
                decodeTime: packet.decodeTime,
                duration: packet.durationMicroseconds,
                streamIndex: packet.streamIndex,
                isVideo: true,
                isAudio: false,
                frameType: packet.frameType
            )

            // With no video timestamp we cannot trim the provisional epoch,
            // but retaining it is still essential for a bounded recovery:
            // the pinned keyframe keeps the fallback decodable and preserves
            // primary audio instead of creating a deterministic reconnect loop.
            let provisional = provisionalPackets
            provisionalPackets.removeAll(keepingCapacity: true)
            provisionalPayloadBytes = 0
            for provisionalPacket in provisional {
                let stagedPacket = provisionalPacket.packet
                let stagedTime = stagedPacket.presentationTime ?? stagedPacket.decodeTime
                if !provisionalPacket.isAudio,
                   !shouldAcceptAncillaryPacket(stagedPacket) {
                    continue
                }
                if provisionalPacket.isAudio,
                   !coverage.shouldAcceptPacket(
                       time: stagedTime,
                       decodeTime: stagedPacket.decodeTime,
                       duration: stagedPacket.durationMicroseconds,
                       isVideo: false,
                       isAudio: true,
                       frameType: stagedPacket.frameType
                   ) {
                    continue
                }
                guard packets.append(
                    stagedPacket,
                    isVideo: false,
                    maximumPayloadBytes: maximumPayloadBytes
                ) else {
                    return finishOverflow(trailingPacket: stagedPacket)
                }
                _ = coverage.observePacket(
                    time: stagedTime,
                    decodeTime: stagedPacket.decodeTime,
                    duration: stagedPacket.durationMicroseconds,
                    streamIndex: stagedPacket.streamIndex,
                    isVideo: false,
                    isAudio: provisionalPacket.isAudio,
                    frameType: stagedPacket.frameType
                )
            }
            return .waiting
        }

        let exceededDeadline = acceptedVideoKeyframeAt.map {
            date.timeIntervalSince($0) >= maximumWaitAfterVideoKeyframe
        } == true
        if !isVideo, !isAudio, !shouldAcceptAncillaryPacket(packet) {
            return exceededDeadline
                ? finishOverflow(trailingPacket: nil)
                : .waiting
        }
        guard coverage.shouldAcceptPacket(
            time: packetTime,
            decodeTime: packet.decodeTime,
            duration: packet.durationMicroseconds,
            isVideo: isPrimaryVideo,
            isAudio: isAudio,
            frameType: packet.frameType
        ) else {
            return exceededDeadline
                ? finishOverflow(trailingPacket: nil)
                : .waiting
        }

        guard packets.append(
            packet,
            isVideo: isVideo,
            maximumPayloadBytes: maximumPayloadBytes
        ) else {
            if packets.append(packet, isVideo: isVideo, maximumPayloadBytes: .max) {
                return finishOverflow(trailingPacket: nil)
            }
            return finishOverflow(trailingPacket: packet)
        }

        let completion = coverage.observePacket(
            time: packetTime,
            decodeTime: packet.decodeTime,
            duration: packet.durationMicroseconds,
            streamIndex: packet.streamIndex,
            isVideo: isPrimaryVideo,
            isAudio: isAudio,
            frameType: packet.frameType
        )
        guard completion != nil else {
            return exceededDeadline
                ? finishOverflow(trailingPacket: nil)
                : .waiting
        }

        let batch = packets.finish()
        let diagnostics = coverage.completionDiagnostics ?? coverage.progressDiagnostics
        coverage.cancel()
        isActive = false
        return .ready(
            batch: batch,
            primaryVideoStreamIndex: primaryVideoStreamIndex,
            primaryAudioStreamIndex: primaryAudioStreamIndex,
            diagnostics: diagnostics
        )
    }

    mutating func cancel() {
        coverage.cancel()
        packets.cancel()
        maximumPayloadBytes = 0
        primaryVideoStreamIndex = nil
        primaryAudioStreamIndex = nil
        provisionalPackets.removeAll(keepingCapacity: true)
        provisionalPayloadBytes = 0
        stagingStartedAt = nil
        acceptedVideoKeyframeAt = nil
        acceptedVideoAnchorTime = nil
        maximumWaitBeforeVideoKeyframe = 3
        maximumWaitAfterVideoKeyframe = 2
        isActive = false
    }

    private mutating func retainProvisional(
        _ packet: HTSPMuxPacket,
        isAudio: Bool
    ) {
        guard packet.payload.count <= maximumPayloadBytes else { return }
        provisionalPackets.append(ProvisionalPacket(packet: packet, isAudio: isAudio))
        provisionalPayloadBytes += packet.payload.count
        while provisionalPayloadBytes > maximumPayloadBytes,
              !provisionalPackets.isEmpty {
            provisionalPayloadBytes -= provisionalPackets.removeFirst().packet.payload.count
        }
    }

    private mutating func trimProvisionalPacketsToMakeRoom(for payloadByteCount: Int) {
        let availableBytes = max(0, maximumPayloadBytes - payloadByteCount)
        while provisionalPayloadBytes > availableBytes,
              !provisionalPackets.isEmpty {
            provisionalPayloadBytes -= provisionalPackets.removeFirst().packet.payload.count
        }
    }

    private mutating func finishOverflow(
        trailingPacket: HTSPMuxPacket?
    ) -> Disposition {
        let batch = packets.finish()
        let diagnostics = coverage.completionDiagnostics ?? coverage.progressDiagnostics
        let containsPrimaryAudio = primaryAudioStreamIndex.map { streamIndex in
            batch.containsPacket(streamIndex: streamIndex)
                || trailingPacket?.streamIndex == streamIndex
        } ?? false
        coverage.cancel()
        provisionalPackets.removeAll(keepingCapacity: true)
        provisionalPayloadBytes = 0
        stagingStartedAt = nil
        acceptedVideoKeyframeAt = nil
        acceptedVideoAnchorTime = nil
        isActive = false
        return .overflow(
            batch: batch,
            trailingPacket: trailingPacket,
            containsPrimaryAudio: containsPrimaryAudio,
            diagnostics: diagnostics
        )
    }

    private mutating func finishFailure(_ reason: String) -> Disposition {
        cancel()
        return .failure(reason)
    }

    private func shouldAcceptAncillaryPacket(_ packet: HTSPMuxPacket) -> Bool {
        guard let acceptedVideoAnchorTime,
              let packetTime = packet.presentationTime ?? packet.decodeTime
        else { return true }
        let subtraction = acceptedVideoAnchorTime.subtractingReportingOverflow(
            HTSPPostSeekBufferTracker.audioLeadTolerance
        )
        let earliestTime = subtraction.overflow ? Int64.min : subtraction.partialValue
        if packetTime >= earliestTime { return true }
        guard let duration = packet.durationMicroseconds, duration >= 0 else { return false }
        let end = packetTime.addingReportingOverflow(duration)
        return end.overflow || end.partialValue >= earliestTime
    }
}

/// Keeps one decodable live window warm without exposing bytes to VLC. The
/// window always starts at the newest primary-video keyframe and only releases
/// packets through the common primary A/V watermark. A completed window stays
/// available while its replacement is assembled, so an arriving keyframe
/// never creates a readiness gap. The committed and in-progress windows share
/// one payload budget.
struct HTSPRollingTunePacketBuffer: Sendable {
    struct Snapshot: Sendable {
        let orderedPackets: [HTSPMuxPacket]
        let tailInterleaver: HTSPPostSeekTailInterleaver?
        let commonHorizonMicroseconds: Int64
        let readyAt: Date
        let lastAlignedOutputAt: Date
        let diagnostics: String

        var payloadByteCount: Int {
            orderedPackets.reduce(into: 0) { $0 += $1.payload.count }
                + (tailInterleaver?.queuedPayloadByteCount ?? 0)
        }
    }

    enum Claim: Sendable {
        case ready(Snapshot)
        case partial(HTSPInitialTunePacketStager)
        case unavailable
    }

    private var hasVideo = false
    private var primaryVideoStreamIndex: Int?
    private var primaryAudioStreamIndex: Int?
    private var requiredDuration: Int64 = 500_000
    private var maximumPayloadBytes = 8 * 1_024 * 1_024
    private var maximumWaitBeforeVideoKeyframe: TimeInterval = 3
    private var maximumWaitAfterVideoKeyframe: TimeInterval = 2.5
    private var initialStager = HTSPInitialTunePacketStager()
    private var orderedPackets: [HTSPMuxPacket] = []
    private var orderedPayloadBytes = 0
    private var tailInterleaver: HTSPPostSeekTailInterleaver?
    private var readyAt: Date?
    private var lastAlignedOutputAt: Date?
    private var diagnostics: String?

    var isReady: Bool { readyAt != nil && !orderedPackets.isEmpty }

    var payloadByteCount: Int {
        committedPayloadByteCount + initialStager.payloadByteCount
    }

    mutating func begin(
        hasVideo: Bool,
        primaryVideoStreamIndex: Int?,
        primaryAudioStreamIndex: Int?,
        requiredDuration: Int64,
        maximumPayloadBytes: Int,
        maximumWaitBeforeVideoKeyframe: TimeInterval = 3,
        maximumWaitAfterVideoKeyframe: TimeInterval = 2.5
    ) {
        self.hasVideo = hasVideo
        self.primaryVideoStreamIndex = primaryVideoStreamIndex
        self.primaryAudioStreamIndex = primaryAudioStreamIndex
        self.requiredDuration = max(250_000, requiredDuration)
        self.maximumPayloadBytes = max(1, maximumPayloadBytes)
        self.maximumWaitBeforeVideoKeyframe = max(0, maximumWaitBeforeVideoKeyframe)
        self.maximumWaitAfterVideoKeyframe = max(0, maximumWaitAfterVideoKeyframe)
        cancel()
        startPendingWindow()
    }

    mutating func append(
        _ packet: HTSPMuxPacket,
        isVideo: Bool,
        isAudio: Bool,
        at date: Date = Date()
    ) {
        let startsNewPrimaryVideoWindow = isReady
            && isVideo
            && packet.streamIndex == primaryVideoStreamIndex
            && packet.frameType == 0x49
        if startsNewPrimaryVideoWindow { startPendingWindow() }

        if initialStager.isActive {
            switch initialStager.append(
                packet,
                isVideo: isVideo,
                isAudio: isAudio,
                at: date
            ) {
            case .passthrough:
                break
            case .waiting:
                return
            case let .ready(
                batch,
                primaryVideoStreamIndex,
                primaryAudioStreamIndex,
                completionDiagnostics
            ):
                guard let primaryVideoStreamIndex,
                      let primaryAudioStreamIndex
                else {
                    startPendingWindow()
                    return
                }
                var interleaver = HTSPPostSeekTailInterleaver(
                    batch: batch,
                    primaryVideoStreamIndex: primaryVideoStreamIndex,
                    primaryAudioStreamIndex: primaryAudioStreamIndex
                )
                let released = interleaver.drainAvailable()
                guard !released.isEmpty else {
                    startPendingWindow()
                    return
                }
                let replacementPayloadBytes = released.reduce(into: 0) {
                    $0 += $1.payload.count
                } + interleaver.queuedPayloadByteCount
                guard replacementPayloadBytes <= maximumPayloadBytes else {
                    startPendingWindow()
                    return
                }

                // Every field of the committed generation is replaced only
                // after the new generation has proven a common A/V watermark.
                orderedPackets = released
                orderedPayloadBytes = released.reduce(into: 0) {
                    $0 += $1.payload.count
                }
                tailInterleaver = interleaver
                readyAt = date
                lastAlignedOutputAt = date
                diagnostics = completionDiagnostics
                return
            case .overflow, .failure:
                // A candidate is optional: never promote a bounded fallback
                // whose common A/V watermark could not be proven.
                startPendingWindow()
                return
            }
        }

        guard var interleaver = tailInterleaver else { return }
        guard payloadByteCount <= maximumPayloadBytes - min(
            packet.payload.count,
            maximumPayloadBytes
        ) else {
            // Freeze the still-decodable committed window rather than
            // invalidating it merely because its tail reached the cap.
            return
        }
        interleaver.append(packet)
        let released = interleaver.drainAvailable()
        if !released.isEmpty {
            orderedPackets.append(contentsOf: released)
            orderedPayloadBytes += released.reduce(into: 0) {
                $0 += $1.payload.count
            }
            lastAlignedOutputAt = date
        }
        tailInterleaver = interleaver
    }

    mutating func claim(
        at date: Date = Date(),
        maximumAlignedAge: TimeInterval = 0.5
    ) -> Claim {
        if let readyAt,
           let lastAlignedOutputAt,
           date.timeIntervalSince(lastAlignedOutputAt) <= maximumAlignedAge,
           !orderedPackets.isEmpty {
            let snapshot = Snapshot(
                orderedPackets: orderedPackets,
                tailInterleaver: tailInterleaver,
                commonHorizonMicroseconds: requiredDuration,
                readyAt: readyAt,
                lastAlignedOutputAt: lastAlignedOutputAt,
                diagnostics: diagnostics ?? "timestamp-aligned rolling candidate"
            )
            cancel()
            return .ready(snapshot)
        }
        if initialStager.isActive {
            let partial = initialStager
            cancel()
            return .partial(partial)
        }
        cancel()
        return .unavailable
    }

    mutating func cancel() {
        initialStager.cancel()
        orderedPackets.removeAll(keepingCapacity: true)
        orderedPayloadBytes = 0
        tailInterleaver = nil
        readyAt = nil
        lastAlignedOutputAt = nil
        diagnostics = nil
    }

    private var committedPayloadByteCount: Int {
        orderedPayloadBytes + (tailInterleaver?.queuedPayloadByteCount ?? 0)
    }

    private mutating func startPendingWindow() {
        initialStager.cancel()
        let availablePayloadBytes = maximumPayloadBytes - committedPayloadByteCount
        guard availablePayloadBytes > 0 else { return }
        initialStager.begin(
            hasVideo: hasVideo,
            primaryVideoStreamIndex: primaryVideoStreamIndex,
            primaryAudioStreamIndex: primaryAudioStreamIndex,
            requiredDuration: requiredDuration,
            maximumPayloadBytes: availablePayloadBytes,
            maximumWaitBeforeVideoKeyframe: maximumWaitBeforeVideoKeyframe,
            maximumWaitAfterVideoKeyframe: maximumWaitAfterVideoKeyframe
        )
    }
}

/// Continues the timestamp merge across the boundary between a staged seek
/// batch and TVHeadend's subsequent packets. Only packets covered by both the
/// primary video and primary audio watermarks are released. This prevents a
/// video-heavy end of the staged batch from sitting in front of the next audio
/// burst in VLC's byte stream.
struct HTSPPostSeekTailInterleaver: Sendable {
    private struct TimedEntry: Sendable {
        let packet: HTSPMuxPacket
        let ordinal: Int
        let decodeTime: Int64?

        func precedes(_ other: TimedEntry) -> Bool {
            switch (decodeTime, other.decodeTime) {
            case let (lhs?, rhs?) where lhs != rhs:
                return lhs < rhs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return ordinal < other.ordinal
            }
        }
    }

    private let primaryVideoStreamIndex: Int
    private let primaryAudioStreamIndex: Int
    private var queues: [Int: [TimedEntry]] = [:]
    private var queueOffsets: [Int: Int] = [:]
    private var previousTimeByStream: [Int: Int64] = [:]
    private var latestTimeByStream: [Int: Int64] = [:]
    private var pinnedPacket: HTSPMuxPacket?
    private var anchorTime: Int64?
    private var nextOrdinal = 0
    private(set) var queuedPayloadByteCount = 0

    init(
        batch: HTSPPostSeekPacketStager.Batch,
        primaryVideoStreamIndex: Int,
        primaryAudioStreamIndex: Int
    ) {
        self.primaryVideoStreamIndex = primaryVideoStreamIndex
        self.primaryAudioStreamIndex = primaryAudioStreamIndex

        let pinnedOrdinal: Int?
        if batch.pinsInitialVideoKeyframe {
            pinnedOrdinal = batch.entries.first(where: {
                $0.packet.streamIndex == primaryVideoStreamIndex
                    && $0.isVideo
                    && $0.packet.frameType == 0x49
            })?.ordinal
        } else {
            pinnedOrdinal = nil
        }
        if let pinnedEntry = batch.entries.first(where: { $0.ordinal == pinnedOrdinal }) {
            pinnedPacket = pinnedEntry.packet
            queuedPayloadByteCount += pinnedEntry.packet.payload.count
            let time = pinnedEntry.decodeTime
            if let time {
                anchorTime = time
                previousTimeByStream[primaryVideoStreamIndex] = time
                latestTimeByStream[primaryVideoStreamIndex] = time
            }
        }
        nextOrdinal = batch.entries.count
        for entry in batch.entries where entry.ordinal != pinnedOrdinal {
            appendEntry(entry.packet, ordinal: entry.ordinal)
        }
    }

    mutating func append(_ packet: HTSPMuxPacket) {
        appendEntry(packet, ordinal: nextOrdinal)
        nextOrdinal &+= 1
    }

    var hasExceededPayloadLimit: Bool {
        queuedPayloadByteCount > 8 * 1_024 * 1_024
    }

    var isEmpty: Bool { queuedPayloadByteCount == 0 }

    mutating func drainAvailable() -> [HTSPMuxPacket] {
        guard let videoTime = latestTimeByStream[primaryVideoStreamIndex],
              let audioTime = latestTimeByStream[primaryAudioStreamIndex]
        else { return drainPinnedPacket() }
        return drain(through: min(videoTime, audioTime))
    }

    mutating func drainAll() -> [HTSPMuxPacket] {
        drain(through: nil)
    }

    private mutating func appendEntry(_ packet: HTSPMuxPacket, ordinal: Int) {
        let streamIndex = packet.streamIndex
        let rawTime = streamIndex == primaryVideoStreamIndex
            ? (packet.decodeTime ?? packet.presentationTime)
            : (packet.presentationTime ?? packet.decodeTime)
        let previousTime = previousTimeByStream[streamIndex]
        let decodeTime: Int64?
        if let rawTime, let previousTime {
            decodeTime = max(previousTime, rawTime)
        } else {
            decodeTime = rawTime ?? previousTime
                ?? anchorTime
        }
        if let rawTime, previousTime == nil {
            resolveLeadingUnknownTimes(in: streamIndex, to: rawTime)
        }
        // Timestamp-less packets may inherit an ordering key so they cannot
        // block their PID, but they must not claim real A/V coverage and open
        // the watermark for an unobserved primary stream.
        if rawTime != nil, let decodeTime {
            previousTimeByStream[streamIndex] = decodeTime
            let coverageTime: Int64
            if streamIndex == primaryAudioStreamIndex,
               let duration = packet.durationMicroseconds,
               duration >= 0 {
                let addition = decodeTime.addingReportingOverflow(duration)
                coverageTime = addition.overflow ? decodeTime : addition.partialValue
            } else {
                coverageTime = decodeTime
            }
            latestTimeByStream[streamIndex] = max(
                latestTimeByStream[streamIndex] ?? coverageTime,
                coverageTime
            )
        }
        queues[streamIndex, default: []].append(
            TimedEntry(packet: packet, ordinal: ordinal, decodeTime: decodeTime)
        )
        queueOffsets[streamIndex] = queueOffsets[streamIndex] ?? 0
        queuedPayloadByteCount += packet.payload.count
    }

    private mutating func resolveLeadingUnknownTimes(
        in streamIndex: Int,
        to time: Int64
    ) {
        guard var queue = queues[streamIndex] else { return }
        let offset = queueOffsets[streamIndex] ?? 0
        guard offset < queue.count else { return }
        for index in offset..<queue.count {
            guard queue[index].decodeTime == nil else { break }
            let entry = queue[index]
            queue[index] = TimedEntry(
                packet: entry.packet,
                ordinal: entry.ordinal,
                decodeTime: time
            )
        }
        queues[streamIndex] = queue
    }

    private mutating func drain(through watermark: Int64?) -> [HTSPMuxPacket] {
        var result = drainPinnedPacket()
        while let selection = nextEntry(through: watermark) {
            result.append(selection.entry.packet)
            queuedPayloadByteCount -= selection.entry.packet.payload.count
            queueOffsets[selection.streamIndex, default: 0] += 1
            compactQueueIfNeeded(selection.streamIndex)
        }
        return result
    }

    private mutating func drainPinnedPacket() -> [HTSPMuxPacket] {
        guard let pinnedPacket else { return [] }
        self.pinnedPacket = nil
        queuedPayloadByteCount -= pinnedPacket.payload.count
        return [pinnedPacket]
    }

    private func nextEntry(
        through watermark: Int64?
    ) -> (streamIndex: Int, entry: TimedEntry)? {
        var selected: (streamIndex: Int, entry: TimedEntry)?
        for (streamIndex, queue) in queues {
            let offset = queueOffsets[streamIndex] ?? 0
            guard offset < queue.count else { continue }
            let candidate = queue[offset]
            if let watermark {
                guard candidate.decodeTime.map({ $0 <= watermark }) == true else { continue }
            }
            if selected.map({ candidate.precedes($0.entry) }) ?? true {
                selected = (streamIndex, candidate)
            }
        }
        return selected
    }

    private mutating func compactQueueIfNeeded(_ streamIndex: Int) {
        guard var queue = queues[streamIndex] else { return }
        let offset = queueOffsets[streamIndex] ?? 0
        guard offset >= 128 || offset == queue.count else { return }
        queue.removeFirst(offset)
        queues[streamIndex] = queue
        queueOffsets[streamIndex] = 0
    }
}

struct MPEGTransportStreamStartupSnapshot: Equatable, Sendable {
    let trackLayout: String
    let packetOrder: String
    let audioVideoTimestampDeltaMilliseconds: Int64?
    let patPrefix: String
    let pmtPrefix: String
    let audioStarts: String
    let audioPESPrefixes: String

    var summary: String {
        let delta = audioVideoTimestampDeltaMilliseconds.map { "\($0)ms" } ?? "unknown"
        return "layout=[\(trackLayout)] order=[\(packetOrder)] avPTS=\(delta) "
            + "pat=\(patPrefix) pmt=\(pmtPrefix) audioStarts=[\(audioStarts)] "
            + "audioPES=[\(audioPESPrefixes)]"
    }
}

struct MPEGTimestampContinuity {
    static let epochGap: Int64 = 40_000

    private var offset: Int64 = 0
    private var latestOutputTime: Int64?
    private var startsNewEpoch = false

    mutating func beginNewEpoch() {
        startsNewEpoch = true
    }

    mutating func normalize(
        presentationTime: Int64?,
        decodeTime: Int64?
    ) -> (presentationTime: Int64?, decodeTime: Int64?) {
        let sourceAnchor = decodeTime ?? presentationTime
        if startsNewEpoch, let sourceAnchor {
            if let latestOutputTime {
                offset = latestOutputTime + Self.epochGap - sourceAnchor
            }
            startsNewEpoch = false
        }

        let normalizedPTS = presentationTime.map { $0 + offset }
        let normalizedDTS = decodeTime.map { $0 + offset }
        if let outputTime = [normalizedPTS, normalizedDTS].compactMap({ $0 }).max() {
            latestOutputTime = max(latestOutputTime ?? outputTime, outputTime)
        }
        return (normalizedPTS, normalizedDTS)
    }
}

final class MPEGTransportStreamMuxer {
    // VLC 3.x intentionally does not propagate the standard MPEG-TS
    // discontinuity indicator to packetizers and decoders. Its TS demuxer
    // recognizes this private-data marker and turns it into
    // BLOCK_FLAG_DISCONTINUITY, which flushes stale audio/video decoder state.
    private static let vlcDiscontinuityMarker = Data("VLC_DISCONTINU".utf8)

    private struct Track {
        let info: HTSPStreamInfo
        let pid: UInt16
        let streamType: UInt8
        let streamID: UInt8
        let descriptor: Data
        let bootstrap: Data?
        let isVideo: Bool
        let isAudio: Bool
    }

    private enum Discontinuity {
        case none
        case transport
        case decoderFlush
    }

    private var tracksByIndex: [Int: Track] = [:]
    private var continuity: [UInt16: UInt8] = [:]
    private var packetsSinceTables = Int.max
    private var pendingBootstrapIndexes: Set<Int> = []
    private var pendingDiscontinuityPIDs: Set<UInt16> = []
    private var pendingDecoderFlushPIDs: Set<UInt16> = []
    private var timestampContinuity = MPEGTimestampContinuity()
    private var startupTimestampAnchor: Int64?
    private var startupPacketEvents: [String] = []
    private var startupFirstVideoTimestamp: Int64?
    private var startupFirstAudioTimestamp: Int64?
    private var startupMuxInputCount = 0
    private var startupFirstAudioOrdinals: [UInt16: Int] = [:]
    private var startupFirstAudioTimestamps: [UInt16: Int64] = [:]
    private var startupPATPrefix = "unseen"
    private var startupPMTPrefix = "unseen"
    private var startupAudioPESPrefixes: [UInt16: String] = [:]
    private let pmtPID: UInt16 = 0x1000
    private let pcrPID: UInt16

    init(streams: [HTSPStreamInfo]) throws {
        var nextPID: UInt16 = 0x0100
        var videoOrdinal: UInt8 = 0
        var audioOrdinal: UInt8 = 0
        var firstPlayablePID: UInt16?
        var firstVideoPID: UInt16?

        for stream in streams {
            guard let mapping = Self.mapping(for: stream) else { continue }
            let streamID: UInt8
            if mapping.isVideo {
                streamID = 0xe0 | min(videoOrdinal, 0x0f)
                videoOrdinal &+= 1
            } else if mapping.isAudio {
                streamID = 0xc0 | min(audioOrdinal, 0x1f)
                audioOrdinal &+= 1
            } else {
                streamID = 0xbd
            }
            let track = Track(
                info: stream,
                pid: nextPID,
                streamType: mapping.streamType,
                streamID: streamID,
                descriptor: mapping.descriptor,
                bootstrap: Self.bootstrapData(for: stream),
                isVideo: mapping.isVideo,
                isAudio: mapping.isAudio
            )
            tracksByIndex[stream.index] = track
            firstPlayablePID = firstPlayablePID ?? nextPID
            if mapping.isVideo { firstVideoPID = firstVideoPID ?? nextPID }
            nextPID &+= 1
        }
        guard let firstPlayablePID else { throw HTSPError.unsupportedStream }
        pcrPID = firstVideoPID ?? firstPlayablePID
        pendingBootstrapIndexes = Set(
            tracksByIndex.values.compactMap { track in
                track.isVideo && track.bootstrap != nil ? track.info.index : nil
            }
        )
        pendingDiscontinuityPIDs = Set(tracksByIndex.values.map(\.pid))
        pendingDiscontinuityPIDs.insert(0)
        pendingDiscontinuityPIDs.insert(pmtPID)
        // A brand-new stream has no stale VLC decoder state to flush. The
        // standard transport discontinuity is sufficient to initialize its
        // continuity counters without disrupting AAC format detection.
    }

    var supportedTrackCount: Int { tracksByIndex.count }
    var hasVideo: Bool { tracksByIndex.values.contains(where: \.isVideo) }
    var hasAudio: Bool { tracksByIndex.values.contains(where: \.isAudio) }
    var primaryVideoStreamIndex: Int? {
        tracksByIndex.values
            .filter(\.isVideo)
            .min { $0.pid < $1.pid }?
            .info.index
    }
    var primaryAudioStreamIndex: Int? {
        tracksByIndex.values
            .filter(\.isAudio)
            .min { $0.pid < $1.pid }?
            .info.index
    }
    var audioStreamTypes: [String] {
        tracksByIndex.values
            .filter(\.isAudio)
            .map(\.info.type)
            .sorted()
    }
    var startupSnapshot: MPEGTransportStreamStartupSnapshot {
        let tracks = tracksByIndex.values.sorted { $0.pid < $1.pid }
        let layout = tracks.map { track in
            let language = track.info.language.map { ":\($0)" } ?? ""
            return String(
                format: "%03x=%@%@/st%02x/sid%02x",
                track.pid,
                track.info.type,
                language,
                track.streamType,
                track.streamID
            )
        }.joined(separator: ",")
        let audioPrefixes = startupAudioPESPrefixes
            .sorted { $0.key < $1.key }
            .map { String(format: "%03x:%@", $0.key, $0.value) }
            .joined(separator: ",")
        let audioStarts = tracks.filter(\.isAudio).map { track in
            let ordinal = startupFirstAudioOrdinals[track.pid].map(String.init) ?? "?"
            let delta = startupFirstAudioTimestamps[track.pid].flatMap { audio in
                startupFirstVideoTimestamp.map { video in (audio - video) / 1_000 }
            }.map(String.init) ?? "?"
            return String(format: "%03x", track.pid) + "#\(ordinal)@\(delta)ms"
        }.joined(separator: ",")
        let timestampDelta = startupFirstVideoTimestamp.flatMap { video in
            startupFirstAudioTimestamp.map { audio in (audio - video) / 1_000 }
        }
        return MPEGTransportStreamStartupSnapshot(
            trackLayout: layout,
            packetOrder: startupPacketEvents.joined(separator: ","),
            audioVideoTimestampDeltaMilliseconds: timestampDelta,
            patPrefix: startupPATPrefix,
            pmtPrefix: startupPMTPrefix,
            audioStarts: audioStarts,
            audioPESPrefixes: audioPrefixes
        )
    }

    func isVideoStream(_ streamIndex: Int) -> Bool {
        tracksByIndex[streamIndex]?.isVideo == true
    }

    func isAudioStream(_ streamIndex: Int) -> Bool {
        tracksByIndex[streamIndex]?.isAudio == true
    }

    func resetAfterDiscontinuity() {
        timestampContinuity.beginNewEpoch()
        resetTransportState(flushesDecoders: true)
    }

    /// Resets transport state for media that will be consumed by a newly
    /// created VLC input. A fresh decoder has no stale access units to flush;
    /// injecting VLC's private discontinuity marker here makes its first
    /// audio block discontinuous and suppresses the first video PCR.
    func resetForFreshPipeline() {
        timestampContinuity = MPEGTimestampContinuity()
        resetTransportState(flushesDecoders: false)
    }

    private func resetTransportState(flushesDecoders: Bool) {
        continuity.removeAll()
        packetsSinceTables = Int.max
        pendingBootstrapIndexes = Set(
            tracksByIndex.values.compactMap { track in
                track.isVideo && track.bootstrap != nil ? track.info.index : nil
            }
        )
        pendingDiscontinuityPIDs = Set(tracksByIndex.values.map(\.pid))
        pendingDiscontinuityPIDs.insert(0)
        pendingDiscontinuityPIDs.insert(pmtPID)
        pendingDecoderFlushPIDs = flushesDecoders
            ? Set(tracksByIndex.values.map(\.pid))
            : []
    }

    func mux(_ packet: HTSPMuxPacket) -> Data {
        guard let track = tracksByIndex[packet.streamIndex] else { return Data() }
        var output = Data()
        if packetsSinceTables >= 250 {
            output.append(contentsOf: tables())
            packetsSinceTables = 0
        }

        var payload = packet.payload
        if pendingBootstrapIndexes.contains(packet.streamIndex),
           packet.frameType == Character("I").asciiValue,
           let bootstrap = track.bootstrap, !bootstrap.isEmpty {
            payload.insert(contentsOf: bootstrap, at: 0)
            pendingBootstrapIndexes.remove(packet.streamIndex)
        }

        let timestamps = timestampContinuity.normalize(
            presentationTime: packet.presentationTime,
            decodeTime: packet.decodeTime
        )
        let pts = timestamps.presentationTime ?? timestamps.decodeTime
        let dts = timestamps.decodeTime
        let pes = Self.pesPacket(
            streamID: track.streamID,
            ptsMicroseconds: pts,
            dtsMicroseconds: dts,
            payload: payload,
            unboundedLength: track.isVideo
        )
        recordStartup(
            track: track,
            packet: packet,
            timestamp: dts ?? pts,
            pes: pes
        )
        let transportPackets = packetize(
            pes,
            pid: track.pid,
            presentationUnitStart: true,
            pcrMicroseconds: track.pid == pcrPID ? (dts ?? pts) : nil,
            discontinuity: consumeDiscontinuity(for: track.pid)
        )
        output.append(transportPackets)
        packetsSinceTables += transportPackets.count / 188
        return output
    }

    func tables() -> Data {
        var result = Data()
        let patSection = Self.patSection(pmtPID: pmtPID)
        let pat = sectionPacket(
            pid: 0,
            section: patSection,
            discontinuity: consumeDiscontinuity(for: 0) != .none
        )
        result.append(pat)
        let tracks = tracksByIndex.values.sorted { $0.pid < $1.pid }
        let pmtSection = Self.pmtSection(pcrPID: pcrPID, tracks: tracks)
        let pmt = sectionPacket(
            pid: pmtPID,
            section: pmtSection,
            discontinuity: consumeDiscontinuity(for: pmtPID) != .none
        )
        result.append(pmt)
        if startupPATPrefix == "unseen" {
            startupPATPrefix = Self.hexPrefix(patSection, count: patSection.count)
            startupPMTPrefix = Self.hexPrefix(pmtSection, count: pmtSection.count)
        }
        return result
    }

    private func recordStartup(
        track: Track,
        packet: HTSPMuxPacket,
        timestamp: Int64?,
        pes: Data
    ) {
        startupMuxInputCount += 1
        if startupTimestampAnchor == nil { startupTimestampAnchor = timestamp }
        if track.isVideo {
            startupFirstVideoTimestamp = startupFirstVideoTimestamp ?? timestamp
        } else if track.isAudio {
            startupFirstAudioTimestamp = startupFirstAudioTimestamp ?? timestamp
            startupFirstAudioOrdinals[track.pid] = startupFirstAudioOrdinals[track.pid]
                ?? startupMuxInputCount
            if let timestamp {
                startupFirstAudioTimestamps[track.pid] = startupFirstAudioTimestamps[track.pid]
                    ?? timestamp
            }
            if startupAudioPESPrefixes[track.pid] == nil {
                startupAudioPESPrefixes[track.pid] = Self.hexPrefix(pes, count: 32)
            }
        }
        guard startupPacketEvents.count < 16 else { return }
        let kind = track.isVideo ? "v" : (track.isAudio ? "a" : "o")
        let delta = timestamp.flatMap { value in
            startupTimestampAnchor.map { (value - $0) / 1_000 }
        }
        let timing = delta.map { "\($0)" } ?? "?"
        startupPacketEvents.append(
            String(
                format: "%@%03x@%@/%c/%dB",
                kind,
                track.pid,
                timing,
                packet.frameType,
                packet.payload.count
            )
        )
    }

    private static func hexPrefix(_ data: Data, count: Int) -> String {
        data.prefix(count).map { String(format: "%02x", $0) }.joined()
    }

    private func sectionPacket(pid: UInt16, section: Data, discontinuity: Bool) -> Data {
        var payload = Data([0])
        payload.append(section)
        var packet = Data([0x47, UInt8(0x40 | ((pid >> 8) & 0x1f)), UInt8(pid & 0xff)])
        if discontinuity {
            packet.append(0x30 | nextContinuity(for: pid))
            let adaptationLength = 183 - payload.count
            packet.append(UInt8(adaptationLength))
            packet.append(0x80)
            if adaptationLength > 1 {
                packet.append(Data(repeating: 0xff, count: adaptationLength - 1))
            }
        } else {
            packet.append(0x10 | nextContinuity(for: pid))
        }
        packet.append(payload)
        if packet.count < 188 { packet.append(Data(repeating: 0xff, count: 188 - packet.count)) }
        return packet
    }

    private func consumeDiscontinuity(for pid: UInt16) -> Discontinuity {
        let hasTransportDiscontinuity = pendingDiscontinuityPIDs.remove(pid) != nil
        if pendingDecoderFlushPIDs.remove(pid) != nil {
            return .decoderFlush
        }
        return hasTransportDiscontinuity ? .transport : .none
    }

    private func packetize(
        _ data: Data,
        pid: UInt16,
        presentationUnitStart: Bool,
        pcrMicroseconds: Int64?,
        discontinuity: Discontinuity
    ) -> Data {
        var result = Data()
        var offset = 0
        var first = true
        while offset < data.count {
            let writesVLCDiscontinuity = first && discontinuity == .decoderFlush
            let writesTransportDiscontinuity = first && discontinuity == .transport
            // VLC requires the private marker's flags byte to be exactly 0x82,
            // so PCR cannot share this adaptation field. The next video PES
            // resumes the normal per-frame PCR cadence.
            let writesPCR = first && pcrMicroseconds != nil && !writesVLCDiscontinuity
            let requiredAdaptation = writesVLCDiscontinuity
                ? 3 + Self.vlcDiscontinuityMarker.count
                : (writesPCR ? 8 : (writesTransportDiscontinuity ? 2 : 0))
            let remaining = data.count - offset
            var payloadCount = min(184 - requiredAdaptation, remaining)
            var adaptationTotal = 184 - payloadCount
            if requiredAdaptation == 0, remaining >= 184 {
                payloadCount = 184
                adaptationTotal = 0
            } else if requiredAdaptation != 0, adaptationTotal < requiredAdaptation {
                payloadCount -= requiredAdaptation - adaptationTotal
                adaptationTotal = requiredAdaptation
            }

            var packet = Data()
            packet.append(0x47)
            packet.append(
                UInt8((first && presentationUnitStart ? 0x40 : 0) | Int((pid >> 8) & 0x1f))
            )
            packet.append(UInt8(pid & 0xff))
            packet.append((adaptationTotal > 0 ? 0x30 : 0x10) | nextContinuity(for: pid))

            if adaptationTotal > 0 {
                packet.append(UInt8(adaptationTotal - 1))
                if adaptationTotal > 1 {
                    var flags: UInt8 = 0
                    if writesVLCDiscontinuity { flags |= 0x82 }
                    if writesTransportDiscontinuity { flags |= 0x80 }
                    if writesPCR { flags |= 0x10 }
                    packet.append(flags)
                    var used = 2
                    if writesVLCDiscontinuity {
                        packet.append(UInt8(Self.vlcDiscontinuityMarker.count))
                        packet.append(Self.vlcDiscontinuityMarker)
                        used += 1 + Self.vlcDiscontinuityMarker.count
                    }
                    if writesPCR, let pcrMicroseconds {
                        packet.append(Self.pcrBytes(microseconds: pcrMicroseconds))
                        used += 6
                    }
                    if used < adaptationTotal {
                        packet.append(Data(repeating: 0xff, count: adaptationTotal - used))
                    }
                }
            }

            packet.append(data[offset..<(offset + payloadCount)])
            if packet.count < 188 { packet.append(Data(repeating: 0xff, count: 188 - packet.count)) }
            result.append(packet)
            offset += payloadCount
            first = false
        }
        return result
    }

    private func nextContinuity(for pid: UInt16) -> UInt8 {
        let current = continuity[pid, default: 0]
        continuity[pid] = (current + 1) & 0x0f
        return current
    }

    private static func pesPacket(
        streamID: UInt8,
        ptsMicroseconds: Int64?,
        dtsMicroseconds: Int64?,
        payload: Data,
        unboundedLength: Bool
    ) -> Data {
        let hasDistinctDTS = ptsMicroseconds != nil && dtsMicroseconds != nil && ptsMicroseconds != dtsMicroseconds
        let headerDataLength = ptsMicroseconds == nil ? 0 : (hasDistinctDTS ? 10 : 5)
        let boundedLength = 3 + headerDataLength + payload.count
        let packetLength: UInt16 = unboundedLength || boundedLength > Int(UInt16.max)
            ? 0
            : UInt16(boundedLength)

        var result = Data([0, 0, 1, streamID, UInt8(packetLength >> 8), UInt8(packetLength & 0xff), 0x80])
        result.append(ptsMicroseconds == nil ? 0 : (hasDistinctDTS ? 0xc0 : 0x80))
        result.append(UInt8(headerDataLength))
        if let ptsMicroseconds {
            let pts = timestamp90k(from: ptsMicroseconds)
            result.append(timestampBytes(pts, prefix: hasDistinctDTS ? 0x3 : 0x2))
            if hasDistinctDTS, let dtsMicroseconds {
                result.append(timestampBytes(timestamp90k(from: dtsMicroseconds), prefix: 0x1))
            }
        }
        result.append(payload)
        return result
    }

    private static func timestamp90k(from microseconds: Int64) -> UInt64 {
        UInt64(max(0, microseconds)) * 90 / 1_000
    }

    private static func timestampBytes(_ timestamp: UInt64, prefix: UInt8) -> Data {
        let value = timestamp & 0x1ffffffff
        let markerAndPrefix = UInt8(
            (UInt64(prefix) << 4) | (((value >> 30) & 0x07) << 1) | 1
        )
        let high = UInt8((value >> 22) & 0xff)
        let middleMarker = UInt8((((value >> 15) & 0x7f) << 1) | 1)
        let low = UInt8((value >> 7) & 0xff)
        let lowMarker = UInt8(((value & 0x7f) << 1) | 1)
        return Data([markerAndPrefix, high, middleMarker, low, lowMarker])
    }

    private static func pcrBytes(microseconds: Int64) -> Data {
        let base = timestamp90k(from: microseconds) & 0x1ffffffff
        return Data([
            UInt8((base >> 25) & 0xff),
            UInt8((base >> 17) & 0xff),
            UInt8((base >> 9) & 0xff),
            UInt8((base >> 1) & 0xff),
            UInt8(((base & 1) << 7) | 0x7e),
            0,
        ])
    }

    private static func patSection(pmtPID: UInt16) -> Data {
        var section = Data([
            0x00, 0xb0, 0x0d,
            0x00, 0x01,
            0xc1, 0x00, 0x00,
            0x00, 0x01,
            UInt8(0xe0 | ((pmtPID >> 8) & 0x1f)), UInt8(pmtPID & 0xff),
        ])
        appendCRC(to: &section)
        return section
    }

    private static func pmtSection(pcrPID: UInt16, tracks: [Track]) -> Data {
        var body = Data([
            0x00, 0x01,
            0xc1, 0x00, 0x00,
            UInt8(0xe0 | ((pcrPID >> 8) & 0x1f)), UInt8(pcrPID & 0xff),
            0xf0, 0x00,
        ])
        for track in tracks {
            body.append(track.streamType)
            body.append(UInt8(0xe0 | ((track.pid >> 8) & 0x1f)))
            body.append(UInt8(track.pid & 0xff))
            body.append(UInt8(0xf0 | ((track.descriptor.count >> 8) & 0x0f)))
            body.append(UInt8(track.descriptor.count & 0xff))
            body.append(track.descriptor)
        }
        let sectionLength = body.count + 4
        var section = Data([
            0x02,
            UInt8(0xb0 | ((sectionLength >> 8) & 0x0f)),
            UInt8(sectionLength & 0xff),
        ])
        section.append(body)
        appendCRC(to: &section)
        return section
    }

    private static func appendCRC(to data: inout Data) {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x80000000) != 0
                    ? (crc << 1) ^ 0x04c11db7
                    : crc << 1
            }
        }
        data.append(UInt8((crc >> 24) & 0xff))
        data.append(UInt8((crc >> 16) & 0xff))
        data.append(UInt8((crc >> 8) & 0xff))
        data.append(UInt8(crc & 0xff))
    }

    private static func mapping(
        for stream: HTSPStreamInfo
    ) -> (streamType: UInt8, descriptor: Data, isVideo: Bool, isAudio: Bool)? {
        switch stream.type.uppercased() {
        case "MPEG2VIDEO": return (0x02, Data(), true, false)
        case "H264": return (0x1b, Data(), true, false)
        case "HEVC": return (0x24, Data(), true, false)
        case "MPEG2AUDIO": return (0x03, languageDescriptor(stream.language), false, true)
        case "AAC": return (0x0f, languageDescriptor(stream.language), false, true)
        case "AC3": return (0x06, Data([0x6a, 0x00]) + languageDescriptor(stream.language), false, true)
        case "EAC3": return (0x06, Data([0x7a, 0x00]) + languageDescriptor(stream.language), false, true)
        case "DVBSUB":
            let language = languageCode(stream.language)
            return (0x06, Data([0x59, 0x08]) + language + Data([0x10, 0, 1, 0, 1]), false, false)
        case "TELETEXT":
            let language = languageCode(stream.language)
            return (0x06, Data([0x56, 0x05]) + language + Data([0x10, 0x00]), false, false)
        default: return nil
        }
    }

    private static func languageDescriptor(_ language: String?) -> Data {
        guard language != nil else { return Data() }
        return Data([0x0a, 0x04]) + languageCode(language) + Data([0])
    }

    private static func languageCode(_ language: String?) -> Data {
        var bytes = Array((language ?? "und").lowercased().utf8.prefix(3))
        while bytes.count < 3 { bytes.append(UInt8(ascii: "d")) }
        return Data(bytes)
    }

    private static func bootstrapData(for stream: HTSPStreamInfo) -> Data? {
        guard let metadata = stream.metadata, !metadata.isEmpty else { return nil }
        if metadata.starts(with: [0, 0, 0, 1]) || metadata.starts(with: [0, 0, 1]) {
            return metadata
        }
        switch stream.type.uppercased() {
        case "H264": return annexBFromAVCConfiguration(metadata)
        case "HEVC": return annexBFromHEVCConfiguration(metadata)
        default: return metadata
        }
    }

    private static func annexBFromAVCConfiguration(_ data: Data) -> Data? {
        guard data.count >= 7, data[0] == 1 else { return nil }
        var offset = 6
        var output = Data()
        let spsCount = Int(data[5] & 0x1f)
        for _ in 0..<spsCount {
            guard offset + 2 <= data.count else { return nil }
            let length = Int(data[offset]) << 8 | Int(data[offset + 1])
            offset += 2
            guard offset + length <= data.count else { return nil }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(data[offset..<(offset + length)])
            offset += length
        }
        guard offset < data.count else { return output }
        let ppsCount = Int(data[offset])
        offset += 1
        for _ in 0..<ppsCount {
            guard offset + 2 <= data.count else { return nil }
            let length = Int(data[offset]) << 8 | Int(data[offset + 1])
            offset += 2
            guard offset + length <= data.count else { return nil }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(data[offset..<(offset + length)])
            offset += length
        }
        return output
    }

    private static func annexBFromHEVCConfiguration(_ data: Data) -> Data? {
        guard data.count >= 23, data[0] == 1 else { return nil }
        var offset = 23
        var output = Data()
        let arrayCount = Int(data[22])
        for _ in 0..<arrayCount {
            guard offset + 3 <= data.count else { return nil }
            offset += 1
            let count = Int(data[offset]) << 8 | Int(data[offset + 1])
            offset += 2
            for _ in 0..<count {
                guard offset + 2 <= data.count else { return nil }
                let length = Int(data[offset]) << 8 | Int(data[offset + 1])
                offset += 2
                guard offset + length <= data.count else { return nil }
                output.append(contentsOf: [0, 0, 0, 1])
                output.append(data[offset..<(offset + length)])
                offset += length
            }
        }
        return output
    }
}

private extension Character {
    var asciiValue: UInt8 { String(self).utf8.first ?? 0 }
}
