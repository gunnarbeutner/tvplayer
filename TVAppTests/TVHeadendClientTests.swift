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

    func testEPGMetadataDecodesHighValueProgrammeFields() throws {
        let data = Data(#"""
        {
          "eventId": 123,
          "channelUuid": "channel-1",
          "title": "Example",
          "summary": "A concise summary.",
          "extraText": "An extended description.",
          "start": 1760000000,
          "stop": 1760003600,
          "seasonNumber": 2,
          "seasonCount": 4,
          "episodeNumber": 3,
          "episodeCount": 8,
          "episodeOnscreen": "S02E03",
          "partNumber": 1,
          "partCount": 2,
          "firstAired": 1700000000,
          "copyright_year": 1999,
          "genre": [16, 64],
          "ratingLabel": "FSK 12",
          "ratingCountry": "DE",
          "ratingAuthority": "FSK"
        }
        """#.utf8)

        let event = try JSONDecoder().decode(TVHeadendEPGEvent.self, from: data)
        let metadata = GuideProgramMetadata(
            seasonNumber: event.seasonNumber,
            seasonCount: event.seasonCount,
            episodeNumber: event.episodeNumber,
            episodeCount: event.episodeCount,
            episodeOnscreen: event.episodeOnscreen,
            partNumber: event.partNumber,
            partCount: event.partCount,
            firstAired: event.firstAired,
            copyrightYear: event.copyrightYear,
            genres: event.genres,
            summary: event.summary,
            extraText: event.extraText,
            ratingLabel: event.ratingLabel,
            ratingCountry: event.ratingCountry,
            ratingAuthority: event.ratingAuthority
        )

        XCTAssertEqual(metadata.displayLabels.first, "Season 2 of 4 · Episode 3 of 8")
        XCTAssertTrue(metadata.displayLabels.contains("Part 1 of 2"))
        XCTAssertTrue(metadata.displayLabels.contains("Movie / Drama"))
        XCTAssertTrue(metadata.displayLabels.contains("Sports"))
        XCTAssertTrue(metadata.displayLabels.contains("FSK 12"))
        XCTAssertFalse(metadata.displayFacts.contains("Broadcast episode S02E03"))
        XCTAssertTrue(metadata.displayFacts.contains("Year 1999"))
        XCTAssertTrue(metadata.displayFacts.contains("Rating source FSK · DE"))
        XCTAssertEqual(
            metadata.supplementaryDescriptions(excluding: "A concise summary."),
            ["An extended description."]
        )
    }

    func testDistinctBroadcastEpisodeIdentifierRemainsVisible() {
        let metadata = GuideProgramMetadata(
            seasonNumber: "2",
            episodeNumber: "3",
            episodeOnscreen: "Special 14"
        )

        XCTAssertTrue(metadata.displayFacts.contains("Broadcast episode Special 14"))
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
            xmltvURL: nil,
            resolvedAddresses: ["127.0.0.1"],
            cachedAddressesObservedAt: Date()
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
            resolvedAddresses: ["127.0.0.1"],
            cachedAddressesObservedAt: Date()
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        let proxy = try XCTUnwrap(CachedAddressProxy(configuration: configuration))
        proxy.configure(sessionConfiguration)
        let proxyPort = proxy.port

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

    func testCachedAddressProxyDoesNotRerouteAnExistingClientWhenAnotherClientUsesTheSameHost() throws {
        let firstOrigin = try ProxyTestOriginServer(
            bindAddress: "127.0.0.1",
            responseBody: Data("first".utf8)
        )
        let secondOrigin = try ProxyTestOriginServer(
            bindAddress: "::1",
            port: firstOrigin.port,
            responseBody: Data("second".utf8)
        )
        let logicalHost = "shared-cached-address-\(UUID().uuidString).local"
        let firstConfiguration = TVHeadendConfiguration(
            baseURL: URL(string: "http://\(logicalHost):\(firstOrigin.port)")!,
            username: "",
            password: "",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil,
            resolvedAddresses: ["127.0.0.1"],
            cachedAddressesObservedAt: Date()
        )
        let secondConfiguration = TVHeadendConfiguration(
            baseURL: URL(string: "http://\(logicalHost):\(secondOrigin.port)")!,
            username: "",
            password: "",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil,
            resolvedAddresses: ["::1"],
            cachedAddressesObservedAt: Date()
        )
        let firstProxy = try XCTUnwrap(CachedAddressProxy(configuration: firstConfiguration))
        let firstProxyPort = firstProxy.port
        let secondProxy = try XCTUnwrap(CachedAddressProxy(configuration: secondConfiguration))
        _ = secondProxy.port

        let response = try Self.sendRawProxyRequest(
            proxyPort: firstProxyPort,
            request: "GET http://\(logicalHost):\(firstOrigin.port)/status HTTP/1.1\r\n"
                + "Host: \(logicalHost):\(firstOrigin.port)\r\n"
                + "Connection: close\r\n\r\n"
        )

        XCTAssertTrue(response.hasSuffix("first"))
        XCTAssertNotNil(firstOrigin.receivedRequest)
        XCTAssertNil(secondOrigin.receivedRequest)
    }

    func testCachedAddressProxyDrainsResponseBeforeHandlingHangup() throws {
        let responseBody = Data(repeating: 0x41, count: 256 * 1_024)
        let origin = try ProxyTestOriginServer(responseBody: responseBody)
        let logicalHost = "cached-address-\(UUID().uuidString).local"
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://\(logicalHost):\(origin.port)")!,
            username: "",
            password: "",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil,
            resolvedAddresses: ["127.0.0.1"],
            cachedAddressesObservedAt: Date()
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        let proxy = try XCTUnwrap(CachedAddressProxy(configuration: configuration))
        proxy.configure(sessionConfiguration)
        let proxyPort = proxy.port

        let response = try Self.sendRawProxyRequestData(
            proxyPort: proxyPort,
            request: "GET http://\(logicalHost):\(origin.port)/guide HTTP/1.1\r\n"
                + "Host: \(logicalHost):\(origin.port)\r\n"
                + "Connection: close\r\n\r\n"
        )
        let separator = Data("\r\n\r\n".utf8)
        let headerRange = try XCTUnwrap(response.range(of: separator))

        XCTAssertEqual(Data(response[headerRange.upperBound...]), responseBody)
    }

    func testCachedAddressProxyKeepsAcceptingAfterRecoverableErrors() {
        XCTAssertFalse(CachedAddressProxy.isFatalAcceptError(EINTR))
        XCTAssertFalse(CachedAddressProxy.isFatalAcceptError(ECONNABORTED))
        XCTAssertFalse(CachedAddressProxy.isFatalAcceptError(EMFILE))
        XCTAssertFalse(CachedAddressProxy.isFatalAcceptError(ENFILE))
        XCTAssertFalse(CachedAddressProxy.isFatalAcceptError(ENOMEM))

        XCTAssertTrue(CachedAddressProxy.shouldBackOffAfterAcceptError(EMFILE))
        XCTAssertTrue(CachedAddressProxy.shouldBackOffAfterAcceptError(ENFILE))
        XCTAssertTrue(CachedAddressProxy.shouldBackOffAfterAcceptError(ENOMEM))
        XCTAssertFalse(CachedAddressProxy.shouldBackOffAfterAcceptError(ECONNABORTED))
    }

    func testCachedAddressProxyStopsForInvalidListenerErrors() {
        XCTAssertTrue(CachedAddressProxy.isFatalAcceptError(EBADF))
        XCTAssertTrue(CachedAddressProxy.isFatalAcceptError(EINVAL))
        XCTAssertTrue(CachedAddressProxy.isFatalAcceptError(ENOTSOCK))
        XCTAssertTrue(CachedAddressProxy.isFatalAcceptError(EOPNOTSUPP))
    }

    func testCachedAddressProxyCanPreferCurrentNameResolutionForPlayback() {
        XCTAssertEqual(
            CachedAddressProxy.connectionCandidates(
                host: "tvheadend.local",
                cachedAddresses: ["192.168.1.20", "192.168.1.21"],
                connectionOrder: .logicalHostFirst
            ),
            ["tvheadend.local", "192.168.1.20", "192.168.1.21"]
        )
        XCTAssertEqual(
            CachedAddressProxy.connectionCandidates(
                host: "tvheadend.local",
                cachedAddresses: ["192.168.1.20", "tvheadend.local"],
                connectionOrder: .cachedAddressesFirst
            ),
            ["192.168.1.20", "tvheadend.local"]
        )
    }

    func testVLCPlaybackUsesCachedAddressProxyOnlyAsOneTimeStartupFallback() throws {
        let logicalHost = "cached-address-\(UUID().uuidString).local"
        let url = try XCTUnwrap(URL(string: "http://\(logicalHost):9981/stream/channel/1"))
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://\(logicalHost):9981")!,
            username: "",
            password: "",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil,
            resolvedAddresses: ["192.0.2.10"],
            cachedAddressesObservedAt: Date()
        )
        let proxy = try XCTUnwrap(CachedAddressProxy(configuration: configuration))
        var routing = VLCURLPlaybackRouting()

        XCTAssertNil(routing.initialProxyOption)
        XCTAssertNotNil(routing.takeStartupFallbackOption(proxy: proxy, url: url))
        XCTAssertNil(routing.takeStartupFallbackOption(proxy: proxy, url: url))

        var startedRouting = VLCURLPlaybackRouting()
        startedRouting.markPlaybackStarted()
        XCTAssertNil(startedRouting.takeStartupFallbackOption(proxy: proxy, url: url))
    }

    func testCachedAddressFallbackOnlyRetriesPreConnectionFailures() {
        XCTAssertTrue(TVHeadendClient.shouldRetryUsingCachedAddress(
            after: URLError(.cannotFindHost)
        ))
        XCTAssertTrue(TVHeadendClient.shouldRetryUsingCachedAddress(
            after: URLError(.dnsLookupFailed)
        ))
        XCTAssertTrue(TVHeadendClient.shouldRetryUsingCachedAddress(
            after: URLError(.cannotConnectToHost)
        ))
        XCTAssertFalse(TVHeadendClient.shouldRetryUsingCachedAddress(
            after: URLError(.timedOut)
        ))
        XCTAssertFalse(TVHeadendClient.shouldRetryUsingCachedAddress(
            after: URLError(.networkConnectionLost)
        ))
    }

    func testCachedAddressRoutesExpireInsteadOfPersistingIndefinitely() {
        let staleConfiguration = TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.local:9981")!,
            username: "",
            password: "",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil,
            resolvedAddresses: ["192.168.1.20"],
            cachedAddressesObservedAt: Date().addingTimeInterval(-301)
        )

        XCTAssertNil(CachedAddressRoutes(staleConfiguration))
        XCTAssertEqual(staleConfiguration.htspConnectionHosts, ["tvheadend.local"])
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
        let response = try sendRawProxyRequestData(proxyPort: proxyPort, request: request)
        return String(decoding: response, as: UTF8.self)
    }

    private static func sendRawProxyRequestData(proxyPort: Int, request: String) throws -> Data {
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
        return response
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
    private let responseBody: Data
    private var request: String?
    let port: Int

    var receivedRequest: String? { lock.withLock { request } }

    init(
        bindAddress: String = "127.0.0.1",
        port: Int = 0,
        responseBody: Data = Data("OK".utf8)
    ) throws {
        let family = bindAddress.contains(":") ? AF_INET6 : AF_INET
        let descriptor = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw ProxyTestError.socketCreationFailed }
        self.descriptor = descriptor
        self.responseBody = responseBody
        var noSignal: Int32 = 1
        var reuseAddress: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout.size(ofValue: reuseAddress))
        )
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEPORT,
            &reuseAddress,
            socklen_t(MemoryLayout.size(ofValue: reuseAddress))
        )
        if family == AF_INET6 {
            var ipv6Only: Int32 = 1
            setsockopt(
                descriptor,
                IPPROTO_IPV6,
                IPV6_V6ONLY,
                &ipv6Only,
                socklen_t(MemoryLayout.size(ofValue: ipv6Only))
            )
        }

        let status: Int32
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(bigEndian: in_port_t(port))
            guard bindAddress.withCString({
                inet_pton(AF_INET6, $0, &address.sin6_addr)
            }) == 1 else {
                Darwin.close(descriptor)
                throw ProxyTestError.bindFailed
            }
            status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(bigEndian: in_port_t(port))
            address.sin_addr = in_addr(s_addr: inet_addr(bindAddress))
            status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
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

        var boundAddress = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let nameStatus = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameStatus == 0 else {
            Darwin.close(descriptor)
            throw ProxyTestError.socketNameFailed
        }
        if family == AF_INET6 {
            self.port = withUnsafePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    Int(in_port_t(bigEndian: $0.pointee.sin6_port))
                }
            }
        } else {
            self.port = withUnsafePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    Int(in_port_t(bigEndian: $0.pointee.sin_port))
                }
            }
        }

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
        var response = Data(
            "HTTP/1.1 200 OK\r\nContent-Length: \(responseBody.count)\r\n"
                .appending("Connection: close\r\n\r\n")
                .utf8
        )
        response.append(responseBody)
        _ = sendAll(response, to: client)
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
    ) throws -> HTSPSubscriptionStart {
        lock.withLock { subscriptions += 1 }
        return HTSPSubscriptionStart(timeshiftPeriod: 60, streams: [], sourceInfo: nil)
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
