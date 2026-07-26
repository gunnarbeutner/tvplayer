import Foundation
import OSLog

struct HTSPLiveCandidateDescriptor: Equatable, Sendable {
    let configuration: TVHeadendConfiguration
    let channelID: UInt32
    let profile: String
    let tuningPolicy: NativeTimeshiftTuningPolicy

    init(
        configuration: TVHeadendConfiguration,
        channelID: UInt32,
        profile: String,
        tuningPolicy: NativeTimeshiftTuningPolicy = NativeTimeshiftTuningPolicy()
    ) {
        self.configuration = configuration
        self.channelID = channelID
        self.profile = profile
        self.tuningPolicy = tuningPolicy
    }

    init?(_ request: LiveStreamRequest) {
        guard case let .live(.nativeTimeshift(htsp)) = request.kind else { return nil }
        self.init(
            configuration: htsp.configuration,
            channelID: htsp.channelID,
            profile: request.profile,
            tuningPolicy: htsp.tuningPolicy
        )
    }
}

struct HTSPLiveCandidateClaim: Sendable {
    let stream: HTSPLiveInputStream
    let promotion: HTSPLiveCandidatePromotion
    let stagedDuration: TimeInterval
    let promotionDuration: TimeInterval
}

/// Owns at most one optional low-priority live subscription. A claim consumes
/// the slot exactly once; superseded or cancelled tasks close their socket even
/// if a blocking connect finishes after cancellation.
actor HTSPLiveCandidatePool {
    static let shared = HTSPLiveCandidatePool()

    typealias Connector = @Sendable (
        HTSPLiveCandidateDescriptor
    ) async throws -> HTSPLiveInputStream

    private struct Slot {
        let id: UUID
        let generation: UUID?
        let descriptor: HTSPLiveCandidateDescriptor
        let startedAt: ContinuousClock.Instant
        let task: Task<HTSPLiveInputStream, Error>
    }

    private let logger = Logger(
        subsystem: "de.beutner.TVPlayer",
        category: "HTSPCandidate"
    )
    private let clock = ContinuousClock()
    private let connector: Connector
    private var slot: Slot?

    init(
        connector: @escaping Connector = { descriptor in
            try await HTSPLiveInputStream.connectCandidate(
                configuration: descriptor.configuration,
                channelID: descriptor.channelID,
                profile: descriptor.profile,
                tuningPolicy: descriptor.tuningPolicy
            )
        }
    ) {
        self.connector = connector
    }

    func stage(
        _ descriptor: HTSPLiveCandidateDescriptor,
        generation: UUID? = nil
    ) {
        // A named generation may harmlessly repeat its own request. A new
        // owner (or an unscoped diagnostic call) deliberately replaces even
        // an equal descriptor: the connected stream may have failed since it
        // was staged and must not poison a retry for the same channel.
        if let generation,
           slot?.descriptor == descriptor,
           slot?.generation == generation {
            return
        }
        disposeCurrentSlot()

        let id = UUID()
        let connector = connector
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let stream = try await connector(descriptor)
            guard !Task.isCancelled else {
                stream.close()
                throw CancellationError()
            }
            return stream
        }
        slot = Slot(
            id: id,
            generation: generation,
            descriptor: descriptor,
            startedAt: clock.now,
            task: task
        )
        logger.debug("Staging HTSP channel \(descriptor.channelID, privacy: .public)")

        Task { [weak self] in
            do {
                _ = try await task.value
            } catch {
                await self?.discardFailedSlot(id: id, error: error)
            }
        }
    }

    func take(
        matching descriptor: HTSPLiveCandidateDescriptor
    ) async throws -> HTSPLiveCandidateClaim? {
        guard let candidate = slot, candidate.descriptor == descriptor else { return nil }
        slot = nil

        return try await withTaskCancellationHandler {
            let stream: HTSPLiveInputStream
            do {
                stream = try await candidate.task.value
                try Task.checkCancellation()
            } catch {
                if error is CancellationError { throw error }
                logger.info(
                    "Staged HTSP channel was unavailable: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }

            let promotionStartedAt = clock.now
            do {
                let promotion = try await stream.promoteCandidate()
                try Task.checkCancellation()
                let promotionDuration = promotionStartedAt.duration(to: clock.now)
                let stagedDuration = candidate.startedAt.duration(to: clock.now)
                let claim = HTSPLiveCandidateClaim(
                    stream: stream,
                    promotion: promotion,
                    stagedDuration: Self.seconds(stagedDuration),
                    promotionDuration: Self.seconds(promotionDuration)
                )
                logger.info("Claimed HTSP channel \(descriptor.channelID, privacy: .public) aligned=\(promotion.usedAlignedWindow) promotion=\(Int(claim.promotionDuration * 1_000))ms")
                return claim
            } catch {
                stream.close()
                if error is CancellationError { throw error }
                logger.info(
                    "Staged HTSP promotion failed: \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        } onCancel: {
            Self.cancelAndClose(candidate.task)
        }
    }

    func cancel() {
        disposeCurrentSlot()
    }

    func cancel(generation: UUID) {
        guard slot?.generation == generation else { return }
        disposeCurrentSlot()
    }

    func contains(_ descriptor: HTSPLiveCandidateDescriptor) -> Bool {
        slot?.descriptor == descriptor
    }

    private func discardFailedSlot(id: UUID, error: Error) {
        guard slot?.id == id else { return }
        slot = nil
        logger.debug(
            "Discarded failed HTSP candidate: \(error.localizedDescription, privacy: .public)"
        )
    }

    private func disposeCurrentSlot() {
        guard let discarded = slot else { return }
        slot = nil
        Self.cancelAndClose(discarded.task)
    }

    private nonisolated static func cancelAndClose(
        _ task: Task<HTSPLiveInputStream, Error>
    ) {
        task.cancel()
        Task {
            if let stream = try? await task.value { stream.close() }
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
