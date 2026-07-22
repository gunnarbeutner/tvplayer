import Foundation
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

    func testTicketedPlaylistChannelsAreParsedCentrally() {
        let channels = TVHeadendClient.playlistChannels(in: #"""
        #EXTM3U
        #EXTINF:-1 tvg-id="news",World News
        http://tvheadend.test:9981/stream/channelid/42?ticket=one
        #EXTINF:-1 tvg-id="sports",Sports HD
        http://tvheadend.test:9981/stream/channelid/73?ticket=two
        """#)

        XCTAssertEqual(channels, [
            TVHeadendPlaylistChannel(id: 42, name: "World News"),
            TVHeadendPlaylistChannel(id: 73, name: "Sports HD"),
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

    func subscribe(channelID: UInt32, profile: String) throws -> (Int64, [HTSPStreamInfo]) {
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
