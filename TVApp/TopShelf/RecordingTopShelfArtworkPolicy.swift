#if os(tvOS)
import Foundation

enum RecordingTopShelfLogoPlateStyle: Equatable {
    case light
    case dark

    static func forContentLuminance(_ luminance: CGFloat) -> Self {
        luminance >= 0.55 ? .dark : .light
    }
}

enum RecordingTopShelfThumbnailSeekTarget: Equatable {
    case position(Float)
    case time(milliseconds: Int32)
}

struct RecordingThumbnailWorkQueue<Element> {
    private var keys: [String] = []
    private var values: [String: Element] = [:]

    var isEmpty: Bool { keys.isEmpty }

    mutating func enqueue(_ element: Element, forKey key: String) {
        if values.updateValue(element, forKey: key) == nil {
            keys.append(key)
        }
    }

    mutating func popFirst() -> Element? {
        guard !keys.isEmpty else { return nil }
        return values.removeValue(forKey: keys.removeFirst())
    }
}

enum RecordingTopShelfArtworkPolicy {
    static func selectedFilename(
        guideArtwork: String?,
        cachedFrame: String?,
        channelLogo: String? = nil,
        fallback: String?
    ) -> String? {
        // The channel logo belongs inside the composed fallback artwork; a
        // raw logo is not a suitable 16:9 Top Shelf hero image.
        guideArtwork ?? cachedFrame ?? fallback
    }

    static func frameCacheIdentifier(
        recordingID: String,
        state: TVRecordingState,
        channelLogoIdentifier: String? = nil
    ) -> String {
        let variant = state == .recording ? "growing" : "completed"
        return [
            "recording-frame-v4",
            recordingID,
            variant,
            channelLogoIdentifier ?? "no-logo",
        ].joined(separator: "-")
    }

    static func referencedFilenames(
        selected: String?,
        channelLogo: String?
    ) -> Set<String> {
        Set([selected, channelLogo].compactMap { $0 })
    }

    static func snapshotPosition(for state: TVRecordingState) -> Float {
        state == .recording ? 0.05 : 0.20
    }

    static func thumbnailSeekTarget(
        for recording: TVRecording,
        now: Date
    ) -> RecordingTopShelfThumbnailSeekTarget {
        guard recording.state == .recording else {
            return .position(snapshotPosition(for: recording.state))
        }

        let elapsed = max(0, now.timeIntervalSince(recording.start))
        let distanceFromGrowingEdge = min(30, max(2, elapsed * 0.20))
        let targetSeconds = max(0, elapsed - distanceFromGrowingEdge)
        let milliseconds = min(
            Double(Int32.max),
            targetSeconds * 1_000
        )
        return .time(milliseconds: Int32(milliseconds))
    }
}

struct RecordingThumbnailOverlay: Equatable, Sendable {
    let title: String
    let detail: String?
    let channelName: String
    let badge: String
}

enum RecordingThumbnailOverlayPolicy {
    static func overlay(
        for recording: TVRecording,
        matchingProgram: GuideProgram?
    ) -> RecordingThumbnailOverlay {
        var detailParts: [String] = []
        if let episode = matchingProgram?.metadata.episodeDisplayDescription {
            detailParts.append(episode)
        }
        if let subtitle = nonEmpty(recording.subtitle ?? matchingProgram?.subtitle),
           !detailParts.contains(subtitle) {
            detailParts.append(subtitle)
        }
        return RecordingThumbnailOverlay(
            title: recording.title,
            detail: detailParts.isEmpty ? nil : detailParts.joined(separator: " · "),
            channelName: recording.channelName,
            badge: recording.state.label.uppercased()
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
