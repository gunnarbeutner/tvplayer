import XCTest
@testable import TVApp

final class GuideTimelineTests: XCTestCase {
    @MainActor
    func testChannelWithoutEPGReceivesTimelinePlaceholder() throws {
        let timeline = GuideTimeline(
            start: Date(timeIntervalSince1970: 10_000),
            end: Date(timeIntervalSince1970: 31_600)
        )

        let programs = TVHeadendClient.programsFillingPastGap(
            [],
            channelID: "news",
            timeline: timeline,
            now: Date(timeIntervalSince1970: 20_000)
        )
        let placeholder = try XCTUnwrap(programs.first)

        XCTAssertEqual(programs.count, 1)
        XCTAssertEqual(placeholder.title, "No programme information")
        XCTAssertEqual(placeholder.start, timeline.start)
        XCTAssertEqual(placeholder.end, timeline.end)
        XCTAssertTrue(placeholder.isAiring(at: Date(timeIntervalSince1970: 20_000)))
    }

    func testDiscoveredSettingsParseBonjourTXTRecord() throws {
        let fields = [
            "txtvers": Data("1".utf8),
            "id": Data("server-0123".utf8),
            "scheme": Data("http".utf8),
            "path": Data("/tvh".utf8),
            "username": Data("viewer".utf8),
            "password": Data("secret".utf8),
            "profile": Data("pass".utf8),
        ]
        let guideURL = try XCTUnwrap(URL(string: "http://guide.example:49382/guide.json"))

        let discovered = try XCTUnwrap(DiscoveredTVHeadendSettings(
            fields: fields,
            hostName: "tvheadend.local.",
            port: 9981,
            guideCacheURL: guideURL
        ))

        XCTAssertEqual(discovered.discoveryID, "server-0123")
        XCTAssertEqual(discovered.baseURL.absoluteString, "http://tvheadend.local:9981/tvh")
        XCTAssertEqual(discovered.username, "viewer")
        XCTAssertEqual(discovered.password, "secret")
        XCTAssertEqual(discovered.streamProfile, "pass")
        XCTAssertEqual(discovered.guideCacheURL?.absoluteString, "http://guide.example:49382/guide.json")
        XCTAssertNil(discovered.xmltvURL)
    }

    func testDiscoveredSettingsAcceptAnonymousAccess() throws {
        let discovered = try XCTUnwrap(DiscoveredTVHeadendSettings(
            fields: [
                "txtvers": Data("1".utf8),
                "id": Data("server-anonymous".utf8),
                "scheme": Data("http".utf8),
                "path": Data("/".utf8),
            ],
            hostName: "tvheadend.local.",
            port: 9981
        ))

        XCTAssertEqual(discovered.username, "")
        XCTAssertEqual(discovered.password, "")
        XCTAssertTrue(TVHeadendConfiguration(
            baseURL: discovered.baseURL,
            username: discovered.username,
            password: discovered.password,
            streamProfile: discovered.streamProfile,
            guideCacheURL: nil,
            xmltvURL: nil
        ).isComplete)
    }

    func testDiscoveredGuideCacheParsesItsResolvedEndpoint() throws {
        let endpoint = try XCTUnwrap(DiscoveredGuideCacheEndpoint(
            fields: [
                "TXTVERS": Data("1".utf8),
                "ID": Data("server-0123".utf8),
                "SCHEME": Data("http".utf8),
                "PATH": Data("/guide.json".utf8),
                "FORMAT": Data("tvplayer-json".utf8),
            ],
            hostName: "guide-cache.local.",
            port: 49_382
        ))

        XCTAssertEqual(endpoint.discoveryID, "server-0123")
        XCTAssertEqual(endpoint.url.absoluteString, "http://guide-cache.local:49382/guide.json")
        XCTAssertNil(DiscoveredGuideCacheEndpoint(
            fields: [
                "txtvers": Data("1".utf8),
                "id": Data("server-0123".utf8),
                "scheme": Data("http".utf8),
                "path": Data("/guide.json".utf8),
            ],
            hostName: "guide-cache.local.",
            port: 49_382
        ))
    }

    func testDiscoveryRegistryJoinsAndDetachesGuideByStableID() throws {
        let fields = [
            "txtvers": Data("1".utf8),
            "id": Data("server-0123".utf8),
            "scheme": Data("http".utf8),
            "path": Data("/".utf8),
            "username": Data("viewer".utf8),
            "password": Data("secret".utf8),
        ]
        let primaryIdentity = "local.|_tvplayer._tcp.|server"
        let guideIdentity = "local.|_tvplayer-guide._tcp.|server"
        var registry = TVHeadendDiscoveryRegistry()

        var events = registry.upsert(ResolvedTVHeadendDiscoveryRecord(
            name: "TVHeadend",
            serviceIdentity: primaryIdentity,
            fields: fields,
            hostName: "tvheadend.local.",
            port: 9_981,
            discoveryID: "server-0123",
            resolvedAddresses: ["192.168.10.20", "2001:db8::20"]
        ))
        guard case let .upsert(initialService) = try XCTUnwrap(events.first) else {
            return XCTFail("Expected the primary service to be inserted")
        }
        XCTAssertNil(initialService.settings.guideCacheURL)
        XCTAssertEqual(
            initialService.settings.resolvedAddresses,
            ["192.168.10.20", "2001:db8::20"]
        )

        let endpoint = try XCTUnwrap(DiscoveredGuideCacheEndpoint(
            fields: [
                "txtvers": Data("1".utf8),
                "id": Data("server-0123".utf8),
                "scheme": Data("http".utf8),
                "path": Data("/guide.json".utf8),
                "format": Data("tvplayer-json".utf8),
            ],
            hostName: "guide.local.",
            port: 49_382,
            resolvedAddresses: ["192.168.10.21"]
        ))
        events = registry.upsert(ResolvedGuideDiscoveryRecord(
            serviceIdentity: guideIdentity,
            endpoint: endpoint
        ))
        guard case let .upsert(joinedService) = try XCTUnwrap(events.first) else {
            return XCTFail("Expected the guide service to update the primary service")
        }
        XCTAssertEqual(
            joinedService.settings.guideCacheURL?.absoluteString,
            "http://guide.local:49382/guide.json"
        )
        XCTAssertEqual(joinedService.settings.guideResolvedAddresses, ["192.168.10.21"])

        events = registry.remove(serviceIdentity: guideIdentity)
        guard case let .upsert(detachedService) = try XCTUnwrap(events.first) else {
            return XCTFail("Expected guide removal to update the primary service")
        }
        XCTAssertNil(detachedService.settings.guideCacheURL)
        XCTAssertEqual(detachedService.settings.guideResolvedAddresses, [])
        XCTAssertEqual(
            registry.remove(serviceIdentity: primaryIdentity),
            [.removed(serviceIdentity: primaryIdentity)]
        )
    }

    @MainActor
    func testDiscoveryKeepsOnlyRoutableNumericAddresses() {
        XCTAssertEqual(
            TVHeadendDiscovery.usableNumericAddresses([
                "192.168.10.20",
                "192.168.10.20",
                "2001:db8::20",
                "0.0.0.0",
                "127.0.0.1",
                "169.254.1.2",
                "224.0.0.1",
                "::",
                "::1",
                "fe80::1",
                "ff02::fb",
                "not-an-address",
            ]),
            ["192.168.10.20", "2001:db8::20"]
        )
    }

    func testDiscoveredSettingsRejectLegacyRecord() {
        XCTAssertNil(DiscoveredTVHeadendSettings(fields: [
            "version": Data("1".utf8),
            "id": Data("server-0123".utf8),
            "url": Data("http://tvheadend.local:9981".utf8),
            "username": Data("viewer".utf8),
            "password": Data("secret".utf8),
        ], hostName: "tvheadend.local.", port: 9981))
    }

    func testDiscoveredSettingsRejectInvalidOrIncompleteRecords() {
        XCTAssertNil(DiscoveredTVHeadendSettings(fields: [
            "txtvers": Data("1".utf8),
            "id": Data("server-0123".utf8),
            "scheme": Data("ftp".utf8),
            "username": Data("viewer".utf8),
            "password": Data("secret".utf8),
        ], hostName: "tvheadend.local.", port: 9981))
        XCTAssertNil(DiscoveredTVHeadendSettings(fields: [
            "txtvers": Data("1".utf8),
            "id": Data("server-0123".utf8),
            "scheme": Data("http".utf8),
            "password": Data("secret".utf8),
        ], hostName: "tvheadend.local.", port: 9981))
        XCTAssertNil(DiscoveredTVHeadendSettings(fields: [
            "txtvers": Data("1".utf8),
            "id": Data("server-0123".utf8),
            "scheme": Data("http".utf8),
            "username": Data("viewer".utf8),
        ], hostName: "tvheadend.local.", port: 9981))
        XCTAssertNil(DiscoveredTVHeadendSettings(fields: [
            "txtvers": Data("1".utf8),
            "id": Data("server-0123".utf8),
            "scheme": Data("http".utf8),
            "path": Data("relative".utf8),
            "username": Data("viewer".utf8),
            "password": Data("secret".utf8),
        ], hostName: "tvheadend.local.", port: 9981))
    }

    func testOneHourUsesExpectedWidth() {
        let start = Date(timeIntervalSince1970: 10_000)
        let timeline = GuideTimeline(start: start, end: start.addingTimeInterval(7_200))

        XCTAssertEqual(timeline.xOffset(for: start.addingTimeInterval(3_600)), 360, accuracy: 0.001)
        XCTAssertEqual(timeline.width, 720, accuracy: 0.001)
    }

    @MainActor
    func testPersistedGuideSnapshotRoundTripFiltersGeneratedHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvplayer-guide-test-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 10_000)
        let channel = GuideChannel(
            id: "channel-1",
            number: 1,
            name: "A channel with a long name",
            monogram: "AC",
            tint: .orange,
            iconURL: URL(string: "https://example.test/icon.png"),
            programs: [
                GuideProgram(
                    id: "earlier-channel-1",
                    channelID: "channel-1",
                    title: "Earlier programme",
                    subtitle: nil,
                    overview: "",
                    start: now.addingTimeInterval(-3_600),
                    end: now.addingTimeInterval(-1_800)
                ),
                GuideProgram(
                    id: "current",
                    channelID: "channel-1",
                    title: "Current programme",
                    subtitle: "Episode",
                    overview: "Description",
                    start: now.addingTimeInterval(-300),
                    end: now.addingTimeInterval(1_500)
                ),
            ]
        )
        let snapshot = PersistedGuideSnapshot(
            serverIdentifier: "server|viewer||",
            channelPreferencesIdentifier: "profile:stable-id",
            serverName: "Test TVHeadend",
            savedAt: now,
            channels: [channel]
        )
        let store = GuideSnapshotStore(fileURL: fileURL)

        await store.save(snapshot)
        let loadedSnapshot = await store.load(serverIdentifier: "server|viewer||")
        let loaded = try XCTUnwrap(loadedSnapshot)
        let restored = loaded.restoredChannels(
            for: GuideTimeline(
                start: now.addingTimeInterval(-3_600),
                end: now.addingTimeInterval(3_600)
            )
        )

        XCTAssertEqual(restored.first?.name, channel.name)
        XCTAssertEqual(restored.first?.programs.map(\.id), ["current"])
        XCTAssertEqual(loaded.startupChannelPreferencesIdentifier, "profile:stable-id")
        let mismatchedSnapshot = await store.load(serverIdentifier: "another-server")
        XCTAssertNil(mismatchedSnapshot)
    }

    @MainActor
    func testGuideSnapshotsStayAvailableForMultipleServers() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuideSnapshotStoreTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let first = PersistedGuideSnapshot(
            serverIdentifier: "profile:first",
            serverName: "First",
            channels: []
        )
        let second = PersistedGuideSnapshot(
            serverIdentifier: "profile:second",
            serverName: "Second",
            channels: []
        )
        let store = GuideSnapshotStore(fileURL: fileURL)

        await store.save(first)
        await store.save(second)

        let loadedFirst = await store.load(serverIdentifier: "profile:first")
        let loadedSecond = await store.load(serverIdentifier: "profile:second")
        XCTAssertEqual(loadedFirst?.serverName, "First")
        XCTAssertEqual(loadedSecond?.serverName, "Second")
    }

    @MainActor
    func testGuideModelBootstrapsWithCurrentCachedGuide() {
        let now = Date(timeIntervalSince1970: 10_000)
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.local:9981"),
            username: "viewer",
            password: "secret",
            streamProfile: "pass",
            guideCacheURL: URL(string: "http://guide.local:49382/guide.json"),
            xmltvURL: nil
        )
        let channel = GuideChannel(
            id: "channel-1",
            number: 1,
            name: "Cached channel",
            monogram: "CC",
            tint: .orange,
            iconURL: nil,
            programs: [
                GuideProgram(
                    id: "current",
                    channelID: "channel-1",
                    title: "Cached current programme",
                    subtitle: nil,
                    overview: "",
                    start: now.addingTimeInterval(-300),
                    end: now.addingTimeInterval(1_500)
                ),
            ]
        )
        let snapshot = PersistedGuideSnapshot(
            serverIdentifier: configuration.guideSnapshotIdentifier,
            serverName: "Cached TVHeadend",
            savedAt: now,
            channels: [channel]
        )

        let model = GuideViewModel(
            now: now,
            configuration: configuration,
            cachedSnapshot: snapshot
        )

        XCTAssertTrue(model.hasUsableGuide)
        XCTAssertEqual(model.channels.first?.programs.first?.id, "current")
        XCTAssertEqual(model.loadState, .loaded(serverName: "Cached TVHeadend", channelCount: 1))
    }

    @MainActor
    func testGuideModelKeepsCachedGuideWhileDiscoveryRestoresConfiguration() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let channel = GuideChannel(
            id: "channel-1",
            number: 1,
            name: "Cached channel",
            monogram: "CC",
            tint: .orange,
            iconURL: nil,
            programs: [
                GuideProgram(
                    id: "current",
                    channelID: "channel-1",
                    title: "Cached current programme",
                    subtitle: nil,
                    overview: "",
                    start: now.addingTimeInterval(-300),
                    end: now.addingTimeInterval(1_500)
                ),
            ]
        )
        let snapshot = PersistedGuideSnapshot(
            serverIdentifier: "http://tvheadend.local:9981|viewer||",
            serverName: "Cached TVHeadend",
            savedAt: now,
            channels: [channel]
        )
        let model = GuideViewModel(now: now, cachedSnapshot: snapshot)
        let incompleteConfiguration = TVHeadendConfiguration(
            baseURL: nil,
            username: "",
            password: "",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )

        await model.load(configuration: incompleteConfiguration, at: now)

        XCTAssertTrue(model.hasUsableGuide)
        XCTAssertEqual(model.channels.first?.programs.first?.id, "current")
        XCTAssertEqual(model.loadState, .loaded(serverName: "Cached TVHeadend", channelCount: 1))
    }

    @MainActor
    func testGuideModelDoesNotSurfaceURLSessionCancellationOverCachedGuide() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.local:9981"),
            username: "viewer",
            password: "secret",
            streamProfile: "pass",
            guideCacheURL: URL(string: "http://guide.local:49382/guide.json"),
            xmltvURL: nil
        )
        let snapshot = PersistedGuideSnapshot(
            serverIdentifier: configuration.guideSnapshotIdentifier,
            serverName: "Cached TVHeadend",
            savedAt: now,
            channels: [GuideChannel(
                id: "channel-1",
                number: 1,
                name: "Cached channel",
                monogram: "CC",
                tint: .orange,
                iconURL: nil,
                programs: [GuideProgram(
                    id: "current",
                    channelID: "channel-1",
                    title: "Cached current programme",
                    subtitle: nil,
                    overview: "The cached programme description.",
                    start: now.addingTimeInterval(-300),
                    end: now.addingTimeInterval(1_500)
                )]
            )]
        )
        let model = GuideViewModel(
            now: now,
            configuration: configuration,
            cachedSnapshot: snapshot
        ) { _, _, _ in
            throw URLError(.cancelled)
        }

        await model.load(configuration: configuration, at: now, force: true)

        XCTAssertTrue(model.hasUsableGuide)
        XCTAssertEqual(model.channels.first?.programs.first?.overview, "The cached programme description.")
        XCTAssertEqual(model.loadState, .loaded(serverName: "Cached TVHeadend", channelCount: 1))
    }

    @MainActor
    func testGuideModelSupersedesAnInFlightLoadForANewServer() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let oldConfiguration = TVHeadendConfiguration(
            baseURL: URL(string: "http://old-guide-race.test:9981")!,
            username: "",
            password: "",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )
        let newConfiguration = TVHeadendConfiguration(
            baseURL: URL(string: "http://new-guide-race.test:9981")!,
            username: "",
            password: "",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )
        let oldLoadStarted = expectation(description: "Old guide load started")
        let model = GuideViewModel(now: now) { configuration, _, _ in
            if configuration == oldConfiguration {
                oldLoadStarted.fulfill()
                try await Task.sleep(for: .seconds(30))
                return TVProviderSnapshot(channels: [], serverName: "Old server")
            }
            return TVProviderSnapshot(
                channels: [GuideChannel(
                    id: "new-channel",
                    number: 1,
                    name: "New channel",
                    monogram: "NC",
                    tint: .blue,
                    iconURL: nil,
                    programs: []
                )],
                serverName: "New server"
            )
        }

        let oldLoad = Task {
            await model.load(configuration: oldConfiguration, at: now, force: true)
        }
        await fulfillment(of: [oldLoadStarted], timeout: 1)

        await model.load(configuration: newConfiguration, at: now, force: true)
        await oldLoad.value

        XCTAssertEqual(model.channels.map(\.id), ["new-channel"])
        XCTAssertEqual(model.loadState, .loaded(serverName: "New server", channelCount: 1))
    }

    func testOffsetsAreClampedToTimeline() {
        let start = Date(timeIntervalSince1970: 10_000)
        let timeline = GuideTimeline(start: start, end: start.addingTimeInterval(3_600))

        XCTAssertEqual(timeline.xOffset(for: start.addingTimeInterval(-600)), 0)
        XCTAssertEqual(timeline.xOffset(for: start.addingTimeInterval(7_200)), timeline.width)
    }

    func testProgramPhaseAtBoundaries() {
        let start = Date(timeIntervalSince1970: 10_000)
        let program = GuideProgram(
            id: "test",
            channelID: "channel",
            title: "Test",
            subtitle: nil,
            overview: "",
            start: start,
            end: start.addingTimeInterval(1_800)
        )

        XCTAssertEqual(program.phase(at: start), .current)
        XCTAssertEqual(program.phase(at: start.addingTimeInterval(1_799)), .current)
        XCTAssertEqual(program.phase(at: start.addingTimeInterval(1_800)), .past)
        XCTAssertEqual(program.phase(at: start.addingTimeInterval(-1)), .future)
    }

    func testXMLTVParserReadsProgrammeMetadata() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ard.de">
            <display-name>Das Erste</display-name>
            <icon src="https://example.test/ard.png" />
          </channel>
          <programme start="20260719140000 +0200" stop="20260719150000 +0200" channel="ard.de">
            <title>Tagesschau</title>
            <sub-title>Nachrichten</sub-title>
            <desc>Die Nachrichten des Tages.</desc>
            <icon src="https://example.test/tagesschau.jpg" />
          </programme>
        </tv>
        """

        let document = try XMLTVParser.parse(Data(xml.utf8))

        XCTAssertEqual(document.channels.count, 1)
        XCTAssertEqual(document.channels.first?.id, "ard.de")
        XCTAssertEqual(document.channels.first?.displayName, "Das Erste")
        XCTAssertEqual(document.programmes.count, 1)
        XCTAssertEqual(document.programmes.first?.title, "Tagesschau")
        XCTAssertEqual(document.programmes.first?.subtitle, "Nachrichten")
        XCTAssertEqual(document.programmes.first?.description, "Die Nachrichten des Tages.")
        XCTAssertEqual(document.programmes.first?.imageURL, "https://example.test/tagesschau.jpg")
        XCTAssertEqual(document.programmes.first?.end.timeIntervalSince(document.programmes.first!.start), 3_600)
    }

    func testLiveStreamURLUsesConfiguredPassProfile() throws {
        let configuration = TVHeadendConfiguration(
            baseURL: URL(string: "http://tvheadend.local:9981"),
            username: "test",
            password: "secret",
            streamProfile: "pass",
            guideCacheURL: nil,
            xmltvURL: nil
        )

        let url = try TVHeadendClient(configuration: configuration)
            .liveStreamURL(channelID: "channel-uuid")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/stream/channel/channel-uuid")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "profile" })?.value, "pass")
    }

    func testDVREntryDecodesTVHeadendGridFields() throws {
        let json = """
        {
          "uuid": "recording-uuid",
          "broadcast": 259754,
          "disp_title": "Sportschau",
          "disp_subtitle": "15. Etappe",
          "disp_description": "Tour de France",
          "channel": "channel-uuid",
          "channelname": "Das Erste HD",
          "start": 1784473380,
          "start_real": 1784473200,
          "stop": 1784484000,
          "stop_real": 1784484300,
          "sched_status": "recording",
          "status": "Recording",
          "filesize": 123456789,
          "errors": 1,
          "data_errors": 2,
          "autorec": "rule-uuid"
        }
        """

        let entry = try JSONDecoder().decode(TVHeadendDVREntry.self, from: Data(json.utf8))

        XCTAssertEqual(entry.uuid, "recording-uuid")
        XCTAssertEqual(entry.eventID, 259754)
        XCTAssertEqual(entry.displayTitle, "Sportschau")
        XCTAssertEqual(entry.channelUUID, "channel-uuid")
        XCTAssertEqual(entry.start, 1784473380)
        XCTAssertEqual(entry.stop, 1784484000)
        XCTAssertEqual(entry.fileSize, 123456789)
        XCTAssertEqual(entry.errors, 1)
        XCTAssertEqual(entry.dataErrors, 2)
        XCTAssertEqual(entry.autorecUUID, "rule-uuid")
    }

    func testDVRCompletedErrorWithoutAFileRemainsFailed() throws {
        let entry = try dvrEntry(
            scheduleStatus: "completedError",
            status: "File missing",
            start: 1_000,
            stop: 2_000
        )

        XCTAssertEqual(
            TVHeadendClient.recordingState(for: entry, at: Date(timeIntervalSince1970: 1_500)),
            .failed
        )
    }

    func testDVRCompletedErrorWithAFileIsPlayableWithWarning() throws {
        let entry = try dvrEntry(
            scheduleStatus: "completedError",
            status: "Weak stream",
            start: 1_000,
            stop: 2_000,
            fileSize: 2_901_346_472
        )

        let state = TVHeadendClient.recordingState(
            for: entry,
            at: Date(timeIntervalSince1970: 2_500)
        )
        XCTAssertEqual(state, .completed)
        XCTAssertEqual(
            TVHeadendClient.recordingWarning(for: entry, state: state),
            "Weak stream"
        )
    }

    func testDVRCompletedRerecordWithAFileIsPlayableWithWarning() throws {
        let entry = try dvrEntry(
            scheduleStatus: "completedRerecord",
            status: "Completed OK",
            start: 1_000,
            stop: 2_000,
            fileSize: 3_549_510_500
        )

        let state = TVHeadendClient.recordingState(
            for: entry,
            at: Date(timeIntervalSince1970: 2_500)
        )
        XCTAssertEqual(state, .completed)
        XCTAssertEqual(
            TVHeadendClient.recordingWarning(for: entry, state: state),
            "TVheadend requested a re-record because quality issues were detected."
        )
    }

    func testDVRScheduledAndActiveEntriesRetainTheirStates() throws {
        let scheduled = try dvrEntry(
            scheduleStatus: "scheduled",
            status: "Scheduled for recording",
            start: 2_000,
            stop: 3_000
        )
        let recording = try dvrEntry(
            scheduleStatus: "recording",
            status: "Recording",
            start: 1_000,
            stop: 3_000
        )
        let now = Date(timeIntervalSince1970: 1_500)

        XCTAssertEqual(TVHeadendClient.recordingState(for: scheduled, at: now), .upcoming)
        XCTAssertEqual(TVHeadendClient.recordingState(for: recording, at: now), .recording)
    }

    func testEPGEventDecodesNativeSeriesMetadata() throws {
        let json = """
        {
          "eventId": 42,
          "channelUuid": "channel-uuid",
          "serieslinkUri": "crid://example.test/series/7",
          "title": "Example Show",
          "start": 1784473380,
          "stop": 1784476980
        }
        """

        let event = try JSONDecoder().decode(TVHeadendEPGEvent.self, from: Data(json.utf8))

        XCTAssertEqual(event.eventID, 42)
        XCTAssertEqual(event.seriesLink, "crid://example.test/series/7")
    }

    func testEPGHistoryDropsAbsentCurrentEventAfterLargeScheduleAmendment() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let stale = try JSONDecoder().decode(
            TVHeadendEPGEvent.self,
            from: Data(
                """
                {
                  "eventId": 1,
                  "channelUuid": "channel-uuid",
                  "title": "phoenix vor ort",
                  "start": 101000,
                  "stop": 102800
                }
                """.utf8
            )
        )
        let amended = try JSONDecoder().decode(
            TVHeadendEPGEvent.self,
            from: Data(
                """
                {
                  "eventId": 2,
                  "channelUuid": "channel-uuid",
                  "title": "phoenix vor ort",
                  "start": 99200,
                  "stop": 102800
                }
                """.utf8
            )
        )

        let retained = EPGHistoryStore.retainedCachedEvents(
            [stale],
            freshEvents: [amended],
            now: now.addingTimeInterval(60)
        )

        XCTAssertTrue(retained.isEmpty)
    }

    func testEPGHistoryRetainsAbsentFinishedEvent() throws {
        let finished = try JSONDecoder().decode(
            TVHeadendEPGEvent.self,
            from: Data(
                """
                {
                  "eventId": 1,
                  "channelUuid": "channel-uuid",
                  "title": "Finished Show",
                  "start": 98200,
                  "stop": 99700
                }
                """.utf8
            )
        )

        let retained = EPGHistoryStore.retainedCachedEvents(
            [finished],
            freshEvents: [],
            now: Date(timeIntervalSince1970: 100_060)
        )

        XCTAssertEqual(retained.map(\.eventID), [1])
    }

    func testRichGuideDocumentRetainsEpisodeRatingsAndRecordingState() throws {
        let json = """
        {
          "version": 1,
          "lastRefresh": 1784473380,
          "channels": [],
          "events": [
            {
              "eventId": 42,
              "channelUuid": "channel-uuid",
              "episodeUri": "crid://example.test/episode/2",
              "serieslinkUri": "crid://example.test/series/7",
              "title": "Example Show",
              "summary": "An example episode.",
              "start": 1784473380,
              "stop": 1784476980,
              "seasonNumber": 3,
              "episodeNumber": "2",
              "genre": [16, 17],
              "categories": ["Drama", "Mystery"],
              "ageRating": 12,
              "ratingLabel": "FSK 12",
              "starRating": 4,
              "hd": 1,
              "subtitled": true,
              "dvrUuid": "recording-uuid",
              "dvrState": "scheduled",
              "image": "http://images.example/show.jpg"
            }
          ]
        }
        """

        let document = try JSONDecoder().decode(
            TVPlayerGuideCacheDocument.self,
            from: Data(json.utf8)
        )
        let event = try XCTUnwrap(document.events.first)

        XCTAssertEqual(document.version, 1)
        XCTAssertEqual(event.eventID, 42)
        XCTAssertEqual(event.episodeURI, "crid://example.test/episode/2")
        XCTAssertEqual(event.seasonNumber, "3")
        XCTAssertEqual(event.episodeNumber, "2")
        XCTAssertEqual(event.genres, [16, 17])
        XCTAssertEqual(event.categories, ["Drama", "Mystery"])
        XCTAssertEqual(event.ageRating, "12")
        XCTAssertEqual(event.ratingLabel, "FSK 12")
        XCTAssertEqual(event.starRating, "4")
        XCTAssertTrue(event.isHD)
        XCTAssertTrue(event.isSubtitled)
        XCTAssertEqual(event.dvrUUID, "recording-uuid")
        XCTAssertEqual(event.dvrState, "scheduled")
        XCTAssertEqual(event.imageURL, "http://images.example/show.jpg")
    }

    func testExternalHTTPArtworkPrefersHTTPSWithoutRewritingLocalTVHeadend() throws {
        let serverURL = try XCTUnwrap(URL(string: "http://tvheadend.local:9981"))

        XCTAssertEqual(
            TVHeadendClient.resolvedArtworkURLString(
                "http://ngiss.t-online.de/cm1s/media/gracenote/show.jpg",
                relativeTo: serverURL
            ),
            "https://ngiss.t-online.de/cm1s/media/gracenote/show.jpg"
        )
        XCTAssertEqual(
            TVHeadendClient.resolvedArtworkURLString(
                "http://tvheadend.local:9981/imagecache/52",
                relativeTo: serverURL
            ),
            "http://tvheadend.local:9981/imagecache/52"
        )
    }

    private func dvrEntry(
        scheduleStatus: String,
        status: String,
        start: Int64,
        stop: Int64,
        fileSize: Int64 = 0
    ) throws -> TVHeadendDVREntry {
        let json = """
        {
          "uuid": "recording-uuid",
          "disp_title": "Test programme",
          "channel": "channel-uuid",
          "channelname": "Test channel",
          "start": \(start),
          "stop": \(stop),
          "sched_status": "\(scheduleStatus)",
          "status": "\(status)",
          "filesize": \(fileSize),
          "errors": 0,
          "data_errors": 0
        }
        """
        return try JSONDecoder().decode(TVHeadendDVREntry.self, from: Data(json.utf8))
    }
}
