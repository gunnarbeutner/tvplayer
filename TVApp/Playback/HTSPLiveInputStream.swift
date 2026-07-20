import Foundation
import OSLog

final class HTSPLiveInputStream: InputStream, NativeTimeshiftCommandSink, @unchecked Sendable {
    private static let maximumQueuedBytes = 8 * 1_024 * 1_024

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
    private var navigationCompletionHandler: (@Sendable () -> Void)?
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
        try connection.sendControl(method: "subscriptionSpeed", fields: ["speed": .int(0)])
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
        !deliveryGate.shouldDeliverPackets
    }

    func setNavigationCompletionHandler(_ handler: (@Sendable () -> Void)?) {
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
        guard deliveryGate.shouldDeliverPackets else { return }
        enqueueControl(method: "subscriptionSpeed", fields: ["speed": .int(100)])
    }

    func pause() {
        enqueueControl(method: "subscriptionSpeed", fields: ["speed": .int(0)])
    }

    func seek(by seconds: TimeInterval) {
        beginNavigation()
        enqueueControl(
            method: "subscriptionSkip",
            fields: ["time": .int(Int64((seconds * 1_000_000).rounded()))],
            cancelsNavigationOnFailure: true
        )
    }

    func returnToLive() {
        beginNavigation()
        enqueueControl(method: "subscriptionLive", cancelsNavigationOnFailure: true)
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
            let transportData = processLock.withLock { muxer.mux(packet) }
            if let completionHandler = appendIfDeliveryIsOpen(transportData) {
                completionHandler()
            }

        case "timeshiftStatus":
            let metrics = HTSPTimeshiftMetrics.decode(from: message)
            condition.withLock {
                currentLiveDelay = metrics.liveDelay
                currentWindow = metrics.window
                currentBufferStart = metrics.window > 0
                    ? Date().addingTimeInterval(-metrics.window)
                    : nil
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
            completeNavigation()
            if message["error"]?.intValue == 1 {
                logger.error("TVHeadend rejected an HTSP seek request")
            }

        case "subscriptionStop":
            let message = message["status"]?.stringValue ?? "TVHeadend stopped the HTSP stream."
            throw HTSPError.server(message)

        default:
            break
        }
    }

    private func appendIfDeliveryIsOpen(_ data: Data) -> (@Sendable () -> Void)? {
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
        let completionHandler: (@Sendable () -> Void)?
        if !stopped, currentError == nil, deliveryGate.shouldDeliverPackets {
            buffer.append(data)
            completionHandler = deliveryGate.consumePostNavigationPacket()
                ? navigationCompletionHandler
                : nil
            condition.broadcast()
        } else {
            completionHandler = nil
        }
        condition.unlock()
        return completionHandler
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
        condition.withLock {
            deliveryGate.beginNavigation()
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            condition.broadcast()
        }
        processLock.withLock { muxer.resetAfterDiscontinuity() }
    }

    private func completeNavigation() {
        processLock.withLock { muxer.resetAfterDiscontinuity() }
        let completedAllNavigation: Bool = condition.withLock {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
            let completedAllNavigation = deliveryGate.completeNavigation()
            condition.broadcast()
            return completedAllNavigation
        }
        if completedAllNavigation {
            enqueueControl(method: "subscriptionSpeed", fields: ["speed": .int(100)])
        }
    }

    private func enqueueControl(
        method: String,
        fields: [String: HTSPValue] = [:],
        cancelsNavigationOnFailure: Bool = false
    ) {
        controlQueue.async { [weak self] in
            self?.sendControl(
                method: method,
                fields: fields,
                cancelsNavigationOnFailure: cancelsNavigationOnFailure
            )
        }
    }

    private func sendControl(
        method: String,
        fields: [String: HTSPValue] = [:],
        cancelsNavigationOnFailure: Bool = false
    ) {
        do {
            try connection.sendControl(method: method, fields: fields)
        } catch {
            if cancelsNavigationOnFailure {
                deliveryGate.cancelAllNavigation()
            }
            condition.withLock {
                guard !stopped else { return }
                currentError = error
                currentStatus = .error
                condition.broadcast()
            }
        }
    }
}
