import CoreGraphics
import XCTest
@testable import TVApp

final class GuideGridLayoutTests: XCTestCase {
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
