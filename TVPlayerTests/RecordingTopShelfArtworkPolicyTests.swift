#if os(tvOS)
import XCTest
@testable import TVPlayer

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
                channelLogo: nil,
                fallback: "fallback.jpg"
            ),
            "fallback.jpg"
        )
    }

    func testChannelLogoDoesNotReplaceComposedFallback() {
        XCTAssertEqual(
            RecordingTopShelfArtworkPolicy.selectedFilename(
                guideArtwork: nil,
                cachedFrame: nil,
                channelLogo: "channel-logo.png",
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

    func testFrameCacheChangesWhenAChannelLogoBecomesAvailable() {
        let withoutLogo = RecordingTopShelfArtworkPolicy.frameCacheIdentifier(
            recordingID: "recording-id",
            state: .completed,
            channelLogoIdentifier: nil
        )
        let withLogo = RecordingTopShelfArtworkPolicy.frameCacheIdentifier(
            recordingID: "recording-id",
            state: .completed,
            channelLogoIdentifier: "channel-logo.png"
        )

        XCTAssertNotEqual(withoutLogo, withLogo)
    }

    func testChannelLogoIsRetainedAsSourceArtwork() {
        XCTAssertEqual(
            RecordingTopShelfArtworkPolicy.referencedFilenames(
                selected: "recording-frame.jpg",
                channelLogo: "channel-logo.png"
            ),
            ["recording-frame.jpg", "channel-logo.png"]
        )
    }

    func testGrowingRecordingsUseAnEarlierFrame() {
        let growing = RecordingTopShelfArtworkPolicy.snapshotPosition(for: .recording)
        let completed = RecordingTopShelfArtworkPolicy.snapshotPosition(for: .completed)

        XCTAssertLessThan(growing, completed)
    }

    func testGrowingRecordingUsesTimeWithinTheBytesAlreadyWritten() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recording = TVRecording(
            id: "growing-recording",
            eventID: nil,
            title: "Example Show",
            subtitle: nil,
            overview: "",
            channelID: "channel",
            channelName: "Example Channel",
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(3_540),
            state: .recording,
            statusText: nil,
            warningText: nil,
            fileSize: 1_000,
            errorCount: 0,
            dataErrorCount: 0,
            autorecID: nil,
            streamPath: "/recording"
        )

        let target = RecordingTopShelfArtworkPolicy.thumbnailSeekTarget(
            for: recording,
            now: now
        )

        XCTAssertEqual(target, .time(milliseconds: 48_000))
    }

    func testRecordingThumbnailOverlayIncludesIdentityAndState() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let program = GuideProgram(
            id: "programme",
            channelID: "channel",
            title: "Example Show",
            subtitle: "Guide subtitle",
            overview: "",
            start: start,
            end: start.addingTimeInterval(3_600),
            metadata: GuideProgramMetadata(
                seasonNumber: "4",
                episodeNumber: "8"
            )
        )
        let recording = TVRecording(
            id: "recording",
            eventID: nil,
            title: "Example Show",
            subtitle: "Recorded subtitle",
            overview: "",
            channelID: "channel",
            channelName: "Example Channel",
            start: start,
            end: start.addingTimeInterval(3_900),
            state: .completed,
            statusText: nil,
            warningText: nil,
            fileSize: 1_000,
            errorCount: 0,
            dataErrorCount: 0,
            autorecID: nil,
            streamPath: "/recording"
        )

        let overlay = RecordingThumbnailOverlayPolicy.overlay(
            for: recording,
            matchingProgram: program
        )

        XCTAssertEqual(overlay.title, "Example Show")
        XCTAssertEqual(
            overlay.detail,
            "Season 4 · Episode 8 · Recorded subtitle"
        )
        XCTAssertEqual(overlay.channelName, "Example Channel")
        XCTAssertEqual(overlay.badge, "RECORDED")
    }

    func testRecordingLogoPlateAvoidsTheBroadcastLogoRegion() {
        let size = CGSize(width: 1_216, height: 684)

        let plate = RecordingTopShelfArtworkLayout.logoPlateRect(in: size)

        XCTAssertGreaterThan(plate.midY, size.height * 0.75)
        XCTAssertGreaterThan(plate.midX, size.width * 0.75)
        XCTAssertLessThanOrEqual(plate.maxX, size.width - 64)
        XCTAssertLessThanOrEqual(plate.maxY, size.height - 48)
    }

    func testLogoPlateUsesDarkBackgroundForLightLogos() {
        XCTAssertEqual(
            RecordingTopShelfLogoPlateStyle.forContentLuminance(0.95),
            .dark
        )
    }

    func testLogoPlateUsesLightBackgroundForDarkLogos() {
        XCTAssertEqual(
            RecordingTopShelfLogoPlateStyle.forContentLuminance(0.05),
            .light
        )
    }

    func testThumbnailQueueRetainsWorkAddedDuringGeneration() {
        var queue = RecordingThumbnailWorkQueue<String>()
        queue.enqueue("first recording", forKey: "first")

        XCTAssertEqual(queue.popFirst(), "first recording")

        queue.enqueue("growing recording", forKey: "growing")

        XCTAssertEqual(queue.popFirst(), "growing recording")
        XCTAssertNil(queue.popFirst())
    }
}

final class TopShelfSnapshotStoreTests: XCTestCase {
    func testSharedFilesAreStoredInLibraryCaches() {
        let container = URL(fileURLWithPath: "/shared/app-group", isDirectory: true)

        let cacheDirectory = TopShelfSnapshotStore.cacheDirectoryURL(for: container)

        XCTAssertEqual(cacheDirectory.path, "/shared/app-group/Library/Caches")
        XCTAssertEqual(
            cacheDirectory.appending(path: TopShelfSnapshotStore.snapshotFilename).path,
            "/shared/app-group/Library/Caches/top-shelf-v2.json"
        )
    }

    func testCachedArtworkURLRejectsPathTraversal() {
        XCTAssertNil(
            TopShelfSnapshotStore.cachedArtworkURL(for: "../top-shelf-artwork-image.jpg")
        )
        XCTAssertNil(TopShelfSnapshotStore.cachedArtworkURL(for: "unrelated-image.jpg"))
    }

    func testCarouselMetadataSurvivesSnapshotSerialization() throws {
        let creationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let item = TopShelfSnapshot.Item(
            id: "programme",
            title: "Example Show",
            contextTitle: "On Now · Example Channel",
            summary: "An example summary.",
            genre: "Comedy",
            duration: 3_600,
            creationDate: creationDate,
            mediaOptions: [.hd, .closedCaptioning],
            namedAttributes: [
                .init(name: "Episode", values: ["Season 2 · Episode 3"]),
            ],
            routeURL: "tvplayer://channel/example",
            displayRouteURL: "tvplayer://show/channel/example",
            artworkFilename: "top-shelf-artwork-example.jpg",
            expirationDate: nil,
            playbackProgress: nil
        )

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(TopShelfSnapshot.Item.self, from: data)

        XCTAssertEqual(decoded.contextTitle, item.contextTitle)
        XCTAssertEqual(decoded.summary, item.summary)
        XCTAssertEqual(decoded.genre, item.genre)
        XCTAssertEqual(decoded.duration, item.duration)
        XCTAssertEqual(decoded.creationDate, creationDate)
        XCTAssertEqual(decoded.mediaOptions, [.hd, .closedCaptioning])
        XCTAssertEqual(decoded.namedAttributes, item.namedAttributes)
        XCTAssertEqual(decoded.displayRouteURL, item.displayRouteURL)
    }

    func testAvailableOnNowItemsExcludeExpiredAndFuturePrograms() {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = TopShelfSnapshot(
            version: 2,
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
            version: 2,
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
            version: 2,
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
    func testProgramCarouselMetadataIncludesGuideDetails() {
        let firstAired = Date(timeIntervalSince1970: 1_700_000_000)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let program = GuideProgram(
            id: "programme",
            channelID: "channel",
            title: "Example Show",
            subtitle: "The Example Episode",
            overview: "A useful programme description.",
            start: start,
            end: start.addingTimeInterval(3_600),
            metadata: GuideProgramMetadata(
                seasonNumber: "2",
                episodeNumber: "3",
                firstAired: Int64(firstAired.timeIntervalSince1970),
                categories: ["Comedy"],
                ageRating: "FSK 12",
                isHD: true,
                isSubtitled: true,
                isNew: true
            )
        )
        let channel = GuideChannel(
            id: "channel",
            number: 2,
            name: "Example Channel",
            monogram: "EC",
            tint: .blue,
            iconURL: nil,
            programs: [program]
        )

        let metadata = TopShelfMetadataPolicy.program(
            channel: channel,
            program: program
        )

        XCTAssertEqual(metadata.title, "Example Show")
        XCTAssertEqual(metadata.contextTitle, "On Now · Example Channel")
        XCTAssertEqual(
            metadata.summary,
            "The Example Episode\nA useful programme description."
        )
        XCTAssertEqual(metadata.genre, "Comedy")
        XCTAssertEqual(metadata.duration, 3_600)
        XCTAssertEqual(metadata.creationDate, firstAired)
        XCTAssertEqual(metadata.mediaOptions, [.hd, .closedCaptioning])
        XCTAssertEqual(
            metadata.namedAttributes,
            [
                .init(name: "Episode", values: ["Season 2 · Episode 3"]),
                .init(name: "Rating", values: ["FSK 12"]),
                .init(name: "Features", values: ["New", "HD", "Subtitles"]),
            ]
        )
    }

    func testRecordingCarouselMetadataUsesRecordingAndMatchedGuideDetails() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let program = GuideProgram(
            id: "programme",
            channelID: "channel",
            title: "Example Show",
            subtitle: "Guide subtitle",
            overview: "Guide overview",
            start: start,
            end: start.addingTimeInterval(3_600),
            metadata: GuideProgramMetadata(
                seasonNumber: "4",
                episodeNumber: "8",
                categories: ["Drama"],
                starRating: "4/5",
                isHD: true
            )
        )
        let recording = TVRecording(
            id: "recording",
            eventID: nil,
            title: "Example Show",
            subtitle: "Recorded subtitle",
            overview: "Recorded overview",
            channelID: "channel",
            channelName: "Example Channel",
            start: start,
            end: start.addingTimeInterval(3_900),
            state: .completed,
            statusText: nil,
            warningText: nil,
            fileSize: 1_000,
            errorCount: 0,
            dataErrorCount: 0,
            autorecID: nil,
            streamPath: "/recording"
        )

        let metadata = TopShelfMetadataPolicy.recording(
            recording,
            matchingProgram: program
        )

        XCTAssertEqual(metadata.title, "Example Show")
        XCTAssertEqual(metadata.contextTitle, "Recorded · Example Channel")
        XCTAssertEqual(metadata.summary, "Recorded subtitle\nRecorded overview")
        XCTAssertEqual(metadata.genre, "Drama")
        XCTAssertEqual(metadata.duration, 3_900)
        XCTAssertEqual(metadata.creationDate, start)
        XCTAssertEqual(metadata.mediaOptions, [.hd])
        XCTAssertEqual(
            metadata.namedAttributes,
            [
                .init(name: "Episode", values: ["Season 4 · Episode 8"]),
                .init(name: "Rating", values: ["★ 4/5"]),
                .init(name: "Features", values: ["HD"]),
            ]
        )
    }

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

    func testArtworkCoversTheCompleteAvailableFavoriteSchedule() {
        let now = Date(timeIntervalSince1970: 5_000)
        let programs = (0..<6).map { index in
            let start = now.addingTimeInterval(TimeInterval(index * 1_800))
            return candidate(
                channelID: "favorite",
                programID: "event-\(index)",
                title: "Programme \(index)",
                start: start,
                end: start.addingTimeInterval(1_800)
            ).program
        }
        let channel = GuideChannel(
            id: "favorite",
            number: 1,
            name: "Favorite",
            monogram: "F",
            tint: .blue,
            iconURL: nil,
            programs: programs
        )

        let identifiers = TopShelfOnNowPolicy.artworkIdentifiersForSnapshot(
            from: [channel],
            favoriteChannelIDs: ["favorite"],
            after: now
        )

        XCTAssertEqual(
            identifiers,
            Set((0..<6).map { "favorite:event-\($0)" })
        )
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
