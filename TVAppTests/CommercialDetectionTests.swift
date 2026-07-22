import Foundation
import XCTest
@testable import TVApp

final class CommercialDetectionTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 100_000)

    func testAutomaticPolicyAvoidsExpensiveAndConstrainedNetworks() {
        XCTAssertTrue(CommercialDetectionPolicy.isAllowed(
            mode: .automatic,
            network: network()
        ))
        XCTAssertFalse(CommercialDetectionPolicy.isAllowed(
            mode: .automatic,
            network: network(isExpensive: true)
        ))
        XCTAssertFalse(CommercialDetectionPolicy.isAllowed(
            mode: .automatic,
            network: network(isConstrained: true)
        ))
    }

    func testAlwaysPolicyStillRequiresAConnectedNetwork() {
        XCTAssertTrue(CommercialDetectionPolicy.isAllowed(
            mode: .always,
            network: network(isExpensive: true, isConstrained: true)
        ))
        XCTAssertFalse(CommercialDetectionPolicy.isAllowed(
            mode: .always,
            network: network(isConnected: false)
        ))
    }

    func testOffPolicyNeverStartsAnalysis() {
        XCTAssertFalse(CommercialDetectionPolicy.isAllowed(
            mode: .off,
            network: network()
        ))
    }

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

    func testFaintLogoEdgesDoNotCreateCommercialMarker() {
        var detector = learnedDetector()

        for second in 0...20 {
            _ = detector.consume(
                frame(logoVisible: false, faintLogoVisible: true),
                at: date(second)
            )
        }

        XCTAssertTrue(detector.breaks.isEmpty)
    }

    func testBackgroundTextureInsideLogoBoundsDoesNotHideLogo() {
        var detector = learnedDetector()

        for second in 0...20 {
            _ = detector.consume(
                frame(logoVisible: true, backgroundEdgeCount: 500),
                at: date(second)
            )
        }

        XCTAssertTrue(detector.breaks.isEmpty)
    }

    func testBackgroundTextureAloneDoesNotImitateLogo() {
        var detector = learnedDetector()

        for second in 0...15 {
            _ = detector.consume(
                frame(logoVisible: false, backgroundEdgeCount: 500),
                at: date(second)
            )
        }

        XCTAssertEqual(detector.breaks.first?.start, date(0))
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

    func testDiagnosticsExposeLearningProgressAndSampledFrame() {
        var detector = CommercialBreakDetector()
        let features = frame(logoVisible: true)

        _ = detector.consume(features, at: date(0))
        let diagnostics = detector.diagnostics(for: features, sampledAt: date(0))

        XCTAssertEqual(diagnostics.phase, "Learning")
        XCTAssertEqual(diagnostics.learningProgress, 0, accuracy: 0.0001)
        XCTAssertEqual(diagnostics.sampledAt, date(0))
        XCTAssertEqual(diagnostics.sampledPixels, features.pixels)
        XCTAssertNil(diagnostics.logoCorner)
        XCTAssertNil(diagnostics.logoSimilarity)
    }

    func testDiagnosticsExposeLearnedLogoMaskAndMatchResult() {
        var detector = learnedDetector()
        let features = frame(logoVisible: false)

        _ = detector.consume(features, at: date(60))
        let diagnostics = detector.diagnostics(for: features, sampledAt: date(60))

        XCTAssertEqual(diagnostics.phase, "Possible commercial")
        XCTAssertEqual(diagnostics.logoCorner, 0)
        XCTAssertFalse(diagnostics.logoMask.isEmpty)
        XCTAssertEqual(diagnostics.logoSimilarity, 0)
        XCTAssertEqual(diagnostics.logoIsPresent, false)
    }

    func testAuxiliaryLogoDisappearanceDoesNotStartCommercial() {
        var detector = detectorWithPrimaryAndAuxiliaryLogo()

        for second in 0...20 {
            _ = detector.consume(
                frame(logoVisible: true, auxiliaryLogoVisible: false),
                at: date(second)
            )
        }

        XCTAssertTrue(detector.breaks.isEmpty)
    }

    func testPrimaryLogoDisappearanceStartsCommercialWhileAuxiliaryRemains() {
        var detector = detectorWithPrimaryAndAuxiliaryLogo()

        for second in 0...15 {
            _ = detector.consume(
                frame(logoVisible: false, auxiliaryLogoVisible: true),
                at: date(second)
            )
        }

        XCTAssertEqual(detector.breaks.first?.start, date(0))
    }

    func testMultiplePersistentGraphicsRemainUntrustedWhenIdentityIsAmbiguous() {
        var detector = CommercialBreakDetector()

        for second in 0..<CommercialBreakDetector.logoLearningSampleCount {
            _ = detector.consume(
                frame(
                    logoVisible: true,
                    auxiliaryLogoVisible: true,
                    sceneValue: second.isMultiple(of: 2) ? 70 : 150
                ),
                at: date(second),
                context: CommercialObservationContext(programmeID: "programme-one")
            )
        }

        let features = frame(
            logoVisible: true,
            auxiliaryLogoVisible: true,
            sceneValue: 90
        )
        _ = detector.consume(
            features,
            at: date(CommercialBreakDetector.logoLearningSampleCount),
            context: CommercialObservationContext(programmeID: "programme-one")
        )
        let diagnostics = detector.diagnostics(
            for: features,
            sampledAt: date(CommercialBreakDetector.logoLearningSampleCount)
        )

        XCTAssertEqual(diagnostics.candidates.count, 2)
        XCTAssertTrue(diagnostics.candidates.allSatisfy { $0.role == .untrusted })
        XCTAssertEqual(diagnostics.abstentionReason, "Logo identity is ambiguous")
        XCTAssertTrue(detector.breaks.isEmpty)
    }

    func testProfileStoreRoundTripsCandidates() async {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "profiles.json")
        let store = CommercialLogoProfileStore(fileURL: fileURL)
        let model = CommercialLogoModel(corner: 0, edgeMask: leftLogoMask())

        await store.save(model, key: "server|channel")
        let restored = await store.load(key: "server|channel")

        XCTAssertEqual(restored?.candidates.count, 1)
        XCTAssertEqual(restored?.trustedCandidates.count, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    private func learnedDetector() -> CommercialBreakDetector {
        let model = CommercialLogoModel(corner: 0, edgeMask: leftLogoMask())
        let detector = CommercialBreakDetector(logoModel: model)
        XCTAssertTrue(detector.hasLearnedLogo)
        return detector
    }

    private func detectorWithPrimaryAndAuxiliaryLogo() -> CommercialBreakDetector {
        let left = CommercialLogoCandidateModel(
            id: UUID(),
            bounds: CommercialLogoBounds(
                x: 0, y: 0,
                width: CommercialFrameFeatures.cornerWidth,
                height: CommercialFrameFeatures.cornerHeight
            ),
            edgeMask: leftLogoMask(),
            role: .channelIdentity,
            observedSeconds: 300,
            sceneCount: 10,
            programmeIDs: ["one", "two"],
            lastSeenAt: nil
        )
        let right = CommercialLogoCandidateModel(
            id: UUID(),
            bounds: CommercialLogoBounds(
                x: CommercialFrameFeatures.width - CommercialFrameFeatures.cornerWidth,
                y: 0,
                width: CommercialFrameFeatures.cornerWidth,
                height: CommercialFrameFeatures.cornerHeight
            ),
            edgeMask: rightLogoMask(),
            role: .auxiliary,
            observedSeconds: 300,
            sceneCount: 10,
            programmeIDs: ["one"],
            lastSeenAt: nil
        )
        return CommercialBreakDetector(
            logoModel: CommercialLogoModel(candidates: [left, right])
        )
    }

    private func date(_ seconds: Int) -> Date {
        start.addingTimeInterval(TimeInterval(seconds))
    }

    private func network(
        isConnected: Bool = true,
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) -> CommercialDetectionNetworkConditions {
        CommercialDetectionNetworkConditions(
            isConnected: isConnected,
            isExpensive: isExpensive,
            isConstrained: isConstrained
        )
    }

    private func frame(
        logoVisible: Bool,
        auxiliaryLogoVisible: Bool = false,
        sceneValue: UInt8 = 100,
        faintLogoVisible: Bool = false,
        backgroundEdgeCount: Int = 0
    ) -> CommercialFrameFeatures {
        let edgeCount = CommercialFrameFeatures.cornerWidth
            * CommercialFrameFeatures.cornerHeight
        let leftEdges = logoVisible
            ? leftLogoMask()
            : [UInt8](repeating: 0, count: edgeCount)
        let rightEdges = auxiliaryLogoVisible
            ? rightLogoMask()
            : [UInt8](repeating: 0, count: edgeCount)
        let logoMask = leftLogoMask()
        var perimeterEdges = CommercialFrameFeatures(
            pixels: [], meanLuma: 0, darkPixelFraction: 0,
            cornerEdges: [leftEdges, rightEdges]
        ).perimeterEdges
        if backgroundEdgeCount > 0 {
            var inserted = 0
            for y in stride(
                from: CommercialFrameFeatures.cornerHeight - 1,
                through: 0,
                by: -1
            ) {
                for x in 0..<CommercialFrameFeatures.cornerWidth
                    where logoMask[y * CommercialFrameFeatures.cornerWidth + x] == 0 {
                    perimeterEdges[y * CommercialFrameFeatures.width + x] = 1
                    inserted += 1
                    if inserted == backgroundEdgeCount { break }
                }
                if inserted == backgroundEdgeCount { break }
            }
        }
        var matchingEdges = perimeterEdges
        if faintLogoVisible {
            for y in 0..<CommercialFrameFeatures.cornerHeight {
                for x in 0..<CommercialFrameFeatures.cornerWidth
                    where logoMask[y * CommercialFrameFeatures.cornerWidth + x] != 0 {
                    matchingEdges[y * CommercialFrameFeatures.width + x] = 1
                }
            }
        }
        return CommercialFrameFeatures(
            pixels: [UInt8](repeating: sceneValue, count: CommercialFrameFeatures.width
                * CommercialFrameFeatures.height),
            meanLuma: Double(sceneValue),
            darkPixelFraction: 0,
            cornerEdges: [leftEdges, rightEdges],
            perimeterEdges: perimeterEdges,
            perimeterMatchingEdges: matchingEdges
        )
    }

    private func leftLogoMask() -> [UInt8] {
        var mask = [UInt8](
            repeating: 0,
            count: CommercialFrameFeatures.cornerWidth * CommercialFrameFeatures.cornerHeight
        )
        for index in 20..<50 { mask[index] = 1 }
        return mask
    }

    private func rightLogoMask() -> [UInt8] {
        var mask = [UInt8](
            repeating: 0,
            count: CommercialFrameFeatures.cornerWidth * CommercialFrameFeatures.cornerHeight
        )
        for index in 100..<140 { mask[index] = 1 }
        return mask
    }
}
