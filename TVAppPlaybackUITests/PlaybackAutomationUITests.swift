import XCTest

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
}

private struct GuideFocusProbeSnapshot: Codable, CustomStringConvertible {
    let version: Int
    let sampledAt: TimeInterval
    let focusedProgramID: String?
    let focusedChannelID: String?
    let programMarkerIDs: [String]
    let channelMarkerIDs: [String]
    let displayedChannelIDs: [String]
    let favoriteChannelIDs: [String]
    let channelRestorationPending: Bool
    let markerOverlapCount: Int
    let programMarkerDuringChannelRestorationCount: Int

    var description: String {
        "program=\(String(describing: focusedProgramID)) "
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
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        var lastVideoAdvance = baseline.sampledAt
        var lastAudioAdvance = baseline.sampledAt
        while ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            let current = try currentProbe()
            samples.append(current)
            if current.displayedPictures < previous.displayedPictures
                || current.playedAudioBuffers < previous.playedAudioBuffers {
                lastVideoAdvance = current.sampledAt
                lastAudioAdvance = current.sampledAt
            } else {
                if current.displayedPictures > previous.displayedPictures {
                    lastVideoAdvance = current.sampledAt
                }
                if current.playedAudioBuffers > previous.playedAudioBuffers {
                    lastAudioAdvance = current.sampledAt
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

        if let start = baseline.playbackTimeMilliseconds,
           let end = previous.playbackTimeMilliseconds,
           end >= start,
           previous.sampledAt > baseline.sampledAt {
            let sampledDuration = previous.sampledAt - baseline.sampledAt
            let clockSlope = Double(end - start) / (sampledDuration * 1_000)
            XCTAssertGreaterThan(clockSlope, 0.9, "Playback clock advanced too slowly.")
            XCTAssertLessThan(clockSlope, 1.1, "Playback clock advanced too quickly.")
        }
        return previous
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
        app.launchArguments = ["--guide-ui-testing"]
        app.launchEnvironment = [
            "TVPLAYER_TVH_URL": "http://guide-ui.invalid",
            "TVPLAYER_TVH_USERNAME": "guide",
            "TVPLAYER_TVH_PASSWORD": "guide",
            "TVPLAYER_TVH_PROFILE": "pass",
            "TVPLAYER_TVH_HTSP_PORT": "9982",
            "TVPLAYER_TRANSIENT_ENVIRONMENT_PROFILE": "1",
        ]
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
            XCUIRemote.shared.press(.left)
            _ = try waitForChannel(channelID)

            XCUIRemote.shared.press(.right)
            _ = try waitForProgram(programID)
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

        XCUIRemote.shared.press(.left)
        _ = try waitForChannel(channelID)
        XCUIRemote.shared.press(.right)
        _ = try waitForProgram(programID)

        try assertNoMarkerViolations()
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
        let programID = "guide-test-current-12"
        XCUIRemote.shared.press(.left)
        _ = try waitForChannel(channelID)

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
        _ = try waitForProgram(programID)
        try assertNoMarkerViolations()
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

    private func waitForChannel(
        _ channelID: String,
        timeout: TimeInterval = 8
    ) throws -> GuideFocusProbeSnapshot {
        try waitForProbe(timeout: timeout) {
            $0.focusedProgramID == nil
                && $0.focusedChannelID == channelID
                && $0.programMarkerIDs.isEmpty
                && $0.channelMarkerIDs == [channelID]
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
