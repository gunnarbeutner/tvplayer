import Darwin
import Foundation
import OSLog

enum VLCLoopbackHTTPTransportError: LocalizedError {
    case listenerCreationFailed

    var errorDescription: String? {
        switch self {
        case .listenerCreationFailed:
            "Could not create the local HTTP playback transport."
        }
    }
}

/// Exposes a blocking transport-stream reader through VLC's regular HTTP access
/// path.
///
/// This intentionally avoids VLCKit's `VLCMedia(stream:)` bridge. Identical
/// MPEG-TS captures containing E-AC-3 audio play correctly through
/// `VLCMedia(url:)` (both file and HTTP URLs), but lose most audio through the
/// stream bridge—even when it is backed by a plain Foundation `InputStream`.
/// AAC works through the same bridge, which isolates the failure to VLCKit's
/// E-AC-3 stream-access path rather than our HTSP reader, muxer, or pacing.
///
/// Each HTTP request receives a fresh reader while the reader's underlying HTSP
/// subscription and TVHeadend timeshift session remain independently owned.
final class VLCLoopbackHTTPTransport: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "de.beutner.TVPlayer",
        category: "VLCLoopbackHTTPTransport"
    )

    private final class Connection: @unchecked Sendable {
        let descriptor: Int32
        private let lock = NSLock()
        private var stream: InputStream?
        private var stopped = false

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        func install(_ stream: InputStream) -> Bool {
            let installed = lock.withLock {
                guard !stopped else { return false }
                self.stream = stream
                return true
            }
            if !installed { stream.close() }
            return installed
        }

        func stop() {
            let activeStream = lock.withLock {
                guard !stopped else { return nil as InputStream? }
                stopped = true
                let activeStream = stream
                stream = nil
                return activeStream
            }
            activeStream?.close()
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var listenerDescriptor: Int32
        private var connections: [UUID: Connection] = [:]
        private var stopped = false

        init(listenerDescriptor: Int32) {
            self.listenerDescriptor = listenerDescriptor
        }

        var isStopped: Bool {
            lock.withLock { stopped }
        }

        func register(_ connection: Connection, id: UUID) -> Bool {
            lock.withLock {
                guard !stopped else { return false }
                connections[id] = connection
                return true
            }
        }

        func removeConnection(id: UUID) {
            _ = lock.withLock {
                connections.removeValue(forKey: id)
            }
        }

        func disconnectClients() {
            let activeConnections = lock.withLock {
                Array(connections.values)
            }
            activeConnections.forEach { $0.stop() }
        }

        func stop() {
            let stoppedState = lock.withLock {
                guard !stopped else {
                    return (descriptor: Int32(-1), connections: [Connection]())
                }
                stopped = true
                let descriptor = listenerDescriptor
                listenerDescriptor = -1
                return (descriptor, Array(connections.values))
            }
            stoppedState.connections.forEach { $0.stop() }
            guard stoppedState.descriptor >= 0 else { return }
            _ = Darwin.shutdown(stoppedState.descriptor, SHUT_RDWR)
            Darwin.close(stoppedState.descriptor)
        }
    }

    let mediaURL: URL

    private let state: State
    private let requestPath: String

    init(
        streamFactory: @escaping @Sendable () -> InputStream
    ) throws {
        guard let listener = Self.makeListener() else {
            throw VLCLoopbackHTTPTransportError.listenerCreationFailed
        }
        let requestPath = "/live/\(UUID().uuidString.lowercased()).ts"
        self.requestPath = requestPath
        mediaURL = URL(
            string: "http://127.0.0.1:\(listener.port)\(requestPath)"
        )!
        let state = State(listenerDescriptor: listener.descriptor)
        self.state = state

        DispatchQueue.global(qos: .userInitiated).async {
            Self.acceptConnections(
                listenerDescriptor: listener.descriptor,
                requestPath: requestPath,
                state: state,
                streamFactory: streamFactory
            )
        }
    }

    deinit {
        stop()
    }

    /// Wakes readers blocked waiting for live bytes without destroying the
    /// listener. VLC can then reconnect to the same URL after a pipeline reset.
    func disconnectClients() {
        state.disconnectClients()
    }

    func stop() {
        state.stop()
    }

    private static func acceptConnections(
        listenerDescriptor: Int32,
        requestPath: String,
        state: State,
        streamFactory: @escaping @Sendable () -> InputStream
    ) {
        while true {
            let client = Darwin.accept(listenerDescriptor, nil, nil)
            if client < 0 {
                let error = errno
                if state.isStopped { return }
                if error == EINTR { continue }
                if error == EMFILE || error == ENFILE || error == ENOMEM {
                    usleep(100_000)
                    continue
                }
                logger.error(
                    "Local playback listener stopped after accept failed with errno \(error)"
                )
                return
            }
            disableSIGPIPE(on: client)
            let id = UUID()
            let connection = Connection(descriptor: client)
            guard state.register(connection, id: id) else {
                Darwin.close(client)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    state.removeConnection(id: id)
                    Darwin.close(client)
                }
                handle(
                    connection,
                    requestPath: requestPath,
                    streamFactory: streamFactory
                )
            }
        }
    }

    private static func handle(
        _ connection: Connection,
        requestPath: String,
        streamFactory: @escaping @Sendable () -> InputStream
    ) {
        guard let request = receiveHTTPHeader(from: connection.descriptor),
              let lineEnd = request.range(of: Data("\r\n".utf8)),
              let requestLine = String(
                data: request[..<lineEnd.lowerBound],
                encoding: .utf8
              )
        else {
            sendHTTPResponse(status: 400, to: connection.descriptor)
            return
        }
        let fields = requestLine.split(separator: " ", maxSplits: 2)
        guard fields.count == 3 else {
            sendHTTPResponse(status: 400, to: connection.descriptor)
            return
        }
        let method = fields[0].uppercased()
        guard method == "GET" || method == "HEAD" else {
            sendHTTPResponse(status: 405, to: connection.descriptor)
            return
        }
        let requestedPath = fields[1].split(separator: "?", maxSplits: 1)[0]
        guard requestedPath == Substring(requestPath) else {
            sendHTTPResponse(status: 404, to: connection.descriptor)
            return
        }

        let header = Data(
            (
                "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: video/mp2t\r\n"
                    + "Transfer-Encoding: chunked\r\n"
                    + "Cache-Control: no-store\r\n"
                    + "Connection: close\r\n"
                    + "\r\n"
            ).utf8
        )
        guard sendAll(header, to: connection.descriptor), method == "GET" else {
            return
        }

        let stream = streamFactory()
        guard connection.install(stream) else { return }
        stream.open()
        defer { stream.close() }

        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                if count == 0 {
                    _ = sendAll(Data("0\r\n\r\n".utf8), to: connection.descriptor)
                }
                return
            }
            guard sendChunk(
                Data(buffer[0..<count]),
                to: connection.descriptor
            ) else { return }
        }
    }

    private static func sendChunk(_ data: Data, to descriptor: Int32) -> Bool {
        sendAll(Data("\(String(data.count, radix: 16))\r\n".utf8), to: descriptor)
            && sendAll(data, to: descriptor)
            && sendAll(Data("\r\n".utf8), to: descriptor)
    }

    private static func sendHTTPResponse(status: Int, to descriptor: Int32) {
        let reason: String
        switch status {
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Error"
        }
        _ = sendAll(
            Data(
                "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    .utf8
            ),
            to: descriptor
        )
    }

    private static func makeListener() -> (descriptor: Int32, port: Int)? {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return nil }
        disableSIGPIPE(on: descriptor)
        var reuse: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout.size(ofValue: reuse))
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor)
            return nil
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return (
            descriptor,
            Int(in_port_t(bigEndian: boundAddress.sin_port))
        )
    }

    private static func receiveHTTPHeader(from descriptor: Int32) -> Data? {
        let marker = Data("\r\n\r\n".utf8)
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while request.count <= 32_768 {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            request.append(buffer, count: count)
            if request.range(of: marker) != nil { return request }
        }
        return nil
    }

    private static func sendAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: sent),
                    rawBuffer.count - sent,
                    0
                )
                if count > 0 {
                    sent += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func disableSIGPIPE(on descriptor: Int32) {
        var noSignal: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )
    }
}
