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
        XCTAssertEqual(PlaybackURLProtocol.requestCount(for: "/playlist/ticket/channels"), 2)
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
