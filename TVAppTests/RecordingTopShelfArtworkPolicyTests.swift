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
#endif
