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
    static let width = 320
    static let height = 180
    static let cornerWidth = 80
    static let cornerHeight = 36

    let pixels: [UInt8]
    let meanLuma: Double
    let darkPixelFraction: Double
    let cornerEdges: [[UInt8]]
    let perimeterEdges: [UInt8]
    let perimeterMatchingEdges: [UInt8]

    init(
        pixels: [UInt8],
        meanLuma: Double,
        darkPixelFraction: Double,
        cornerEdges: [[UInt8]],
        perimeterEdges: [UInt8]? = nil,
        perimeterMatchingEdges: [UInt8]? = nil
    ) {
        self.pixels = pixels
        self.meanLuma = meanLuma
        self.darkPixelFraction = darkPixelFraction
        self.cornerEdges = cornerEdges
        if let perimeterEdges {
            self.perimeterEdges = perimeterEdges
        } else {
            self.perimeterEdges = Self.perimeterMask(from: cornerEdges)
        }
        self.perimeterMatchingEdges = perimeterMatchingEdges ?? self.perimeterEdges
    }

    var isDark: Bool { meanLuma < 20 || darkPixelFraction > 0.90 }

    private static func perimeterMask(from corners: [[UInt8]]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height)
        for corner in corners.indices.prefix(2) {
            guard corners[corner].count == cornerWidth * cornerHeight else { continue }
            let originX = corner == 0 ? 0 : width - cornerWidth
            for y in 0..<cornerHeight {
                for x in 0..<cornerWidth {
                    result[y * width + originX + x] = corners[corner][y * cornerWidth + x]
                }
            }
        }
        return result
    }
}

struct CommercialLogoBounds: Codable, Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

enum CommercialLogoRole: String, Codable, Equatable, Sendable {
    case channelIdentity
    case auxiliary
    case untrusted
}

struct CommercialLogoCandidateModel: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var bounds: CommercialLogoBounds
    var edgeMask: [UInt8]
    var role: CommercialLogoRole
    var observedSeconds: Int
    var sceneCount: Int
    var programmeIDs: Set<String>
    var lastSeenAt: Date?
}

struct CommercialLogoModel: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version = currentVersion
    var candidates: [CommercialLogoCandidateModel]
    var savedAt = Date()

    init(candidates: [CommercialLogoCandidateModel]) {
        self.candidates = candidates
    }

    // Compatibility with the original corner model and deterministic tests.
    init(corner: Int, edgeMask: [UInt8]) {
        let bounds = CommercialLogoBounds(
            x: corner == 0 ? 0 : CommercialFrameFeatures.width - CommercialFrameFeatures.cornerWidth,
            y: 0,
            width: CommercialFrameFeatures.cornerWidth,
            height: CommercialFrameFeatures.cornerHeight
        )
        candidates = [CommercialLogoCandidateModel(
            id: UUID(),
            bounds: bounds,
            edgeMask: edgeMask,
            role: .channelIdentity,
            observedSeconds: 300,
            sceneCount: 10,
            programmeIDs: ["legacy"],
            lastSeenAt: nil
        )]
    }

    var trustedCandidates: [CommercialLogoCandidateModel] {
        candidates.filter { $0.role == .channelIdentity }
    }

    var corner: Int {
        guard let first = trustedCandidates.first ?? candidates.first else { return 0 }
        return first.bounds.x < CommercialFrameFeatures.width / 2 ? 0 : 1
    }

    var edgeMask: [UInt8] {
        (trustedCandidates.first ?? candidates.first)?.edgeMask ?? []
    }
}

struct CommercialLogoDiagnostic: Equatable, Identifiable, Sendable {
    let id: UUID
    let bounds: CommercialLogoBounds
    let edgeMask: [UInt8]
    let role: CommercialLogoRole
    let similarity: Double?
    let isPresent: Bool?
}

struct CommercialArtworkFingerprint: Equatable, Sendable {
    static let size = 32
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
        logoIsPresent: nil,
        candidates: [],
        abstentionReason: "No analyser is active"
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
    let candidates: [CommercialLogoDiagnostic]
    let abstentionReason: String?
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
            ],
            // Learning remains conservative so transient texture does not
            // become a logo candidate. Matching also gets a permissive map:
            // translucent white station bugs can fall below the strong edge
            // threshold whenever the picture behind them is bright.
            perimeterEdges: perimeterEdgeMask(pixels, threshold: 52),
            perimeterMatchingEdges: perimeterEdgeMask(pixels, threshold: 20)
        )
    }

    static func artworkFingerprint(from data: Data) -> CommercialArtworkFingerprint? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let size = CommercialArtworkFingerprint.size
        var pixels = [UInt8](repeating: 0, count: size * size)
        let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard rendered else { return nil }
        var edges = [UInt8](repeating: 0, count: pixels.count)
        for y in 1..<(size - 1) {
            for x in 1..<(size - 1) {
                let horizontal = abs(Int(pixels[y * size + x + 1]) - Int(pixels[y * size + x - 1]))
                let vertical = abs(Int(pixels[(y + 1) * size + x]) - Int(pixels[(y - 1) * size + x]))
                if horizontal + vertical >= 40 { edges[y * size + x] = 1 }
            }
        }
        guard edges.contains(1) else { return nil }
        return CommercialArtworkFingerprint(edgeMask: edges)
    }

    private static func perimeterEdgeMask(
        _ pixels: [UInt8],
        threshold: Int
    ) -> [UInt8] {
        let width = CommercialFrameFeatures.width
        let height = CommercialFrameFeatures.height
        let horizontalBand = max(1, Int(Double(height) * 0.20))
        let verticalBand = max(1, Int(Double(width) * 0.20))
        var mask = [UInt8](repeating: 0, count: width * height)

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                guard y < horizontalBand || y >= height - horizontalBand
                        || x < verticalBand || x >= width - verticalBand
                else { continue }
                let horizontal = abs(
                    Int(pixels[y * width + x + 1]) - Int(pixels[y * width + x - 1])
                )
                let vertical = abs(
                    Int(pixels[(y + 1) * width + x]) - Int(pixels[(y - 1) * width + x])
                )
                if horizontal + vertical >= threshold { mask[y * width + x] = 1 }
            }
        }
        return mask
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

struct CommercialObservationContext: Equatable, Sendable {
    let programmeID: String?

    static let unknown = CommercialObservationContext(programmeID: nil)
}

struct CommercialBreakDetector: Sendable {
    static let logoLearningSampleCount = 90
    static let requiredSceneChanges = 8
    static let commercialConfirmationDuration: TimeInterval = 15
    static let logoReturnDuration: TimeInterval = 2
    static let maximumCommercialDuration: TimeInterval = 600
    static let mergeGap: TimeInterval = 5
    static let discontinuityTolerance: TimeInterval = 5
    static let logoPresentThreshold = 0.72
    static let logoAbsentThreshold = 0.48

    private enum State: Sendable {
        case programme
        case candidate(start: Date)
        case commercial(id: UUID, start: Date, returningSince: Date?)
    }

    private(set) var breaks: [CommercialBreak] = []
    private var state: State = .programme
    private var learningCounts = [Int](
        repeating: 0,
        count: CommercialFrameFeatures.width * CommercialFrameFeatures.height
    )
    private var learningSamples = 0
    private var sceneChanges = 0
    private var previousPixels: [UInt8]?
    private var candidates: [CommercialLogoCandidateModel] = []
    private var lastTimestamp: Date?
    private var lastMatches: [UUID: Double] = [:]
    private var lastPresence: [UUID: Bool?] = [:]
    private var artworkFingerprint: CommercialArtworkFingerprint?

    var hasLearnedLogo: Bool { candidates.contains { $0.role == .channelIdentity } }
    var learnedLogoModel: CommercialLogoModel? {
        guard !candidates.isEmpty else { return nil }
        return CommercialLogoModel(candidates: candidates)
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
        if hasLearnedLogo { return 1 }
        let samples = Double(learningSamples) / Double(Self.logoLearningSampleCount)
        let scenes = Double(sceneChanges) / Double(Self.requiredSceneChanges)
        return min(1, min(samples, scenes))
    }

    init(logoModel: CommercialLogoModel? = nil) {
        if logoModel?.version == CommercialLogoModel.currentVersion {
            candidates = logoModel?.candidates ?? []
        }
    }

    mutating func setArtworkFingerprint(_ fingerprint: CommercialArtworkFingerprint?) {
        artworkFingerprint = fingerprint
        promoteArtworkMatchIfUnambiguous()
    }

    mutating func consume(
        _ features: CommercialFrameFeatures,
        at timestamp: Date,
        context: CommercialObservationContext = .unknown
    ) -> [CommercialBreak] {
        if let lastTimestamp {
            let elapsed = timestamp.timeIntervalSince(lastTimestamp)
            if elapsed <= 0 || elapsed > Self.discontinuityTolerance {
                resetTemporalState()
            }
        }
        lastTimestamp = timestamp

        guard !features.isDark else {
            if case .candidate = state { state = .programme }
            return breaks
        }

        if candidates.isEmpty {
            learn(from: features, at: timestamp)
            return breaks
        }

        observeCandidates(in: features, at: timestamp, context: context)
        let trusted = candidates.filter { $0.role == .channelIdentity }
        guard !trusted.isEmpty else {
            resetTemporalState()
            return breaks
        }

        let trustedStates = trusted.map { lastPresence[$0.id] ?? nil }
        let logoIsPresent: Bool?
        if trustedStates.contains(where: { $0 == true }) {
            logoIsPresent = true
        } else if trustedStates.allSatisfy({ $0 == false }) {
            logoIsPresent = false
        } else {
            logoIsPresent = nil
        }
        guard let logoIsPresent else {
            if case .candidate = state { state = .programme }
            return breaks
        }
        let similarity = trusted.compactMap { lastMatches[$0.id] }.max() ?? 0
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
        let trusted = candidates.filter { $0.role == .channelIdentity }
        let best = trusted.max { (lastMatches[$0.id] ?? 0) < (lastMatches[$1.id] ?? 0) }
            ?? candidates.first
        let candidateDiagnostics = candidates.map { candidate in
            CommercialLogoDiagnostic(
                id: candidate.id,
                bounds: candidate.bounds,
                edgeMask: candidate.edgeMask,
                role: candidate.role,
                similarity: lastMatches[candidate.id],
                isPresent: lastPresence[candidate.id] ?? nil
            )
        }
        let abstentionReason: String?
        if candidates.isEmpty {
            abstentionReason = "Learning persistent perimeter graphics"
        } else if trusted.isEmpty {
            abstentionReason = candidates.count > 1
                ? "Logo identity is ambiguous"
                : "Waiting for programme-spanning evidence"
        } else {
            abstentionReason = nil
        }
        return CommercialDetectionDiagnostics(
            isActive: true,
            phase: diagnosticsPhase,
            learningProgress: learningProgress,
            sampledAt: sampledAt,
            sampledPixels: features.pixels,
            logoCorner: best.map { $0.bounds.x < CommercialFrameFeatures.width / 2 ? 0 : 1 },
            logoMask: best?.edgeMask ?? [],
            logoSimilarity: best.flatMap { lastMatches[$0.id] },
            logoIsPresent: best.flatMap { lastPresence[$0.id] ?? nil },
            candidates: candidateDiagnostics,
            abstentionReason: abstentionReason
        )
    }

    private mutating func resetTemporalState() {
        state = .programme
        lastTimestamp = nil
    }

    private mutating func learn(from features: CommercialFrameFeatures, at timestamp: Date) {
        guard features.perimeterEdges.count == learningCounts.count else { return }
        registerSceneChange(features.pixels)
        for index in learningCounts.indices where features.perimeterEdges[index] != 0 {
            learningCounts[index] += 1
        }
        learningSamples += 1
        guard learningSamples >= Self.logoLearningSampleCount,
              sceneChanges >= Self.requiredSceneChanges
        else { return }

        let required = Int(ceil(Double(learningSamples) * 0.65))
        let stable = learningCounts.map { $0 >= required ? UInt8(1) : UInt8(0) }
        let discovered = Self.connectedCandidates(in: stable, at: timestamp)
        guard !discovered.isEmpty else {
            learningCounts = [Int](repeating: 0, count: learningCounts.count)
            learningSamples = 0
            sceneChanges = 0
            return
        }
        candidates = discovered
        lastMatches.removeAll()
        lastPresence.removeAll()
    }

    private mutating func observeCandidates(
        in features: CommercialFrameFeatures,
        at timestamp: Date,
        context: CommercialObservationContext
    ) {
        registerSceneChange(features.pixels)
        for index in candidates.indices {
            let score = Self.match(candidates[index], in: features.perimeterMatchingEdges)
            lastMatches[candidates[index].id] = score
            let presence: Bool?
            if score >= Self.logoPresentThreshold {
                presence = true
                candidates[index].observedSeconds += 1
                candidates[index].sceneCount = max(candidates[index].sceneCount, sceneChanges)
                if let programmeID = context.programmeID {
                    candidates[index].programmeIDs.insert(programmeID)
                }
                candidates[index].lastSeenAt = timestamp
            } else if score <= Self.logoAbsentThreshold {
                presence = false
            } else {
                presence = nil
            }
            lastPresence[candidates[index].id] = presence
        }

        let eligible = candidates.indices.filter {
            candidates[$0].observedSeconds >= 300
                && candidates[$0].sceneCount >= 10
                && candidates[$0].programmeIDs.count >= 2
        }
        promoteArtworkMatchIfUnambiguous()
        if candidates.filter({ $0.role == .channelIdentity }).isEmpty,
           eligible.count == 1,
           let index = eligible.first {
            candidates[index].role = .channelIdentity
            for other in candidates.indices where other != index {
                candidates[other].role = .auxiliary
            }
        }
    }

    private mutating func promoteArtworkMatchIfUnambiguous() {
        guard candidates.allSatisfy({ $0.role != .channelIdentity }),
              let artworkFingerprint
        else { return }
        let scores = candidates.indices.map {
            (index: $0, score: Self.artworkSimilarity(candidates[$0], artworkFingerprint))
        }.sorted { $0.score > $1.score }
        guard let best = scores.first, best.score >= 0.75,
              scores.dropFirst().first.map({ best.score - $0.score >= 0.10 }) ?? true
        else { return }
        candidates[best.index].role = .channelIdentity
        for index in candidates.indices where index != best.index {
            candidates[index].role = .auxiliary
        }
    }

    private static func artworkSimilarity(
        _ candidate: CommercialLogoCandidateModel,
        _ fingerprint: CommercialArtworkFingerprint
    ) -> Double {
        let size = CommercialArtworkFingerprint.size
        guard candidate.bounds.width > 0, candidate.bounds.height > 0 else { return 0 }
        var normalized = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let sourceX = min(candidate.bounds.width - 1, x * candidate.bounds.width / size)
                let sourceY = min(candidate.bounds.height - 1, y * candidate.bounds.height / size)
                normalized[y * size + x] = candidate.edgeMask[
                    sourceY * candidate.bounds.width + sourceX
                ] == 0 ? 0 : 1
            }
        }
        var best = 0.0
        for offsetY in -2...2 {
            for offsetX in -2...2 {
                var lhs = 0
                var rhs = 0
                var intersection = 0
                for y in 0..<size {
                    for x in 0..<size {
                        let left = normalized[y * size + x]
                        if left != 0 { lhs += 1 }
                        let rx = x + offsetX
                        let ry = y + offsetY
                        guard rx >= 0, rx < size, ry >= 0, ry < size else { continue }
                        let right = fingerprint.edgeMask[ry * size + rx]
                        if right != 0 { rhs += 1 }
                        if left != 0, right != 0 { intersection += 1 }
                    }
                }
                guard lhs > 0, rhs > 0 else { continue }
                best = max(best, 2 * Double(intersection) / Double(lhs + rhs))
            }
        }
        return best
    }

    private mutating func registerSceneChange(_ pixels: [UInt8]) {
        defer { previousPixels = pixels }
        guard pixels.count == CommercialFrameFeatures.width * CommercialFrameFeatures.height,
              let previousPixels, previousPixels.count == pixels.count
        else { return }
        var difference = 0
        var samples = 0
        let width = CommercialFrameFeatures.width
        let height = CommercialFrameFeatures.height
        for y in stride(from: height / 4, to: height * 3 / 4, by: 4) {
            for x in stride(from: width / 4, to: width * 3 / 4, by: 4) {
                difference += abs(Int(pixels[y * width + x]) - Int(previousPixels[y * width + x]))
                samples += 1
            }
        }
        if samples > 0, Double(difference) / Double(samples) >= 10 { sceneChanges += 1 }
    }

    private static func connectedCandidates(
        in stable: [UInt8],
        at timestamp: Date
    ) -> [CommercialLogoCandidateModel] {
        let width = CommercialFrameFeatures.width
        let height = CommercialFrameFeatures.height
        guard stable.count == width * height else { return [] }
        var visited = [Bool](repeating: false, count: stable.count)
        var components: [(CommercialLogoBounds, [Int])] = []

        for seed in stable.indices where stable[seed] != 0 && !visited[seed] {
            var queue = [seed]
            visited[seed] = true
            var indices: [Int] = []
            var cursor = 0
            while cursor < queue.count {
                let current = queue[cursor]
                cursor += 1
                indices.append(current)
                let x = current % width
                let y = current / width
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) {
                        let next = ny * width + nx
                        if stable[next] != 0, !visited[next] {
                            visited[next] = true
                            queue.append(next)
                        }
                    }
                }
            }
            guard indices.count >= 3 else { continue }
            let xs = indices.map { $0 % width }
            let ys = indices.map { $0 / width }
            components.append((
                CommercialLogoBounds(
                    x: xs.min()!, y: ys.min()!,
                    width: xs.max()! - xs.min()! + 1,
                    height: ys.max()! - ys.min()! + 1
                ),
                indices
            ))
        }

        var merged: [(CommercialLogoBounds, [Int])] = []
        for component in components {
            if let index = merged.firstIndex(where: { boxesAreNear($0.0, component.0) }) {
                let old = merged[index]
                let minX = min(old.0.x, component.0.x)
                let minY = min(old.0.y, component.0.y)
                let maxX = max(old.0.x + old.0.width, component.0.x + component.0.width)
                let maxY = max(old.0.y + old.0.height, component.0.y + component.0.height)
                merged[index] = (
                    CommercialLogoBounds(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                    old.1 + component.1
                )
            } else {
                merged.append(component)
            }
        }

        return merged.compactMap { bounds, indices in
            guard bounds.width <= width / 3, bounds.height <= height / 3,
                  bounds.width * bounds.height <= width * height / 12,
                  indices.count >= 8, indices.count <= 1_500
            else { return nil }
            var local = [UInt8](repeating: 0, count: bounds.width * bounds.height)
            for source in indices {
                let x = source % width - bounds.x
                let y = source / width - bounds.y
                local[y * bounds.width + x] = stable[source]
            }
            return CommercialLogoCandidateModel(
                id: UUID(), bounds: bounds, edgeMask: local, role: .untrusted,
                observedSeconds: 0, sceneCount: 0, programmeIDs: [], lastSeenAt: timestamp
            )
        }
    }

    private static func boxesAreNear(_ lhs: CommercialLogoBounds, _ rhs: CommercialLogoBounds) -> Bool {
        let expanded = CommercialLogoBounds(
            x: lhs.x - 4, y: lhs.y - 4, width: lhs.width + 8, height: lhs.height + 8
        )
        return expanded.x < rhs.x + rhs.width && expanded.x + expanded.width > rhs.x
            && expanded.y < rhs.y + rhs.height && expanded.y + expanded.height > rhs.y
    }

    private static func match(
        _ candidate: CommercialLogoCandidateModel,
        in frame: [UInt8]
    ) -> Double {
        let width = CommercialFrameFeatures.width
        guard frame.count == width * CommercialFrameFeatures.height else { return 0 }
        var best = 0.0
        for offsetY in -3...3 {
            for offsetX in -3...3 {
                var reference = 0
                var matchedReference = 0
                var observed = 0
                for y in 0..<candidate.bounds.height {
                    for x in 0..<candidate.bounds.width {
                        let template = candidate.edgeMask[y * candidate.bounds.width + x]
                        let frameX = candidate.bounds.x + x + offsetX
                        let frameY = candidate.bounds.y + y + offsetY
                        guard frameX >= 0, frameX < width,
                              frameY >= 0, frameY < CommercialFrameFeatures.height
                        else { continue }
                        let current = frame[frameY * width + frameX]
                        if template != 0 {
                            reference += 1
                            if current != 0 {
                                matchedReference += 1
                            }
                        }
                        if current != 0 {
                            observed += 1
                        }
                    }
                }
                guard reference > 0, observed > 0 else { continue }
                let recall = Double(matchedReference) / Double(reference)
                // Estimate how many template points would be hit merely by
                // the background's edge density. This removes chance matches
                // without treating every unrelated texture edge as evidence
                // against a translucent logo.
                let density = min(
                    0.95,
                    Double(observed)
                        / Double(candidate.bounds.width * candidate.bounds.height)
                )
                let chanceRecall = density
                let score = max(0, (recall - chanceRecall) / max(0.01, 1 - chanceRecall))
                best = max(best, score)
            }
        }
        return best
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
        learningCounts = [Int](repeating: 0, count: learningCounts.count)
        learningSamples = 0
        sceneChanges = 0
        previousPixels = nil
        candidates.removeAll()
        lastTimestamp = nil
        lastMatches.removeAll()
        lastPresence.removeAll()
    }
}

struct CommercialChannelContext: Sendable {
    let serverIdentifier: String
    let channelID: String
    let channelIconURL: URL?
    let programmes: [GuideProgram]

    func observation(at date: Date) -> CommercialObservationContext {
        CommercialObservationContext(
            programmeID: programmes.first(where: { $0.isAiring(at: date) })?.id
        )
    }

    var cacheKey: String { "\(serverIdentifier)|\(channelID)" }
}

actor CommercialLogoProfileStore {
    static let shared = CommercialLogoProfileStore()

    private struct Payload: Codable {
        var version = 1
        var profiles: [String: CommercialLogoModel] = [:]
    }

    private let fileURL: URL
    private var payload: Payload

    init(fileURL: URL? = nil) {
        let defaultURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appending(path: "TVPlayer", directoryHint: .isDirectory)
            .appending(path: "commercial-logo-profiles-v1.json")
            ?? FileManager.default.temporaryDirectory
                .appending(path: "commercial-logo-profiles-v1.json")
        let resolvedURL = fileURL ?? defaultURL
        self.fileURL = resolvedURL
        if let data = try? Data(contentsOf: resolvedURL),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data),
           decoded.version == 1 {
            payload = decoded
        } else {
            payload = Payload()
        }
        let expiry = Date().addingTimeInterval(-90 * 86_400)
        payload.profiles = payload.profiles.filter { $0.value.savedAt >= expiry }
    }

    func load(key: String, now: Date = Date()) -> CommercialLogoModel? {
        guard var model = payload.profiles[key],
              model.version == CommercialLogoModel.currentVersion,
              model.savedAt >= now.addingTimeInterval(-90 * 86_400)
        else { return nil }
        if model.savedAt < now.addingTimeInterval(-30 * 86_400) {
            for index in model.candidates.indices {
                model.candidates[index].role = .untrusted
            }
        }
        return model
    }

    func save(_ model: CommercialLogoModel, key: String) {
        var updated = model
        updated.savedAt = Date()
        payload.profiles[key] = updated
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(payload).write(to: fileURL, options: .atomic)
        } catch {
            // This is a disposable performance cache. Detection continues in memory.
        }
    }
}

@MainActor
final class CommercialLiveAnalyzer: NSObject, ObservableObject,
    @preconcurrency VLCMediaPlayerDelegate {
    static let snapshotInterval: Duration = .seconds(1)
    static let snapshotWidth = Int32(CommercialFrameFeatures.width)
    static let snapshotHeight = Int32(CommercialFrameFeatures.height)

    @Published private(set) var breaks: [CommercialBreak] = []
    @Published private(set) var diagnostics = CommercialDetectionDiagnostics.inactive
    let mediaPlayer: VLCMediaPlayer
    var breaksChanged: (([CommercialBreak]) -> Void)?

    private let logger = Logger(
        subsystem: "de.beutner.TVPlayer",
        category: "CommercialDetection"
    )
    private var detector = CommercialBreakDetector()
    private let profileStore = CommercialLogoProfileStore.shared
    private var captureTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var pendingSnapshot: (url: URL, timestamp: Date, requestedAt: Date)?
    private var channelContext: CommercialChannelContext?
    private var lastProfileSaveAt: Date?
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

    func start(context: CommercialChannelContext, url: URL) async {
        let channelID = context.channelID
        stop(resetMarkers: self.channelID != channelID)
        if self.channelID != channelID {
            let stored = await profileStore.load(key: context.cacheKey)
            detector = CommercialBreakDetector(logoModel: stored)
            publish(detector.breaks)
        }
        self.channelID = channelID
        channelContext = context
        artworkTask?.cancel()
        if let iconURL = context.channelIconURL {
            artworkTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let (data, _) = try await URLSession.shared.data(from: iconURL)
                    try Task.checkCancellation()
                    let fingerprint = await Task.detached(priority: .utility) {
                        CommercialFrameFeatureExtractor.artworkFingerprint(from: data)
                    }.value
                    detector.setArtworkFingerprint(fingerprint)
                } catch {
                    // Artwork is optional evidence; temporal learning remains available.
                }
            }
        }
        diagnostics = CommercialDetectionDiagnostics(
            isActive: true,
            phase: detector.diagnosticsPhase,
            learningProgress: detector.learningProgress,
            sampledAt: nil,
            sampledPixels: [],
            logoCorner: detector.learnedLogoModel?.corner,
            logoMask: detector.learnedLogoModel?.edgeMask ?? [],
            logoSimilarity: nil,
            logoIsPresent: nil,
            candidates: detector.learnedLogoModel?.candidates.map {
                CommercialLogoDiagnostic(
                    id: $0.id, bounds: $0.bounds, edgeMask: $0.edgeMask,
                    role: $0.role, similarity: nil, isPresent: nil
                )
            } ?? [],
            abstentionReason: detector.hasLearnedLogo
                ? nil
                : "Waiting for a trusted channel logo"
        )
        guard let media = VLCMedia(url: url) else { return }
        if let proxy = CachedAddressProxy.shared.vlcHTTPProxyOption(for: url) {
            media.addOption(proxy)
        }
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
        artworkTask?.cancel()
        artworkTask = nil
        clearPendingSnapshot()
        mediaPlayer.stop()
        mediaPlayer.media = nil
        diagnostics = .inactive
        if resetMarkers {
            cacheLearnedLogo()
            channelID = nil
            channelContext = nil
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
            let observation = channelContext?.observation(at: timestamp) ?? .unknown
            publish(detector.consume(features, at: timestamp, context: observation))
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
        guard let channelContext, let model = detector.learnedLogoModel else { return }
        let now = Date()
        guard lastProfileSaveAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true else { return }
        lastProfileSaveAt = now
        Task { await profileStore.save(model, key: channelContext.cacheKey) }
    }
}
