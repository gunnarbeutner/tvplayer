import Foundation
import Darwin
import XCTest
@testable import TVApp

final class TVHeadendClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PlaybackURLProtocol.reset()
    }

    override func tearDown() {
        PlaybackURLProtocol.reset()
        super.tearDown()
    }

    func testLivePlaybackRequestsCacheServerCapabilities() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PlaybackURLProtocol.self]
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.test:9981")!,
            username: "",
            password: "",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )
        let client = TVHeadendClient(
            configuration: configuration,
            sessionConfiguration: sessionConfiguration
        )

        let first = try await client.livePlaybackRequest(channelID: "channel-1")
        let second = try await client.livePlaybackRequest(channelID: "channel-1")

        guard case .live(.nativeTimeshift) = first.kind,
              case .live(.nativeTimeshift) = second.kind
        else {
            return XCTFail("Expected cached timeshift capability to select native playback")
        }
        XCTAssertEqual(PlaybackURLProtocol.requestCount(for: "/api/serverinfo"), 1)
        XCTAssertEqual(PlaybackURLProtocol.requestCount(for: "/playlist/ticket/channels"), 1)
    }

    func testHTSPPrewarmingAuthenticatesWithoutSubscribing() async throws {
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.test:9981")!,
            username: "viewer",
            password: "secret",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )
        let connection = PrewarmHTSPConnection()
        let prewarmer = HTSPConnectionPrewarmer()

        await prewarmer.preconnect(
            configuration: configuration,
            connectionFactory: { connection }
        )
        let warmed = await prewarmer.takeConnection(configuration: configuration)

        XCTAssertNotNil(warmed)
        XCTAssertEqual(connection.handshakeCount, 1)
        XCTAssertEqual(connection.subscribeCount, 0)
        warmed?.close()
    }

    func testHTTPAuthenticationIsRestrictedToTheConfiguredServerOrigin() {
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.test:9981")!,
            username: "viewer",
            password: "secret",
            streamProfile: "pass",
            guideCacheURL: URL(string: "http://guide.test:49382/guide.json"),
            xmltvURL: nil
        )

        XCTAssertTrue(TVHeadendClient.isServerProtectionSpace(
            protectionSpace(host: "TVHEADEND.TEST", port: 9981, protocol: "http"),
            for: configuration
        ))
        XCTAssertFalse(TVHeadendClient.isServerProtectionSpace(
            protectionSpace(host: "guide.test", port: 49382, protocol: "http"),
            for: configuration
        ))
        XCTAssertFalse(TVHeadendClient.isServerProtectionSpace(
            protectionSpace(host: "tvheadend.test", port: 8080, protocol: "http"),
            for: configuration
        ))
        XCTAssertFalse(TVHeadendClient.isServerProtectionSpace(
            protectionSpace(host: "tvheadend.test", port: 9981, protocol: "https"),
            for: configuration
        ))
    }

    func testClientIsReleasedAfterCompletingRequest() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PlaybackURLProtocol.self]
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.test:9981")!,
            username: "",
            password: "",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )
        weak var weakClient: TVHeadendClient?

        do {
            let client = TVHeadendClient(
                configuration: configuration,
                sessionConfiguration: sessionConfiguration
            )
            weakClient = client
            _ = try await client.serverInfo()
        }

        for _ in 0..<20 where weakClient != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(weakClient)
    }

    func testCachedAddressProxyPreservesTheLogicalRequestHost() throws {
        let origin = try ProxyTestOriginServer()
        let logicalHost = "cached-address-\(UUID().uuidString).local"
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://\(logicalHost):\(origin.port)")!,
            username: "",
            password: "",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil,
            resolvedAddresses: ["127.0.0.1"]
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        let proxy = CachedAddressProxy.shared
        proxy.configure(sessionConfiguration, for: configuration)
        let proxyPort = try XCTUnwrap(proxy.port)

        let proxySettings = try XCTUnwrap(sessionConfiguration.connectionProxyDictionary)
        XCTAssertEqual(proxySettings["HTTPProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(proxySettings["HTTPPort"] as? Int, proxyPort)

        let response = try Self.sendRawProxyRequest(
            proxyPort: proxyPort,
            request: "GET http://\(logicalHost):\(origin.port)/status?detail=1 HTTP/1.1\r\n"
                + "Host: \(logicalHost):\(origin.port)\r\n"
                + "Connection: close\r\n\r\n"
        )
        let receivedRequest = try XCTUnwrap(origin.receivedRequest)

        XCTAssertTrue(response.contains("200 OK"))
        XCTAssertTrue(receivedRequest.hasPrefix("GET /status?detail=1 HTTP/1.1\r\n"))
        XCTAssertTrue(receivedRequest.lowercased().contains(
            "\r\nhost: \(logicalHost.lowercased()):\(origin.port)\r\n"
        ))
    }

    func testTicketedPlaylistChannelsAreParsedCentrally() {
        let channels = TVHeadendClient.playlistChannels(in: #"""
        #EXTM3U
        #EXTINF:-1 tvg-id="news",World News
        http://tvheadend.test:9981/stream/channelid/42?ticket=one
        #EXTINF:-1 tvg-id="sports",Sports HD
        http://tvheadend.test:9981/stream/channelid/73?ticket=two
        """#)

        XCTAssertEqual(channels, [
            TVHeadendPlaylistChannel(id: 42, name: "World News", playlistID: "news"),
            TVHeadendPlaylistChannel(id: 73, name: "Sports HD", playlistID: "sports"),
        ])
    }

    @MainActor
    func testPlaybackStartIntentSupersedesAndCancelsPreviousTask() {
        let intents = PlaybackStartIntentTracker()
        let firstID = intents.begin()
        let firstTask = Task<Void, Never> {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                // Cancellation is the expected outcome.
            }
        }
        intents.attach(firstTask, to: firstID)

        let secondID = intents.begin()

        XCTAssertTrue(firstTask.isCancelled)
        XCTAssertFalse(intents.isCurrent(firstID))
        XCTAssertTrue(intents.isCurrent(secondID))
        intents.finish(secondID)
        XCTAssertFalse(intents.isCurrent(secondID))
    }

    private func protectionSpace(
        host: String,
        port: Int,
        protocol: String
    ) -> URLProtectionSpace {
        URLProtectionSpace(
            host: host,
            port: port,
            protocol: `protocol`,
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPDigest
        )
    }

    private static func sendRawProxyRequest(proxyPort: Int, request: String) throws -> String {
        let descriptor = try connectToLoopback(port: proxyPort)
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
        guard sendAll(Data(request.utf8), to: descriptor) else {
            throw ProxyTestError.writeFailed
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count > 0 {
                response.append(buffer, count: count)
            } else {
                break
            }
        }
        return String(decoding: response, as: UTF8.self)
    }
}

private enum ProxyTestError: Error {
    case socketCreationFailed
    case bindFailed
    case listenFailed
    case socketNameFailed
    case connectFailed
    case writeFailed
}

private final class ProxyTestOriginServer: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var request: String?
    let port: Int

    var receivedRequest: String? { lock.withLock { request } }

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw ProxyTestError.socketCreationFailed }
        self.descriptor = descriptor
        var noSignal: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else {
            Darwin.close(descriptor)
            throw ProxyTestError.bindFailed
        }
        guard Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw ProxyTestError.listenFailed
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameStatus == 0 else {
            Darwin.close(descriptor)
            throw ProxyTestError.socketNameFailed
        }
        port = Int(in_port_t(bigEndian: boundAddress.sin_port))

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            serveOneRequest()
        }
    }

    deinit {
        Darwin.close(descriptor)
    }

    private func serveOneRequest() {
        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }

        let marker = Data("\r\n\r\n".utf8)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.range(of: marker) == nil {
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            data.append(buffer, count: count)
        }
        lock.withLock {
            request = String(decoding: data, as: UTF8.self)
        }
        _ = sendAll(
            Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".utf8),
            to: client
        )
    }
}

private func connectToLoopback(port: Int) throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard descriptor >= 0 else { throw ProxyTestError.socketCreationFailed }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(bigEndian: in_port_t(port))
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let status = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard status == 0 else {
        Darwin.close(descriptor)
        throw ProxyTestError.connectFailed
    }
    return descriptor
}

private func sendAll(_ data: Data, to descriptor: Int32) -> Bool {
    data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return true }
        var sent = 0
        while sent < buffer.count {
            let count = Darwin.send(
                descriptor,
                baseAddress.advanced(by: sent),
                buffer.count - sent,
                0
            )
            guard count > 0 else { return false }
            sent += count
        }
        return true
    }
}

private final class PrewarmHTSPConnection: HTSPConnectionTransport, @unchecked Sendable {
    let capabilities: Set<String> = ["timeshift"]
    private let lock = NSLock()
    private var handshakes = 0
    private var subscriptions = 0

    var handshakeCount: Int { lock.withLock { handshakes } }
    var subscribeCount: Int { lock.withLock { subscriptions } }

    func handshake(username: String, password: String) throws {
        lock.withLock { handshakes += 1 }
    }

    func subscribe(
        channelID: UInt32,
        profile: String,
        weight: UInt32
    ) throws -> (Int64, [HTSPStreamInfo]) {
        lock.withLock { subscriptions += 1 }
        return (60, [])
    }

    func reserveSequence() -> Int64 { 1 }

    func sendRequest(
        method: String,
        sequence: Int64,
        fields: [String: HTSPValue],
        includesSubscriptionID: Bool
    ) throws {}

    func readMessage() throws -> [String: HTSPValue] { throw HTSPError.disconnected }
    func close() {}
}

private final class PlaybackURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestCounts: [String: Int] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.recordRequest(for: url.path)

        let data: Data
        switch url.path {
        case "/api/serverinfo":
            data = Data(#"{"name":"TVHeadend","capabilities":["timeshift"]}"#.utf8)
        case "/playlist/ticket/channels":
            data = Data(
                #"""
                #EXTM3U
                #EXTINF:-1 tvg-id="channel-1",Channel 1
                http://tvheadend.test:9981/stream/channelid/42?ticket=fresh
                """#.utf8
            )
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        requestCounts = [:]
        lock.unlock()
    }

    static func requestCount(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounts[path, default: 0]
    }

    private static func recordRequest(for path: String) {
        lock.lock()
        requestCounts[path, default: 0] += 1
        lock.unlock()
    }
}
