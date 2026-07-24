import Foundation
import XCTest
@testable import TVApp

final class VLCLoopbackHTTPTransportTests: XCTestCase {
    func testServesEachRequestAsAChunkedTransportStream() async throws {
        let payload = Data((0..<1_024).map { UInt8($0 % 251) })
        let factory = StreamFactory(payload: payload)
        let transport = try VLCLoopbackHTTPTransport {
            factory.makeStream()
        }
        defer { transport.stop() }

        let (firstData, firstResponse) = try await URLSession.shared.data(
            from: transport.mediaURL
        )
        let (secondData, secondResponse) = try await URLSession.shared.data(
            from: transport.mediaURL
        )

        XCTAssertEqual(firstData, payload)
        XCTAssertEqual(secondData, payload)
        XCTAssertEqual((firstResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(
            (firstResponse as? HTTPURLResponse)?.value(
                forHTTPHeaderField: "Content-Type"
            ),
            "video/mp2t"
        )
        XCTAssertEqual(factory.streamCount, 2)
    }

    func testRejectsRequestsWithoutTheSessionToken() async throws {
        let factory = StreamFactory(payload: Data([0x47]))
        let transport = try VLCLoopbackHTTPTransport {
            factory.makeStream()
        }
        defer { transport.stop() }
        let unknownURL = try XCTUnwrap(
            URL(string: "/not-the-session-token", relativeTo: transport.mediaURL)
        )

        let (_, response) = try await URLSession.shared.data(from: unknownURL)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(factory.streamCount, 0)
    }
}

private final class StreamFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let payload: Data
    private var count = 0

    init(payload: Data) {
        self.payload = payload
    }

    var streamCount: Int {
        lock.withLock { count }
    }

    func makeStream() -> InputStream {
        lock.withLock { count += 1 }
        return InputStream(data: payload)
    }
}
