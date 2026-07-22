import Foundation
import XCTest
@testable import TVApp

final class CommercialDetectionTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 100_000)

    func testCommercialIsPublishedOnlyAfterConfirmationAndBackdated() {
        var detector = learnedDetector()

        for second in 60..<75 {
            XCTAssertTrue(detector.consume(frame(logoVisible: false), at: date(second)).isEmpty)
        }

        let breaks = detector.consume(frame(logoVisible: false), at: date(75))
        XCTAssertEqual(breaks.count, 1)
        XCTAssertEqual(breaks[0].start, date(60))
        XCTAssertEqual(breaks[0].end, date(75))
        XCTAssertGreaterThanOrEqual(breaks[0].confidence, 0.65)
    }

    func testLogoReturnClosesCommercialAtFirstReturnedFrame() {
        var detector = learnedDetector()
        for second in 60...75 {
            _ = detector.consume(frame(logoVisible: false), at: date(second))
        }

        _ = detector.consume(frame(logoVisible: true), at: date(76))
        _ = detector.consume(frame(logoVisible: true), at: date(77))
        let breaks = detector.consume(frame(logoVisible: true), at: date(78))

        XCTAssertEqual(breaks.count, 1)
        XCTAssertEqual(breaks[0].end, date(76))
    }

    func testShortLogoAbsenceDoesNotCreateMarker() {
        var detector = learnedDetector()
        for second in 60..<74 {
            _ = detector.consume(frame(logoVisible: false), at: date(second))
        }
        let breaks = detector.consume(frame(logoVisible: true), at: date(74))

        XCTAssertTrue(breaks.isEmpty)
    }

    func testTimestampDiscontinuityPreservesLearnedLogo() {
        var detector = learnedDetector()
        XCTAssertTrue(detector.hasLearnedLogo)

        _ = detector.consume(frame(logoVisible: true), at: date(100))

        XCTAssertTrue(detector.hasLearnedLogo)
    }

    func testLearnedLogoModelCanBeRestoredForLaterTune() {
        let original = learnedDetector()
        let restored = CommercialBreakDetector(logoModel: original.learnedLogoModel)

        XCTAssertNotNil(original.learnedLogoModel)
        XCTAssertTrue(restored.hasLearnedLogo)
    }

    func testPruningDropsMarkersBeforeBufferStart() {
        var detector = learnedDetector()
        for second in 60...75 {
            _ = detector.consume(frame(logoVisible: false), at: date(second))
        }
        XCTAssertEqual(detector.breaks.count, 1)

        XCTAssertTrue(detector.prune(before: date(76)).isEmpty)
    }

    private func learnedDetector() -> CommercialBreakDetector {
        var detector = CommercialBreakDetector()
        for second in 0..<CommercialBreakDetector.logoLearningSampleCount {
            _ = detector.consume(frame(logoVisible: true), at: date(second))
        }
        XCTAssertTrue(detector.hasLearnedLogo)
        return detector
    }

    private func date(_ seconds: Int) -> Date {
        start.addingTimeInterval(TimeInterval(seconds))
    }

    private func frame(logoVisible: Bool) -> CommercialFrameFeatures {
        let edgeCount = CommercialFrameFeatures.cornerWidth
            * CommercialFrameFeatures.cornerHeight
        var leftEdges = [UInt8](repeating: 0, count: edgeCount)
        if logoVisible {
            for index in 20..<50 { leftEdges[index] = 1 }
        }
        return CommercialFrameFeatures(
            pixels: [UInt8](repeating: 100, count: CommercialFrameFeatures.width
                * CommercialFrameFeatures.height),
            meanLuma: 100,
            darkPixelFraction: 0,
            cornerEdges: [leftEdges, [UInt8](repeating: 0, count: edgeCount)]
        )
    }
}
