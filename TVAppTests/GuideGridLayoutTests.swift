import CoreGraphics
import XCTest
@testable import TVApp

final class GuideGridLayoutTests: XCTestCase {
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
}
