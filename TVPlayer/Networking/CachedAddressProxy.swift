import Darwin
import Foundation
import OSLog

struct CachedAddressRoutes: Equatable, Sendable {
    fileprivate let addressesByHost: [String: [String]]
    private let expiresAt: Date

    init?(_ configuration: TVHeadendConfiguration) {
        guard let observedAt = configuration.cachedAddressesObservedAt else { return nil }
        var routes: [String: [String]] = [:]
        if let host = configuration.baseURL?.host {
            routes[Self.normalized(host), default: []]
                .append(contentsOf: configuration.usableResolvedAddresses)
        }
        if let host = configuration.guideCacheURL?.host {
            routes[Self.normalized(host), default: []]
                .append(contentsOf: configuration.usableGuideResolvedAddresses)
        }
        routes = routes.compactMapValues { addresses in
            let unique = Self.unique(addresses)
            return unique.isEmpty ? nil : unique
        }
        guard !routes.isEmpty else { return nil }
        addressesByHost = routes
        expiresAt = observedAt.addingTimeInterval(
            TVHeadendConfiguration.cachedAddressLifetime
        )
    }

    fileprivate func addresses(for host: String) -> [String] {
        guard Date() <= expiresAt else { return [] }
        return addressesByHost[Self.normalized(host)] ?? []
    }

    private static func normalized(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}

struct VLCURLPlaybackRouting {
    private var hasStartedPlayback = false
    private var hasAttemptedFallback = false

    var initialProxyOption: String? { nil }

    mutating func markPlaybackStarted() {
        hasStartedPlayback = true
    }

    mutating func takeStartupFallbackOption(
        proxy: CachedAddressProxy?,
        url: URL
    ) -> String? {
        guard !hasStartedPlayback,
              !hasAttemptedFallback,
              let option = proxy?.vlcHTTPProxyOption(for: url)
        else { return nil }
        hasAttemptedFallback = true
        return option
    }
}

/// An immutable, scoped loopback proxy used only as a fallback for one
/// configuration. The logical URL remains visible to URLSession and VLC, so
/// Host, TLS SNI, certificate validation, redirects, and authentication keep
/// their original origin semantics.
final class CachedAddressProxy: @unchecked Sendable {
    enum ConnectionOrder: Sendable {
        case cachedAddressesFirst
        case logicalHostFirst
    }

    private static let logger = Logger(
        subsystem: "de.beutner.TVPlayer",
        category: "CachedAddressProxy"
    )

    private final class ListenerState: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        var isStopped: Bool {
            lock.withLock { descriptor < 0 }
        }

        func stop() {
            let currentDescriptor = lock.withLock {
                let current = self.descriptor
                self.descriptor = -1
                return current
            }
            guard currentDescriptor >= 0 else { return }
            _ = Darwin.shutdown(currentDescriptor, SHUT_RDWR)
            Darwin.close(currentDescriptor)
        }
    }

    private let routes: CachedAddressRoutes
    private let listenerState: ListenerState
    let port: Int

    init?(
        routes: CachedAddressRoutes?,
        connectionOrder: ConnectionOrder = .cachedAddressesFirst
    ) {
        guard let routes, let listener = Self.makeListener() else { return nil }
        self.routes = routes
        port = listener.port
        let listenerState = ListenerState(descriptor: listener.descriptor)
        self.listenerState = listenerState
        DispatchQueue.global(qos: .userInitiated).async {
            Self.acceptConnections(
                listenerDescriptor: listener.descriptor,
                listenerState: listenerState,
                routes: routes,
                connectionOrder: connectionOrder
            )
        }
    }

    convenience init?(
        configuration: TVHeadendConfiguration,
        connectionOrder: ConnectionOrder = .cachedAddressesFirst
    ) {
        self.init(
            routes: CachedAddressRoutes(configuration),
            connectionOrder: connectionOrder
        )
    }

    deinit {
        listenerState.stop()
    }

    func configure(_ sessionConfiguration: URLSessionConfiguration) {
        var proxies = sessionConfiguration.connectionProxyDictionary ?? [:]
        proxies["HTTPEnable"] = 1
        proxies["HTTPProxy"] = "127.0.0.1"
        proxies["HTTPPort"] = port
        proxies["HTTPSEnable"] = 1
        proxies["HTTPSProxy"] = "127.0.0.1"
        proxies["HTTPSPort"] = port
        sessionConfiguration.connectionProxyDictionary = proxies
    }

    func vlcHTTPProxyOption(for url: URL) -> String? {
        guard let host = url.host, !routes.addresses(for: host).isEmpty else { return nil }
        return ":http-proxy=http://127.0.0.1:\(port)"
    }

    private static func acceptConnections(
        listenerDescriptor: Int32,
        listenerState: ListenerState,
        routes: CachedAddressRoutes,
        connectionOrder: ConnectionOrder
    ) {
        while true {
            let client = Darwin.accept(listenerDescriptor, nil, nil)
            if client < 0 {
                let error = errno
                if listenerState.isStopped { return }
                guard !isFatalAcceptError(error) else {
                    logger.error(
                        "Proxy listener stopped after accept failed with errno \(error)"
                    )
                    return
                }
                if shouldBackOffAfterAcceptError(error) {
                    // Avoid a tight retry loop while the process or system is
                    // temporarily unable to allocate another socket.
                    usleep(100_000)
                }
                continue
            }
            Self.disableSIGPIPE(on: client)
            DispatchQueue.global(qos: .utility).async {
                handleHTTPProxyConnection(
                    client,
                    routes: routes,
                    connectionOrder: connectionOrder
                )
            }
        }
    }

    static func isFatalAcceptError(_ error: Int32) -> Bool {
        switch error {
        case EBADF, EINVAL, ENOTSOCK, EOPNOTSUPP:
            true
        default:
            false
        }
    }

    static func shouldBackOffAfterAcceptError(_ error: Int32) -> Bool {
        switch error {
        case EMFILE, ENFILE, ENOMEM:
            true
        default:
            false
        }
    }

    private static func handleHTTPProxyConnection(
        _ client: Int32,
        routes: CachedAddressRoutes,
        connectionOrder: ConnectionOrder
    ) {
        defer { Darwin.close(client) }
        guard let request = Self.receiveHTTPHeader(from: client),
              let firstLineEnd = request.data.range(of: Data("\r\n".utf8)),
              let firstLine = String(
                data: request.data[..<firstLineEnd.lowerBound],
                encoding: .utf8
              )
        else {
            Self.sendHTTPError(400, to: client)
            return
        }

        let fields = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard fields.count == 3 else {
            Self.sendHTTPError(400, to: client)
            return
        }

        if fields[0].caseInsensitiveCompare("CONNECT") == .orderedSame {
            guard let target = Self.hostAndPort(fromAuthority: fields[1], defaultPort: 443),
                  let upstream = connect(
                    host: target.host,
                    port: target.port,
                    routes: routes,
                    connectionOrder: connectionOrder
                  )
            else {
                Self.sendHTTPError(502, to: client)
                return
            }
            defer { Darwin.close(upstream) }
            guard Self.sendAll(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), to: client)
            else { return }
            Self.tunnel(client, upstream)
            return
        }

        guard let url = URL(string: fields[1]),
              let host = url.host,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            Self.sendHTTPError(400, to: client)
            return
        }
        let targetPort = url.port ?? (scheme == "https" ? 443 : 80)
        guard let upstream = connect(
            host: host,
            port: targetPort,
            routes: routes,
            connectionOrder: connectionOrder
        ) else {
            Self.sendHTTPError(502, to: client)
            return
        }
        defer { Darwin.close(upstream) }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = nil
        components?.host = nil
        components?.port = nil
        components?.user = nil
        components?.password = nil
        let target = components?.string?.nilIfEmpty ?? "/"
        let rewrittenLine = "\(fields[0]) \(target) \(fields[2])"
        let remainingHeader = request.data[firstLineEnd.upperBound..<request.headerEnd]
        guard var headerText = String(data: remainingHeader, encoding: .isoLatin1) else {
            Self.sendHTTPError(400, to: client)
            return
        }
        headerText = Self.connectionClosingHeader(headerText)
        var forwarded = Data("\(rewrittenLine)\r\n\(headerText)\r\n\r\n".utf8)
        if request.bodyStart < request.data.endIndex {
            forwarded.append(request.data[request.bodyStart...])
        }
        guard Self.sendAll(forwarded, to: upstream) else { return }
        Self.tunnel(client, upstream)
    }

    private static func connect(
        host: String,
        port: Int,
        routes: CachedAddressRoutes,
        connectionOrder: ConnectionOrder
    ) -> Int32? {
        for candidate in connectionCandidates(
            host: host,
            cachedAddresses: routes.addresses(for: host),
            connectionOrder: connectionOrder
        ) {
            if let descriptor = Self.connectSocket(host: candidate, port: port) {
                return descriptor
            }
        }
        return nil
    }

    static func connectionCandidates(
        host: String,
        cachedAddresses: [String],
        connectionOrder: ConnectionOrder
    ) -> [String] {
        let ordered: [String]
        switch connectionOrder {
        case .cachedAddressesFirst:
            ordered = cachedAddresses + [host]
        case .logicalHostFirst:
            ordered = [host] + cachedAddresses
        }
        var seen: Set<String> = []
        return ordered.filter { seen.insert($0.lowercased()).inserted }
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
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 16) == 0 else {
            Darwin.close(descriptor)
            return nil
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return (descriptor, Int(in_port_t(bigEndian: bound.sin_port)))
    }

    private static func connectSocket(host: String, port: Int) -> Int32? {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result
        else { return nil }
        defer { freeaddrinfo(result) }

        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let info = candidate?.pointee {
            let descriptor = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if descriptor >= 0 {
                disableSIGPIPE(on: descriptor)
                let oldFlags = fcntl(descriptor, F_GETFL)
                _ = fcntl(descriptor, F_SETFL, oldFlags | O_NONBLOCK)
                let status = Darwin.connect(descriptor, info.ai_addr, info.ai_addrlen)
                if status == 0 || errno == EINPROGRESS {
                    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    if status == 0 || Darwin.poll(&pollDescriptor, 1, 3_000) > 0 {
                        var socketError: Int32 = 0
                        var errorLength = socklen_t(MemoryLayout.size(ofValue: socketError))
                        getsockopt(
                            descriptor,
                            SOL_SOCKET,
                            SO_ERROR,
                            &socketError,
                            &errorLength
                        )
                        if socketError == 0 {
                            _ = fcntl(descriptor, F_SETFL, oldFlags)
                            return descriptor
                        }
                    }
                }
                Darwin.close(descriptor)
            }
            candidate = info.ai_next
        }
        return nil
    }

    private static func receiveHTTPHeader(
        from descriptor: Int32
    ) -> (data: Data, headerEnd: Data.Index, bodyStart: Data.Index)? {
        let marker = Data("\r\n\r\n".utf8)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while data.count <= 65_536 {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
            if let range = data.range(of: marker) {
                return (data, range.lowerBound, range.upperBound)
            }
        }
        return nil
    }

    private static func hostAndPort(
        fromAuthority authority: String,
        defaultPort: Int
    ) -> (host: String, port: Int)? {
        guard let components = URLComponents(string: "http://\(authority)"),
              let host = components.host
        else { return nil }
        return (host, components.port ?? defaultPort)
    }

    private static func connectionClosingHeader(_ header: String) -> String {
        var lines = header.components(separatedBy: "\r\n").filter {
            !$0.lowercased().hasPrefix("connection:")
                && !$0.lowercased().hasPrefix("proxy-connection:")
        }
        lines.append("Connection: close")
        return lines.joined(separator: "\r\n")
    }

    private static func sendHTTPError(_ status: Int, to descriptor: Int32) {
        let reason = status == 502 ? "Bad Gateway" : "Bad Request"
        _ = sendAll(
            Data("HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8),
            to: descriptor
        )
    }

    private static func tunnel(_ first: Int32, _ second: Int32) {
        var descriptors = [
            pollfd(fd: first, events: Int16(POLLIN), revents: 0),
            pollfd(fd: second, events: Int16(POLLIN), revents: 0),
        ]
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let pollResult = Darwin.poll(&descriptors, nfds_t(descriptors.count), -1)
            if pollResult < 0, errno == EINTR { continue }
            guard pollResult > 0 else { return }
            for index in descriptors.indices where descriptors[index].revents & Int16(POLLIN) != 0 {
                let source = descriptors[index].fd
                let destination = descriptors[index == 0 ? 1 : 0].fd
                let count = Darwin.recv(source, &buffer, buffer.count, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0,
                      sendAll(Data(buffer[0..<count]), to: destination)
                else { return }
            }
            // A peer can close immediately after writing, producing POLLIN
            // and POLLHUP together. Drain the readable bytes before treating
            // the hangup as terminal or large HTTP responses are truncated.
            if descriptors.contains(where: {
                $0.revents & Int16(POLLIN) == 0
                    && $0.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0
            }) { return }
        }
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
