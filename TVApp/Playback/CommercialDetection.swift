import Combine
import CoreGraphics
import Foundation
import ImageIO
import OSLog
@preconcurrency import VLCKit

struct CommercialBreak: Identifiable, Equatable, Sendable {
    let id: UUID
    let start: Date
    var end: Date
    var confidence: Double

    init(
        id: UUID = UUID(),
        start: Date,
        end: Date,
        confidence: Double
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    func contains(_ date: Date) -> Bool {
        start <= date && date < end
    }
}

struct CommercialFrameFeatures: Equatable, Sendable {
    static let width = 160
    static let height = 90
    static let cornerWidth = 40
    static let cornerHeight = 18

    let pixels: [UInt8]
    let meanLuma: Double
    let darkPixelFraction: Double
    let cornerEdges: [[UInt8]]

    var isDark: Bool { meanLuma < 20 || darkPixelFraction > 0.90 }
}

struct CommercialLogoModel: Equatable, Sendable {
    let corner: Int
    let edgeMask: [UInt8]
}

struct CommercialDetectionDiagnostics: Equatable, Sendable {
    static let inactive = CommercialDetectionDiagnostics(
        isActive: false,
        phase: "Inactive",
        learningProgress: 0,
        sampledAt: nil,
        sampledPixels: [],
        logoCorner: nil,
        logoMask: [],
        logoSimilarity: nil,
        logoIsPresent: nil
    )

    let isActive: Bool
    let phase: String
    let learningProgress: Double
    let sampledAt: Date?
    let sampledPixels: [UInt8]
    let logoCorner: Int?
    let logoMask: [UInt8]
    let logoSimilarity: Double?
    let logoIsPresent: Bool?
}

enum CommercialFrameFeatureExtractor {
    static func extract(from url: URL) -> CommercialFrameFeatures? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let width = CommercialFrameFeatures.width
        let height = CommercialFrameFeatures.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        let total = pixels.reduce(into: 0) { $0 += Int($1) }
        let darkCount = pixels.reduce(into: 0) { count, pixel in
            if pixel < 30 { count += 1 }
        }
        return CommercialFrameFeatures(
            pixels: pixels,
            meanLuma: Double(total) / Double(pixels.count),
            darkPixelFraction: Double(darkCount) / Double(pixels.count),
            cornerEdges: [
                cornerEdgeMask(pixels, startsAtX: 0),
                cornerEdgeMask(
                    pixels,
                    startsAtX: width - CommercialFrameFeatures.cornerWidth
                )
            ]
        )
    }

    private static func cornerEdgeMask(
        _ pixels: [UInt8],
        startsAtX originX: Int
    ) -> [UInt8] {
        let sourceWidth = CommercialFrameFeatures.width
        let width = CommercialFrameFeatures.cornerWidth
        let height = CommercialFrameFeatures.cornerHeight
        var mask = [UInt8](repeating: 0, count: width * height)
        guard width > 2, height > 2 else { return mask }

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let sourceX = originX + x
                let horizontal = abs(
                    Int(pixels[y * sourceWidth + sourceX + 1])
                        - Int(pixels[y * sourceWidth + sourceX - 1])
                )
                let vertical = abs(
                    Int(pixels[(y + 1) * sourceWidth + sourceX])
                        - Int(pixels[(y - 1) * sourceWidth + sourceX])
                )
                if horizontal + vertical >= 52 { mask[y * width + x] = 1 }
            }
        }
        return mask
    }
}

struct CommercialBreakDetector: Sendable {
    static let logoLearningSampleCount = 60
    static let commercialConfirmationDuration: TimeInterval = 15
    static let logoReturnDuration: TimeInterval = 2
    static let maximumCommercialDuration: TimeInterval = 600
    static let mergeGap: TimeInterval = 5
    static let discontinuityTolerance: TimeInterval = 5
    static let logoSimilarityThreshold = 0.62

    private enum State: Sendable {
        case programme
        case candidate(start: Date)
        case commercial(id: UUID, start: Date, returningSince: Date?)
    }

    private(set) var breaks: [CommercialBreak] = []
    private var state: State = .programme
    private var learningCounts = [
        [Int](repeating: 0, count: CommercialFrameFeatures.cornerWidth
            * CommercialFrameFeatures.cornerHeight),
        [Int](repeating: 0, count: CommercialFrameFeatures.cornerWidth
            * CommercialFrameFeatures.cornerHeight)
    ]
    private var learningSamples = 0
    private var logoCorner: Int?
    private var logoMask: [UInt8] = []
    private var lastTimestamp: Date?
    private var lastLogoSimilarity: Double?

    var hasLearnedLogo: Bool { logoCorner != nil && !logoMask.isEmpty }
    var learnedLogoModel: CommercialLogoModel? {
        guard let logoCorner, !logoMask.isEmpty else { return nil }
        return CommercialLogoModel(corner: logoCorner, edgeMask: logoMask)
    }

    var diagnosticsPhase: String {
        guard hasLearnedLogo else { return "Learning" }
        switch state {
        case .programme: return "Programme"
        case .candidate: return "Possible commercial"
        case .commercial: return "Commercial"
        }
    }

    var learningProgress: Double {
        hasLearnedLogo
            ? 1
            : min(1, Double(learningSamples) / Double(Self.logoLearningSampleCount))
    }

    init(logoModel: CommercialLogoModel? = nil) {
        logoCorner = logoModel?.corner
        logoMask = logoModel?.edgeMask ?? []
    }

    mutating func consume(
        _ features: CommercialFrameFeatures,
        at timestamp: Date
    ) -> [CommercialBreak] {
        if let lastTimestamp {
            let elapsed = timestamp.timeIntervalSince(lastTimestamp)
            if elapsed <= 0 || elapsed > Self.discontinuityTolerance {
                resetTemporalState()
            }
        }
        lastTimestamp = timestamp

        guard hasLearnedLogo else {
            lastLogoSimilarity = nil
            learn(from: features)
            return breaks
        }

        let similarity = logoSimilarity(in: features)
        lastLogoSimilarity = similarity
        let logoIsPresent = similarity >= Self.logoSimilarityThreshold
        switch state {
        case .programme:
            if !logoIsPresent, !features.isDark {
                state = .candidate(start: timestamp)
            }

        case let .candidate(start):
            if logoIsPresent {
                state = .programme
            } else if timestamp.timeIntervalSince(start)
                        >= Self.commercialConfirmationDuration {
                let id: UUID
                if let previous = breaks.last,
                   start.timeIntervalSince(previous.end) <= Self.mergeGap {
                    id = previous.id
                    breaks[breaks.count - 1].end = timestamp
                    breaks[breaks.count - 1].confidence = max(
                        previous.confidence,
                        confidence(for: similarity, features: features)
                    )
                } else {
                    id = UUID()
                    breaks.append(CommercialBreak(
                        id: id,
                        start: start,
                        end: timestamp,
                        confidence: confidence(for: similarity, features: features)
                    ))
                }
                state = .commercial(id: id, start: start, returningSince: nil)
            }

        case let .commercial(id, start, returningSince):
            if timestamp.timeIntervalSince(start) > Self.maximumCommercialDuration {
                state = .programme
                return breaks
            }
            guard let index = breaks.lastIndex(where: { $0.id == id }) else {
                state = .programme
                return breaks
            }
            if logoIsPresent {
                let returning = returningSince ?? timestamp
                if timestamp.timeIntervalSince(returning) >= Self.logoReturnDuration {
                    breaks[index].end = returning
                    state = .programme
                } else {
                    state = .commercial(id: id, start: start, returningSince: returning)
                }
            } else {
                breaks[index].end = timestamp
                breaks[index].confidence = max(
                    breaks[index].confidence,
                    confidence(for: similarity, features: features)
                )
                state = .commercial(id: id, start: start, returningSince: nil)
            }
        }
        return breaks
    }

    mutating func prune(before date: Date) -> [CommercialBreak] {
        breaks.removeAll { $0.end < date }
        return breaks
    }

    mutating func reset() {
        breaks.removeAll()
        resetModel(preservingBreaks: true)
    }

    func diagnostics(
        for features: CommercialFrameFeatures,
        sampledAt: Date
    ) -> CommercialDetectionDiagnostics {
        CommercialDetectionDiagnostics(
            isActive: true,
            phase: diagnosticsPhase,
            learningProgress: learningProgress,
            sampledAt: sampledAt,
            sampledPixels: features.pixels,
            logoCorner: logoCorner,
            logoMask: logoMask,
            logoSimilarity: lastLogoSimilarity,
            logoIsPresent: lastLogoSimilarity.map {
                $0 >= Self.logoSimilarityThreshold
            }
        )
    }

    private mutating func resetTemporalState() {
        state = .programme
        lastTimestamp = nil
    }

    private mutating func learn(from features: CommercialFrameFeatures) {
        guard features.cornerEdges.count == learningCounts.count else { return }
        for corner in learningCounts.indices {
            for index in learningCounts[corner].indices
                where features.cornerEdges[corner][index] != 0 {
                learningCounts[corner][index] += 1
            }
        }
        learningSamples += 1
        guard learningSamples >= Self.logoLearningSampleCount else { return }

        let required = Int(Double(learningSamples) * 0.78)
        let candidates = learningCounts.enumerated().map { corner, counts in
            let mask = counts.map { $0 >= required ? UInt8(1) : UInt8(0) }
            return (corner: corner, mask: mask, edges: mask.reduce(0) { $0 + Int($1) })
        }
        guard let best = candidates
            .filter({ (8...220).contains($0.edges) })
            .max(by: { $0.edges < $1.edges })
        else {
            // Try another learning window rather than treating arbitrary
            // static imagery as a channel logo.
            learningCounts = learningCounts.map { _ in
                [Int](repeating: 0, count: CommercialFrameFeatures.cornerWidth
                    * CommercialFrameFeatures.cornerHeight)
            }
            learningSamples = 0
            return
        }
        logoCorner = best.corner
        logoMask = best.mask
    }

    private func logoSimilarity(in features: CommercialFrameFeatures) -> Double {
        guard let logoCorner,
              features.cornerEdges.indices.contains(logoCorner),
              features.cornerEdges[logoCorner].count == logoMask.count
        else { return 1 }
        var referenceCount = 0
        var intersection = 0
        for index in logoMask.indices where logoMask[index] != 0 {
            referenceCount += 1
            if features.cornerEdges[logoCorner][index] != 0 { intersection += 1 }
        }
        guard referenceCount > 0 else { return 1 }
        return Double(intersection) / Double(referenceCount)
    }

    private func confidence(
        for similarity: Double,
        features: CommercialFrameFeatures
    ) -> Double {
        min(0.98, max(0.65, 0.72 + (0.62 - similarity) * 0.35
            + (features.isDark ? 0.08 : 0)))
    }

    private mutating func resetModel(preservingBreaks: Bool) {
        if !preservingBreaks { breaks.removeAll() }
        state = .programme
        learningCounts = learningCounts.map { _ in
            [Int](repeating: 0, count: CommercialFrameFeatures.cornerWidth
                * CommercialFrameFeatures.cornerHeight)
        }
        learningSamples = 0
        logoCorner = nil
        logoMask.removeAll()
        lastTimestamp = nil
        lastLogoSimilarity = nil
    }
}

@MainActor
final class CommercialLiveAnalyzer: NSObject, ObservableObject,
    @preconcurrency VLCMediaPlayerDelegate {
    static let snapshotInterval: Duration = .seconds(1)
    static let snapshotWidth: Int32 = 160
    static let snapshotHeight: Int32 = 90

    @Published private(set) var breaks: [CommercialBreak] = []
    @Published private(set) var diagnostics = CommercialDetectionDiagnostics.inactive
    let mediaPlayer: VLCMediaPlayer
    var breaksChanged: (([CommercialBreak]) -> Void)?

    private let logger = Logger(
        subsystem: "de.beutner.TVPlayer",
        category: "CommercialDetection"
    )
    private var detector = CommercialBreakDetector()
    private var logoModelsByChannel: [String: CommercialLogoModel] = [:]
    private var captureTask: Task<Void, Never>?
    private var pendingSnapshot: (url: URL, timestamp: Date, requestedAt: Date)?
    private(set) var channelID: String?

    override init() {
        let library = VLCLibrary(options: [
            "--quiet",
            "--no-snapshot-preview",
            "--no-audio"
        ])
        mediaPlayer = VLCMediaPlayer(library: library)
        super.init()
        mediaPlayer.delegate = self
        enforceSilence()
    }

    func start(channelID: String, url: URL) {
        stop(resetMarkers: self.channelID != channelID)
        if self.channelID != channelID {
            detector = CommercialBreakDetector(logoModel: logoModelsByChannel[channelID])
            publish(detector.breaks)
        }
        self.channelID = channelID
        diagnostics = CommercialDetectionDiagnostics(
            isActive: true,
            phase: detector.diagnosticsPhase,
            learningProgress: detector.learningProgress,
            sampledAt: nil,
            sampledPixels: [],
            logoCorner: detector.learnedLogoModel?.corner,
            logoMask: detector.learnedLogoModel?.edgeMask ?? [],
            logoSimilarity: nil,
            logoIsPresent: nil
        )
        guard let media = VLCMedia(url: url) else { return }
        media.addOption(":no-audio")
        media.addOption(":network-caching=300")
        media.addOption(":live-caching=300")
        mediaPlayer.media = media
        enforceSilence()
        mediaPlayer.play()
        enforceSilence()
        captureTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.snapshotInterval)
                guard !Task.isCancelled else { return }
                self?.captureSnapshot()
            }
        }
    }

    func stop(resetMarkers: Bool) {
        captureTask?.cancel()
        captureTask = nil
        clearPendingSnapshot()
        mediaPlayer.stop()
        mediaPlayer.media = nil
        diagnostics = .inactive
        if resetMarkers {
            cacheLearnedLogo()
            channelID = nil
            detector.reset()
            publish(detector.breaks)
        }
    }

    func prune(before date: Date) {
        publish(detector.prune(before: date))
    }

    func mediaPlayerSnapshot(_ notification: Notification) {
        guard let pendingSnapshot else { return }
        self.pendingSnapshot = nil
        let url = pendingSnapshot.url
        let timestamp = pendingSnapshot.timestamp
        Task { @MainActor [weak self] in
            let features = await Task.detached(priority: .utility) {
                defer { try? FileManager.default.removeItem(at: url) }
                return CommercialFrameFeatureExtractor.extract(from: url)
            }.value
            guard let self, let features else { return }
            publish(detector.consume(features, at: timestamp))
            diagnostics = detector.diagnostics(for: features, sampledAt: timestamp)
            cacheLearnedLogo()
        }
    }

    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak self] in
            self?.enforceSilence()
        }
    }

    private func captureSnapshot() {
        guard channelID != nil, mediaPlayer.isPlaying else { return }
        if let pendingSnapshot {
            guard Date().timeIntervalSince(pendingSnapshot.requestedAt) > 4 else { return }
            clearPendingSnapshot()
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "tvplayer-commercial-frame-\(UUID().uuidString)")
            .appendingPathExtension("png")
        pendingSnapshot = (
            url: url,
            timestamp: Date().addingTimeInterval(-0.3),
            requestedAt: Date()
        )
        mediaPlayer.saveVideoSnapshot(
            at: url.path,
            withWidth: Self.snapshotWidth,
            andHeight: Self.snapshotHeight
        )
    }

    private func clearPendingSnapshot() {
        guard let pendingSnapshot else { return }
        try? FileManager.default.removeItem(at: pendingSnapshot.url)
        self.pendingSnapshot = nil
    }

    private func publish(_ updatedBreaks: [CommercialBreak]) {
        guard breaks != updatedBreaks else { return }
        breaks = updatedBreaks
        breaksChanged?(updatedBreaks)
        logger.debug("Published \(updatedBreaks.count, privacy: .public) commercial ranges")
    }

    private func enforceSilence() {
        mediaPlayer.audio?.volume = 0
        mediaPlayer.audio?.isMuted = true
    }

    private func cacheLearnedLogo() {
        guard let channelID, let model = detector.learnedLogoModel else { return }
        logoModelsByChannel[channelID] = model
    }
}
