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
            "version": Data("1".utf8),
            "url": Data("http://tvheadend.local:9981".utf8),
            "username": Data("viewer".utf8),
            "password": Data("secret".utf8),
            "profile": Data("pass".utf8),
            "guide": Data("http://guide.example:49382/guide.json".utf8),
            "xmltv": Data("https://guide.example/guide.xml".utf8),
        ]

        let discovered = try XCTUnwrap(DiscoveredTVHeadendSettings(fields: fields))

        XCTAssertEqual(discovered.baseURL.absoluteString, "http://tvheadend.local:9981")
        XCTAssertEqual(discovered.username, "viewer")
        XCTAssertEqual(discovered.password, "secret")
        XCTAssertEqual(discovered.streamProfile, "pass")
        XCTAssertEqual(discovered.guideCacheURL?.absoluteString, "http://guide.example:49382/guide.json")
        XCTAssertEqual(discovered.xmltvURL?.absoluteString, "https://guide.example/guide.xml")
    }

    func testDiscoveredSettingsRejectInvalidOrIncompleteRecords() {
        XCTAssertNil(DiscoveredTVHeadendSettings(fields: [
            "url": Data("ftp://tvheadend.local".utf8),
            "username": Data("viewer".utf8),
            "password": Data("secret".utf8),
        ]))
        XCTAssertNil(DiscoveredTVHeadendSettings(fields: [
            "url": Data("http://tvheadend.local:9981".utf8),
            "username": Data("viewer".utf8),
        ]))
        XCTAssertNil(DiscoveredTVHeadendSettings(fields: [
            "url": Data("http://tvheadend.local:9981".utf8),
            "username": Data("viewer".utf8),
            "password": Data("secret".utf8),
            "guide": Data("ftp://guide.example/guide.json".utf8),
        ]))
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
        let mismatchedSnapshot = await store.load(serverIdentifier: "another-server")
        XCTAssertNil(mismatchedSnapshot)
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

    func testDVRCompletedErrorsRemainVisibleAsFailedRecordings() throws {
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

    func testDVRCompletedRerecordRemainsVisibleAsFailedRecording() throws {
        let entry = try dvrEntry(
            scheduleStatus: "completedRerecord",
            status: "Time missed",
            start: 1_000,
            stop: 2_000
        )

        XCTAssertEqual(
            TVHeadendClient.recordingState(for: entry, at: Date(timeIntervalSince1970: 2_500)),
            .failed
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
              "dvrState": "scheduled"
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
    }

    private func dvrEntry(
        scheduleStatus: String,
        status: String,
        start: Int64,
        stop: Int64
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
          "filesize": 0,
          "errors": 0,
          "data_errors": 0
        }
        """
        return try JSONDecoder().decode(TVHeadendDVREntry.self, from: Data(json.utf8))
    }
}
