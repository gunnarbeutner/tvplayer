import CoreGraphics
import XCTest
@testable import TVApp

final class GuideGridLayoutTests: XCTestCase {
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

    func testPinnedChannelColumnDoesNotInheritHorizontalScrollOffset() {
        let initialOffset = CGPoint(x: 280, y: 94)
        let farFutureOffset = CGPoint(x: 1_800, y: 94)

        XCTAssertEqual(
            GuideGridChromeLayout.channelHeadersOffset(for: initialOffset),
            CGSize(width: 0, height: -36)
        )
        XCTAssertEqual(
            GuideGridChromeLayout.channelHeadersOffset(for: farFutureOffset),
            CGSize(width: 0, height: -36)
        )
    }

    func testChannelAndProgrammeCardsUseTheSameRowHeight() {
        XCTAssertEqual(
            GuideGridMetrics.cardHeight + (GuideGridMetrics.rowInset * 2),
            GuideGridMetrics.rowHeight
        )
    }

    func testScrollingBackRestoresTimelineHeaderPosition() {
        let initialScrollOffset = CGPoint(x: 280, y: 94)
        let farFutureScrollOffset = CGPoint(x: 1_800, y: 94)
        let initialHeaderOffset = GuideGridChromeLayout.timelineContentOffset(for: initialScrollOffset)

        XCTAssertEqual(initialHeaderOffset, CGSize(width: -280, height: 0))
        XCTAssertEqual(
            GuideGridChromeLayout.timelineContentOffset(for: farFutureScrollOffset),
            CGSize(width: -1_800, height: 0)
        )
        XCTAssertEqual(
            GuideGridChromeLayout.timelineContentOffset(for: initialScrollOffset),
            initialHeaderOffset
        )
    }

    func testOccludedProgrammeRequestsOffsetClearOfChannelColumn() {
        XCTAssertEqual(
            GuideGridChromeLayout.correctedHorizontalOffset(
                currentOffset: 1_800,
                programmeOffset: 1_500
            ),
            1_492
        )
    }

    func testFirstProgrammeCanRestoreTrueLeadingEdge() {
        XCTAssertEqual(
            GuideGridChromeLayout.correctedHorizontalOffset(
                currentOffset: 220,
                programmeOffset: 0
            ),
            0
        )
    }

    func testVisibleProgrammeDoesNotTriggerFocusCorrection() {
        XCTAssertNil(
            GuideGridChromeLayout.correctedHorizontalOffset(
                currentOffset: 700,
                programmeOffset: 900
            )
        )
    }

    func testTimelineMarkWhoseAnchorIsBehindChannelColumnIsHidden() {
        XCTAssertFalse(
            GuideGridChromeLayout.isTimelineMarkVisible(
                markOffset: 720,
                contentOffset: 780
            )
        )
        XCTAssertTrue(
            GuideGridChromeLayout.isTimelineMarkVisible(
                markOffset: 900,
                contentOffset: 780
            )
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
}
