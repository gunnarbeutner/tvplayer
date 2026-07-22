import XCTest
@testable import TVApp

final class AppRouteTests: XCTestCase {
    func testGuideRouteRoundTrips() {
        XCTAssertEqual(AppRoute(url: AppRoute.guide.url), .guide)
    }

    func testChannelRouteRoundTrips() {
        let route = AppRoute.playChannel("1fcc9c19e67d7a03f541aafc1a2e678f")
        XCTAssertEqual(AppRoute(url: route.url), route)
    }

    func testTopShelfChannelRouteRoundTripsLaunchContext() {
        let route = AppRoute.playChannel(
            "channel id",
            topShelf: TopShelfLaunchContext(
                programID: "programme/id",
                artworkFilename: "top-shelf-artwork-abcd.jpg"
            )
        )

        XCTAssertEqual(AppRoute(url: route.url), route)
    }

    func testRecordingRoutePercentEncodesItsIdentifier() {
        let route = AppRoute.playRecording("recording id ä")
        XCTAssertEqual(AppRoute(url: route.url), route)
    }

    func testRejectsUnknownRoutesAndSchemes() {
        XCTAssertNil(AppRoute(url: URL(string: "https://example.com/guide")!))
        XCTAssertNil(AppRoute(url: URL(string: "tvplayer://play/unknown/123")!))
    }

    func testOnlyPlayerRoutesOpenPlayback() {
        XCTAssertFalse(AppRoute.guide.opensPlayback)
        XCTAssertTrue(AppRoute.playChannel("channel").opensPlayback)
        XCTAssertTrue(AppRoute.playRecording("recording").opensPlayback)
    }
}
