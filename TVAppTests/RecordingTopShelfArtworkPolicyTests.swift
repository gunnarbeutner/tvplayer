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

final class TopShelfSnapshotStoreTests: XCTestCase {
    func testSharedFilesAreStoredInLibraryCaches() {
        let container = URL(fileURLWithPath: "/shared/app-group", isDirectory: true)

        let cacheDirectory = TopShelfSnapshotStore.cacheDirectoryURL(for: container)

        XCTAssertEqual(cacheDirectory.path, "/shared/app-group/Library/Caches")
        XCTAssertEqual(
            cacheDirectory.appending(path: TopShelfSnapshotStore.snapshotFilename).path,
            "/shared/app-group/Library/Caches/top-shelf-v1.json"
        )
    }

    func testCachedArtworkURLRejectsPathTraversal() {
        XCTAssertNil(
            TopShelfSnapshotStore.cachedArtworkURL(for: "../top-shelf-artwork-image.jpg")
        )
        XCTAssertNil(TopShelfSnapshotStore.cachedArtworkURL(for: "unrelated-image.jpg"))
    }

    func testAvailableOnNowItemsExcludeExpiredAndFuturePrograms() {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = TopShelfSnapshot(
            version: 1,
            generatedAt: now,
            onNow: [
                item(id: "expired", start: now.addingTimeInterval(-120), end: now),
                item(
                    id: "current",
                    start: now.addingTimeInterval(-60),
                    end: now.addingTimeInterval(180)
                ),
                item(
                    id: "future",
                    start: now.addingTimeInterval(60),
                    end: now.addingTimeInterval(120)
                ),
            ],
            recordings: []
        )

        XCTAssertEqual(snapshot.availableOnNowItems(at: now).map(\.id), ["current"])
    }

    func testOnNowItemRetiresBeforeItsProgrammeActuallyExpires() {
        let now = Date(timeIntervalSince1970: 15_000)
        let item = item(
            id: "ending",
            start: now.addingTimeInterval(-1_800),
            end: now.addingTimeInterval(60)
        )
        let snapshot = TopShelfSnapshot(
            version: 1,
            generatedAt: now,
            onNow: [item],
            recordings: []
        )

        XCTAssertTrue(item.isAvailable(at: now))
        XCTAssertFalse(item.isPresentableOnTopShelf(at: now))
        XCTAssertTrue(snapshot.availableOnNowItems(at: now).isEmpty)
    }

    func testLegacySnapshotItemsDecodeWithoutSchedulingFields() throws {
        let data = Data(#"""
        {
          "id": "legacy",
          "title": "Legacy item",
          "routeURL": "tvplayer://channel/legacy",
          "artworkFilename": null,
          "expirationDate": null,
          "playbackProgress": null
        }
        """#.utf8)

        let item = try JSONDecoder().decode(TopShelfSnapshot.Item.self, from: data)

        XCTAssertNil(item.availabilityDate)
        XCTAssertNil(item.contentIdentifier)
        XCTAssertTrue(item.isAvailable(at: Date()))
    }

    func testLegacySnapshotDecodesWithoutGuideCoverageEnd() throws {
        let data = Data(#"""
        {
          "version": 1,
          "generatedAt": 10000,
          "onNow": [],
          "recordings": []
        }
        """#.utf8)

        let snapshot = try JSONDecoder().decode(TopShelfSnapshot.self, from: data)

        XCTAssertNil(snapshot.guideCoverageEnd)
    }

    func testBackgroundRefreshIsScheduledBeforeGuideCoverageEnds() {
        let now = Date(timeIntervalSince1970: 10_000)
        let coverageEnd = now.addingTimeInterval(5 * 60 * 60)

        let refreshDate = GuideBackgroundRefreshPolicy.nextRefreshDate(
            after: now,
            guideCoverageEnd: coverageEnd
        )

        XCTAssertEqual(refreshDate, coverageEnd.addingTimeInterval(-30 * 60))
    }

    func testBackgroundRefreshDoesNotImmediatelyLoopNearCoverageEnd() {
        let now = Date(timeIntervalSince1970: 10_000)

        let refreshDate = GuideBackgroundRefreshPolicy.nextRefreshDate(
            after: now,
            guideCoverageEnd: now.addingTimeInterval(5 * 60)
        )

        XCTAssertEqual(refreshDate, now.addingTimeInterval(15 * 60))
    }

    func testBackgroundRefreshRetriesWhenCoverageIsUnknown() {
        let now = Date(timeIntervalSince1970: 10_000)

        let refreshDate = GuideBackgroundRefreshPolicy.nextRefreshDate(
            after: now,
            guideCoverageEnd: nil
        )

        XCTAssertEqual(refreshDate, now.addingTimeInterval(60 * 60))
    }

    func testAvailableOnNowItemsDeduplicateChannelsAndSimulcasts() {
        let now = Date(timeIntervalSince1970: 20_000)
        let end = now.addingTimeInterval(60)
        let snapshot = TopShelfSnapshot(
            version: 1,
            generatedAt: now,
            onNow: [
                item(id: "first", start: now, end: end, contentIdentifier: "episode:one"),
                item(id: "second", start: now, end: end, contentIdentifier: "episode:one"),
                item(id: "first", start: now, end: end, contentIdentifier: "episode:two"),
                item(id: "third", start: now, end: end, contentIdentifier: "episode:three"),
            ],
            recordings: []
        )

        XCTAssertEqual(
            snapshot.availableOnNowItems(at: now).map(\.id),
            ["first", "third"]
        )
    }

    private func item(
        id: String,
        start: Date,
        end: Date,
        contentIdentifier: String? = nil
    ) -> TopShelfSnapshot.Item {
        TopShelfSnapshot.Item(
            id: id,
            title: id,
            routeURL: "tvplayer://channel/\(id)",
            artworkFilename: nil,
            availabilityDate: start,
            expirationDate: end,
            playbackProgress: nil,
            contentIdentifier: contentIdentifier
        )
    }
}

final class TopShelfOnNowPolicyTests: XCTestCase {
    func testSnapshotKeepsTheCompleteAvailableFavoriteSchedule() {
        let now = Date(timeIntervalSince1970: 5_000)
        var candidates: [TopShelfOnNowPolicy.Candidate] = []
        for index in 0..<6 {
            let start = now.addingTimeInterval(TimeInterval(index * 1_800))
            let end = now.addingTimeInterval(TimeInterval((index + 1) * 1_800))
            candidates.append(candidate(
                channelID: "favorite",
                programID: "event-\(index)",
                title: "Programme \(index)",
                start: start,
                end: end
            ))
        }
        let channel = GuideChannel(
            id: "favorite",
            number: 1,
            name: "Favorite",
            monogram: "F",
            tint: .blue,
            iconURL: nil,
            programs: candidates.map { $0.program }
        )

        let programs = TopShelfOnNowPolicy.programsForSnapshot(
            from: [channel],
            favoriteChannelIDs: ["favorite"],
            after: now
        )

        let identifiers = programs.map { $0.program.id }
        let expected = (0..<6).map { "event-\($0)" }
        XCTAssertEqual(identifiers, expected)
    }

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
