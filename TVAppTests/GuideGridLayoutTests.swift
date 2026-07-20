import CoreGraphics
import XCTest
@testable import TVApp

final class GuideGridLayoutTests: XCTestCase {
    func testChannelLogoCacheKeyDoesNotPersistCredentials() throws {
        let first = try XCTUnwrap(URL(string: "http://alice:secret@example.test:9981/imagecache/42?ticket=first&variant=dark"))
        let renewedTicket = try XCTUnwrap(URL(string: "http://bob:different@example.test:9981/imagecache/42?ticket=second&variant=dark"))

        let firstKey = ChannelLogoImageCache.cacheKey(for: first)
        let renewedKey = ChannelLogoImageCache.cacheKey(for: renewedTicket)

        XCTAssertEqual(firstKey, renewedKey)
        XCTAssertEqual(firstKey.count, 64)
        XCTAssertFalse(firstKey.contains("secret"))
        XCTAssertFalse(firstKey.contains("ticket"))
    }

    func testChannelLogoCacheKeySeparatesServersAndImageVariants() throws {
        let first = try XCTUnwrap(URL(string: "http://one.example.test/imagecache/42?variant=dark"))
        let otherServer = try XCTUnwrap(URL(string: "http://two.example.test/imagecache/42?variant=dark"))
        let otherVariant = try XCTUnwrap(URL(string: "http://one.example.test/imagecache/42?variant=light"))

        XCTAssertNotEqual(
            ChannelLogoImageCache.cacheKey(for: first),
            ChannelLogoImageCache.cacheKey(for: otherServer)
        )
        XCTAssertNotEqual(
            ChannelLogoImageCache.cacheKey(for: first),
            ChannelLogoImageCache.cacheKey(for: otherVariant)
        )
    }

    func testPlaybackFocusRestoresThePlayingChannelAndCurrentProgramme() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let firstChannel = channel(
            id: "first",
            programs: [program(id: "first-current", channelID: "first", around: now)]
        )
        let playingChannel = channel(
            id: "playing",
            programs: [program(id: "playing-current", channelID: "playing", around: now)]
        )
        let selection = PlaybackNavigationSelection(
            channelID: "playing",
            programID: "playing-current"
        )

        XCTAssertEqual(
            PlaybackFocusSelection.channelID(
                in: [firstChannel, playingChannel],
                selection: selection
            ),
            "playing"
        )
        XCTAssertEqual(
            PlaybackFocusSelection.programID(
                in: [firstChannel, playingChannel],
                selection: selection,
                at: now
            ),
            "playing-current"
        )
    }

    func testPlaybackFocusMovesToCurrentShowWhenOriginalShowHasEnded() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let ended = GuideProgram(
            id: "ended",
            channelID: "playing",
            title: "Ended",
            subtitle: nil,
            overview: "",
            start: now.addingTimeInterval(-3_600),
            end: now.addingTimeInterval(-1)
        )
        let current = program(id: "current", channelID: "playing", around: now)
        let selection = PlaybackNavigationSelection(channelID: "playing", programID: "ended")

        XCTAssertEqual(
            PlaybackFocusSelection.programID(
                in: [channel(id: "playing", programs: [ended, current])],
                selection: selection,
                at: now
            ),
            "current"
        )
    }

    func testPlaybackFocusIgnoresAChannelMissingFromTheGuide() throws {
        let selection = PlaybackNavigationSelection(channelID: "missing", programID: nil)

        XCTAssertNil(
            PlaybackFocusSelection.channelID(
                in: [channel(id: "available", programs: [])],
                selection: selection
            )
        )
    }

    func testInitialFocusSelectsCurrentProgrammeInsteadOfEarlierPlaceholder() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let earlier = GuideProgram(
            id: "earlier-channel-1",
            channelID: "channel-1",
            title: "Earlier programme",
            subtitle: nil,
            overview: "",
            start: now.addingTimeInterval(-3_600),
            end: now.addingTimeInterval(-1_800)
        )
        let current = GuideProgram(
            id: "current",
            channelID: "channel-1",
            title: "Current programme",
            subtitle: nil,
            overview: "",
            start: now.addingTimeInterval(-300),
            end: now.addingTimeInterval(1_500)
        )

        XCTAssertEqual(
            GuideFocusSelection.initialProgram(in: [earlier, current], at: now)?.id,
            "current"
        )
    }

    func testInitialFocusFallsBackToNextProgramme() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let earlier = GuideProgram(
            id: "earlier-channel-1",
            channelID: "channel-1",
            title: "Earlier programme",
            subtitle: nil,
            overview: "",
            start: now.addingTimeInterval(-3_600),
            end: now.addingTimeInterval(-1_800)
        )
        let next = GuideProgram(
            id: "next",
            channelID: "channel-1",
            title: "Next programme",
            subtitle: nil,
            overview: "",
            start: now.addingTimeInterval(600),
            end: now.addingTimeInterval(2_400)
        )

        XCTAssertEqual(
            GuideFocusSelection.initialProgram(in: [earlier, next], at: now)?.id,
            "next"
        )
    }

    func testChannelAndProgrammeCardsUseTheSameRowHeight() {
        XCTAssertEqual(
            GuideGridMetrics.cardHeight + (GuideGridMetrics.rowInset * 2),
            GuideGridMetrics.rowHeight
        )
    }

    func testDirectionalInputUsesItsEventCellDuringFocusTransitions() {
        XCTAssertEqual(
            GuideFocusNavigation.inputOrigin(
                confirmedProgramID: "stale-row",
                pendingProgramID: "pending-row",
                eventProgramID: "row-1"
            ),
            "row-1"
        )
        XCTAssertEqual(
            GuideFocusNavigation.inputOrigin(
                confirmedProgramID: nil,
                pendingProgramID: "row-2",
                eventProgramID: "row-1"
            ),
            "row-1"
        )
    }

    func testMovingDownSelectsCurrentProgrammeOnNextChannel() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let first = channel(
            id: "first",
            programs: [
                GuideProgram(
                    id: "long-current",
                    channelID: "first",
                    title: "Long current",
                    subtitle: nil,
                    overview: "",
                    start: now.addingTimeInterval(-7_200),
                    end: now.addingTimeInterval(7_200)
                )
            ]
        )
        let second = channel(
            id: "second",
            programs: [
                GuideProgram(
                    id: "second-current",
                    channelID: "second",
                    title: "Current",
                    subtitle: nil,
                    overview: "",
                    start: now.addingTimeInterval(-1_800),
                    end: now.addingTimeInterval(1_800)
                ),
                GuideProgram(
                    id: "second-next",
                    channelID: "second",
                    title: "Next",
                    subtitle: nil,
                    overview: "",
                    start: now.addingTimeInterval(1_800),
                    end: now.addingTimeInterval(5_400)
                )
            ]
        )
        let snapshot = GuideGridSnapshot(
            channels: [first, second],
            timeline: timeline(around: now),
            revision: 1
        )

        XCTAssertEqual(
            snapshot.destinationProgramID(
                from: "long-current",
                direction: .down,
                at: now
            ),
            "second-current"
        )
    }

    func testMovingDownNeverWrapsFromLastChannelToFirst() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let first = channel(
            id: "first",
            programs: [program(id: "first-current", channelID: "first", around: now)]
        )
        let last = channel(
            id: "last",
            programs: [program(id: "last-current", channelID: "last", around: now)]
        )
        let snapshot = GuideGridSnapshot(
            channels: [first, last],
            timeline: timeline(around: now),
            revision: 1
        )

        XCTAssertNil(
            snapshot.destinationProgramID(
                from: "last-current",
                direction: .down,
                at: now
            )
        )
    }

    func testVerticalNavigationPreservesFutureProgrammeTime() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let selected = GuideProgram(
            id: "selected",
            channelID: "first",
            title: "Selected",
            subtitle: nil,
            overview: "",
            start: now.addingTimeInterval(3_600),
            end: now.addingTimeInterval(7_200)
        )
        let overlapping = GuideProgram(
            id: "overlapping",
            channelID: "second",
            title: "Overlapping",
            subtitle: nil,
            overview: "",
            start: now.addingTimeInterval(4_500),
            end: now.addingTimeInterval(8_100)
        )
        let snapshot = GuideGridSnapshot(
            channels: [
                channel(id: "first", programs: [selected]),
                channel(id: "second", programs: [overlapping]),
            ],
            timeline: timeline(around: now),
            revision: 1
        )

        XCTAssertEqual(
            snapshot.destinationProgramID(
                from: selected.id,
                direction: .down,
                at: now
            ),
            overlapping.id
        )
    }

    func testMovingUpSkipsIntermediateChannelWithoutVisibleProgramme() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let first = channel(
            id: "first",
            programs: [program(id: "first-current", channelID: "first", around: now)]
        )
        let empty = channel(id: "empty", programs: [])
        let third = channel(
            id: "third",
            programs: [program(id: "third-current", channelID: "third", around: now)]
        )
        let snapshot = GuideGridSnapshot(
            channels: [first, empty, third],
            timeline: timeline(around: now),
            revision: 1
        )

        XCTAssertEqual(
            snapshot.destinationProgramID(
                from: "third-current",
                direction: .up,
                at: now
            ),
            "first-current"
        )
    }

    func testOnlyFirstChannelMayExitGuideUpward() {
        let now = Date(timeIntervalSince1970: 10_000)
        let first = channel(
            id: "first",
            programs: [program(id: "first-current", channelID: "first", around: now)]
        )
        let second = channel(
            id: "second",
            programs: [program(id: "second-current", channelID: "second", around: now)]
        )
        let snapshot = GuideGridSnapshot(
            channels: [first, second],
            timeline: timeline(around: now),
            revision: 1
        )

        XCTAssertTrue(
            snapshot.isAtBoundary(
                programID: "first-current",
                direction: .up
            )
        )
        XCTAssertFalse(
            snapshot.isAtBoundary(
                programID: "second-current",
                direction: .up
            )
        )
    }

    func testCollectionSnapshotIndexesProgrammeGeometry() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let timeline = timeline(around: now)
        let first = program(id: "first", channelID: "one", around: now)
        let second = GuideProgram(
            id: "second",
            channelID: "two",
            title: "Second",
            subtitle: nil,
            overview: "",
            start: now.addingTimeInterval(1_800),
            end: now.addingTimeInterval(3_600)
        )
        let snapshot = GuideGridSnapshot(
            channels: [
                channel(id: "one", programs: [first]),
                channel(id: "two", programs: [second]),
            ],
            timeline: timeline,
            revision: 7
        )

        XCTAssertEqual(snapshot.revision, 7)
        XCTAssertEqual(snapshot.indexPath(for: first.id), IndexPath(item: 0, section: 0))
        XCTAssertEqual(snapshot.indexPath(for: second.id), IndexPath(item: 0, section: 1))
        let secondItem = try XCTUnwrap(snapshot.item(at: IndexPath(item: 0, section: 1)))
        XCTAssertEqual(
            secondItem.frame.minY,
            GuideGridMetrics.headerHeight + GuideGridMetrics.rowHeight + GuideGridMetrics.rowInset
        )
        XCTAssertEqual(
            snapshot.contentSize.height,
            GuideGridMetrics.headerHeight + 2 * GuideGridMetrics.rowHeight
        )
    }

    func testCollectionSnapshotQueriesOnlyIntersectingProgrammes() {
        let start = Date(timeIntervalSince1970: 0)
        let timeline = GuideTimeline(
            start: start,
            end: start.addingTimeInterval(6 * 3_600)
        )
        let programs = (0..<6).map { index in
            GuideProgram(
                id: "program-\(index)",
                channelID: "channel",
                title: "Program \(index)",
                subtitle: nil,
                overview: "",
                start: start.addingTimeInterval(Double(index) * 3_600),
                end: start.addingTimeInterval(Double(index + 1) * 3_600)
            )
        }
        let snapshot = GuideGridSnapshot(
            channels: [channel(id: "channel", programs: programs)],
            timeline: timeline,
            revision: 1
        )
        let secondHourStart = GuideGridMetrics.channelWidth + GuideTimeline.pointsPerHour
        let visible = snapshot.items(
            inRow: 0,
            intersecting: secondHourStart...(secondHourStart + GuideTimeline.pointsPerHour - 10)
        )

        XCTAssertEqual(visible.map(\.id), ["program-1"])
    }

    func testCollectionSnapshotUsesIndexedVerticalNavigation() {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = GuideGridSnapshot(
            channels: [
                channel(id: "first", programs: [
                    program(id: "first-current", channelID: "first", around: now)
                ]),
                channel(id: "empty", programs: []),
                channel(id: "third", programs: [
                    program(id: "third-current", channelID: "third", around: now)
                ]),
            ],
            timeline: timeline(around: now),
            revision: 1
        )

        XCTAssertEqual(
            snapshot.destinationProgramID(
                from: "first-current",
                direction: .down,
                at: now
            ),
            "third-current"
        )
        XCTAssertTrue(snapshot.isAtBoundary(programID: "first-current", direction: .up))
    }

    func testCollectionSnapshotUsesIndexedHorizontalNavigation() {
        let start = Date(timeIntervalSince1970: 10_000)
        let programmes = (0..<3).map { index in
            GuideProgram(
                id: "program-\(index)",
                channelID: "channel",
                title: "Program \(index)",
                subtitle: nil,
                overview: "",
                start: start.addingTimeInterval(Double(index) * 1_800),
                end: start.addingTimeInterval(Double(index + 1) * 1_800)
            )
        }
        let snapshot = GuideGridSnapshot(
            channels: [channel(id: "channel", programs: programmes)],
            timeline: GuideTimeline(
                start: start,
                end: start.addingTimeInterval(5_400)
            ),
            revision: 1
        )

        XCTAssertEqual(
            snapshot.destinationProgramID(
                from: "program-1",
                direction: .left,
                at: start
            ),
            "program-0"
        )
        XCTAssertEqual(
            snapshot.destinationProgramID(
                from: "program-1",
                direction: .right,
                at: start
            ),
            "program-2"
        )
        XCTAssertNil(
            snapshot.destinationProgramID(
                from: "program-0",
                direction: .left,
                at: start
            )
        )
        XCTAssertNil(
            snapshot.destinationProgramID(
                from: "program-2",
                direction: .right,
                at: start
            )
        )
    }

    func testCollectionSnapshotHandlesStressSizedGuide() {
        let start = Date(timeIntervalSince1970: 100_000)
        let timeline = GuideTimeline(
            start: start,
            end: start.addingTimeInterval(8 * 3_600)
        )
        let channels = (0..<500).map { channelIndex in
            let programs = (0..<16).map { programIndex in
                GuideProgram(
                    id: "\(channelIndex)-\(programIndex)",
                    channelID: "channel-\(channelIndex)",
                    title: "Programme \(programIndex)",
                    subtitle: nil,
                    overview: "",
                    start: start.addingTimeInterval(Double(programIndex) * 1_800),
                    end: start.addingTimeInterval(Double(programIndex + 1) * 1_800)
                )
            }
            return channel(id: "channel-\(channelIndex)", programs: programs)
        }

        let snapshot = GuideGridSnapshot(
            channels: channels,
            timeline: timeline,
            revision: 1
        )

        XCTAssertEqual(snapshot.rows.count, 500)
        XCTAssertEqual(snapshot.locationByProgramID.count, 8_000)
        XCTAssertEqual(snapshot.rows[499].count, 16)
        XCTAssertEqual(
            snapshot.indexPath(for: "499-15"),
            IndexPath(item: 15, section: 499)
        )
    }

    private func channel(id: String, programs: [GuideProgram]) -> GuideChannel {
        GuideChannel(
            id: id,
            number: 1,
            name: id,
            monogram: String(id.prefix(2)).uppercased(),
            tint: .orange,
            iconURL: nil,
            programs: programs
        )
    }

    private func program(id: String, channelID: String, around date: Date) -> GuideProgram {
        GuideProgram(
            id: id,
            channelID: channelID,
            title: id,
            subtitle: nil,
            overview: "",
            start: date.addingTimeInterval(-300),
            end: date.addingTimeInterval(1_500)
        )
    }

    private func timeline(around date: Date) -> GuideTimeline {
        GuideTimeline(
            start: date.addingTimeInterval(-10_800),
            end: date.addingTimeInterval(10_800)
        )
    }
}
