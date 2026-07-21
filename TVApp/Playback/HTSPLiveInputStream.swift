import Foundation
import OSLog

enum HTSPStreamLifecycleEvent: Equatable, Sendable {
    case reconnecting(reason: String, attempt: Int)
    case readyAfterRecovery
    case terminalFailure(String)
}

struct HTSPStreamHealthSnapshot: Equatable, Sendable {
    let isRecovering: Bool
    let isNavigating: Bool
    let desiredSpeed: Int32
    let lastMuxPacketAt: Date?
    let expectsAudio: Bool
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
    private static let fastPrebufferDelay: TimeInterval = 10

    private struct PendingControlRequest {
        let method: String
        let connectionGeneration: Int
        let succeeded: @Sendable () -> Void
        let failed: @Sendable (Error) -> Void
    }

    private let configuration: TVHeadendConfiguration
    private let channelID: UInt32
    private let profile: String
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
    private var receiverThread: Thread?
    private var currentLiveDelay: TimeInterval = 0
    private var currentWindow: TimeInterval = 0
    private var currentBufferStart: Date?
    private var timelineEpoch: Date?
    private var lastMuxPacketAt: Date?
    private var subscriptionReadyAt = Date()
    private var recovering = false
    private var recoveryWaitsForVideoKeyframe = false
    private var desiredPlaybackSpeed: Int32 = 100
    private var lifecycleHandler: (@Sendable (HTSPStreamLifecycleEvent) -> Void)?
    private var navigationCompletionHandler: (
        @Sendable (Result<HTSPNavigationResult, HTSPNavigationError>) -> Void
    )?
    private var postSeekBuffer = HTSPPostSeekBufferTracker()

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
    let acceptedTimeshiftPeriod: TimeInterval

    private init(
        configuration: TVHeadendConfiguration,
        channelID: UInt32,
        profile: String,
        connection: any HTSPConnectionTransport,
        connectionFactory: @escaping HTSPConnectionFactory,
        streams: [HTSPStreamInfo],
        acceptedTimeshiftPeriod: TimeInterval
    ) throws {
        self.configuration = configuration
        self.channelID = channelID
        self.profile = profile
        self.connection = connection
        self.connectionFactory = connectionFactory
        muxer = try MPEGTransportStreamMuxer(streams: streams)
        self.acceptedTimeshiftPeriod = acceptedTimeshiftPeriod
        super.init(data: Data())
    }

    static func connect(
        configuration: TVHeadendConfiguration,
        channelID: UInt32,
        profile: String,
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
                do {
                    let subscription = try preconnected.subscribe(
                        channelID: channelID,
                        profile: profile
                    )
                    return (preconnected, subscription)
                } catch {
                    // An idle socket may be closed by the server before Play.
                    // Fall through to the normal fresh connection path.
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
            acceptedTimeshiftPeriod: TimeInterval(connected.1.0)
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
        let expectsAudio = processLock.withLock { muxer.hasAudio }
        return condition.withLock {
            HTSPStreamHealthSnapshot(
                isRecovering: recovering,
                isNavigating: navigating || postSeekBuffer.result != nil,
                desiredSpeed: desiredPlaybackSpeed,
                lastMuxPacketAt: lastMuxPacketAt,
                expectsAudio: expectsAudio
            )
        }
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
            guard deliveryGate.shouldDeliverPackets else { return }
            guard let streamIndex = message["stream"]?.intValue,
                  let payload = message["payload"]?.dataValue
            else { throw HTSPCodecError.malformedMessage }
            let packet = HTSPMuxPacket(
                streamIndex: Int(streamIndex),
                frameType: UInt8(truncatingIfNeeded: message["frametype"]?.intValue ?? 0),
                presentationTime: message["pts"]?.intValue,
                decodeTime: message["dts"]?.intValue,
                payload: payload
            )
            let isVideo = processLock.withLock { muxer.isVideoStream(packet.streamIndex) }
            let recoveryAcceptsPacket = condition.withLock {
                lastMuxPacketAt = Date()
                guard recovering, recoveryWaitsForVideoKeyframe else { return true }
                guard isVideo, packet.frameType == Character("I").asciiValue else {
                    return false
                }
                recoveryWaitsForVideoKeyframe = false
                return true
            }
            guard recoveryAcceptsPacket else { return }
            let acceptsPacket = condition.withLock {
                postSeekBuffer.shouldAcceptPacket(
                    isVideo: isVideo,
                    frameType: packet.frameType
                )
            }
            guard acceptsPacket else { return }
            let transportData = processLock.withLock { muxer.mux(packet) }
            if let completion = appendIfDeliveryIsOpen(
                transportData,
                packetTime: packet.presentationTime ?? packet.decodeTime
            ) {
                enqueueSpeed(100)
                completion.handler(.success(completion.result))
            }
            finishRecoveryAfterFirstDecodablePacketIfNeeded()

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
            let streams = message["streams"]?.listValue?.compactMap { value -> HTSPStreamInfo? in
                guard let stream = value.mapValue,
                      let index = stream["index"]?.intValue,
                      let type = stream["type"]?.stringValue
                else { return nil }
                return HTSPStreamInfo(
                    index: Int(index),
                    type: type,
                    language: stream["language"]?.stringValue,
                    metadata: stream["meta"]?.dataValue
                )
            } ?? []
            let replacement = try MPEGTransportStreamMuxer(streams: streams)
            processLock.withLock { muxer = replacement }
            resetDeliveryQueue()

        case "subscriptionSkip":
            controlQueue.async { [weak self] in self?.handleSubscriptionSkip(message) }

        case "subscriptionSpeed":
            guard let speed = message["speed"]?.intValue else { return }
            controlQueue.async { [weak self] in
                guard let self else { return }
                if let command = self.speedController.observeActual(Int32(clamping: speed)) {
                    self.sendSpeed(command)
                }
                self.sendPendingNavigationIfPaused()
            }

        case "subscriptionStop":
            let message = message["status"]?.stringValue ?? "TVHeadend stopped the HTSP stream."
            throw HTSPError.server(message)

        default:
            break
        }
    }

    private func appendIfDeliveryIsOpen(
        _ data: Data,
        packetTime: Int64?
    ) -> (
        handler: @Sendable (Result<HTSPNavigationResult, HTSPNavigationError>) -> Void,
        result: HTSPNavigationResult
    )? {
        guard !data.isEmpty else { return nil }
        condition.lock()
        guard deliveryGate.shouldDeliverPackets else {
            condition.unlock()
            return nil
        }
        while !stopped,
              currentError == nil,
              buffer.count - readOffset >= Self.maximumQueuedBytes {
            condition.wait()
        }
        let completion: (
            handler: @Sendable (Result<HTSPNavigationResult, HTSPNavigationError>) -> Void,
            result: HTSPNavigationResult
        )?
        if !stopped, currentError == nil, deliveryGate.shouldDeliverPackets {
            buffer.append(data)
            if let result = postSeekBuffer.observePacket(time: packetTime),
               let navigationCompletionHandler {
                completion = (navigationCompletionHandler, result)
            } else {
                completion = nil
            }
            condition.broadcast()
        } else {
            completion = nil
        }
        condition.unlock()
        return completion
    }

    private func resetDeliveryQueue() {
        processLock.withLock { muxer.resetAfterDiscontinuity() }
        clearDeliveryQueue()
    }

    private func clearDeliveryQueue() {
        condition.withLock {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            condition.broadcast()
        }
    }

    private func beginNavigation() {
        processLock.withLock { muxer.resetAfterDiscontinuity() }
        condition.withLock {
            deliveryGate.beginNavigation()
            postSeekBuffer.cancel()
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            condition.broadcast()
        }
    }

    private func preparePostSeekBuffering(_ result: HTSPNavigationResult) {
        let generation = navigationGeneration
        let hasVideo = processLock.withLock {
            muxer.resetAfterDiscontinuity()
            return muxer.hasVideo
        }
        condition.withLock {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            postSeekBuffer.begin(result, hasVideo: hasVideo)
            deliveryGate.completeNavigation()
            condition.broadcast()
        }
        requestSpeed(result.liveDelay >= Self.fastPrebufferDelay ? 400 : 100)

        controlQueue.asyncAfter(deadline: .now() + Self.controlResponseTimeout) { [weak self] in
            guard let self,
                  self.navigationGeneration == generation,
                  self.condition.withLock({ self.postSeekBuffer.result != nil }) else { return }
            self.failNavigation(.timedOut)
        }
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
                if self.isNavigatingTimeshift {
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
        seekCoordinator.fail()
        processLock.withLock { muxer.resetAfterDiscontinuity() }

        let handler = condition.withLock {
            postSeekBuffer.cancel()
            deliveryGate.cancelAllNavigation()
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            condition.broadcast()
            return navigationCompletionHandler
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
        guard ProcessInfo.processInfo.arguments.contains("--vlc-timeshift-benchmark") else { return }
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
            seekCoordinator.fail()
            condition.withLock { postSeekBuffer.cancel() }
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
        connectionLock.withLock {
            connection = replacement
            connectionGeneration += 1
        }
        processLock.withLock { muxer = replacementMuxer }
        let desiredSpeed = condition.withLock {
            currentLiveDelay = 0
            currentWindow = 0
            currentBufferStart = nil
            timelineEpoch = nil
            subscriptionReadyAt = Date()
            lastMuxPacketAt = nil
            recoveryWaitsForVideoKeyframe = replacementMuxer.hasVideo
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

    private func finishRecoveryAfterFirstDecodablePacketIfNeeded() {
        let completion = condition.withLock { () -> (
            handler: (@Sendable (HTSPStreamLifecycleEvent) -> Void)?,
            desiredSpeed: Int32
        )? in
            guard recovering, !recoveryWaitsForVideoKeyframe else { return nil }
            recovering = false
            subscriptionReadyAt = Date()
            return (lifecycleHandler, desiredPlaybackSpeed)
        }
        guard let completion else { return }
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.speedController = HTSPSubscriptionSpeedController()
            self.requestSpeed(completion.desiredSpeed)
        }
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
            condition.broadcast()
            return lifecycleHandler
        }
        handler?(.terminalFailure(error.localizedDescription))
        logger.error("HTSP stream ended: \(error.localizedDescription, privacy: .public)")
    }
}
