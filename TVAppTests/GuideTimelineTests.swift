import XCTest
@testable import TVApp

final class GuideTimelineTests: XCTestCase {
    func testOneHourUsesExpectedWidth() {
        let start = Date(timeIntervalSince1970: 10_000)
        let timeline = GuideTimeline(start: start, end: start.addingTimeInterval(7_200))

        XCTAssertEqual(timeline.xOffset(for: start.addingTimeInterval(3_600)), 360, accuracy: 0.001)
        XCTAssertEqual(timeline.width, 720, accuracy: 0.001)
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
            xmltvURL: nil
        )

        let url = try TVHeadendClient(configuration: configuration)
            .liveStreamURL(channelID: "channel-uuid")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/stream/channel/channel-uuid")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "profile" })?.value, "pass")
    }
}
