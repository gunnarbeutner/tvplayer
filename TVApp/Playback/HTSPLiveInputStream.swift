import Foundation
import OSLog

enum HTSPStreamLifecycleEvent: Equatable, Sendable {
    case reconnecting(reason: String, attempt: Int)
    case readyAfterRecovery
    case terminalFailure(String)
}

/// A single-use view of the long-lived HTSP byte source. VLC owns and closes
/// this object; the underlying subscription is owned by `HTSPLiveInputStream`.
private final class HTSPLiveReaderInputStream: InputStream, @unchecked Sendable {
    private weak var source: HTSPLiveInputStream?
    private let generation: Int
    private let lock = NSLock()
    private var status: Stream.Status = .notOpen

    init(source: HTSPLiveInputStream, generation: Int) {
        self.source = source
        self.generation = generation
        super.init(data: Data())
    }

    override var streamStatus: Stream.Status { lock.withLock { status } }
    override var streamError: Error? { source?.streamError }
    override var hasBytesAvailable: Bool { source?.hasBytesAvailable ?? false }

    override func open() {
        lock.withLock {
            guard status == .notOpen else { return }
            status = .open
        }
        source?.open()
    }

    override func close() {
        let shouldClose = lock.withLock {
            guard status != .closed else { return false }
            status = .closed
            return true
        }
        if shouldClose { source?.closeVLCReader(generation: generation) }
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard lock.withLock({ status == .open }) else { return 0 }
        return source?.readForVLC(buffer, maxLength: len, generation: generation) ?? 0
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool {
        false
    }
}

struct HTSPStreamHealthSnapshot: Equatable, Sendable {
    let isRecovering: Bool
    let isNavigating: Bool
    let desiredSpeed: Int32
    let lastMuxPacketAt: Date?
    let expectsVideo: Bool
    let expectsAudio: Bool
    let videoPacketCount: Int64
    let videoPayloadBytes: Int64
    let firstVideoPacketAt: Date?
    let lastVideoPacketAt: Date?
    let audioPacketCount: Int64
    let audioPayloadBytes: Int64
    let firstAudioPacketAt: Date?
    let lastAudioPacketAt: Date?
    let audioStreamTypes: [String]
    let transportStartup: MPEGTransportStreamStartupSnapshot
}

private enum HTSPStreamFailure: LocalizedError {
    case packetStalled

    var errorDescription: String? {
        "TVHeadend delivered no stream packets for 10 seconds."
    }
}

final class HTSPLiveInputStream: InputStream, NativeTimeshiftCommandSink, @unchecked Sendable {
    private static let maximumQueuedBytes = 8 * 1_024 * 1_024
    private static let controlResponseTimeout: TimeInterval = 5
    private static let fastPrebufferSpeed: Int32 = 400
    private static let fastPrebufferLiveEdgeMargin: TimeInterval = 0.5

    private struct PendingControlRequest {
        let method: String
        let connectionGeneration: Int
        let succeeded: @Sendable () -> Void
        let failed: @Sendable (Error) -> Void
    }

    private struct BufferedNavigationCompletion {
        let handler: (@Sendable (
            Result<HTSPNavigationResult, HTSPNavigationError>
        ) -> Void)?
        let result: HTSPNavigationResult
        let diagnostics: String
    }

    private struct ReadyPostSeekDelivery {
        let batch: HTSPPostSeekPacketStager.Batch
        let epoch: UInt64
        let navigationGeneration: Int
        let handler: (@Sendable (
            Result<HTSPNavigationResult, HTSPNavigationError>
        ) -> Void)?
        let result: HTSPNavigationResult
        let diagnostics: String
        let primaryVideoStreamIndex: Int?
        let primaryAudioStreamIndex: Int?
    }

    private struct ReadyInitialTuneDelivery {
        let batch: HTSPPostSeekPacketStager.Batch
        let trailingPacket: HTSPMuxPacket?
        let epoch: UInt64
        let primaryVideoStreamIndex: Int?
        let primaryAudioStreamIndex: Int?
        let diagnostics: String
        let flushesExistingDecoder: Bool
    }

    private enum MuxPacketDisposition {
        case drop
        case live
        case staged
        case initialTuneFailure(reason: String, epoch: UInt64)
        case flushInitialTune(ReadyInitialTuneDelivery)
        case flush(ReadyPostSeekDelivery)
        case interleaved(packets: [HTSPMuxPacket], epoch: UInt64, fellBack: Bool)
        case stagingOverflow(navigationGeneration: Int)
    }

    private enum InitialTunePublishResult {
        case published
        case stale
        case failed
    }

    private let configuration: TVHeadendConfiguration
    private let channelID: UInt32
    private let profile: String
    private let vlcCacheDuration: Int64
    private let connectionLock = NSLock()
    private var connection: any HTSPConnectionTransport
    private var connectionGeneration = 0
    private let connectionFactory: HTSPConnectionFactory
    private let condition = NSCondition()
    private let processLock = NSLock()
    private let deliveryGate = HTSPTimeshiftDeliveryGate()
    private let controlQueue = DispatchQueue(
        label: "de.beutner.TVPlayer.htsp-control",
        qos: .userInitiated
    )
    private let logger = Logger(subsystem: "de.beutner.TVPlayer", category: "HTSP")
    private var muxer: MPEGTransportStreamMuxer
    private var buffer = Data()
    private var readOffset = 0
    private var currentStatus: Stream.Status = .notOpen
    private var currentError: Error?
    private var stopped = false
    private var vlcReaderGeneration = 0
    private var receiverThread: Thread?
    private var currentLiveDelay: TimeInterval = 0
    private var currentWindow: TimeInterval = 0
    private var currentBufferStart: Date?
    private var timelineEpoch: Date?
    private var lastMuxPacketAt: Date?
    private var videoPacketCount: Int64 = 0
    private var videoPayloadBytes: Int64 = 0
    private var firstVideoPacketAt: Date?
    private var lastVideoPacketAt: Date?
    private var audioPacketCount: Int64 = 0
    private var audioPayloadBytes: Int64 = 0
    private var firstAudioPacketAt: Date?
    private var lastAudioPacketAt: Date?
    private var subscriptionReadyAt = Date()
    private var recovering = false
    private var recoveryWaitsForVideoKeyframe = false
    private var desiredPlaybackSpeed: Int32 = 100
    private var lifecycleHandler: (@Sendable (HTSPStreamLifecycleEvent) -> Void)?
    private var navigationCompletionHandler: (
        @Sendable (Result<HTSPNavigationResult, HTSPNavigationError>) -> Void
    )?
    private var initialTunePacketStager = HTSPInitialTunePacketStager()
    private var initialTuneFlushesExistingDecoder = false
    private var postSeekBuffer = HTSPPostSeekBufferTracker()
    private var postSeekPacketStager = HTSPPostSeekPacketStager()
    private var postSeekTailInterleaver: HTSPPostSeekTailInterleaver?
    private var hasInitialTuneTailInterleaver = false
    private var postSeekStagingEpoch: UInt64 = 0
    private var postSeekNavigationGeneration = 0
    private var postSeekPrimaryVideoStreamIndex: Int?
    private var postSeekPrimaryAudioStreamIndex: Int?

    // Accessed only from controlQueue.
    private var pendingControlRequests: [Int64: PendingControlRequest] = [:]
    private var seekCoordinator = HTSPAbsoluteSeekCoordinator()
    private var speedController = HTSPSubscriptionSpeedController()
    private var seekRPCAccepted = false
    private var asynchronousLandingTime: Int64?
    private var activeSeekSequence: Int64?
    private var pendingLiveCommand = false
    private var navigationCommandInFlight = false
    private var navigationAcceptsLiveEdge = false
    private var navigationTargetsLiveEdge = false
    private var navigationGeneration = 0
    private var bufferedNavigationCompletion: BufferedNavigationCompletion?
    let acceptedTimeshiftPeriod: TimeInterval

    private init(
        configuration: TVHeadendConfiguration,
        channelID: UInt32,
        profile: String,
        connection: any HTSPConnectionTransport,
        connectionFactory: @escaping HTSPConnectionFactory,
        streams: [HTSPStreamInfo],
        acceptedTimeshiftPeriod: TimeInterval,
        vlcCacheMilliseconds: Int
    ) throws {
        self.configuration = configuration
        self.channelID = channelID
        self.profile = profile
        self.connection = connection
        self.connectionFactory = connectionFactory
        muxer = try MPEGTransportStreamMuxer(streams: streams)
        self.acceptedTimeshiftPeriod = acceptedTimeshiftPeriod
        vlcCacheDuration = Int64(max(0, vlcCacheMilliseconds)) * 1_000
        super.init(data: Data())
        beginInitialTunePacketStaging()
    }

    static func connect(
        configuration: TVHeadendConfiguration,
        channelID: UInt32,
        profile: String,
        vlcCacheMilliseconds: Int = 1_500,
        connectionFactory suppliedFactory: HTSPConnectionFactory? = nil
    ) async throws -> HTSPLiveInputStream {
        guard let host = configuration.baseURL?.host else { throw HTSPError.invalidHost }
        let connectionFactory: HTSPConnectionFactory = suppliedFactory ?? {
            try HTSPConnection.openSynchronously(host: host, port: configuration.htspPort)
        }
        let preconnected: (any HTSPConnectionTransport)?
        if suppliedFactory == nil {
            preconnected = await HTSPConnectionPrewarmer.shared.takeConnection(
                configuration: configuration
            )
        } else {
            preconnected = nil
        }
        let connected = try await Task.detached(priority: .userInitiated) {
            if let preconnected {
#if DEBUG
                print("HTSP_PRECONNECT using authenticated idle connection")
                fflush(stdout)
#endif
                do {
                    let subscription = try preconnected.subscribe(
                        channelID: channelID,
                        profile: profile
                    )
                    return (preconnected, subscription)
                } catch {
                    // An idle socket may be closed by the server before Play.
                    // Fall through to the normal fresh connection path.
#if DEBUG
                    print("HTSP_PRECONNECT idle connection failed; opening a fresh connection")
                    fflush(stdout)
#endif
                    preconnected.close()
                }
            }
            let connection = try connectionFactory()
            try connection.handshake(username: configuration.username, password: configuration.password)
            guard connection.capabilities.contains("timeshift") else {
                throw HTSPError.timeshiftUnavailable
            }
            let subscription = try connection.subscribe(channelID: channelID, profile: profile)
            return (connection, subscription)
        }.value
        let stream = try HTSPLiveInputStream(
            configuration: configuration,
            channelID: channelID,
            profile: profile,
            connection: connected.0,
            connectionFactory: connectionFactory,
            streams: connected.1.1,
            acceptedTimeshiftPeriod: TimeInterval(connected.1.0),
            vlcCacheMilliseconds: vlcCacheMilliseconds
        )
        return stream
    }

    override var streamStatus: Stream.Status {
        condition.withLock { currentStatus }
    }

    override var streamError: Error? {
        condition.withLock { currentError }
    }

    override var hasBytesAvailable: Bool {
        condition.withLock { readOffset < buffer.count }
    }

    var liveDelaySeconds: TimeInterval {
        condition.withLock { currentLiveDelay }
    }

    var timeshiftWindowSeconds: TimeInterval {
        condition.withLock { currentWindow }
    }

    var bufferStartedAt: Date? {
        condition.withLock { currentBufferStart }
    }

    var queuedByteCount: Int64 {
        condition.withLock { Int64(max(0, buffer.count - readOffset)) }
    }

    var isNavigatingTimeshift: Bool {
        !deliveryGate.shouldDeliverPackets || condition.withLock { postSeekBuffer.result != nil }
    }

    var healthSnapshot: HTSPStreamHealthSnapshot {
        let navigating = !deliveryGate.shouldDeliverPackets
        let streamInfo = processLock.withLock {
            (
                expectsVideo: muxer.hasVideo,
                expectsAudio: muxer.hasAudio,
                audioStreamTypes: muxer.audioStreamTypes,
                transportStartup: muxer.startupSnapshot
            )
        }
        return condition.withLock {
            HTSPStreamHealthSnapshot(
                isRecovering: recovering,
                isNavigating: navigating || postSeekBuffer.result != nil,
                desiredSpeed: desiredPlaybackSpeed,
                lastMuxPacketAt: lastMuxPacketAt,
                expectsVideo: streamInfo.expectsVideo,
                expectsAudio: streamInfo.expectsAudio,
                videoPacketCount: videoPacketCount,
                videoPayloadBytes: videoPayloadBytes,
                firstVideoPacketAt: firstVideoPacketAt,
                lastVideoPacketAt: lastVideoPacketAt,
                audioPacketCount: audioPacketCount,
                audioPayloadBytes: audioPayloadBytes,
                firstAudioPacketAt: firstAudioPacketAt,
                lastAudioPacketAt: lastAudioPacketAt,
                audioStreamTypes: streamInfo.audioStreamTypes,
                transportStartup: streamInfo.transportStartup
            )
        }
    }

    /// Creates a disposable VLC-facing reader without transferring ownership
    /// of the HTSP subscription. Replacing this reader flushes VLC's private
    /// demux/decoder queues while the server-side timeshift session survives.
    func makeVLCReader() -> InputStream {
        let generation = condition.withLock {
            vlcReaderGeneration += 1
            condition.broadcast()
            return vlcReaderGeneration
        }
        return HTSPLiveReaderInputStream(source: self, generation: generation)
    }

    func setLifecycleHandler(
        _ handler: (@Sendable (HTSPStreamLifecycleEvent) -> Void)?
    ) {
        condition.withLock { lifecycleHandler = handler }
    }

    func setNavigationCompletionHandler(
        _ handler: (@Sendable (Result<HTSPNavigationResult, HTSPNavigationError>) -> Void)?
    ) {
        condition.withLock { navigationCompletionHandler = handler }
    }

    override func open() {
        condition.lock()
        guard currentStatus == .notOpen else {
            condition.unlock()
            return
        }
        currentStatus = .open
        condition.unlock()

        let thread = Thread { [weak self] in
            self?.receiveLoop()
        }
        thread.name = "TVHeadend HTSP receiver"
        thread.qualityOfService = .userInitiated
        receiverThread = thread
        thread.start()
    }

    override func close() {
        condition.lock()
        guard !stopped else {
            condition.unlock()
            return
        }
        stopped = true
        currentStatus = .closed
        postSeekBuffer.cancel()
        cancelPostSeekPacketStagingLocked()
        condition.broadcast()
        condition.unlock()

        receiverThread?.cancel()
        receiverThread = nil
        deliveryGate.cancelAllNavigation()
        currentConnection().connection.close()
    }

    func play() {
        let canSend = condition.withLock {
            if desiredPlaybackSpeed <= 0 {
                // A long intentional pause must not count toward the packet
                // stall timeout once delivery is requested again.
                lastMuxPacketAt = nil
                subscriptionReadyAt = Date()
            }
            desiredPlaybackSpeed = 100
            return !recovering
        }
        guard canSend, !isNavigatingTimeshift else { return }
        enqueueSpeed(100)
    }

    func pause() {
        let canSend = condition.withLock {
            desiredPlaybackSpeed = 0
            return !recovering
        }
        guard canSend else { return }
        enqueueSpeed(0)
    }

    func seek(by seconds: TimeInterval) {
        guard seconds != 0, !condition.withLock({ recovering }) else { return }
        beginNavigation()
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.pendingLiveCommand = false
            if let target = self.seekCoordinator.requestRelative(seconds: seconds) {
                self.sendSeekWhenPaused(to: target)
            } else if self.seekCoordinator.inFlightTarget == nil {
                self.schedulePendingNavigationTimeout()
            }
        }
    }

    func returnToLive() {
        guard !condition.withLock({ recovering }) else { return }
        beginNavigation()
        controlQueue.async { [weak self] in
            guard let self else { return }
            // Prefer an absolute seek to the known live-edge timestamp. Some
            // TVHeadend versions can flood stale packets after
            // subscriptionLive, which makes VLC fail and resets this session's
            // timeshift buffer. A rejected absolute live-edge seek is still
            // retried with subscriptionLive by recoverRejectedLiveEdgeSeek().
            self.pendingLiveCommand = false
            if let target = self.seekCoordinator.requestLiveEdge() {
                self.sendSeekWhenPaused(to: target)
            } else if self.seekCoordinator.inFlightTarget == nil {
                self.schedulePendingNavigationTimeout()
            }
        }
    }

    override func read(_ output: UnsafeMutablePointer<UInt8>, maxLength length: Int) -> Int {
        guard length > 0 else { return 0 }
        condition.lock()
        while !stopped, currentError == nil, readOffset >= buffer.count {
            condition.wait()
        }
        if stopped {
            condition.unlock()
            return 0
        }
        if currentError != nil {
            currentStatus = .error
            condition.unlock()
            return -1
        }

        let count = min(length, buffer.count - readOffset)
        buffer.copyBytes(to: output, from: readOffset..<(readOffset + count))
        readOffset += count
        if readOffset >= 1 * 1_024 * 1_024 {
            buffer.removeSubrange(0..<readOffset)
            readOffset = 0
        }
        condition.broadcast()
        condition.unlock()
        return count
    }

    fileprivate func readForVLC(
        _ output: UnsafeMutablePointer<UInt8>,
        maxLength length: Int,
        generation: Int
    ) -> Int {
        guard length > 0 else { return 0 }
        condition.lock()
        while !stopped,
              currentError == nil,
              generation == vlcReaderGeneration,
              readOffset >= buffer.count {
            condition.wait()
        }
        guard !stopped, generation == vlcReaderGeneration else {
            condition.unlock()
            return 0
        }
        if currentError != nil {
            condition.unlock()
            return -1
        }

        let count = min(length, buffer.count - readOffset)
        buffer.copyBytes(to: output, from: readOffset..<(readOffset + count))
        readOffset += count
        if readOffset >= 1 * 1_024 * 1_024 {
            buffer.removeSubrange(0..<readOffset)
            readOffset = 0
        }
        condition.broadcast()
        condition.unlock()
        return count
    }

    fileprivate func closeVLCReader(generation: Int) {
        condition.withLock {
            if vlcReaderGeneration == generation {
                vlcReaderGeneration += 1
            }
            condition.broadcast()
        }
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool {
        false
    }

    private func receiveLoop() {
        while !Thread.current.isCancelled {
            let active = currentConnection()
            do {
                let message = try active.connection.readMessage()
                try process(message, connectionGeneration: active.generation)
                if shouldRecoverForPacketStall(at: Date()) {
                    throw HTSPStreamFailure.packetStalled
                }
            } catch HTSPError.readTimedOut {
                guard shouldRecoverForPacketStall(at: Date()) else { continue }
                guard recoverConnection(after: HTSPStreamFailure.packetStalled) else { return }
            } catch {
                guard !condition.withLock({ stopped }) else { return }
                guard recoverConnection(after: error) else { return }
            }
        }
    }

    private func process(
        _ message: [String: HTSPValue],
        connectionGeneration: Int
    ) throws {
        if let sequence = message["seq"]?.intValue {
            controlQueue.async { [weak self] in
                self?.handleControlResponse(
                    message,
                    sequence: sequence,
                    connectionGeneration: connectionGeneration
                )
            }
            return
        }

        switch message["method"]?.stringValue {
        case "muxpkt":
            guard let streamIndex = message["stream"]?.intValue,
                  let payload = message["payload"]?.dataValue
            else { throw HTSPCodecError.malformedMessage }
            let durationMicroseconds = message["duration"]?.intValue.flatMap { duration in
                (0...Int64(UInt32.max)).contains(duration) ? duration : nil
            }
            let packet = HTSPMuxPacket(
                streamIndex: Int(streamIndex),
                frameType: UInt8(truncatingIfNeeded: message["frametype"]?.intValue ?? 0),
                presentationTime: message["pts"]?.intValue,
                decodeTime: message["dts"]?.intValue,
                durationMicroseconds: durationMicroseconds,
                payload: payload
            )
            let trackKind = processLock.withLock {
                (
                    isVideo: muxer.isVideoStream(packet.streamIndex),
                    isAudio: muxer.isAudioStream(packet.streamIndex)
                )
            }
            let receiptDate = Date()
            condition.withLock {
                lastMuxPacketAt = receiptDate
                if trackKind.isVideo {
                    videoPacketCount += 1
                    videoPayloadBytes += Int64(payload.count)
                    firstVideoPacketAt = firstVideoPacketAt ?? receiptDate
                    lastVideoPacketAt = receiptDate
                } else if trackKind.isAudio {
                    audioPacketCount += 1
                    audioPayloadBytes += Int64(payload.count)
                    firstAudioPacketAt = firstAudioPacketAt ?? receiptDate
                    lastAudioPacketAt = receiptDate
                }
            }
            guard deliveryGate.shouldDeliverPackets else { return }
            let recoveryAcceptsPacket = condition.withLock {
                guard recovering, recoveryWaitsForVideoKeyframe else { return true }
                if initialTunePacketStager.isActive { return true }
                guard trackKind.isVideo, packet.frameType == Character("I").asciiValue else {
                    return false
                }
                recoveryWaitsForVideoKeyframe = false
                return true
            }
            guard recoveryAcceptsPacket else { return }
            var publishedInitialTuneEpoch: UInt64?
            switch routeMuxPacket(
                packet,
                isVideo: trackKind.isVideo,
                isAudio: trackKind.isAudio
            ) {
            case .drop:
                return
            case .live:
                let transportData = processLock.withLock { muxer.mux(packet) }
                appendIfDeliveryIsOpen(transportData)
            case .staged:
                break
            case let .initialTuneFailure(reason, epoch):
                guard condition.withLock({
                    epoch == postSeekStagingEpoch
                        && !stopped
                        && currentError == nil
                        && deliveryGate.shouldDeliverPackets
                }) else { return }
                throw HTSPError.server(reason)
            case let .flushInitialTune(completion):
                switch publishInitialTuneBatch(completion) {
                case .published:
                    publishedInitialTuneEpoch = completion.epoch
                case .stale:
                    return
                case .failed:
                    throw HTSPError.server("The initial live A/V buffer could not be published.")
                }
            case let .flush(completion):
                guard publishPostSeekBatch(completion) else {
                    controlQueue.async { [weak self] in
                        guard let self,
                              self.navigationGeneration == completion.navigationGeneration
                        else { return }
                        self.failNavigation(
                            .controlFailed("Post-seek media could not be published.")
                        )
                    }
                    return
                }
                controlQueue.async { [weak self] in
                    guard let self,
                          self.navigationGeneration == completion.navigationGeneration
                    else { return }
                    self.finishPostSeekBuffering(
                        handler: completion.handler,
                        result: completion.result,
                        diagnostics: completion.diagnostics
                    )
                }
            case let .interleaved(packets, epoch, fellBack):
                muxAndAppendInterleavedPackets(packets, stagingEpoch: epoch)
                if fellBack {
                    benchmarkTrace(
                        "A/V tail interleave reached its payload bound; "
                            + "flushed in per-stream order"
                    )
                }
            case let .stagingOverflow(navigationGeneration):
                controlQueue.async { [weak self] in
                    guard let self,
                          self.navigationGeneration == navigationGeneration
                    else { return }
                    self.failNavigation(
                        .controlFailed("Post-seek media exceeded the staging limit.")
                    )
                }
                return
            }
            finishRecoveryAfterFirstDecodablePacketIfNeeded(
                publishedInitialTuneEpoch: publishedInitialTuneEpoch
            )

        case "timeshiftStatus":
            let metrics = HTSPTimeshiftMetrics.decode(from: message)
            let receiptDate = Date()
            condition.withLock {
                currentLiveDelay = metrics.liveDelay
                currentWindow = metrics.window
                if timelineEpoch == nil, let endTime = metrics.endTime {
                    timelineEpoch = receiptDate.addingTimeInterval(
                        -TimeInterval(endTime) / 1_000_000
                    )
                }
                if let timelineEpoch, let startTime = metrics.startTime {
                    currentBufferStart = timelineEpoch.addingTimeInterval(
                        TimeInterval(startTime) / 1_000_000
                    )
                } else {
                    currentBufferStart = nil
                }
            }
            let updatesCurrentPosition = !isNavigatingTimeshift
            controlQueue.async { [weak self] in
                guard let self else { return }
                if let target = self.seekCoordinator.update(
                    metrics: metrics,
                    updateCurrentPosition: updatesCurrentPosition
                ), !self.pendingLiveCommand, !self.navigationAcceptsLiveEdge {
                    self.sendSeekWhenPaused(to: target)
                }
            }

        case "subscriptionStart":
            let streams = HTSPStreamInfo.decodeList(message["streams"])
            let replacement = try MPEGTransportStreamMuxer(streams: streams)
            processLock.withLock { muxer = replacement }
            clearDeliveryQueue()
            if replacement.hasVideo,
               replacement.primaryVideoStreamIndex != nil,
               replacement.primaryAudioStreamIndex != nil {
                beginInitialTunePacketStaging(flushesExistingDecoder: true)
            } else {
                processLock.withLock { muxer.resetAfterDiscontinuity() }
            }

        case "subscriptionSkip":
            controlQueue.async { [weak self] in self?.handleSubscriptionSkip(message) }

        case "subscriptionSpeed":
            guard let speed = message["speed"]?.intValue else { return }
            controlQueue.async { [weak self] in
                guard let self else { return }
                if let command = self.speedController.observeActual(Int32(clamping: speed)) {
                    self.sendSpeed(command)
                }
                self.completeBufferedNavigationAtNormalSpeedIfReady()
                self.sendPendingNavigationIfPaused()
            }

        case "subscriptionStop":
            let message = message["status"]?.stringValue ?? "TVHeadend stopped the HTSP stream."
            throw HTSPError.server(message)

        default:
            break
        }
    }

    private func routeMuxPacket(
        _ packet: HTSPMuxPacket,
        isVideo: Bool,
        isAudio: Bool
    ) -> MuxPacketDisposition {
        let packetTime = packet.presentationTime ?? packet.decodeTime
        condition.lock()
        guard deliveryGate.shouldDeliverPackets else {
            condition.unlock()
            return .drop
        }
        if initialTunePacketStager.isActive {
            switch initialTunePacketStager.append(
                packet,
                isVideo: isVideo,
                isAudio: isAudio
            ) {
            case .passthrough:
                break
            case .waiting:
                condition.unlock()
                return .staged
            case let .ready(
                batch,
                primaryVideoStreamIndex,
                primaryAudioStreamIndex,
                diagnostics
            ):
                if recovering { recoveryWaitsForVideoKeyframe = false }
                let completion = ReadyInitialTuneDelivery(
                    batch: batch,
                    trailingPacket: nil,
                    epoch: postSeekStagingEpoch,
                    primaryVideoStreamIndex: primaryVideoStreamIndex,
                    primaryAudioStreamIndex: primaryAudioStreamIndex,
                    diagnostics: diagnostics,
                    flushesExistingDecoder: initialTuneFlushesExistingDecoder
                )
                condition.unlock()
                return .flushInitialTune(completion)
            case let .overflow(
                batch,
                trailingPacket,
                containsPrimaryAudio,
                diagnostics
            ):
                let fallbackContainsKeyframe = batch.containsInitialVideoKeyframe
                    || (trailingPacket?.frameType == 0x49 && isVideo)
                if recovering, (!fallbackContainsKeyframe || !containsPrimaryAudio) {
                    let epoch = postSeekStagingEpoch
                    condition.unlock()
                    return .initialTuneFailure(
                        reason: "Initial A/V alignment could not be established during recovery.",
                        epoch: epoch
                    )
                }
                if recovering { recoveryWaitsForVideoKeyframe = false }
                let completion = ReadyInitialTuneDelivery(
                    batch: batch,
                    trailingPacket: trailingPacket,
                    epoch: postSeekStagingEpoch,
                    // Timestamp coverage was not established. Publish the
                    // bounded FIFO fallback instead of retaining a tail whose
                    // common A/V watermark may never become knowable.
                    primaryVideoStreamIndex: nil,
                    primaryAudioStreamIndex: nil,
                    diagnostics: diagnostics,
                    flushesExistingDecoder: initialTuneFlushesExistingDecoder
                )
                condition.unlock()
                return .flushInitialTune(completion)
            case let .failure(reason):
                let epoch = postSeekStagingEpoch
                condition.unlock()
                return .initialTuneFailure(reason: reason, epoch: epoch)
            }
        }
        guard postSeekBuffer.shouldAcceptPacket(
            time: packetTime,
            decodeTime: packet.decodeTime,
            duration: packet.durationMicroseconds,
            isVideo: isVideo,
            isAudio: isAudio,
            frameType: packet.frameType
        ) else {
            condition.unlock()
            return .drop
        }
        guard postSeekPacketStager.isActive else {
            guard var interleaver = postSeekTailInterleaver else {
                condition.unlock()
                return .live
            }
            interleaver.append(packet)
            var packets = interleaver.drainAvailable()
            // A catch-up packet can open the common watermark and release a
            // large tail. Measure the cap after that normal drain so it does
            // not force an avoidable, unbalanced full flush.
            let fellBack = interleaver.hasExceededPayloadLimit
            if fellBack { packets.append(contentsOf: interleaver.drainAll()) }
            let retiresInitialTail = hasInitialTuneTailInterleaver && interleaver.isEmpty
            if fellBack || retiresInitialTail {
                postSeekTailInterleaver = nil
                hasInitialTuneTailInterleaver = false
            } else {
                postSeekTailInterleaver = interleaver
            }
            let epoch = postSeekStagingEpoch
            condition.unlock()
            return packets.isEmpty
                ? .staged
                : .interleaved(packets: packets, epoch: epoch, fellBack: fellBack)
        }
        guard postSeekPacketStager.append(
            packet,
            isVideo: isVideo,
            maximumPayloadBytes: Self.maximumQueuedBytes
        ) else {
            let navigationGeneration = postSeekNavigationGeneration
            postSeekBuffer.cancel()
            cancelPostSeekPacketStagingLocked()
            // Stop accepting ordinary packets until failNavigation has put
            // the subscription back into a coherent delivery state.
            deliveryGate.beginNavigation()
            condition.broadcast()
            condition.unlock()
            return .stagingOverflow(navigationGeneration: navigationGeneration)
        }

        let completion: ReadyPostSeekDelivery?
        if let result = postSeekBuffer.observePacket(
            time: packetTime,
            decodeTime: packet.decodeTime,
            duration: packet.durationMicroseconds,
            streamIndex: packet.streamIndex,
            isVideo: isVideo,
            isAudio: isAudio,
            frameType: packet.frameType
        ) {
            completion = ReadyPostSeekDelivery(
                batch: postSeekPacketStager.finish(),
                epoch: postSeekStagingEpoch,
                navigationGeneration: postSeekNavigationGeneration,
                handler: navigationCompletionHandler,
                result: result,
                diagnostics: postSeekBuffer.completionDiagnostics ?? "unavailable",
                primaryVideoStreamIndex: postSeekPrimaryVideoStreamIndex,
                primaryAudioStreamIndex: postSeekPrimaryAudioStreamIndex
            )
        } else {
            completion = nil
        }
        condition.unlock()
        return completion.map(MuxPacketDisposition.flush) ?? .staged
    }

    private func publishInitialTuneBatch(
        _ completion: ReadyInitialTuneDelivery
    ) -> InitialTunePublishResult {
        var tailInterleaver: HTSPPostSeekTailInterleaver?
        var orderedPackets: [HTSPMuxPacket]
        if let primaryVideoStreamIndex = completion.primaryVideoStreamIndex,
           let primaryAudioStreamIndex = completion.primaryAudioStreamIndex {
            var interleaver = HTSPPostSeekTailInterleaver(
                batch: completion.batch,
                primaryVideoStreamIndex: primaryVideoStreamIndex,
                primaryAudioStreamIndex: primaryAudioStreamIndex
            )
            orderedPackets = interleaver.drainAvailable()
            tailInterleaver = interleaver
        } else {
            orderedPackets = completion.batch.interleavedPackets
        }
        if let trailingPacket = completion.trailingPacket {
            orderedPackets.append(trailingPacket)
        }
        guard !orderedPackets.isEmpty else { return .failed }

        processLock.lock()
        let isCurrent = condition.withLock {
            completion.epoch == postSeekStagingEpoch
                && !stopped
                && currentError == nil
                && deliveryGate.shouldDeliverPackets
        }
        guard isCurrent else {
            processLock.unlock()
            return .stale
        }
        if completion.flushesExistingDecoder {
            muxer.resetAfterDiscontinuity()
        } else {
            muxer.resetForFreshPipeline()
        }
        var transportData = Data()
        for packet in orderedPackets { transportData.append(muxer.mux(packet)) }
        guard !transportData.isEmpty else {
            processLock.unlock()
            return .failed
        }

        let published = condition.withLock {
            guard completion.epoch == postSeekStagingEpoch,
                  !stopped,
                  currentError == nil,
                  deliveryGate.shouldDeliverPackets
            else { return false }
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            let retainedTail = tailInterleaver.flatMap { $0.isEmpty ? nil : $0 }
            postSeekTailInterleaver = retainedTail
            hasInitialTuneTailInterleaver = retainedTail != nil
            buffer.append(transportData)
            condition.broadcast()
            return true
        }
        processLock.unlock()
        if published {
            benchmarkTrace(
                "initial-tune interleave packets=\(orderedPackets.count) "
                    + "payload=\(completion.batch.payloadByteCount)B "
                    + "tail=\(tailInterleaver?.queuedPayloadByteCount ?? 0)B "
                    + "transport=\(transportData.count)B \(completion.diagnostics)"
            )
        }
        return published ? .published : .stale
    }

    private func publishPostSeekBatch(_ completion: ReadyPostSeekDelivery) -> Bool {
        var tailInterleaver: HTSPPostSeekTailInterleaver?
        let orderedPackets: [HTSPMuxPacket]
        if let primaryVideoStreamIndex = completion.primaryVideoStreamIndex,
           let primaryAudioStreamIndex = completion.primaryAudioStreamIndex {
            var interleaver = HTSPPostSeekTailInterleaver(
                batch: completion.batch,
                primaryVideoStreamIndex: primaryVideoStreamIndex,
                primaryAudioStreamIndex: primaryAudioStreamIndex
            )
            orderedPackets = interleaver.drainAvailable()
            tailInterleaver = interleaver
        } else {
            orderedPackets = completion.batch.interleavedPackets
        }
        guard !orderedPackets.isEmpty else { return false }
        processLock.lock()
        let isCurrent = condition.withLock {
            completion.epoch == postSeekStagingEpoch
                && completion.navigationGeneration == postSeekNavigationGeneration
                && !stopped
                && currentError == nil
                && deliveryGate.shouldDeliverPackets
        }
        guard isCurrent else {
            processLock.unlock()
            return false
        }
        muxer.resetForFreshPipeline()
        var transportData = Data()
        for packet in orderedPackets { transportData.append(muxer.mux(packet)) }
        guard !transportData.isEmpty else {
            processLock.unlock()
            return false
        }

        let published = condition.withLock {
            guard completion.epoch == postSeekStagingEpoch,
                  completion.navigationGeneration == postSeekNavigationGeneration,
                  !stopped,
                  currentError == nil,
                  deliveryGate.shouldDeliverPackets
            else { return false }
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            postSeekTailInterleaver = tailInterleaver
            hasInitialTuneTailInterleaver = false
            buffer.append(transportData)
            condition.broadcast()
            return true
        }
        processLock.unlock()
        if published {
            benchmarkTrace(
                "post-seek interleave packets=\(orderedPackets.count) "
                    + "payload=\(completion.batch.payloadByteCount)B "
                    + "tail=\(tailInterleaver?.queuedPayloadByteCount ?? 0)B "
                    + "transport=\(transportData.count)B"
            )
        }
        return published
    }

    private func appendIfDeliveryIsOpen(
        _ data: Data,
        stagingEpoch: UInt64? = nil
    ) {
        guard !data.isEmpty else { return }
        condition.lock()
        guard deliveryGate.shouldDeliverPackets else {
            condition.unlock()
            return
        }
        while !stopped,
              currentError == nil,
              buffer.count - readOffset >= Self.maximumQueuedBytes {
            condition.wait()
        }
        if !stopped,
           currentError == nil,
           stagingEpoch.map({ $0 == postSeekStagingEpoch }) ?? true,
           deliveryGate.shouldDeliverPackets {
            buffer.append(data)
            condition.broadcast()
        }
        condition.unlock()
    }

    private func muxAndAppendInterleavedPackets(
        _ packets: [HTSPMuxPacket],
        stagingEpoch: UInt64
    ) {
        processLock.lock()
        let isCurrent = condition.withLock {
            stagingEpoch == postSeekStagingEpoch
                && !stopped
                && currentError == nil
                && deliveryGate.shouldDeliverPackets
        }
        guard isCurrent else {
            processLock.unlock()
            return
        }
        var transportData = Data()
        for packet in packets { transportData.append(muxer.mux(packet)) }
        processLock.unlock()
        // Do not hold the muxer lock while waiting for VLC-facing buffer
        // capacity: health monitoring needs that lock to detect and recover a
        // stalled consumer. Every reset which can invalidate these bytes also
        // advances the staging epoch and clears the delivery queue, so the
        // append-side epoch check still prevents stale transport data from
        // crossing into the replacement pipeline.
        appendIfDeliveryIsOpen(transportData, stagingEpoch: stagingEpoch)
    }

    private func clearDeliveryQueue() {
        let interruptedNavigationGeneration = condition.withLock { () -> Int? in
            let interruptedNavigation = postSeekPacketStager.isActive
                || postSeekBuffer.result != nil
            let hadPostSeekInterleaving = initialTunePacketStager.isActive
                || interruptedNavigation
                || postSeekTailInterleaver != nil
            let navigationGeneration = interruptedNavigation
                ? postSeekNavigationGeneration
                : nil
            if hadPostSeekInterleaving {
                postSeekBuffer.cancel()
                cancelPostSeekPacketStagingLocked()
            }
            if interruptedNavigation {
                deliveryGate.beginNavigation()
            }
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            condition.broadcast()
            return navigationGeneration
        }
        if let interruptedNavigationGeneration {
            controlQueue.async { [weak self] in
                guard let self,
                      self.navigationGeneration == interruptedNavigationGeneration
                else { return }
                self.failNavigation(
                    .controlFailed("TVHeadend changed the subscription while seeking.")
                )
            }
        }
    }

    /// Must be called while `condition` is held.
    private func cancelPostSeekPacketStagingLocked() {
        postSeekStagingEpoch &+= 1
        postSeekNavigationGeneration = 0
        initialTunePacketStager.cancel()
        initialTuneFlushesExistingDecoder = false
        postSeekPacketStager.cancel()
        postSeekTailInterleaver = nil
        hasInitialTuneTailInterleaver = false
        postSeekPrimaryVideoStreamIndex = nil
        postSeekPrimaryAudioStreamIndex = nil
    }

    private func beginInitialTunePacketStaging(
        flushesExistingDecoder: Bool = false
    ) {
        let tracks = processLock.withLock {
            (
                hasVideo: muxer.hasVideo,
                primaryVideoStreamIndex: muxer.primaryVideoStreamIndex,
                primaryAudioStreamIndex: muxer.primaryAudioStreamIndex
            )
        }
        condition.withLock {
            beginInitialTunePacketStagingLocked(
                hasVideo: tracks.hasVideo,
                primaryVideoStreamIndex: tracks.primaryVideoStreamIndex,
                primaryAudioStreamIndex: tracks.primaryAudioStreamIndex,
                flushesExistingDecoder: flushesExistingDecoder
            )
        }
    }

    /// Must be called while `condition` is held.
    private func beginInitialTunePacketStagingLocked(
        hasVideo: Bool,
        primaryVideoStreamIndex: Int?,
        primaryAudioStreamIndex: Int?,
        flushesExistingDecoder: Bool = false
    ) {
        cancelPostSeekPacketStagingLocked()
        initialTuneFlushesExistingDecoder = flushesExistingDecoder
        // Hold only a short aligned window here. This removes TVHeadend's
        // stale pre-keyframe audio without making tune latency depend on
        // filling VLC's entire cache; the launch-output gate below VLC owns
        // concealment until presentation cadence is stable.
        initialTunePacketStager.begin(
            hasVideo: hasVideo,
            primaryVideoStreamIndex: primaryVideoStreamIndex,
            primaryAudioStreamIndex: primaryAudioStreamIndex,
            requiredDuration: HTSPPostSeekBufferTracker.minimumRequiredDuration,
            maximumPayloadBytes: Self.maximumQueuedBytes,
            // TVHeadend often delivers the initial video burst ahead of the
            // selected audio PID. Give the next audio access unit time to
            // prove the half-second common horizon instead of publishing the
            // skewed fallback a few milliseconds early.
            maximumWaitAfterVideoKeyframe: 2.5
        )
    }

    private func beginNavigation() {
        condition.withLock {
            // Keep the current reader valid until TVHeadend has accepted and
            // resolved the navigation. A rejected/timed-out seek can then
            // reopen this same pipeline instead of resuming an EOF reader.
            deliveryGate.beginNavigation()
            postSeekBuffer.cancel()
            cancelPostSeekPacketStagingLocked()
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            condition.broadcast()
        }
    }

    private func preparePostSeekBuffering(_ result: HTSPNavigationResult) {
        let generation = navigationGeneration
        let tracks = processLock.withLock {
            muxer.resetForFreshPipeline()
            return (
                hasVideo: muxer.hasVideo,
                primaryVideoStreamIndex: muxer.primaryVideoStreamIndex,
                primaryAudioStreamIndex: muxer.primaryAudioStreamIndex
            )
        }
        // VLC's callback-input access advertises only a small fixed delay, so
        // the app-side staging buffer must preserve the configured startup
        // reserve after the requested position for shallow seeks as well.
        let baseRequiredDuration = max(
            HTSPPostSeekBufferTracker.minimumRequiredDuration,
            vlcCacheDuration
        )
        let requiredDuration = baseRequiredDuration
        let requiredSeconds = TimeInterval(requiredDuration) / 1_000_000
        let acceleratesBackfill = result.liveDelay
            >= requiredSeconds + Self.fastPrebufferLiveEdgeMargin
        condition.withLock {
            // Destination media starts a new input epoch. Invalidate the old
            // VLC reader before opening delivery so it cannot consume any of
            // the freshly muxed destination bytes.
            vlcReaderGeneration += 1
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            cancelPostSeekPacketStagingLocked()
            postSeekPacketStager.begin(pinsInitialVideoKeyframe: tracks.hasVideo)
            postSeekNavigationGeneration = generation
            postSeekPrimaryVideoStreamIndex = tracks.primaryVideoStreamIndex
            postSeekPrimaryAudioStreamIndex = tracks.primaryAudioStreamIndex
            postSeekBuffer.begin(
                result,
                hasVideo: tracks.hasVideo,
                audioStreamIndexes: tracks.primaryAudioStreamIndex.map { [$0] } ?? [],
                requiredDuration: requiredDuration
            )
            deliveryGate.completeNavigation()
            condition.broadcast()
        }
        benchmarkTrace(
            "post-seek backfill duration=\(requiredDuration)us speed="
                + "\(acceleratesBackfill ? Self.fastPrebufferSpeed : 100)"
        )
        requestSpeed(acceleratesBackfill ? Self.fastPrebufferSpeed : 100)

        controlQueue.asyncAfter(deadline: .now() + Self.controlResponseTimeout) { [weak self] in
            guard let self,
                  self.navigationGeneration == generation,
                  self.condition.withLock({ self.postSeekBuffer.result != nil })
                    || self.bufferedNavigationCompletion != nil
            else { return }
            self.failNavigation(.timedOut)
        }
    }

    private func finishPostSeekBuffering(
        handler: (@Sendable (
            Result<HTSPNavigationResult, HTSPNavigationError>
        ) -> Void)?,
        result: HTSPNavigationResult,
        diagnostics: String
    ) {
        bufferedNavigationCompletion = BufferedNavigationCompletion(
            handler: handler,
            result: result,
            diagnostics: diagnostics
        )
        requestSpeed(100)
        completeBufferedNavigationAtNormalSpeedIfReady()
    }

    private func completeBufferedNavigationAtNormalSpeedIfReady() {
        guard speedController.actualSpeed == 100,
              speedController.outstandingSpeed == nil,
              let completion = bufferedNavigationCompletion
        else { return }
        bufferedNavigationCompletion = nil
        benchmarkTrace(
            "post-seek backfill handed to VLC at normal speed "
                + completion.diagnostics
        )
        completion.handler?(.success(completion.result))
    }

    private func enqueueSpeed(_ speed: Int32) {
        controlQueue.async { [weak self] in self?.requestSpeed(speed) }
    }

    private func requestSpeed(_ speed: Int32) {
        let outstanding = speedController.outstandingSpeed.map(String.init) ?? "nil"
        benchmarkTrace(
            "speed request=\(speed) actual=\(speedController.actualSpeed) outstanding=\(outstanding)"
        )
        if let command = speedController.request(speed) { sendSpeed(command) }
    }

    private func sendSpeed(_ speed: Int32) {
        benchmarkTrace("sending subscriptionSpeed speed=\(speed)")
        sendControlRequest(
            method: "subscriptionSpeed",
            fields: ["speed": .int(Int64(speed))],
            succeeded: { [weak self] in
                guard let self else { return }
                self.benchmarkTrace("subscriptionSpeed response succeeded speed=\(speed)")
                if let command = self.speedController.commandSucceeded(speed) {
                    self.sendSpeed(command)
                } else {
                    // A subscriptionSpeed notification is optional. Once the
                    // pause RPC has established speed zero, continue a seek
                    // that was waiting for that acknowledgement.
                    self.sendPendingNavigationIfPaused()
                }
                self.completeBufferedNavigationAtNormalSpeedIfReady()
            },
            failed: { [weak self] error in
                guard let self else { return }
                self.benchmarkTrace("subscriptionSpeed response failed speed=\(speed) error=\(error.localizedDescription)")
                if let command = self.speedController.commandFailed(speed) {
                    self.sendSpeed(command)
                }
                self.logger.error(
                    "TVHeadend speed \(speed, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                if self.isNavigatingTimeshift
                    || self.bufferedNavigationCompletion != nil {
                    self.failNavigation(
                        .controlFailed(error.localizedDescription)
                    )
                }
            }
        )
    }

    private func sendSeekWhenPaused(to target: Int64) {
        guard activeSeekSequence == nil else { return }
        if !HTSPSeekStartPolicy.canSendSeek(
            actualSpeed: speedController.actualSpeed,
            outstandingSpeed: speedController.outstandingSpeed
        ) {
            requestSpeed(0)
        }
        guard HTSPSeekStartPolicy.canSendSeek(
            actualSpeed: speedController.actualSpeed,
            outstandingSpeed: speedController.outstandingSpeed
        ) else {
            schedulePendingNavigationTimeout()
            return
        }
        guard activeSeekSequence == nil else { return }
        sendAbsoluteSeek(to: target)
    }

    private func sendPendingNavigationIfPaused() {
        guard activeSeekSequence == nil,
              !deliveryGate.shouldDeliverPackets else { return }
        if !HTSPSeekStartPolicy.canSendSeek(
            actualSpeed: speedController.actualSpeed,
            outstandingSpeed: speedController.outstandingSpeed
        ) {
            requestSpeed(0)
        }
        guard HTSPSeekStartPolicy.canSendSeek(
            actualSpeed: speedController.actualSpeed,
            outstandingSpeed: speedController.outstandingSpeed
        ) else {
            schedulePendingNavigationTimeout()
            return
        }
        guard activeSeekSequence == nil else { return }
        if pendingLiveCommand {
            sendLiveNavigation()
            return
        }
        guard let target = seekCoordinator.inFlightTarget else { return }
        sendAbsoluteSeek(to: target)
    }

    private func sendAbsoluteSeek(to target: Int64) {
        sendNavigationCommand(
            method: "subscriptionSkip",
            fields: [
                "time": .int(target),
                "absolute": .int(1),
            ],
            acceptsLiveEdge: false,
            targetsLiveEdge: seekCoordinator.isTargetingLiveEdge
        )
    }

    private func sendLiveNavigation() {
        pendingLiveCommand = false
        // subscriptionLive changes TVHeadend back to normal playback speed as
        // it reaches the readable edge. Model that server-side transition so
        // the speed controller does not immediately fight it with a late pause.
        speedController.expectServerSpeed(100)
        sendNavigationCommand(
            method: "subscriptionLive",
            fields: [:],
            acceptsLiveEdge: true,
            targetsLiveEdge: true
        )
    }

    private func sendNavigationCommand(
        method: String,
        fields: [String: HTSPValue],
        acceptsLiveEdge: Bool,
        targetsLiveEdge: Bool
    ) {
        benchmarkTrace("sending \(method) fields=\(fields)")
        seekRPCAccepted = false
        asynchronousLandingTime = nil
        navigationCommandInFlight = true
        navigationAcceptsLiveEdge = acceptsLiveEdge
        navigationTargetsLiveEdge = targetsLiveEdge
        navigationGeneration += 1
        let generation = navigationGeneration

        activeSeekSequence = sendControlRequest(
            method: method,
            fields: fields,
            succeeded: { [weak self] in
                guard let self, self.navigationGeneration == generation else { return }
                self.seekRPCAccepted = true
                self.finishSeekIfReady()
            },
            failed: { [weak self] error in
                guard let self, self.navigationGeneration == generation else { return }
                self.failNavigation(self.navigationError(from: error))
            }
        )

        controlQueue.asyncAfter(deadline: .now() + Self.controlResponseTimeout) { [weak self] in
            guard let self,
                  self.navigationGeneration == generation,
                  self.navigationCommandInFlight
            else { return }
            self.failNavigation(.timedOut)
        }
    }

    private func schedulePendingNavigationTimeout() {
        navigationGeneration += 1
        let generation = navigationGeneration
        controlQueue.asyncAfter(deadline: .now() + Self.controlResponseTimeout) { [weak self] in
            guard let self,
                  self.navigationGeneration == generation,
                  !self.deliveryGate.shouldDeliverPackets,
                  self.activeSeekSequence == nil
            else { return }
            self.failNavigation(.timedOut)
        }
    }

    private func handleSubscriptionSkip(_ message: [String: HTSPValue]) {
        benchmarkTrace("received subscriptionSkip event fields=\(message)")
        guard navigationCommandInFlight else { return }
        if message["error"]?.intValue == 1 {
            if HTSPNavigationRecoveryPolicy.shouldRetryWithLiveCommand(
                acceptsLiveEdge: navigationAcceptsLiveEdge,
                targetsLiveEdge: navigationTargetsLiveEdge
            ) {
                recoverRejectedLiveEdgeSeek()
                return
            }
            failNavigation(.rejected)
            return
        }
        guard let landingTime = message["time"]?.intValue else {
            failNavigation(.invalidResponse)
            return
        }
        asynchronousLandingTime = max(0, landingTime)
        finishSeekIfReady()
    }

    private func finishSeekIfReady() {
        guard seekRPCAccepted, let asynchronousLandingTime else { return }
        let acceptsLiveEdge = navigationAcceptsLiveEdge
        activeSeekSequence = nil
        seekRPCAccepted = false
        self.asynchronousLandingTime = nil
        navigationCommandInFlight = false
        navigationAcceptsLiveEdge = false
        navigationTargetsLiveEdge = false

        switch seekCoordinator.complete(
            landingTime: asynchronousLandingTime,
            acceptsLiveEdgeLanding: acceptsLiveEdge
        ) {
        case let .seek(target):
            if pendingLiveCommand {
                sendPendingNavigationIfPaused()
            } else {
                sendSeekWhenPaused(to: target)
            }
        case let .buffer(result):
            navigationGeneration += 1
            preparePostSeekBuffering(result)
        }
    }

    private func recoverRejectedLiveEdgeSeek() {
        logger.info("Absolute live-edge seek was rejected; retrying with subscriptionLive")
        navigationGeneration += 1
        if let activeSeekSequence {
            pendingControlRequests.removeValue(forKey: activeSeekSequence)
        }
        activeSeekSequence = nil
        seekRPCAccepted = false
        asynchronousLandingTime = nil
        navigationCommandInFlight = false
        navigationAcceptsLiveEdge = false
        navigationTargetsLiveEdge = false
        pendingLiveCommand = true
        _ = seekCoordinator.requestLiveEdge()
        sendPendingNavigationIfPaused()
    }

    private func failNavigation(_ error: HTSPNavigationError) {
        logger.error("Timeshift navigation failed: \(error.localizedDescription, privacy: .public)")
        navigationGeneration += 1
        if let activeSeekSequence {
            pendingControlRequests.removeValue(forKey: activeSeekSequence)
        }
        activeSeekSequence = nil
        seekRPCAccepted = false
        asynchronousLandingTime = nil
        pendingLiveCommand = false
        navigationCommandInFlight = false
        navigationAcceptsLiveEdge = false
        navigationTargetsLiveEdge = false
        bufferedNavigationCompletion = nil
        seekCoordinator.fail()
        let handler = processLock.withLock {
            muxer.resetAfterDiscontinuity()
            return condition.withLock {
                postSeekBuffer.cancel()
                cancelPostSeekPacketStagingLocked()
                deliveryGate.cancelAllNavigation()
                buffer.removeAll(keepingCapacity: true)
                readOffset = 0
                condition.broadcast()
                return navigationCompletionHandler
            }
        }
        // A rejected or timed-out navigation must not strand the subscription
        // at speed zero. Reopen delivery and continue from the last position
        // TVHeadend still owns; the user can try the navigation again.
        requestSpeed(100)
        handler?(.failure(error))
    }

    @discardableResult
    private func sendControlRequest(
        method: String,
        fields: [String: HTSPValue] = [:],
        succeeded: @escaping @Sendable () -> Void,
        failed: @escaping @Sendable (Error) -> Void
    ) -> Int64? {
        guard !condition.withLock({ recovering }) else {
            failed(HTSPError.disconnected)
            return nil
        }
        let active = currentConnection()
        let sequence = active.connection.reserveSequence()
        pendingControlRequests[sequence] = PendingControlRequest(
            method: method,
            connectionGeneration: active.generation,
            succeeded: succeeded,
            failed: failed
        )
        do {
            try active.connection.sendRequest(
                method: method,
                sequence: sequence,
                fields: fields,
                includesSubscriptionID: true
            )
        } catch {
            pendingControlRequests.removeValue(forKey: sequence)
            if !HTSPRecoveryPolicy.isTerminal(error) {
                active.connection.close()
            }
            failed(error)
            return nil
        }

        controlQueue.asyncAfter(deadline: .now() + Self.controlResponseTimeout) { [weak self] in
            guard let self,
                  let request = self.pendingControlRequests[sequence],
                  request.connectionGeneration == active.generation
            else { return }
            self.pendingControlRequests.removeValue(forKey: sequence)
            request.failed(HTSPNavigationError.timedOut)
            active.connection.close()
        }
        return sequence
    }

    private func handleControlResponse(
        _ message: [String: HTSPValue],
        sequence: Int64,
        connectionGeneration: Int
    ) {
        guard let request = pendingControlRequests[sequence],
              request.connectionGeneration == connectionGeneration
        else { return }
        benchmarkTrace("received \(request.method) response seq=\(sequence) fields=\(message)")
        pendingControlRequests.removeValue(forKey: sequence)
        do {
            try HTSPConnection.validate(response: message)
            request.succeeded()
        } catch {
            logger.error(
                "TVHeadend \(request.method, privacy: .public) request failed: \(error.localizedDescription, privacy: .public)"
            )
            request.failed(error)
        }
    }

    private func navigationError(from error: Error) -> HTSPNavigationError {
        if let navigationError = error as? HTSPNavigationError { return navigationError }
        return .controlFailed(error.localizedDescription)
    }

    private func benchmarkTrace(_ message: String) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--vlc-timeshift-benchmark")
            || arguments.contains("--vlc-tuning-benchmark")
        else { return }
        print("VLC_TIMESHIFT_HTSP \(message)")
        fflush(stdout)
    }

    private func currentConnection() -> (
        connection: any HTSPConnectionTransport,
        generation: Int
    ) {
        connectionLock.withLock { (connection, connectionGeneration) }
    }

    private func shouldRecoverForPacketStall(at date: Date) -> Bool {
        let navigating = !deliveryGate.shouldDeliverPackets
        return condition.withLock {
            guard !stopped else { return false }
            let expectsPackets = recovering || (desiredPlaybackSpeed > 0 && !navigating)
            guard expectsPackets else { return false }
            let baseline = lastMuxPacketAt ?? subscriptionReadyAt
            return date.timeIntervalSince(baseline) >= HTSPRecoveryPolicy.stalledPacketThreshold
        }
    }

    private func recoverConnection(after initialError: Error) -> Bool {
        if HTSPRecoveryPolicy.isTerminal(initialError) {
            failStream(initialError)
            return false
        }

        beginRecovery()
        currentConnection().connection.close()
        var attempt = 1
        var reason = initialError.localizedDescription

        while !Thread.current.isCancelled, !condition.withLock({ stopped }) {
            notifyLifecycle(.reconnecting(reason: reason, attempt: attempt))
            let delay = HTSPRecoveryPolicy.delay(beforeAttempt: attempt)
            guard waitForRetryDelay(delay) else { return false }

            do {
                let replacement = try connectionFactory()
                try replacement.handshake(
                    username: configuration.username,
                    password: configuration.password
                )
                guard replacement.capabilities.contains("timeshift") else {
                    throw HTSPError.timeshiftUnavailable
                }
                let subscription = try replacement.subscribe(
                    channelID: channelID,
                    profile: profile
                )
                let replacementMuxer = try MPEGTransportStreamMuxer(streams: subscription.1)
                guard !condition.withLock({ stopped }) else {
                    replacement.close()
                    return false
                }
                installReplacementConnection(replacement, muxer: replacementMuxer)
                logger.info("Rebuilt TVHeadend subscription at the live edge")
                return true
            } catch {
                if HTSPRecoveryPolicy.isTerminal(error) {
                    failStream(error)
                    return false
                }
                reason = error.localizedDescription
                logger.error(
                    "HTSP reconnect attempt \(attempt, privacy: .public) failed: \(reason, privacy: .public)"
                )
                attempt += 1
            }
        }
        return false
    }

    private func beginRecovery() {
        let wasAlreadyRecovering = condition.withLock {
            let wasRecovering = recovering
            recovering = true
            recoveryWaitsForVideoKeyframe = false
            lastMuxPacketAt = nil
            cancelPostSeekPacketStagingLocked()
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            condition.broadcast()
            return wasRecovering
        }
        guard !wasAlreadyRecovering else { return }

        processLock.withLock { muxer.resetAfterDiscontinuity() }
        deliveryGate.cancelAllNavigation()
        let navigationHandler = controlQueue.sync { () -> (
            @Sendable (Result<HTSPNavigationResult, HTSPNavigationError>) -> Void
        )? in
            let hadNavigation = navigationCommandInFlight
                || activeSeekSequence != nil
                || bufferedNavigationCompletion != nil
                || condition.withLock { postSeekBuffer.result != nil }
            navigationGeneration += 1
            pendingControlRequests.removeAll()
            activeSeekSequence = nil
            seekRPCAccepted = false
            asynchronousLandingTime = nil
            pendingLiveCommand = false
            navigationCommandInFlight = false
            navigationAcceptsLiveEdge = false
            navigationTargetsLiveEdge = false
            bufferedNavigationCompletion = nil
            seekCoordinator.fail()
            condition.withLock {
                postSeekBuffer.cancel()
                cancelPostSeekPacketStagingLocked()
            }
            return hadNavigation ? condition.withLock({ navigationCompletionHandler }) : nil
        }
        navigationHandler?(
            .failure(.controlFailed("The TVHeadend subscription restarted at the live edge."))
        )
    }

    private func installReplacementConnection(
        _ replacement: any HTSPConnectionTransport,
        muxer replacementMuxer: MPEGTransportStreamMuxer
    ) {
        let replacementTracks = (
            hasVideo: replacementMuxer.hasVideo,
            primaryVideoStreamIndex: replacementMuxer.primaryVideoStreamIndex,
            primaryAudioStreamIndex: replacementMuxer.primaryAudioStreamIndex
        )
        connectionLock.withLock {
            connection = replacement
            connectionGeneration += 1
        }
        processLock.withLock {
            muxer = replacementMuxer
            if replacementTracks.primaryVideoStreamIndex == nil
                || replacementTracks.primaryAudioStreamIndex == nil {
                muxer.resetAfterDiscontinuity()
            }
        }
        let desiredSpeed = condition.withLock {
            currentLiveDelay = 0
            currentWindow = 0
            currentBufferStart = nil
            timelineEpoch = nil
            subscriptionReadyAt = Date()
            lastMuxPacketAt = nil
            videoPacketCount = 0
            videoPayloadBytes = 0
            firstVideoPacketAt = nil
            lastVideoPacketAt = nil
            audioPacketCount = 0
            audioPayloadBytes = 0
            firstAudioPacketAt = nil
            lastAudioPacketAt = nil
            recoveryWaitsForVideoKeyframe = replacementTracks.hasVideo
            postSeekBuffer.cancel()
            beginInitialTunePacketStagingLocked(
                hasVideo: replacementTracks.hasVideo,
                primaryVideoStreamIndex: replacementTracks.primaryVideoStreamIndex,
                primaryAudioStreamIndex: replacementTracks.primaryAudioStreamIndex,
                flushesExistingDecoder: true
            )
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            condition.broadcast()
            return desiredPlaybackSpeed
        }
        controlQueue.sync {
            speedController = HTSPSubscriptionSpeedController()
            if desiredSpeed == 0 {
                // Keep the new subscription moving until one decodable packet
                // is available. finishRecovery... reapplies the viewer's pause.
                speedController.expectServerSpeed(100)
            }
        }
    }

    private func finishRecoveryAfterFirstDecodablePacketIfNeeded(
        publishedInitialTuneEpoch: UInt64?
    ) {
        let completion = condition.withLock { () -> (
            handler: (@Sendable (HTSPStreamLifecycleEvent) -> Void)?,
            desiredSpeed: Int32,
            epoch: UInt64
        )? in
            guard recovering,
                  !recoveryWaitsForVideoKeyframe,
                  !initialTunePacketStager.isActive,
                  !stopped,
                  currentError == nil,
                  publishedInitialTuneEpoch.map({ $0 == postSeekStagingEpoch }) ?? true
            else { return nil }
            recovering = false
            subscriptionReadyAt = Date()
            return (lifecycleHandler, desiredPlaybackSpeed, postSeekStagingEpoch)
        }
        guard let completion else { return }
        controlQueue.async { [weak self] in
            guard let self else { return }
            guard self.condition.withLock({
                !self.stopped
                    && self.currentError == nil
                    && self.postSeekStagingEpoch == completion.epoch
            }) else { return }
            self.speedController = HTSPSubscriptionSpeedController()
            self.requestSpeed(completion.desiredSpeed)
        }
        guard condition.withLock({
            !stopped
                && currentError == nil
                && postSeekStagingEpoch == completion.epoch
        }) else { return }
        completion.handler?(.readyAfterRecovery)
    }

    private func waitForRetryDelay(_ delay: TimeInterval) -> Bool {
        guard delay > 0 else { return !condition.withLock({ stopped }) }
        condition.lock()
        if !stopped {
            _ = condition.wait(until: Date().addingTimeInterval(delay))
        }
        let shouldContinue = !stopped
        condition.unlock()
        return shouldContinue
    }

    private func notifyLifecycle(_ event: HTSPStreamLifecycleEvent) {
        let handler = condition.withLock { lifecycleHandler }
        handler?(event)
    }

    private func failStream(_ error: Error) {
        let handler = condition.withLock { () -> (
            @Sendable (HTSPStreamLifecycleEvent) -> Void
        )? in
            guard !stopped else { return nil }
            currentError = error
            currentStatus = .error
            postSeekBuffer.cancel()
            cancelPostSeekPacketStagingLocked()
            condition.broadcast()
            return lifecycleHandler
        }
        handler?(.terminalFailure(error.localizedDescription))
        logger.error("HTSP stream ended: \(error.localizedDescription, privacy: .public)")
    }
}
