import XCTest
@testable import TVApp

final class PlatformAdaptationTests: XCTestCase {
    func testAdaptiveCardMetricsRemainUsableOnCurrentPlatform() {
        XCTAssertGreaterThanOrEqual(PlatformLayout.channelCardMinimumWidth, 280)
        XCTAssertGreaterThanOrEqual(PlatformLayout.recordingCardMinimumWidth, 280)
        XCTAssertGreaterThanOrEqual(PlatformLayout.contentPadding, 20)
    }

    func testPlatformMoveDirectionsAreDistinct() {
        let directions: Set<String> = [
            String(describing: PlatformMoveDirection.up),
            String(describing: PlatformMoveDirection.down),
            String(describing: PlatformMoveDirection.left),
            String(describing: PlatformMoveDirection.right),
        ]
        XCTAssertEqual(directions.count, 4)
    }
}
