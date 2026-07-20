import Foundation
import OSLog

final class HTSPLiveInputStream: InputStream, NativeTimeshiftCommandSink, @unchecked Sendable {
    private static let maximumQueuedBytes = 8 * 1_024 * 1_024
    private static let controlResponseTimeout: TimeInterval = 5
    private static let fastPrebufferDelay: TimeInterval = 10

    private struct PendingControlRequest {
        let method: String
        let succeeded: @Sendable () -> Void
        let failed: @Sendable (Error) -> Void
    }

    private let connection: HTSPConnection
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
        connection: HTSPConnection,
        streams: [HTSPStreamInfo],
        acceptedTimeshiftPeriod: TimeInterval
    ) throws {
        self.connection = connection
        muxer = try MPEGTransportStreamMuxer(streams: streams)
        self.acceptedTimeshiftPeriod = acceptedTimeshiftPeriod
        super.init(data: Data())
    }

    static func connect(
        configuration: TVHeadendConfiguration,
        channelID: UInt32,
        profile: String
    ) async throws -> HTSPLiveInputStream {
        guard let host = configuration.baseURL?.host else { throw HTSPError.invalidHost }
        let connection = try await HTSPConnection.open(host: host, port: configuration.htspPort)
        let subscription = try await Task.detached(priority: .userInitiated) {
            try connection.handshake(username: configuration.username, password: configuration.password)
            guard connection.capabilities.contains("timeshift") else {
                throw HTSPError.timeshiftUnavailable
            }
            return try connection.subscribe(channelID: channelID, profile: profile)
        }.value
        let stream = try HTSPLiveInputStream(
            connection: connection,
            streams: subscription.1,
            acceptedTimeshiftPeriod: TimeInterval(subscription.0)
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
        connection.close()
    }

    func play() {
        guard !isNavigatingTimeshift else { return }
        enqueueSpeed(100)
    }

    func pause() {
        enqueueSpeed(0)
    }

    func seek(by seconds: TimeInterval) {
        guard seconds != 0 else { return }
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
        beginNavigation()
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.pendingLiveCommand = true
            _ = self.seekCoordinator.requestLiveEdge()
            self.sendPendingNavigationIfPaused()
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
        do {
            while !Thread.current.isCancelled {
                let message = try connection.readMessage()
                try process(message)
            }
        } catch {
            condition.withLock {
                guard !stopped else { return }
                currentError = error
                currentStatus = .error
                condition.broadcast()
            }
            logger.error("HTSP stream ended: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func process(_ message: [String: HTSPValue]) throws {
        if let sequence = message["seq"]?.intValue {
            controlQueue.async { [weak self] in
                self?.handleControlResponse(message, sequence: sequence)
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
        if let command = speedController.request(speed) { sendSpeed(command) }
    }

    private func sendSpeed(_ speed: Int32) {
        sendControlRequest(
            method: "subscriptionSpeed",
            fields: ["speed": .int(Int64(speed))],
            succeeded: {},
            failed: { [weak self] error in
                guard let self else { return }
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
        guard HTSPSeekStartPolicy.canSendSeek(
            actualSpeed: speedController.actualSpeed,
            outstandingSpeed: speedController.outstandingSpeed
        ) else {
            requestSpeed(0)
            schedulePendingNavigationTimeout()
            return
        }
        sendAbsoluteSeek(to: target)
    }

    private func sendPendingNavigationIfPaused() {
        guard activeSeekSequence == nil,
              !deliveryGate.shouldDeliverPackets else { return }
        guard HTSPSeekStartPolicy.canSendSeek(
            actualSpeed: speedController.actualSpeed,
            outstandingSpeed: speedController.outstandingSpeed
        ) else {
            requestSpeed(0)
            schedulePendingNavigationTimeout()
            return
        }
        if pendingLiveCommand {
            sendLiveNavigation()
            return
        }
        guard let target = seekCoordinator.inFlightTarget else { return }
        sendAbsoluteSeek(to: target)
    }

    private func sendAbsoluteSeek(to target: Int64) {
        sendNavigationCommand(
            method: "subscriptionSeek",
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
        let sequence = connection.reserveSequence()
        pendingControlRequests[sequence] = PendingControlRequest(
            method: method,
            succeeded: succeeded,
            failed: failed
        )
        do {
            try connection.sendRequest(
                method: method,
                sequence: sequence,
                fields: fields,
                includesSubscriptionID: true
            )
        } catch {
            pendingControlRequests.removeValue(forKey: sequence)
            failed(error)
            return nil
        }

        controlQueue.asyncAfter(deadline: .now() + Self.controlResponseTimeout) { [weak self] in
            guard let self,
                  let request = self.pendingControlRequests.removeValue(forKey: sequence)
            else { return }
            request.failed(HTSPNavigationError.timedOut)
        }
        return sequence
    }

    private func handleControlResponse(
        _ message: [String: HTSPValue],
        sequence: Int64
    ) {
        guard let request = pendingControlRequests.removeValue(forKey: sequence) else { return }
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

    private func failStream(_ error: Error) {
        condition.withLock {
            guard !stopped else { return }
            currentError = error
            currentStatus = .error
            condition.broadcast()
        }
    }
}
