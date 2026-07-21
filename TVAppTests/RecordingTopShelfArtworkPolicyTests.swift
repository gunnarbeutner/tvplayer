#if os(tvOS)
import XCTest
@testable import TVApp

final class RecordingTopShelfArtworkPolicyTests: XCTestCase {
    func testGuideArtworkWinsOverGeneratedAlternatives() {
        XCTAssertEqual(
            RecordingTopShelfArtworkPolicy.selectedFilename(
                guideArtwork: "guide.jpg",
                cachedFrame: "frame.jpg",
                fallback: "fallback.jpg"
            ),
            "guide.jpg"
        )
    }

    func testCachedFrameWinsWhenGuideArtworkIsUnavailable() {
        XCTAssertEqual(
            RecordingTopShelfArtworkPolicy.selectedFilename(
                guideArtwork: nil,
                cachedFrame: "frame.jpg",
                fallback: "fallback.jpg"
            ),
            "frame.jpg"
        )
    }

    func testFallbackIsUsedWhileAFrameIsBeingGenerated() {
        XCTAssertEqual(
            RecordingTopShelfArtworkPolicy.selectedFilename(
                guideArtwork: nil,
                cachedFrame: nil,
                fallback: "fallback.jpg"
            ),
            "fallback.jpg"
        )
    }

    func testGrowingAndCompletedRecordingsUseDifferentFrameCaches() {
        let growing = RecordingTopShelfArtworkPolicy.frameCacheIdentifier(
            recordingID: "recording-id",
            state: .recording
        )
        let completed = RecordingTopShelfArtworkPolicy.frameCacheIdentifier(
            recordingID: "recording-id",
            state: .completed
        )

        XCTAssertNotEqual(growing, completed)
        XCTAssertTrue(growing.contains("growing"))
        XCTAssertTrue(completed.contains("completed"))
    }

    func testGrowingRecordingsUseAnEarlierFrame() {
        let growing = RecordingTopShelfArtworkPolicy.snapshotPosition(for: .recording)
        let completed = RecordingTopShelfArtworkPolicy.snapshotPosition(for: .completed)

        XCTAssertEqual(growing, 0.05)
        XCTAssertEqual(completed, 0.20)
        XCTAssertLessThan(growing, completed)
    }
}

final class TopShelfOnNowPolicyTests: XCTestCase {
    func testSimulcastsAreDeduplicatedBeforeTheLimit() {
        let start = Date(timeIntervalSince1970: 10_000)
        let end = start.addingTimeInterval(3_600)
        let first = candidate(
            channelID: "first",
            programID: "first-event",
            title: " Morning   News ",
            subtitle: "Headlines",
            start: start,
            end: end
        )
        let simulcast = candidate(
            channelID: "second",
            programID: "second-event",
            title: "morning news",
            subtitle: "headlines",
            start: start,
            end: end
        )
        let unique = candidate(
            channelID: "third",
            programID: "third-event",
            title: "Another Programme",
            start: start,
            end: end
        )

        let programs = TopShelfOnNowPolicy.uniquePrograms(
            from: [first, simulcast, unique],
            limit: 2
        )

        XCTAssertEqual(programs.map(\.channel.id), ["first", "third"])
    }

    func testEpisodeURIDeduplicatesDifferentlyTimedChannelEvents() {
        let start = Date(timeIntervalSince1970: 20_000)
        let first = candidate(
            channelID: "first",
            programID: "first-event",
            title: "Programme",
            start: start,
            end: start.addingTimeInterval(3_600),
            episodeURI: "episode://shared"
        )
        let delayedSimulcast = candidate(
            channelID: "second",
            programID: "second-event",
            title: "Programme (Live)",
            start: start.addingTimeInterval(30),
            end: start.addingTimeInterval(3_630),
            episodeURI: "episode://shared"
        )

        let programs = TopShelfOnNowPolicy.uniquePrograms(
            from: [first, delayedSimulcast],
            limit: 12
        )

        XCTAssertEqual(programs.map(\.channel.id), ["first"])
    }

    func testDifferentEpisodesWithTheSameScheduleRemainSeparate() {
        let start = Date(timeIntervalSince1970: 30_000)
        let first = candidate(
            channelID: "first",
            programID: "first-event",
            title: "Daily Show",
            subtitle: "Episode One",
            start: start,
            end: start.addingTimeInterval(1_800)
        )
        let second = candidate(
            channelID: "second",
            programID: "second-event",
            title: "Daily Show",
            subtitle: "Episode Two",
            start: start,
            end: start.addingTimeInterval(1_800)
        )

        let programs = TopShelfOnNowPolicy.uniquePrograms(
            from: [first, second],
            limit: 12
        )

        XCTAssertEqual(programs.map(\.channel.id), ["first", "second"])
    }

    private func candidate(
        channelID: String,
        programID: String,
        title: String,
        subtitle: String? = nil,
        start: Date,
        end: Date,
        episodeURI: String? = nil
    ) -> TopShelfOnNowPolicy.Candidate {
        let program = GuideProgram(
            id: programID,
            channelID: channelID,
            title: title,
            subtitle: subtitle,
            overview: "",
            start: start,
            end: end,
            metadata: GuideProgramMetadata(episodeURI: episodeURI)
        )
        let channel = GuideChannel(
            id: channelID,
            number: 1,
            name: channelID,
            monogram: channelID,
            tint: .blue,
            iconURL: nil,
            programs: [program]
        )
        return (channel: channel, program: program)
    }
}
#endif
