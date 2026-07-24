import XCTest
import CoreGraphics

private struct PlaybackProbeSnapshot: Codable {
    let version: Int
    let sampledAt: TimeInterval
    let channelID: String?
    let presentationID: String?
    let playerPresented: Bool
    let launchVisible: Bool
    let engineState: String
    let vlcState: String
    let isPlaying: Bool
    let isSeekable: Bool
    let audioTrackCount: Int
    let displayedPictures: Int
    let playedAudioBuffers: Int
    let decodedVideo: Int
    let decodedAudio: Int
    let lostPictures: Int
    let lostAudioBuffers: Int
    let playbackTimeMilliseconds: Int64?
    let audioUnderruns: Int
    let lateClockCorrections: Int
    let earlyClockCorrections: Int
    let timeshiftWindowSeconds: TimeInterval
    let liveDelaySeconds: TimeInterval
    let bufferedBytes: Int64
    let concealed: Bool
    let navigationState: String
    let recoveryCount: Int
    let pipelineDiagnostic: String?
    let surfaceMode: String
    let surfaceWidth: Double
    let surfaceHeight: Double
    let videoTrackWidth: Int
    let videoTrackHeight: Int
    let videoSizeWidth: Double
    let videoSizeHeight: Double
}

private struct ReplayCalibrationGeometry: CustomStringConvertible {
    let topLeftWidth: Int
    let topLeftHeight: Int
    let topRightWidth: Int
    let topRightHeight: Int

    var description: String {
        "topLeft=\(topLeftWidth)x\(topLeftHeight), "
            + "topRight=\(topRightWidth)x\(topRightHeight)"
    }
}

private struct GuideFocusProbeSnapshot: Codable, CustomStringConvertible {
    let version: Int
    let sampledAt: TimeInterval
    let focusedProgramID: String?
    let focusedProgramChannelID: String?
    let focusedChannelID: String?
    let programMarkerIDs: [String]
    let channelMarkerIDs: [String]
    let displayedChannelIDs: [String]
    let focusableChannelIDs: [String]
    let favoriteChannelIDs: [String]
    let channelRestorationPending: Bool
    let markerOverlapCount: Int
    let programMarkerDuringChannelRestorationCount: Int

    var description: String {
        "program=\(String(describing: focusedProgramID)) "
            + "programChannel=\(String(describing: focusedProgramChannelID)) "
            + "channel=\(String(describing: focusedChannelID)) "
            + "programMarkers=\(programMarkerIDs) "
            + "channelMarkers=\(channelMarkerIDs) "
            + "favorites=\(favoriteChannelIDs) "
            + "restore=\(channelRestorationPending) "
            + "overlaps=\(markerOverlapCount) "
            + "restoreMarkers=\(programMarkerDuringChannelRestorationCount)"
    }
}

final class PlaybackAutomationUITests: XCTestCase {
    private let probeIdentifier = "tvplayer.playback.automation.probe"
    private var app: XCUIApplication!
    private var probeElement: XCUIElement!
    private var samples: [PlaybackProbeSnapshot] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        samples = []
        app = XCUIApplication()
    }

    override func tearDown() {
        if let app, app.state != .notRunning {
            if (testRun?.failureCount ?? 0) > 0 {
                let screenshot = XCUIScreen.main.screenshot()
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "Playback failure"
                attachment.lifetime = .keepAlways
                add(attachment)
                attachSamples()
            }
            app.terminate()
        }
        probeElement = nil
        app = nil
        super.tearDown()
    }

    func testReplayTuneSwitchSeekAndPlayerLifecycle() throws {
        launchReplay()

        let tuneStartedAt = ProcessInfo.processInfo.systemUptime
        var current = try waitForReadyPlayback(timeout: 8)
        XCTAssertEqual(current.channelID, "1001")
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - tuneStartedAt,
            8,
            "Cold replay tuning exceeded its functional budget."
        )
        current = try assertContinuousPlayback(from: current, duration: 10)

        for expectedChannel in ["1002", "1003", "1001"] {
            XCUIRemote.shared.press(.pageUp)
            current = try waitForReadyPlayback(
                channelID: expectedChannel,
                timeout: 8
            )
            current = try assertContinuousPlayback(from: current, duration: 10)
        }

        let liveDelayBeforeSeek = current.liveDelaySeconds
        let picturesBeforeSeek = current.displayedPictures
        let audioBuffersBeforeSeek = current.playedAudioBuffers
        XCUIRemote.shared.press(.pageDown, forDuration: 1.2)
        let seekStartedAt = ProcessInfo.processInfo.systemUptime
        XCUIRemote.shared.press(.select)
        let afterSeek = try waitForProbe(timeout: 5) {
            $0.playerPresented
                && !$0.launchVisible
                && !$0.concealed
                && $0.displayedPictures > 0
                && $0.playedAudioBuffers > 0
                && (
                    $0.liveDelaySeconds > liveDelayBeforeSeek + 1
                        || $0.displayedPictures < picturesBeforeSeek
                        || $0.playedAudioBuffers < audioBuffersBeforeSeek
                )
        }
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - seekStartedAt,
            5,
            "Replay timeshift seek exceeded its functional budget."
        )
        _ = try assertContinuousPlayback(from: afterSeek, duration: 10)

        for _ in 0..<3 {
            XCUIRemote.shared.press(.menu)
            if (try? waitForProbe(timeout: 1, where: { !$0.playerPresented })) != nil {
                break
            }
        }
        let preview = try waitForProbe(timeout: 3) {
            !$0.playerPresented && $0.surfaceMode == "guidePreview"
        }
        XCTAssertEqual(preview.surfaceMode, "guidePreview")

        XCUIRemote.shared.press(.playPause)
        let returned = try waitForReadyPlayback(channelID: "1001", timeout: 8)
        XCTAssertEqual(returned.surfaceMode, "fullScreen")
        XCTAssertGreaterThan(returned.surfaceWidth, 1_000)
        XCTAssertGreaterThan(returned.surfaceHeight, 500)
    }

    func testSeekConcealmentScreenshotComparison() throws {
        launchReplay()
        _ = try waitForReadyPlayback(timeout: 8)

        XCUIRemote.shared.press(.pageDown, forDuration: 1.2)
        let liveProbe = try currentProbe()
        XCTAssertFalse(liveProbe.concealed)
        let before = attachScreenshot(named: "Before seek concealment")

        XCUIRemote.shared.press(.select)
        _ = try waitForProbe(timeout: 5) { $0.concealed }
        let during = attachScreenshot(named: "During seek concealment")

        try assertReplayCornerPixelsAreVisible(in: before)
        try assertReplayCornerPixelsAreVisible(in: during)
        let beforeGeometry = try replayGeometry(in: before)
        let duringGeometry = try replayGeometry(in: during)
        let beforeCalibration = try replayCalibrationGeometry(in: before)
        let duringCalibration = try replayCalibrationGeometry(in: during)
        let geometry = try currentProbe()
        XCTAssertEqual(
            beforeGeometry.left,
            duringGeometry.left,
            accuracy: 1,
            "The seek still must preserve the live video's left edge. "
                + "track=\(geometry.videoTrackWidth)x\(geometry.videoTrackHeight) "
                + "videoSize=\(geometry.videoSizeWidth)x\(geometry.videoSizeHeight)"
        )
        XCTAssertEqual(
            beforeGeometry.right,
            duringGeometry.right,
            accuracy: 1,
            "The seek still must preserve the live video's right edge."
        )
        XCTAssertEqual(
            beforeGeometry.topLeftMarker,
            duringGeometry.topLeftMarker,
            accuracy: 2,
            "The seek still must preserve the live video's vertical position."
        )
        XCTAssertEqual(
            beforeCalibration.topLeftWidth,
            duringCalibration.topLeftWidth,
            "The held frame stretched horizontally at its top-left marker. "
                + "live: \(beforeCalibration); held: \(duringCalibration)"
        )
        XCTAssertEqual(
            beforeCalibration.topLeftHeight,
            duringCalibration.topLeftHeight,
            "The held frame stretched vertically at its top-left marker. "
                + "live: \(beforeCalibration); held: \(duringCalibration)"
        )
        XCTAssertEqual(
            beforeCalibration.topRightWidth,
            duringCalibration.topRightWidth,
            "The held frame stretched horizontally at its top-right marker. "
                + "live: \(beforeCalibration); held: \(duringCalibration)"
        )
        XCTAssertEqual(
            beforeCalibration.topRightHeight,
            duringCalibration.topRightHeight,
            "The held frame stretched vertically at its top-right marker. "
                + "live: \(beforeCalibration); held: \(duringCalibration)"
        )
    }

    func testReplayTestSignalDisplaysAllFourCornerPixels() throws {
        launchReplay()
        let playback = try waitForReadyPlayback(timeout: 8)
        XCTAssertEqual(
            playback.videoTrackWidth,
            1_920,
            "The replay fixture must remain native 1080p."
        )
        XCTAssertEqual(
            playback.videoTrackHeight,
            1_080,
            "The replay fixture must remain native 1080p."
        )
        try waitForPlaybackChromeToHide(timeout: 8)

        let screenshot = attachScreenshot(named: "Replay test signal corners")
        try assertReplayCornerPixelsAreVisible(in: screenshot)
    }

    func testRepeatedBidirectionalTimeshiftSeekingRetainsConnectionAndAudio() throws {
        launchReplay()
        let current = try waitForReadyPlayback(timeout: 8)
        try exerciseRepeatedBidirectionalSeeking(startingWith: current)
    }

    func testLiveRepeatedBidirectionalTimeshiftSeekingRetainsConnectionAndAudio() throws {
        launchUsingStoredConfiguration()
        guard let current = try waitForProbeIfAvailable(timeout: 20, where: Self.isReady)
        else {
            throw XCTSkip("No configured live playback became ready in the simulator.")
        }
        try exerciseRepeatedBidirectionalSeeking(startingWith: current)
    }

    func testReplayRapidBidirectionalSeekBurstRetainsConnectionAndAudio() throws {
        launchReplay()
        let current = try waitForReadyPlayback(timeout: 8)
        try exerciseRapidBidirectionalSeekBurst(startingWith: current)
    }

    func testHeldDirectionalSeekCanResumeWithSelectAndPlay() throws {
        launchReplay()
        var current = try waitForReadyPlayback(timeout: 8)
        current = try assertContinuousPlayback(from: current, duration: 6)

        let cases: [
            (
                direction: XCUIRemote.Button,
                resume: XCUIRemote.Button,
                description: String
            )
        ] = [
            (.left, .select, "Left then Select"),
            (.left, .playPause, "Left then Play"),
            (.right, .select, "Right then Select"),
            (.right, .playPause, "Right then Play"),
        ]

        for testCase in cases {
            current = try exerciseHeldSeekResume(
                direction: testCase.direction,
                resumeButton: testCase.resume,
                description: testCase.description,
                startingWith: current
            )
        }
    }

    func testLiveRapidBidirectionalSeekBurstRetainsConnectionAndAudio() throws {
        launchUsingStoredConfiguration()
        guard let current = try waitForProbeIfAvailable(timeout: 20, where: Self.isReady)
        else {
            throw XCTSkip("No configured live playback became ready in the simulator.")
        }
        try exerciseRapidBidirectionalSeekBurst(startingWith: current)
    }

    private func exerciseRapidBidirectionalSeekBurst(
        startingWith initial: PlaybackProbeSnapshot
    ) throws {
        var current = initial
        current = try assertContinuousPlayback(from: current, duration: 12)

        let presentationID = current.presentationID
        let recoveryCount = current.recoveryCount
        let minimumRetainedWindow = max(1, current.timeshiftWindowSeconds - 2)
        for index in 0..<20 {
            XCUIRemote.shared.press(index.isMultiple(of: 2) ? .left : .right)
        }

        guard let settled = try waitForProbeIfAvailable(timeout: 15, where: {
            Self.isReady($0) && !$0.concealed
        }) else {
            let stuck = try currentProbe()
            XCUIRemote.shared.press(.playPause)
            let latest = try samplePlayback(for: 5, startingWith: stuck)
            XCTFail(
                "Rapid seek burst did not settle before Play. "
                    + postPlayDiagnostic(stuck: stuck, latest: latest)
            )
            throw CocoaError(.coderReadCorrupt)
        }
        XCTAssertEqual(settled.presentationID, presentationID)
        XCTAssertEqual(settled.recoveryCount, recoveryCount)
        XCTAssertGreaterThanOrEqual(settled.timeshiftWindowSeconds, minimumRetainedWindow)
        _ = try assertContinuousPlayback(from: settled, duration: 5)
    }

    private func exerciseHeldSeekResume(
        direction: XCUIRemote.Button,
        resumeButton: XCUIRemote.Button,
        description: String,
        startingWith baseline: PlaybackProbeSnapshot
    ) throws -> PlaybackProbeSnapshot {
        XCUIRemote.shared.press(direction, forDuration: 1.2)

        let confirmation = app.buttons["Confirm seek"]
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 2),
            "\(description) did not leave the held seek awaiting confirmation."
        )

        XCUIRemote.shared.press(resumeButton)
        _ = try waitForProbe(timeout: 3) {
            $0.concealed
                || $0.navigationState != baseline.navigationState
                || abs($0.liveDelaySeconds - baseline.liveDelaySeconds) > 1
                || $0.displayedPictures < baseline.displayedPictures
                || $0.playedAudioBuffers < baseline.playedAudioBuffers
        }
        let resumed = try waitForProbe(timeout: 8) {
            Self.isReady($0)
                && $0.isPlaying
                && $0.engineState == "playing"
                && !$0.concealed
        }
        XCTAssertFalse(
            confirmation.exists,
            "\(description) left the held seek confirmation active."
        )
        XCTAssertEqual(
            resumed.presentationID,
            baseline.presentationID,
            "\(description) replaced the playback connection."
        )
        XCTAssertEqual(
            resumed.recoveryCount,
            baseline.recoveryCount,
            "\(description) triggered playback recovery."
        )
        return try assertContinuousPlayback(from: resumed, duration: 2)
    }

    private func exerciseRepeatedBidirectionalSeeking(
        startingWith initial: PlaybackProbeSnapshot
    ) throws {
        var current = initial
        current = try assertContinuousPlayback(from: current, duration: 12)

        let presentationID = current.presentationID
        let recoveryCount = current.recoveryCount
        let minimumRetainedWindow = max(1, current.timeshiftWindowSeconds - 2)
        var nonLiveSeekDurations: [TimeInterval] = []

        for cycle in 1...8 {
            current = try performStressSeek(
                .left,
                from: current,
                cycle: cycle,
                direction: "backward",
                presentationID: presentationID,
                recoveryCount: recoveryCount,
                minimumRetainedWindow: minimumRetainedWindow,
                recordDuration: { nonLiveSeekDurations.append($0) }
            )
            current = try performStressSeek(
                .right,
                from: current,
                cycle: cycle,
                direction: "forward",
                presentationID: presentationID,
                recoveryCount: recoveryCount,
                minimumRetainedWindow: minimumRetainedWindow,
                recordDuration: nil
            )
        }

        let averageNonLiveSeekDuration =
            nonLiveSeekDurations.reduce(0, +) / Double(nonLiveSeekDurations.count)
        print(
            String(
                format: "NON_LIVE_SEEK_AVERAGE %.3fs (%d samples)",
                averageNonLiveSeekDuration,
                nonLiveSeekDurations.count
            )
        )
        XCTAssertLessThan(
            averageNonLiveSeekDuration,
            2,
            "Non-live seeks averaged \(averageNonLiveSeekDuration)s."
        )
        _ = try assertContinuousPlayback(from: current, duration: 5)
    }

    func testLiveTVHeadendTuneSwitchAndSeek() throws {
        let environment = ProcessInfo.processInfo.environment
        if let url = environment["TVPLAYER_LIVE_TEST_URL"], !url.isEmpty {
            launch(
                url: url,
                username: environment["TVPLAYER_LIVE_TEST_USERNAME"] ?? "",
                password: environment["TVPLAYER_LIVE_TEST_PASSWORD"] ?? "",
                htspPort: environment["TVPLAYER_LIVE_TEST_HTSP_PORT"] ?? "9982",
                replay: false
            )
        } else {
            launchUsingStoredConfiguration()
        }

        guard var current = try waitForProbeIfAvailable(timeout: 12, where: Self.isReady)
        else {
            throw XCTSkip(
                "No live playback became ready. Configure the simulator app or set "
                    + "TVPLAYER_LIVE_TEST_URL and matching credentials."
            )
        }
        current = try assertContinuousPlayback(from: current, duration: 10)
        for _ in 0..<4 {
            let previousChannel = current.channelID
            XCUIRemote.shared.press(.pageUp)
            current = try waitForProbe(timeout: 12) {
                $0.channelID != nil
                    && $0.channelID != previousChannel
                    && Self.isReady($0)
            }
            current = try assertContinuousPlayback(from: current, duration: 10)
        }

        guard current.timeshiftWindowSeconds >= 30 else {
            throw XCTSkip("The selected live channel has less than 30 seconds of timeshift.")
        }
        for _ in 0..<3 {
            XCUIRemote.shared.press(.pageDown, forDuration: 1)
            XCUIRemote.shared.press(.select)
            let settled = try waitForProbe(timeout: 8) {
                Self.isReady($0) && !$0.concealed
            }
            current = try assertContinuousPlayback(from: settled, duration: 10)
        }
    }

    private func launchReplay() {
        launch(
            url: "http://playback-replay.invalid",
            username: "replay",
            password: "replay",
            htspPort: "9982",
            replay: true
        )
    }

    private func launchUsingStoredConfiguration() {
        app.launchArguments = ["--playback-ui-testing"]
        app.launchEnvironment = [
            "TVPLAYER_AUTOPLAY": "1",
            "TVPLAYER_PLAYBACK_REPLAY": "0",
        ]
        launchConfiguredApp()
    }

    private func launch(
        url: String,
        username: String,
        password: String,
        htspPort: String,
        replay: Bool
    ) {
        app.launchArguments = ["--playback-ui-testing"]
        if replay {
            app.launchArguments.append("--vlc-timeshift-benchmark")
        }
        app.launchEnvironment = [
            "TVPLAYER_TVH_URL": url,
            "TVPLAYER_TVH_USERNAME": username,
            "TVPLAYER_TVH_PASSWORD": password,
            "TVPLAYER_TVH_PROFILE": "pass",
            "TVPLAYER_TVH_HTSP_PORT": htspPort,
            "TVPLAYER_TRANSIENT_ENVIRONMENT_PROFILE": "1",
            "TVPLAYER_AUTOPLAY": "1",
            "TVPLAYER_PLAYBACK_REPLAY": replay ? "1" : "0",
        ]
        launchConfiguredApp()
    }

    @discardableResult
    private func attachScreenshot(named name: String) -> XCUIScreenshot {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return screenshot
    }

    private func replayGeometry(
        in screenshot: XCUIScreenshot
    ) throws -> (left: Int, right: Int, topLeftMarker: Int) {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func containsVideo(_ x: Int) -> Bool {
            var brightness = 0
            var sampleCount = 0
            for y in stride(from: 0, to: height / 2, by: 4) {
                let offset = (y * width + x) * 4
                brightness += Int(pixels[offset])
                    + Int(pixels[offset + 1])
                    + Int(pixels[offset + 2])
                sampleCount += 3
            }
            return brightness / max(1, sampleCount) > 8
        }

        let left = (0..<width).first(where: containsVideo) ?? width
        let rightEdge = (0..<width).reversed().first(where: containsVideo) ?? -1
        let markerX = min(10, width - 1)
        let topLeftMarker = (0..<(height / 4)).first { y in
            let offset = (y * width + markerX) * 4
            return Int(pixels[offset])
                + Int(pixels[offset + 1])
                + Int(pixels[offset + 2]) < 180
        } ?? height
        return (left, max(0, width - rightEdge - 1), topLeftMarker)
    }

    private func assertReplayCornerPixelsAreVisible(
        in screenshot: XCUIScreenshot
    ) throws {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let width = image.width
        let height = image.height
        XCTAssertEqual(
            width,
            1_920,
            "The corner test requires the 1080p tvOS simulator display."
        )
        XCTAssertEqual(
            height,
            1_080,
            "The corner test requires the 1080p tvOS simulator display."
        )
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // The replay fixture is native 1080p, so each source corner maps to
        // the corresponding screen corner without a fixture-size rescale.
        let corners: [
            (
                name: String,
                x: Int,
                y: Int,
                matches: (Int, Int, Int) -> Bool
            )
        ] = [
            ("top left", 0, 0, { red, green, blue in
                green >= 100 && blue >= 100
                    && red + 50 <= min(green, blue)
            }),
            ("top right", width - 1, 0, { red, green, blue in
                red >= 100 && green >= 100
                    && blue + 50 <= min(red, green)
            }),
            ("bottom left", 0, height - 1, { red, green, blue in
                green >= 100 && green >= red + 50 && green >= blue + 50
            }),
            ("bottom right", width - 1, height - 1, { red, green, blue in
                red >= 100 && blue >= 100
                    && green + 50 <= min(red, blue)
            }),
        ]

        for corner in corners {
            let offset = (corner.y * width + corner.x) * 4
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            XCTAssertTrue(
                corner.matches(red, green, blue),
                "The replay test signal's \(corner.name) corner has RGB "
                    + "\(red),\(green),\(blue), so its unique marker is missing."
            )
        }
    }

    private func replayCalibrationGeometry(
        in screenshot: XCUIScreenshot
    ) throws -> ReplayCalibrationGeometry {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func pixel(atX x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
            let offset = (y * width + x) * 4
            return (
                Int(pixels[offset]),
                Int(pixels[offset + 1]),
                Int(pixels[offset + 2])
            )
        }

        func isCyan(_ x: Int, _ y: Int) -> Bool {
            let color = pixel(atX: x, y: y)
            return color.green >= 100 && color.blue >= 100
                && color.red + 50 <= min(color.green, color.blue)
        }

        func isYellow(_ x: Int, _ y: Int) -> Bool {
            let color = pixel(atX: x, y: y)
            return color.red >= 100 && color.green >= 100
                && color.blue + 50 <= min(color.red, color.green)
        }

        let markerInset = 80
        let topLeftWidth = (0..<width).first {
            !isCyan($0, markerInset)
        } ?? width
        let topLeftHeight = (0..<height).first {
            !isCyan(markerInset, $0)
        } ?? height
        let topRightWidth = (0..<width).first {
            !isYellow(width - $0 - 1, markerInset)
        } ?? width
        let topRightHeight = (0..<height).first {
            !isYellow(width - markerInset - 1, $0)
        } ?? height

        return ReplayCalibrationGeometry(
            topLeftWidth: topLeftWidth,
            topLeftHeight: topLeftHeight,
            topRightWidth: topRightWidth,
            topRightHeight: topRightHeight
        )
    }

    private func waitForPlaybackChromeToHide(timeout: TimeInterval) throws {
        let timeline = app.descendants(matching: .any)[
            "tvplayer.playback.chrome.timeline"
        ]
        guard timeline.exists else { return }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: timeline
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "The playback chrome did not hide before checking the test signal."
        )
        let fadeExpectation = XCTestExpectation(
            description: "Playback chrome fade completed"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            fadeExpectation.fulfill()
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [fadeExpectation], timeout: 1),
            .completed,
            "The playback chrome fade did not complete."
        )
    }

    private func launchConfiguredApp() {
        app.launch()
        probeElement = app.descendants(matching: .any)[probeIdentifier]
        XCTAssertTrue(
            probeElement.waitForExistence(timeout: 5),
            "The playback automation probe did not appear."
        )
    }

    private func waitForReadyPlayback(
        channelID: String? = nil,
        timeout: TimeInterval
    ) throws -> PlaybackProbeSnapshot {
        try waitForProbe(timeout: timeout) {
            (channelID == nil || $0.channelID == channelID) && Self.isReady($0)
        }
    }

    private static func isReady(_ sample: PlaybackProbeSnapshot) -> Bool {
        sample.playerPresented
            && !sample.launchVisible
            && !sample.concealed
            && sample.displayedPictures > 0
            && sample.playedAudioBuffers > 0
            && sample.audioTrackCount > 0
            && sample.isSeekable
            && sample.timeshiftWindowSeconds > 0
    }

    private func assertContinuousPlayback(
        from baseline: PlaybackProbeSnapshot,
        duration: TimeInterval
    ) throws -> PlaybackProbeSnapshot {
        var previous = baseline
        var clockBaseline = baseline
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        var lastVideoAdvance = baseline.sampledAt
        var lastAudioAdvance = baseline.sampledAt
        while ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            let current = try currentProbe()
            samples.append(current)
            let enteredNewPipelineEpoch =
                current.displayedPictures < previous.displayedPictures
                    || current.playedAudioBuffers < previous.playedAudioBuffers
            if enteredNewPipelineEpoch {
                lastVideoAdvance = current.sampledAt
                lastAudioAdvance = current.sampledAt
                clockBaseline = current
            } else {
                if current.displayedPictures > previous.displayedPictures {
                    lastVideoAdvance = current.sampledAt
                }
                if current.playedAudioBuffers > previous.playedAudioBuffers {
                    lastAudioAdvance = current.sampledAt
                }
                if clockBaseline.playbackTimeMilliseconds == nil,
                   current.playbackTimeMilliseconds != nil {
                    clockBaseline = current
                }
            }
            XCTAssertLessThan(
                current.sampledAt - lastVideoAdvance,
                2,
                "Video output stalled for two seconds."
            )
            XCTAssertLessThan(
                current.sampledAt - lastAudioAdvance,
                2,
                "Audio output stalled for two seconds."
            )
            XCTAssertEqual(current.lostAudioBuffers, baseline.lostAudioBuffers)
            XCTAssertEqual(current.audioUnderruns, baseline.audioUnderruns)
            XCTAssertEqual(current.lateClockCorrections, baseline.lateClockCorrections)
            XCTAssertEqual(current.earlyClockCorrections, baseline.earlyClockCorrections)
            XCTAssertEqual(current.recoveryCount, baseline.recoveryCount)
            XCTAssertNil(current.pipelineDiagnostic)
            previous = current
        }

        if let start = clockBaseline.playbackTimeMilliseconds,
           let end = previous.playbackTimeMilliseconds,
           end >= start,
           previous.sampledAt - clockBaseline.sampledAt >= 3 {
            let sampledDuration = previous.sampledAt - clockBaseline.sampledAt
            let clockSlope = Double(end - start) / (sampledDuration * 1_000)
            // VLC exposes this clock in coarse, approximately one-second
            // steps. Account for one step of quantization over short samples.
            let tolerance = max(0.1, 1 / sampledDuration)
            XCTAssertGreaterThan(
                clockSlope,
                1 - tolerance,
                "Playback clock advanced too slowly."
            )
            XCTAssertLessThan(
                clockSlope,
                1 + tolerance,
                "Playback clock advanced too quickly."
            )
        }
        return previous
    }

    private func performStressSeek(
        _ button: XCUIRemote.Button,
        from baseline: PlaybackProbeSnapshot,
        cycle: Int,
        direction: String,
        presentationID: String?,
        recoveryCount: Int,
        minimumRetainedWindow: TimeInterval,
        recordDuration: ((TimeInterval) -> Void)?
    ) throws -> PlaybackProbeSnapshot {
        let startedAt = ProcessInfo.processInfo.systemUptime
        XCUIRemote.shared.press(button)
        _ = try waitForProbe(timeout: 3) {
            $0.concealed
                || $0.navigationState != baseline.navigationState
                || abs($0.liveDelaySeconds - baseline.liveDelaySeconds) > 1
                || $0.displayedPictures < baseline.displayedPictures
                || $0.playedAudioBuffers < baseline.playedAudioBuffers
        }
        guard let settled = try waitForProbeIfAvailable(timeout: 8, where: {
            Self.isReady($0) && !$0.concealed
        }) else {
            let stuck = try currentProbe()
            XCUIRemote.shared.press(.playPause)
            let latest = try samplePlayback(for: 5, startingWith: stuck)
            XCTFail(
                "Seek cycle \(cycle) \(direction) did not settle before Play. "
                    + postPlayDiagnostic(stuck: stuck, latest: latest)
            )
            throw CocoaError(.coderReadCorrupt)
        }
        recordDuration?(
            ProcessInfo.processInfo.systemUptime - startedAt
        )
        XCTAssertEqual(
            settled.presentationID,
            presentationID,
            "Seek cycle \(cycle) \(direction) replaced the playback connection."
        )
        XCTAssertEqual(
            settled.recoveryCount,
            recoveryCount,
            "Seek cycle \(cycle) \(direction) triggered playback recovery."
        )
        XCTAssertGreaterThanOrEqual(
            settled.timeshiftWindowSeconds,
            minimumRetainedWindow,
            "Seek cycle \(cycle) \(direction) discarded the timeshift buffer."
        )
        return try assertContinuousPlayback(from: settled, duration: 1)
    }

    private func samplePlayback(
        for duration: TimeInterval,
        startingWith initial: PlaybackProbeSnapshot
    ) throws -> PlaybackProbeSnapshot {
        var latest = initial
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        while ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            latest = try currentProbe()
            samples.append(latest)
        }
        return latest
    }

    private func postPlayDiagnostic(
        stuck: PlaybackProbeSnapshot,
        latest: PlaybackProbeSnapshot
    ) -> String {
        "stuckState=\(stuck.engineState)/\(stuck.navigationState) "
            + "videoAfterPlay=\(latest.displayedPictures > stuck.displayedPictures) "
            + "audioAfterPlay=\(latest.playedAudioBuffers > stuck.playedAudioBuffers) "
            + "windowBefore=\(stuck.timeshiftWindowSeconds) "
            + "windowAfter=\(latest.timeshiftWindowSeconds) "
            + "recoveryBefore=\(stuck.recoveryCount) "
            + "recoveryAfter=\(latest.recoveryCount) "
            + "latestState=\(latest.engineState)/\(latest.navigationState)"
    }

    private func waitForProbe(
        timeout: TimeInterval,
        where predicate: (PlaybackProbeSnapshot) -> Bool
    ) throws -> PlaybackProbeSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var latest: PlaybackProbeSnapshot?
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let sample = try? currentProbe() {
                latest = sample
                samples.append(sample)
                if predicate(sample) { return sample }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("Playback probe condition timed out. Latest: \(String(describing: latest))")
        throw CocoaError(.coderReadCorrupt)
    }

    private func waitForProbeIfAvailable(
        timeout: TimeInterval,
        where predicate: (PlaybackProbeSnapshot) -> Bool
    ) throws -> PlaybackProbeSnapshot? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let sample = try? currentProbe() {
                samples.append(sample)
                if predicate(sample) { return sample }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private func currentProbe() throws -> PlaybackProbeSnapshot {
        guard let value = probeElement.value as? String,
              let data = value.data(using: .utf8)
        else { throw CocoaError(.coderValueNotFound) }
        return try JSONDecoder().decode(PlaybackProbeSnapshot.self, from: data)
    }

    private func attachSamples() {
        guard !samples.isEmpty,
              let data = try? JSONEncoder().encode(samples)
        else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Playback probe samples"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

final class GuideFocusAutomationUITests: XCTestCase {
    private let probeIdentifier = "tvplayer.guide.automation.probe"
    private var app: XCUIApplication!
    private var probeElement: XCUIElement!
    private var samples: [GuideFocusProbeSnapshot] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        samples = []
        app = XCUIApplication()
        if name.contains("RealGuideData") {
            app.launchArguments = ["--guide-real-data-ui-testing"]
        } else {
            app.launchArguments = ["--guide-ui-testing"]
            app.launchEnvironment = [
                "TVPLAYER_TVH_URL": "http://guide-ui.invalid",
                "TVPLAYER_TVH_USERNAME": "guide",
                "TVPLAYER_TVH_PASSWORD": "guide",
                "TVPLAYER_TVH_PROFILE": "pass",
                "TVPLAYER_TVH_HTSP_PORT": "9982",
                "TVPLAYER_TRANSIENT_ENVIRONMENT_PROFILE": "1",
            ]
        }
        app.launch()
        probeElement = app.descendants(matching: .any)[probeIdentifier]
        XCTAssertTrue(
            probeElement.waitForExistence(timeout: 8),
            "The guide focus automation probe did not appear."
        )
    }

    override func tearDown() {
        if let app, app.state != .notRunning {
            if (testRun?.failureCount ?? 0) > 0 {
                let screenshot = XCUIScreen.main.screenshot()
                let screenshotAttachment = XCTAttachment(screenshot: screenshot)
                screenshotAttachment.name = "Guide focus failure"
                screenshotAttachment.lifetime = .keepAlways
                add(screenshotAttachment)
                attachSamples()
            }
            app.terminate()
        }
        probeElement = nil
        app = nil
        super.tearDown()
    }

    func testProgramChannelRoundTripRestoresExactlyOneProgramMarker() throws {
        let programID = "guide-test-current-01"
        let channelID = "guide-test-channel-01"
        _ = try waitForProgram(programID)

        for _ in 0..<4 {
            let returnProgramID = try moveFocusToChannel(channelID)

            XCUIRemote.shared.press(.right)
            _ = try waitForProgram(returnProgramID)
        }

        try assertNoMarkerViolations()
    }

    func testHeldDownStaysInProgramsAndChannelRoundTripStillWorks() throws {
        _ = try waitForProgram("guide-test-current-01")

        XCUIRemote.shared.press(.down, forDuration: 3)
        let afterRepeat = try waitForProbe(timeout: 5) {
            $0.focusedProgramID != nil
                && $0.focusedProgramID != "guide-test-current-01"
                && $0.focusedChannelID == nil
                && $0.programMarkerIDs == [$0.focusedProgramID!]
                && $0.channelMarkerIDs.isEmpty
        }
        let programID = try XCTUnwrap(afterRepeat.focusedProgramID)
        let ordinal = try XCTUnwrap(
            Int(programID.replacingOccurrences(
                of: "guide-test-current-",
                with: ""
            ))
        )
        let channelID = String(
            format: "guide-test-channel-%02d",
            ordinal
        )

        let returnProgramID = try moveFocusToChannel(channelID)
        XCUIRemote.shared.press(.right)
        _ = try waitForProgram(returnProgramID)

        try assertNoMarkerViolations()
    }

    func testEveryShortVerticalPressMovesExactlyOneProgram() throws {
        let initial = try waitForProbe(timeout: 12) {
            $0.focusedProgramChannelID == "guide-test-channel-01"
                && $0.programMarkerIDs == [$0.focusedProgramID!]
                && $0.displayedChannelIDs.count == 67
                && $0.focusableChannelIDs.count >= 60
        }
        let focusableChannelIDs = initial.focusableChannelIDs
        XCTAssertEqual(focusableChannelIDs.first, "guide-test-channel-01")

        // Exercise discrete remote clicks independently from the held-button
        // path. Waiting after every click prevents a later repeat from hiding
        // a dropped single-step transition. Traverse the complete anonymized
        // real guide in both directions twice.
        for _ in 0..<2 {
            for channelID in focusableChannelIDs.dropFirst() {
                XCUIRemote.shared.press(.down)
                _ = try waitForProgramOnChannel(channelID, timeout: 2)
            }
            for channelID in focusableChannelIDs.dropLast().reversed() {
                XCUIRemote.shared.press(.up)
                _ = try waitForProgramOnChannel(channelID, timeout: 2)
            }
        }

        try assertNoMarkerViolations()
    }

    func testRealGuideDataEveryShortVerticalPressMovesExactlyOneProgram() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires the configured physical Apple TV guide data.")
#else
        let initial = try waitForProbe(timeout: 20) {
            $0.focusedProgramID != nil
                && $0.focusedProgramChannelID != nil
                && $0.programMarkerIDs == [$0.focusedProgramID!]
                && $0.focusableChannelIDs.count >= 3
        }
        let channelID = try XCTUnwrap(initial.focusedProgramChannelID)
        let startIndex = try XCTUnwrap(
            initial.focusableChannelIDs.firstIndex(of: channelID)
        )

        let step: Int
        let availableSteps: Int
        if initial.focusableChannelIDs.count - startIndex - 1 >= 2 {
            step = 1
            availableSteps = initial.focusableChannelIDs.count - startIndex - 1
        } else {
            step = -1
            availableSteps = startIndex
        }
        let traversalLength = min(12, availableSteps)
        XCTAssertGreaterThanOrEqual(traversalLength, 2)

        let outwardIndices = (1...traversalLength).map {
            startIndex + $0 * step
        }
        for index in outwardIndices {
            XCUIRemote.shared.press(step > 0 ? .down : .up)
            _ = try waitForProgramOnChannel(
                initial.focusableChannelIDs[index],
                timeout: 3
            )
        }
        for index in outwardIndices.dropLast().reversed() {
            XCUIRemote.shared.press(step > 0 ? .up : .down)
            _ = try waitForProgramOnChannel(
                initial.focusableChannelIDs[index],
                timeout: 3
            )
        }
        XCUIRemote.shared.press(step > 0 ? .up : .down)
        _ = try waitForProgramOnChannel(channelID, timeout: 3)

        try assertNoMarkerViolations()
#endif
    }

    func testFavoriteReorderKeepsChannelFocusAndNeverShowsProgramMarker() throws {
        _ = try waitForProgram("guide-test-current-01")
        for ordinal in 2...12 {
            XCUIRemote.shared.press(.down)
            _ = try waitForProgram(
                String(format: "guide-test-current-%02d", ordinal)
            )
        }

        let channelID = "guide-test-channel-12"
        _ = try moveFocusToChannel(channelID)

        XCUIRemote.shared.press(.select)
        _ = try waitForProbe(timeout: 8) {
            $0.focusedChannelID == channelID
                && $0.channelMarkerIDs == [channelID]
                && $0.programMarkerIDs.isEmpty
                && !$0.channelRestorationPending
                && $0.favoriteChannelIDs == [channelID]
                && $0.displayedChannelIDs.first == channelID
        }
        try assertNoMarkerViolations()

        XCUIRemote.shared.press(.select)
        _ = try waitForProbe(timeout: 8) {
            $0.focusedChannelID == channelID
                && $0.channelMarkerIDs == [channelID]
                && $0.programMarkerIDs.isEmpty
                && !$0.channelRestorationPending
                && $0.favoriteChannelIDs.isEmpty
                && $0.displayedChannelIDs[safe: 11] == channelID
        }
        try assertNoMarkerViolations()

        XCUIRemote.shared.press(.right)
        _ = try waitForProgramOnChannel(channelID, timeout: 8)
        try assertNoMarkerViolations()
    }

    /// The complete guide fixture deliberately retains the real historical
    /// programmes inside the one-hour look-back window. Walk across every
    /// one with independent clicks instead of assuming the current programme
    /// is always the first item in its row.
    private func moveFocusToChannel(
        _ channelID: String,
        maximumProgramMoves: Int = 64
    ) throws -> String {
        var programID = try XCTUnwrap(currentProbe().focusedProgramID)

        for _ in 0...maximumProgramMoves {
            XCUIRemote.shared.press(.left)
            let next = try waitForProbe(timeout: 2) {
                if $0.focusedChannelID == channelID {
                    return $0.focusedProgramID == nil
                        && $0.programMarkerIDs.isEmpty
                        && $0.channelMarkerIDs == [channelID]
                        && !$0.channelRestorationPending
                }
                return $0.focusedProgramID != nil
                    && $0.focusedProgramID != programID
                    && $0.focusedProgramChannelID == channelID
                    && $0.programMarkerIDs == [$0.focusedProgramID!]
                    && $0.channelMarkerIDs.isEmpty
                    && !$0.channelRestorationPending
            }
            if next.focusedChannelID == channelID {
                return programID
            }
            programID = try XCTUnwrap(next.focusedProgramID)
        }

        XCTFail("Channel focus was not reached after \(maximumProgramMoves + 1) Left presses.")
        throw CocoaError(.coderReadCorrupt)
    }

    private func waitForProgram(
        _ programID: String,
        timeout: TimeInterval = 8
    ) throws -> GuideFocusProbeSnapshot {
        try waitForProbe(timeout: timeout) {
            $0.focusedProgramID == programID
                && $0.focusedChannelID == nil
                && $0.programMarkerIDs == [programID]
                && $0.channelMarkerIDs.isEmpty
                && !$0.channelRestorationPending
        }
    }

    private func waitForProgramOnChannel(
        _ channelID: String,
        timeout: TimeInterval
    ) throws -> GuideFocusProbeSnapshot {
        try waitForProbe(timeout: timeout) {
            $0.focusedProgramID != nil
                && $0.focusedProgramChannelID == channelID
                && $0.focusedChannelID == nil
                && $0.programMarkerIDs == [$0.focusedProgramID!]
                && $0.channelMarkerIDs.isEmpty
                && !$0.channelRestorationPending
        }
    }

    private func assertNoMarkerViolations(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sample = try currentProbe()
        samples.append(sample)
        XCTAssertEqual(sample.markerOverlapCount, 0, file: file, line: line)
        XCTAssertEqual(
            sample.programMarkerDuringChannelRestorationCount,
            0,
            file: file,
            line: line
        )
    }

    private func waitForProbe(
        timeout: TimeInterval,
        where predicate: (GuideFocusProbeSnapshot) -> Bool
    ) throws -> GuideFocusProbeSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var latest: GuideFocusProbeSnapshot?
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let sample = try? currentProbe() {
                latest = sample
                samples.append(sample)
                if predicate(sample) { return sample }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("Guide focus probe condition timed out. Latest: \(String(describing: latest))")
        throw CocoaError(.coderReadCorrupt)
    }

    private func currentProbe() throws -> GuideFocusProbeSnapshot {
        guard let value = probeElement.value as? String,
              let data = value.data(using: .utf8)
        else { throw CocoaError(.coderValueNotFound) }
        return try JSONDecoder().decode(GuideFocusProbeSnapshot.self, from: data)
    }

    private func attachSamples() {
        guard !samples.isEmpty,
              let data = try? JSONEncoder().encode(samples)
        else { return }
        let attachment = XCTAttachment(
            data: data,
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "Guide focus probe samples"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
