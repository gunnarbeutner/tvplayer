#if os(tvOS)
import Foundation

enum RecordingTopShelfArtworkPolicy {
    static func selectedFilename(
        guideArtwork: String?,
        cachedFrame: String?,
        fallback: String?
    ) -> String? {
        guideArtwork ?? cachedFrame ?? fallback
    }

    static func frameCacheIdentifier(
        recordingID: String,
        state: TVRecordingState
    ) -> String {
        let variant = state == .recording ? "growing" : "completed"
        return "recording-frame-v1-\(recordingID)-\(variant)"
    }

    static func snapshotPosition(for state: TVRecordingState) -> Float {
        state == .recording ? 0.05 : 0.20
    }
}
#endif
