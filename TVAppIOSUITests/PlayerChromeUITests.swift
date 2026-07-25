import XCTest

final class PlayerChromeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--playback-ui-testing"]
        app.launchEnvironment = [
            "TVPLAYER_TVH_URL": "http://playback-replay.invalid",
            "TVPLAYER_TVH_USERNAME": "replay",
            "TVPLAYER_TVH_PASSWORD": "replay",
            "TVPLAYER_TVH_PROFILE": "pass",
            "TVPLAYER_TVH_HTSP_PORT": "9982",
            "TVPLAYER_TRANSIENT_ENVIRONMENT_PROFILE": "1",
            "TVPLAYER_AUTOPLAY": "1",
            "TVPLAYER_PLAYBACK_REPLAY": "1",
        ]
        app.launch()
    }

    override func tearDown() {
        if app.state != .notRunning {
            app.terminate()
        }
        app = nil
        super.tearDown()
    }

    func testTimelineAutoHidesAgainAfterTapToReveal() {
        let timeline = app.descendants(matching: .any)[
            "tvplayer.playback.chrome.timeline"
        ]
        XCTAssertTrue(
            timeline.waitForExistence(timeout: 12),
            "The playback timeline never appeared."
        )
        XCTAssertTrue(
            waitForDisappearance(of: timeline, timeout: 8),
            "The initial playback timeline did not auto-hide."
        )

        app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)
        ).tap()
        XCTAssertTrue(
            timeline.waitForExistence(timeout: 3),
            "Tapping the video did not reveal the playback timeline."
        )
        XCTAssertTrue(
            waitForDisappearance(of: timeline, timeout: 8),
            "The playback timeline did not auto-hide after being revealed."
        )
    }

    @MainActor
    func testIPadGuidePreviewIsEmbeddedAndOtherTabsUseTopMiniPlayerBar() {
        let closePlayer = app.buttons["Close Player"]
        XCTAssertTrue(
            closePlayer.waitForExistence(timeout: 12),
            "The player close control never appeared."
        )
        closePlayer.tap()

        tabButton(named: "Guide").tap()
        let miniPlayer = app.descendants(matching: .any)
            .matching(identifier: "tvplayer.mini-player")
            .element(boundBy: 0)
        XCTAssertFalse(
            miniPlayer.waitForExistence(timeout: 2),
            "A separate mini-player obscured the Guide's embedded preview."
        )

        tabButton(named: "Channels").tap()
        XCTAssertTrue(
            miniPlayer.waitForExistence(timeout: 5),
            "The retained playback mini-player did not appear on Channels."
        )
        XCTAssertLessThan(
            miniPlayer.frame.midY,
            app.frame.height * 0.35,
            "The iPad mini-player is not presented as a bar at the top."
        )
    }

    private func waitForDisappearance(
        of element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    @MainActor
    private func tabButton(named name: String) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label == %@", name))
            .element(boundBy: 0)
    }
}
