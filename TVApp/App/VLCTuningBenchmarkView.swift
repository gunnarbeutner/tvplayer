#if os(macOS)
import AppKit
import Foundation
import SwiftUI

struct VLCTuningBenchmarkView: View {
    @StateObject private var benchmark = VLCTuningBenchmarkModel()

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color.black
                VLCVideoSurface(
                    mediaPlayer: benchmark.engine.mediaPlayer,
                    attachmentRevision: benchmark.videoAttachmentRevision
                )

                HStack(spacing: 18) {
                    metric("Attempt", "\(benchmark.completedAttempts)/\(benchmark.totalAttempts)")
                    metric("Channel", benchmark.channelName)
                    metric("VLC", benchmark.playerState)
                }
                .padding(14)
                .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 12))
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("VLC Tuning Benchmark")
                        .font(.title2.bold())
                    Text(benchmark.phase)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ProgressView(
                    value: Double(benchmark.completedAttempts),
                    total: Double(max(1, benchmark.totalAttempts))
                )
                .tint(benchmark.failureCount == 0 ? .blue : .orange)

                Button("Run tuning test again") {
                    benchmark.rerun()
                }
                .disabled(!benchmark.canRerun)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(benchmark.events) { event in
                                VLCTuningEventRow(event: event)
                                    .id(event.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: benchmark.events.count) {
                        guard let last = benchmark.events.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .padding(24)
            .frame(width: 600)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(.black)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.medium))
                .lineLimit(1)
        }
    }
}

struct VLCTuningEvent: Identifiable {
    enum Kind { case information, success, warning, failure }

    let id = UUID()
    let elapsed: TimeInterval
    let kind: Kind
    let title: String
    let detail: String?

    var timestamp: String { String(format: "+%06.2fs", elapsed) }
}

private struct VLCTuningEventRow: View {
    let event: VLCTuningEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.title).font(.callout.weight(.semibold))
                    Spacer()
                    Text(event.timestamp)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let detail = event.detail {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var symbol: String {
        switch event.kind {
        case .information: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "arrow.clockwise.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch event.kind {
        case .information: .blue
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}

@MainActor
final class VLCTuningBenchmarkModel: ObservableObject {
    @Published private(set) var events: [VLCTuningEvent] = []
    @Published private(set) var phase = "Discovering Tvheadend…"
    @Published private(set) var channelName = "—"
    @Published private(set) var completedAttempts = 0
    @Published private(set) var totalAttempts = 0
    @Published private(set) var failureCount = 0
    @Published private(set) var canRerun = false
    @Published private(set) var videoAttachmentRevision = 0

    let engine = VLCPlaybackEngine()

    private typealias Channel = TVHeadendPlaylistChannel

    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var discovery: TVHeadendDiscovery?
    private var runTask: Task<Void, Never>?
    private var discoveredSettings: DiscoveredTVHeadendSettings?
    private var samples: [TuningAttemptSample] = []

    private enum TuningMode: String {
        case cold
        case requestWarm = "request-warm"
        case transportWarm = "transport-warm"
        case paired

        var warmsRequest: Bool {
            self == .requestWarm || self == .transportWarm
        }

        var stagesTransport: Bool {
            self == .transportWarm
        }
    }

    private enum TuningDirection: String {
        case up
        case down
    }

    private struct WarmedRequest {
        let channelID: UInt32
        let request: LiveStreamRequest
        let startedAt: TimeInterval
        let readyAt: TimeInterval
        let candidateStagedAt: TimeInterval?
    }

    private struct TuneOutcome {
        let sample: TuningAttemptSample
        let nextWarmedRequest: WarmedRequest?
    }

    private struct FailureCaptureAnnouncement: Encodable {
        let attempt: Int?
        let channelID: UInt32?
        let path: String
    }

    private struct TuningAttemptBeginAnnouncement: Encodable {
        let attempt: Int
        let channelID: UInt32
        let channelName: String
        let mode: String
        let direction: String
        let unixTimeSeconds: TimeInterval
        let monotonicSeconds: TimeInterval
    }

    private struct TuningAttemptSample: Encodable {
        let attempt: Int
        let mode: String
        let direction: String
        let channelID: UInt32
        let channelName: String
        let vlcCacheMilliseconds: Int
        let initialHorizonMilliseconds: Int

        var requestSource = "cold"
        var requestWarmHit = false
        var requestMilliseconds: Int?
        var commandToRequestReadyMilliseconds: Int?
        var requestWarmLeadMilliseconds: Int?
        var candidateExpected = false
        var candidateHit = false
        var candidateAligned: Bool?
        var candidateStageLeadMilliseconds: Int?
        var candidateStagedDurationMilliseconds: Int?
        var candidatePromotionMilliseconds: Int?
        var candidateReadyAgeMilliseconds: Int?
        var candidatePayloadBytes: Int?
        var vlcStopMilliseconds: Int?
        var prepareMilliseconds: Int?
        var playToHTSPVideoMilliseconds: Int?
        var playToHTSPAudioMilliseconds: Int?
        var playToFirstPictureMilliseconds: Int?
        var playToFirstAudioMilliseconds: Int?
        var playToReadyMilliseconds: Int?
        var startupMaximumVideoGapMilliseconds: Int?
        var dwellObservedMilliseconds = 0
        var dwellMaximumVideoGapMilliseconds: Int?
        var dwellMaximumAudioGapMilliseconds: Int?
        var displayedPictures = 0
        var playedAudioBuffers = 0
        var decodedVideo = 0
        var decodedAudio = 0
        var videoPackets: Int64 = 0
        var audioPackets: Int64 = 0
        var lostPictures = 0
        var lostAudioBuffers = 0
        var dwellLostPictures = 0
        var dwellLostAudioBuffers = 0
        var recoveryCount = 0
        var audioExpected = false
        var audioDiagnosticsAdvanced = false
        var success = false
        var suspiciousReasons: [String] = []
        var qualityWarnings: [String] = []
        var failureDetail: String?
    }

    private struct TuningAggregate: Encodable {
        let mode: String
        let direction: String
        let vlcCacheMilliseconds: Int
        let initialHorizonMilliseconds: Int
        let attempts: Int
        let successfulAttempts: Int
        let suspiciousAttempts: Int
        let requestWarmHits: Int
        let requestWarmMisses: Int
        let candidateExpectedAttempts: Int
        let candidateHits: Int
        let candidateMisses: Int
        let candidateAlignedHits: Int
        let candidateStageLeadP50Milliseconds: Int?
        let candidateStagedP50Milliseconds: Int?
        let candidatePromotionP50Milliseconds: Int?
        let candidatePayloadP50Bytes: Int?
        let requestP50Milliseconds: Int?
        let requestP95Milliseconds: Int?
        let playToReadyP50Milliseconds: Int?
        let playToReadyP95Milliseconds: Int?
        let playToReadyP99Milliseconds: Int?
        let startupVideoGapP95Milliseconds: Int?
        let dwellVideoGapP95Milliseconds: Int?
        let dwellAudioGapP95Milliseconds: Int?
    }

    var playerState: String {
        switch engine.state {
        case .idle: "Idle"
        case .preparing: "Preparing"
        case .playing: "Playing"
        case .paused: "Paused"
        case let .recovering(_, attempt): "Recovering \(attempt)"
        case .failed: "Failed"
        }
    }

    init() {
        append(.information, "mDNS discovery started", "Looking for _tvplayer._tcp.local.")
        let discovery = TVHeadendDiscovery { [weak self] event in
            guard let self, case let .upsert(service) = event else { return }
            self.start(settings: service.settings)
        }
        self.discovery = discovery
        discovery.start()
    }

    func rerun() {
        guard let discoveredSettings else { return }
        startRun(settings: discoveredSettings)
    }

    private func start(settings: DiscoveredTVHeadendSettings) {
        guard discoveredSettings == nil else { return }
        discoveredSettings = settings
        discovery?.stop()
        discovery = nil
        append(.success, "Discovered Tvheadend", settings.baseURL.host)
        startRun(settings: settings)
    }

    private func startRun(settings: DiscoveredTVHeadendSettings) {
        runTask?.cancel()
        engine.stop()
        events.removeAll()
        completedAttempts = 0
        failureCount = 0
        samples.removeAll()
        totalAttempts = requestedAttemptCount
        canRerun = false
        runTask = Task { [weak self] in
            guard let self else { return }
            await HTSPLiveCandidatePool.shared.cancel()
            do {
                try await run(settings: settings)
                await HTSPLiveCandidatePool.shared.cancel()
            } catch is CancellationError {
                await HTSPLiveCandidatePool.shared.cancel()
                return
            } catch {
                await HTSPLiveCandidatePool.shared.cancel()
                failureCount += 1
                phase = "Tuning benchmark failed"
                append(.failure, "Benchmark stopped", error.localizedDescription)
                finish()
            }
        }
    }

    private func run(settings: DiscoveredTVHeadendSettings) async throws {
        if failureCaptureEnabled,
           let sessionDirectory = try HTSPTuningFailureCaptureRegistry.shared.startSession() {
            emitStructured(
                "VLC_TUNING_CAPTURE_SESSION",
                FailureCaptureAnnouncement(
                    attempt: nil,
                    channelID: nil,
                    path: sessionDirectory.path
                )
            )
        }
        let configuration = TVHeadendConfiguration(
            serverProfileID: settings.discoveryID,
            baseURL: settings.baseURL,
            username: settings.username,
            password: settings.password,
            streamProfile: settings.streamProfile,
            htspPort: settings.htspPort,
            guideCacheURL: settings.guideCacheURL,
            xmltvURL: settings.xmltvURL
        )
        let client = TVHeadendClient(configuration: configuration)
        phase = "Loading channels…"
        let loadedChannels = try await client.ticketedChannels()
        guard !loadedChannels.isEmpty else { throw TuningError.noChannels }
        let channels: [Channel]
        if let channelIndex = requestedChannelIndex,
           loadedChannels.indices.contains(channelIndex - 1) {
            channels = [loadedChannels[channelIndex - 1]]
            append(
                .information,
                "Repeating \(channels[0].name)",
                "Playlist channel \(channelIndex) of \(loadedChannels.count)."
            )
        } else {
            channels = loadedChannels
            append(
                .information,
                "Loaded \(channels.count) channels",
                "Cycling across the playlist to exercise fresh subscriptions."
            )
        }

        let orderedChannels = channelsInBenchmarkOrder(channels)
        var warmedRequest: WarmedRequest?
        var firstAttemptBeganBeforePrewarm = false
        let firstAttemptMode = mode(forAttempt: 1)
        if firstAttemptMode.warmsRequest, let first = orderedChannels.first {
            let attemptStartedAt = Date()
            try HTSPTuningFailureCaptureRegistry.shared.beginAttempt(
                attempt: 1,
                channelID: first.id,
                channelName: first.name,
                mode: firstAttemptMode.rawValue,
                direction: tuningDirection.rawValue,
                startedAt: attemptStartedAt
            )
            try HTSPTuningFailureCaptureRegistry.shared.updateActiveAttemptPhase("prewarm")
            emitStructured(
                "VLC_TUNING_ATTEMPT_BEGIN",
                TuningAttemptBeginAnnouncement(
                    attempt: 1,
                    channelID: first.id,
                    channelName: first.name,
                    mode: firstAttemptMode.rawValue,
                    direction: tuningDirection.rawValue,
                    unixTimeSeconds: attemptStartedAt.timeIntervalSince1970,
                    monotonicSeconds: monotonicNow
                )
            )
            firstAttemptBeganBeforePrewarm = true
            warmedRequest = await warmRequest(
                for: first,
                using: client,
                stageTransport: firstAttemptMode.stagesTransport,
                captureAttempt: 1
            )
            if firstAttemptMode.stagesTransport,
               let stagedAt = warmedRequest?.candidateStagedAt {
                let remainingLead = TimeInterval(transportWarmLeadMilliseconds) / 1_000
                    - (monotonicNow - stagedAt)
                if remainingLead > 0 {
                    try await Task.sleep(
                        for: .milliseconds(Int((remainingLead * 1_000).rounded(.up)))
                    )
                }
            }
        }

        for attempt in 1...totalAttempts {
            try Task.checkCancellation()
            let attemptMode = mode(forAttempt: attempt)
            let index = (attempt - 1) % orderedChannels.count
            let channel = orderedChannels[index]
            let hasNextAttempt = attempt < totalAttempts
            let nextChannel = hasNextAttempt
                ? orderedChannels[attempt % orderedChannels.count]
                : nil
            let nextMode = hasNextAttempt ? mode(forAttempt: attempt + 1) : nil
            if attempt != 1 || !firstAttemptBeganBeforePrewarm {
                let attemptStartedAt = Date()
                try HTSPTuningFailureCaptureRegistry.shared.beginAttempt(
                    attempt: attempt,
                    channelID: channel.id,
                    channelName: channel.name,
                    mode: attemptMode.rawValue,
                    direction: tuningDirection.rawValue,
                    startedAt: attemptStartedAt
                )
                emitStructured(
                    "VLC_TUNING_ATTEMPT_BEGIN",
                    TuningAttemptBeginAnnouncement(
                        attempt: attempt,
                        channelID: channel.id,
                        channelName: channel.name,
                        mode: attemptMode.rawValue,
                        direction: tuningDirection.rawValue,
                        unixTimeSeconds: attemptStartedAt.timeIntervalSince1970,
                        monotonicSeconds: monotonicNow
                    )
                )
            }
            let outcome = try await tune(
                channel,
                attempt: attempt,
                mode: attemptMode,
                client: client,
                warmedRequest: warmedRequest,
                nextWarmChannel: nextMode?.warmsRequest == true ? nextChannel : nil,
                nextWarmMode: nextMode
            )
            samples.append(outcome.sample)
            try HTSPTuningFailureCaptureRegistry.shared.completeAttempt(
                attempt: attempt,
                success: outcome.sample.success
            )
            // The runner disarms its watchdog when it observes this line. Keep
            // it armed until the durable attempt metadata is fully completed.
            emitStructured("VLC_TUNING_SAMPLE", outcome.sample)
            warmedRequest = outcome.nextWarmedRequest
            completedAttempts = attempt
        }

        engine.stop()
        phase = failureCount == 0
            ? "All tuning attempts produced audio and video"
            : "Completed with \(failureCount) suspect tuning attempt(s)"
        append(
            failureCount == 0 ? .success : .warning,
            "Tuning benchmark complete",
            "\(totalAttempts) attempts · \(failureCount) recoveries, startup stalls, or output failures"
        )
        emitStructured(
            "VLC_TUNING_AGGREGATE",
            aggregate(for: samples, mode: tuningMode.rawValue)
        )
        if tuningMode == .paired {
            for mode in [TuningMode.cold, .transportWarm] {
                emitStructured(
                    "VLC_TUNING_AGGREGATE",
                    aggregate(
                        for: samples.filter { $0.mode == mode.rawValue },
                        mode: mode.rawValue
                    )
                )
            }
        }
        finish()
    }

    private func mode(forAttempt attempt: Int) -> TuningMode {
        guard tuningMode == .paired else { return tuningMode }
        return attempt.isMultiple(of: 2) ? .transportWarm : .cold
    }

    private func channelsInBenchmarkOrder(_ channels: [Channel]) -> [Channel] {
        guard tuningDirection == .down else { return channels }
        return Array(channels.reversed())
    }

    private func tune(
        _ channel: Channel,
        attempt: Int,
        mode: TuningMode,
        client: TVHeadendClient,
        warmedRequest: WarmedRequest?,
        nextWarmChannel: Channel?,
        nextWarmMode: TuningMode?
    ) async throws -> TuneOutcome {
        channelName = channel.name
        phase = "Attempt \(attempt) of \(totalAttempts): \(channel.name)"
        try? HTSPTuningFailureCaptureRegistry.shared.updateActiveAttemptPhase("request")
        let commandStartedAt = monotonicNow
        if !mode.stagesTransport {
            await HTSPLiveCandidatePool.shared.cancel()
        }
        var result = TuningAttemptSample(
            attempt: attempt,
            mode: mode.rawValue,
            direction: tuningDirection.rawValue,
            channelID: channel.id,
            channelName: channel.name,
            vlcCacheMilliseconds: benchmarkTuningPolicy.vlcCacheMilliseconds,
            initialHorizonMilliseconds: benchmarkTuningPolicy.initialHorizonMilliseconds
        )
        result.candidateExpected = mode.stagesTransport

        let request: LiveStreamRequest
        do {
            if let warmedRequest, warmedRequest.channelID == channel.id {
                request = warmedRequest.request
                result.requestSource = warmedRequest.candidateStagedAt == nil
                    ? "request-warm"
                    : "transport-warm"
                result.requestWarmHit = true
                result.requestMilliseconds = elapsedMilliseconds(
                    from: warmedRequest.startedAt,
                    to: warmedRequest.readyAt
                )
                result.commandToRequestReadyMilliseconds = 0
                result.requestWarmLeadMilliseconds = elapsedMilliseconds(
                    from: warmedRequest.readyAt,
                    to: commandStartedAt
                )
                result.candidateStageLeadMilliseconds = warmedRequest.candidateStagedAt.map {
                    elapsedMilliseconds(from: $0, to: commandStartedAt)
                }
            } else {
                let requestStartedAt = monotonicNow
                request = applyingBenchmarkTuningPolicy(
                    to: try await client.livePlaybackRequest(
                        channelID: channel.playlistID ?? String(channel.id)
                    )
                )
                let requestReadyAt = monotonicNow
                result.requestSource = mode.warmsRequest ? "cold-fallback" : "cold"
                result.requestMilliseconds = elapsedMilliseconds(
                    from: requestStartedAt,
                    to: requestReadyAt
                )
                result.commandToRequestReadyMilliseconds = elapsedMilliseconds(
                    from: commandStartedAt,
                    to: requestReadyAt
                )
            }
        } catch {
            await HTSPLiveCandidatePool.shared.cancel()
            result.failureDetail = error.localizedDescription
            result.suspiciousReasons = ["request-failed"]
            failureCount += 1
            append(.failure, "#\(attempt) \(channel.name) could not resolve its playback request", error.localizedDescription)
            finishFailureCapture(
                for: result,
                diagnosticSummary: error.localizedDescription
            )
            return TuneOutcome(sample: result, nextWarmedRequest: nil)
        }

        try? HTSPTuningFailureCaptureRegistry.shared.updateActiveAttemptPhase("prepare")
        let prepareStartedAt = monotonicNow
        do {
            try await engine.prepare(request)
        } catch {
            await HTSPLiveCandidatePool.shared.cancel()
            result.prepareMilliseconds = elapsedMilliseconds(
                from: prepareStartedAt,
                to: monotonicNow
            )
            result.failureDetail = error.localizedDescription
            result.suspiciousReasons = ["prepare-failed"]
            failureCount += 1
            append(.failure, "#\(attempt) \(channel.name) could not tune", error.localizedDescription)
            finishFailureCapture(
                for: result,
                diagnosticSummary: error.localizedDescription
            )
            return TuneOutcome(sample: result, nextWarmedRequest: nil)
        }
        result.prepareMilliseconds = elapsedMilliseconds(from: prepareStartedAt, to: monotonicNow)
        result.vlcStopMilliseconds = engine.lastVLCStopMilliseconds
        if let candidate = engine.lastNativeCandidateMetrics {
            result.candidateHit = true
            result.candidateAligned = candidate.usedAlignedWindow
            result.candidateStagedDurationMilliseconds = Int(
                (candidate.stagedDuration * 1_000).rounded()
            )
            result.candidatePromotionMilliseconds = Int(
                (candidate.promotionDuration * 1_000).rounded()
            )
            result.candidateReadyAgeMilliseconds = candidate.readyAge.map {
                Int(($0 * 1_000).rounded())
            }
            result.candidatePayloadBytes = candidate.payloadByteCount
        }

        engine.refreshPlaybackInformation()
        let prePlayOutput = counters
        let recoveryCountAtPlay = engine.nativeTimeshiftRecoveryCount
        try? HTSPTuningFailureCaptureRegistry.shared.updateActiveAttemptPhase(
            "playback-start"
        )
        let playStartedAt = monotonicNow
        engine.play()
        let productionReadinessProbe = ProductionReadinessProbe()
        let productionReadinessTask = Task { @MainActor [weak self, engine] () -> Bool in
            defer { productionReadinessProbe.isComplete = true }
            guard await engine.waitForInitialPlaybackOutput(), let self else { return false }
            engine.refreshPlaybackInformation()
            let health = engine.nativeTimeshiftHealthSnapshot
            productionReadinessProbe.readySample = StartupContinuitySample(
                timestamp: self.monotonicNow,
                output: self.counters,
                videoPackets: health?.videoPacketCount ?? 0,
                audioPackets: health?.audioPacketCount ?? 0,
                queuedBytes: engine.bufferedBytes
            )
            return true
        }
        defer { productionReadinessTask.cancel() }

        if standbyPreconnectEnabled,
           case let .live(.nativeTimeshift(htsp)) = request.kind {
            Task {
                await HTSPConnectionPrewarmer.shared.preconnect(configuration: htsp.configuration)
            }
        }

        var firstHTSPVideoAt: TimeInterval?
        var firstHTSPAudioAt: TimeInterval?
        var firstVLCPictureAt: TimeInterval?
        var firstVLCAudioAt: TimeInterval?
        var previousOutput = prePlayOutput
        var startupCadence = VideoCadenceMonitor()
        var dwellContinuity: DwellContinuityMonitor?
        var dwellEndsAt: TimeInterval?
        var nextWarmStartsAt: TimeInterval?
        var nextWarmTask: Task<WarmedRequest?, Never>?
        defer { nextWarmTask?.cancel() }
        var expectsAudio = false
        var didObserveReady = false
        let hardDeadline = playStartedAt + 22 + TimeInterval(dwellSeconds)

        while monotonicNow < hardDeadline {
            try Task.checkCancellation()
            engine.refreshPlaybackInformation()
            let now = monotonicNow
            let health = engine.nativeTimeshiftHealthSnapshot
            expectsAudio = expectsAudio || health?.expectsAudio == true
            if firstHTSPVideoAt == nil, (health?.videoPacketCount ?? 0) > 0 {
                firstHTSPVideoAt = now
            }
            if firstHTSPAudioAt == nil, (health?.audioPacketCount ?? 0) > 0 {
                firstHTSPAudioAt = now
            }

            let output = counters
            if firstVLCPictureAt == nil,
               output.displayedPictures > previousOutput.displayedPictures {
                firstVLCPictureAt = now
            }
            if firstVLCAudioAt == nil,
               output.playedAudioBuffers > previousOutput.playedAudioBuffers {
                firstVLCAudioAt = now
            }
            let cadenceSample = StartupContinuitySample(
                timestamp: now,
                output: output,
                videoPackets: health?.videoPacketCount ?? 0,
                audioPackets: health?.audioPacketCount ?? 0,
                queuedBytes: engine.bufferedBytes
            )

            if !didObserveReady {
                startupCadence.observe(cadenceSample)
            }
            if !didObserveReady, let readySample = productionReadinessProbe.readySample {
                didObserveReady = true
                let endsAt = readySample.timestamp + TimeInterval(dwellSeconds)
                dwellEndsAt = endsAt
                if let nextWarmMode, nextWarmMode.warmsRequest {
                    let leadMilliseconds = nextWarmMode.stagesTransport
                        ? transportWarmLeadMilliseconds
                        : requestWarmLeadMilliseconds
                    nextWarmStartsAt = max(
                        readySample.timestamp,
                        endsAt - TimeInterval(leadMilliseconds) / 1_000
                    )
                }
                dwellContinuity = DwellContinuityMonitor(
                    startingAt: readySample,
                    expectsAudio: expectsAudio,
                    audioDiagnostics: engine.vlcAudioOutputDiagnostics
                )
                try? HTSPTuningFailureCaptureRegistry.shared.updateActiveAttemptPhase("dwell")
                phase = "Attempt \(attempt) of \(totalAttempts): playing \(channel.name) for \(dwellSeconds) seconds"
            }
            if var continuity = dwellContinuity {
                continuity.observe(
                    cadenceSample,
                    expectsAudio: expectsAudio,
                    audioDiagnostics: engine.vlcAudioOutputDiagnostics
                )
                dwellContinuity = continuity
            }
            if nextWarmTask == nil,
               let nextWarmChannel,
               let nextWarmMode,
               let nextWarmStartsAt,
               now >= nextWarmStartsAt {
                nextWarmTask = Task { @MainActor [weak self] in
                    guard let self else { return nil }
                    return await self.warmRequest(
                        for: nextWarmChannel,
                        using: client,
                        stageTransport: nextWarmMode.stagesTransport,
                        captureAttempt: attempt + 1
                    )
                }
            }
            previousOutput = output

            if case .failed = engine.state { break }
            if let dwellEndsAt, now >= dwellEndsAt { break }
            if productionReadinessProbe.isComplete,
               productionReadinessProbe.readySample == nil {
                break
            }
            try await Task.sleep(for: .milliseconds(sampleIntervalMilliseconds))
        }

        if !productionReadinessProbe.isComplete {
            productionReadinessTask.cancel()
        }
        let reachedProductionReady = await productionReadinessTask.value
        let finishedAt = monotonicNow
        engine.refreshPlaybackInformation()
        let output = counters
        let health = engine.nativeTimeshiftHealthSnapshot
        if var continuity = dwellContinuity {
            continuity.finish(
                at: finishedAt,
                output: output,
                audioDiagnostics: engine.vlcAudioOutputDiagnostics
            )
            dwellContinuity = continuity
        }

        result.playToHTSPVideoMilliseconds = optionalElapsedMilliseconds(
            from: playStartedAt,
            to: firstHTSPVideoAt
        )
        result.playToHTSPAudioMilliseconds = optionalElapsedMilliseconds(
            from: playStartedAt,
            to: firstHTSPAudioAt
        )
        result.playToFirstPictureMilliseconds = optionalElapsedMilliseconds(
            from: playStartedAt,
            to: firstVLCPictureAt
        )
        result.playToFirstAudioMilliseconds = optionalElapsedMilliseconds(
            from: playStartedAt,
            to: firstVLCAudioAt
        )
        result.playToReadyMilliseconds = optionalElapsedMilliseconds(
            from: playStartedAt,
            to: productionReadinessProbe.readySample?.timestamp
        )
        result.startupMaximumVideoGapMilliseconds = startupCadence.longestGap.map {
            elapsedMilliseconds(from: $0.start.timestamp, to: $0.end.timestamp)
        }
        if let readyAt = productionReadinessProbe.readySample?.timestamp {
            result.dwellObservedMilliseconds = elapsedMilliseconds(
                from: readyAt,
                to: min(finishedAt, dwellEndsAt ?? finishedAt)
            )
        }
        result.dwellMaximumVideoGapMilliseconds = dwellContinuity.map {
            Int(($0.maximumVideoGap * 1_000).rounded())
        }
        result.dwellMaximumAudioGapMilliseconds = dwellContinuity.flatMap {
            $0.expectsAudio ? Int(($0.maximumAudioGap * 1_000).rounded()) : nil
        }
        result.displayedPictures = output.displayedPictures
        result.playedAudioBuffers = output.playedAudioBuffers
        result.decodedVideo = output.decodedVideo
        result.decodedAudio = output.decodedAudio
        result.videoPackets = health?.videoPacketCount ?? 0
        result.audioPackets = health?.audioPacketCount ?? 0
        result.lostPictures = max(0, output.lostPictures - prePlayOutput.lostPictures)
        result.lostAudioBuffers = max(0, output.lostAudioBuffers - prePlayOutput.lostAudioBuffers)
        result.dwellLostPictures = dwellContinuity?.lostPictureDelta ?? 0
        result.dwellLostAudioBuffers = dwellContinuity?.lostAudioBufferDelta ?? 0
        result.recoveryCount = max(0, engine.nativeTimeshiftRecoveryCount - recoveryCountAtPlay)
        result.audioExpected = expectsAudio
        result.audioDiagnosticsAdvanced = dwellContinuity?.audioDiagnosticsAdvanced == true

        var reasons: [String] = []
        if !reachedProductionReady || productionReadinessProbe.readySample == nil {
            reasons.append("initial-output-not-ready")
        }
        if case .failed = engine.state { reasons.append("engine-failed") }
        if result.candidateExpected, !result.candidateHit {
            reasons.append("candidate-miss")
        }
        if result.candidateExpected,
           result.candidateHit,
           result.candidateAligned != true {
            reasons.append("candidate-unaligned")
        }
        if result.recoveryCount > 0 { reasons.append("pipeline-recovered") }
        if startupCadence.longestConfirmedStall != nil { reasons.append("startup-video-stall") }
        // VLC's loss counters are useful quality diagnostics, but an isolated
        // increment does not establish a visible or audible interruption. The
        // cadence and output probes below classify corroborated continuity
        // failures; retain uncorroborated losses as structured warnings.
        var qualityWarnings: [String] = []
        if result.dwellLostPictures > 0 { qualityWarnings.append("lost-video-output") }
        if result.dwellLostAudioBuffers > 0 { qualityWarnings.append("lost-audio-output") }
        if let audioGap = result.dwellMaximumAudioGapMilliseconds, audioGap >= 500 {
            qualityWarnings.append("audio-output-statistic-gap")
        }
        if engine.mediaPlayer.rate > 1.01 { reasons.append("accelerated-playback") }
        if let dwellContinuity {
            if dwellContinuity.videoStalled { reasons.append("dwell-video-stall") }
            if dwellContinuity.audioStalled { reasons.append("dwell-audio-stall") }
            if dwellContinuity.videoCounterReset { reasons.append("video-counter-reset") }
            if dwellContinuity.audioCounterReset { reasons.append("audio-counter-reset") }
            if dwellSeconds > 0, !dwellContinuity.observedVideoAdvance {
                reasons.append("no-dwell-video-output")
            }
            if dwellSeconds > 0,
               dwellContinuity.expectsAudio,
               !dwellContinuity.observedAudioAdvance {
                reasons.append("no-dwell-audio-output")
            }
            if dwellContinuity.audioDiagnosticsAdvanced {
                reasons.append("audio-underrun-or-clock-correction")
            }
        }
        result.suspiciousReasons = Array(Set(reasons)).sorted()
        result.qualityWarnings = qualityWarnings
        result.success = result.suspiciousReasons.isEmpty
        if !result.success { failureCount += 1 }

        let codecs = health?.audioStreamTypes.joined(separator: ",").nilIfEmpty ?? "none"
        var detail = "mode=\(result.mode) requestSource=\(result.requestSource) "
            + "request=\(formattedMilliseconds(result.requestMilliseconds)) "
            + "vlcStop=\(formattedMilliseconds(result.vlcStopMilliseconds)) "
            + "prepare=\(formattedMilliseconds(result.prepareMilliseconds)) "
            + "candidate=\(result.candidateHit ? "hit" : (result.candidateExpected ? "miss" : "none")) "
            + "aligned=\(result.candidateAligned.map { String($0) } ?? "n/a") "
            + "staged=\(formattedMilliseconds(result.candidateStagedDurationMilliseconds)) "
            + "promotion=\(formattedMilliseconds(result.candidatePromotionMilliseconds)) "
            + "payload=\(result.candidatePayloadBytes.map { String($0) } ?? "n/a")B "
            + "htspVideo=\(formattedMilliseconds(result.playToHTSPVideoMilliseconds)) "
            + "htspAudio=\(formattedMilliseconds(result.playToHTSPAudioMilliseconds)) "
            + "vlcVideo=\(formattedMilliseconds(result.playToFirstPictureMilliseconds)) "
            + "vlcAudio=\(formattedMilliseconds(result.playToFirstAudioMilliseconds)) "
            + "ready=\(formattedMilliseconds(result.playToReadyMilliseconds)) "
            + "dwell=\(result.dwellObservedMilliseconds)ms "
            + "codec=\(codecs) packets=\(result.videoPackets)v/\(result.audioPackets)a "
            + "decoded=\(result.decodedVideo)v/\(result.decodedAudio)a "
            + "output=\(result.displayedPictures)v/\(result.playedAudioBuffers)a "
            + "reasons=\(result.suspiciousReasons.joined(separator: ",").nilIfEmpty ?? "none") "
            + "warnings=\(result.qualityWarnings.joined(separator: ",").nilIfEmpty ?? "none")"
        if let startup = health?.transportStartup {
            detail += " | tsStartup={\(startup.summary)}"
        }
        if let diagnostic = engine.lastNativePipelineDiagnostic {
            detail += " | \(diagnostic)"
        }
        detail += " | " + startupContinuitySummary(
            startupCadence.longestConfirmedStall ?? startupCadence.longestGap,
            confirmedStall: startupCadence.longestConfirmedStall != nil
        )
        append(
            result.success ? .success : .failure,
            "#\(attempt) \(channel.name): \(result.success ? "ready and continuous" : "suspect")",
            detail
        )
        finishFailureCapture(for: result, diagnosticSummary: detail)

        if !result.success {
            nextWarmTask?.cancel()
            await HTSPLiveCandidatePool.shared.cancel()
            return TuneOutcome(sample: result, nextWarmedRequest: nil)
        }
        let nextWarmedRequest = await nextWarmTask?.value
        return TuneOutcome(sample: result, nextWarmedRequest: nextWarmedRequest)
    }

    private func warmRequest(
        for channel: Channel,
        using client: TVHeadendClient,
        stageTransport: Bool,
        captureAttempt: Int
    ) async -> WarmedRequest? {
        let startedAt = monotonicNow
        do {
            let request = applyingBenchmarkTuningPolicy(
                to: try await client.livePlaybackRequest(
                    channelID: channel.playlistID ?? String(channel.id)
                )
            )
            guard !Task.isCancelled else {
                if stageTransport { await HTSPLiveCandidatePool.shared.cancel() }
                return nil
            }
            let readyAt = monotonicNow
            var candidateStagedAt: TimeInterval?
            if stageTransport {
                if let descriptor = HTSPLiveCandidateDescriptor(request) {
                    HTSPTuningFailureCaptureRegistry.shared.associateCandidateRecorder(
                        channelID: descriptor.channelID,
                        withAttempt: captureAttempt
                    )
                    await HTSPLiveCandidatePool.shared.stage(descriptor)
                    guard !Task.isCancelled else {
                        await HTSPLiveCandidatePool.shared.cancel()
                        return nil
                    }
                    candidateStagedAt = monotonicNow
                } else {
                    await HTSPLiveCandidatePool.shared.cancel()
                    append(
                        .warning,
                        "Could not stage \(channel.name)'s HTSP transport",
                        "The playback request does not use native Tvheadend timeshift."
                    )
                }
            }
            return WarmedRequest(
                channelID: channel.id,
                request: request,
                startedAt: startedAt,
                readyAt: readyAt,
                candidateStagedAt: candidateStagedAt
            )
        } catch {
            if stageTransport {
                await HTSPLiveCandidatePool.shared.cancel()
            }
            append(
                .warning,
                "Could not prefetch \(channel.name)'s playback request",
                error.localizedDescription
            )
            return nil
        }
    }

    private var counters: PlaybackOutputCounters {
        let statistics = engine.mediaPlayer.media?.statistics
        func count(_ value: UInt64) -> Int {
            value <= UInt64(Int.max) ? Int(value) : 0
        }
        return PlaybackOutputCounters(
            displayedPictures: count(statistics?.displayedPictures ?? 0),
            playedAudioBuffers: count(statistics?.playedAudioBuffers ?? 0),
            demuxDiscontinuities: count(statistics?.demuxDiscontinuity ?? 0),
            playbackTimeMilliseconds: engine.mediaPlayer.time.intValue > 0
                ? Int64(engine.mediaPlayer.time.intValue)
                : nil,
            decodedVideo: count(statistics?.decodedVideo ?? 0),
            decodedAudio: count(statistics?.decodedAudio ?? 0),
            lostPictures: count(statistics?.lostPictures ?? 0),
            lostAudioBuffers: count(statistics?.lostAudioBuffers ?? 0)
        )
    }

    private struct StartupContinuitySample {
        let timestamp: TimeInterval
        let output: PlaybackOutputCounters
        let videoPackets: Int64
        let audioPackets: Int64
        let queuedBytes: Int64
    }

    @MainActor
    private final class ProductionReadinessProbe {
        var readySample: StartupContinuitySample?
        var isComplete = false
    }

    private struct VideoCadenceMonitor {
        private var previousOutput: PlaybackOutputCounters?
        private var lastPictureAdvance: StartupContinuitySample?
        private var lastFlatPictureSample: StartupContinuitySample?

        private(set) var longestGap: StartupContinuityGap?
        private(set) var longestConfirmedStall: StartupContinuityGap?

        mutating func observe(_ sample: StartupContinuitySample) {
            guard let previousOutput else {
                self.previousOutput = sample.output
                if sample.output.displayedPictures > 0 { lastPictureAdvance = sample }
                return
            }
            let countersReset = sample.output.displayedPictures < previousOutput.displayedPictures
            let pictureAdvanced = sample.output.displayedPictures > previousOutput.displayedPictures
            if countersReset {
                lastPictureAdvance = nil
                lastFlatPictureSample = nil
            } else if pictureAdvanced {
                if let lastPictureAdvance {
                    let closedGap = StartupContinuityGap(
                        start: lastPictureAdvance,
                        end: sample,
                        evidenceEnd: lastFlatPictureSample
                    )
                    longestGap = longer(longestGap, closedGap)
                    let hasRecentFlatEvidence = lastFlatPictureSample.map {
                        sample.timestamp - $0.timestamp <= 0.15
                    } == true
                    if closedGap.isVisibleStall, hasRecentFlatEvidence {
                        longestConfirmedStall = longer(longestConfirmedStall, closedGap)
                    }
                }
                lastPictureAdvance = sample
                lastFlatPictureSample = nil
            } else if let lastPictureAdvance {
                let openGap = StartupContinuityGap(start: lastPictureAdvance, end: sample)
                longestGap = longer(longestGap, openGap)
                if openGap.isVisibleStall {
                    longestConfirmedStall = longer(longestConfirmedStall, openGap)
                }
                lastFlatPictureSample = sample
            }
            self.previousOutput = sample.output
        }

        private func longer(
            _ current: StartupContinuityGap?,
            _ candidate: StartupContinuityGap
        ) -> StartupContinuityGap {
            guard let current else { return candidate }
            return candidate.duration > current.duration ? candidate : current
        }
    }

    private struct DwellContinuityMonitor {
        private var previousOutput: PlaybackOutputCounters
        private var lastVideoAdvanceAt: TimeInterval
        private var lastAudioAdvanceAt: TimeInterval
        private var latestTimestamp: TimeInterval
        private let initialAudioDiagnostics: VLCAudioOutputDiagnostics
        private let initialLostPictures: Int
        private let initialLostAudioBuffers: Int

        private(set) var expectsAudio: Bool
        private(set) var maximumVideoGap: TimeInterval = 0
        private(set) var maximumAudioGap: TimeInterval = 0
        private(set) var observedVideoAdvance = false
        private(set) var observedAudioAdvance = false
        private(set) var videoStalled = false
        private(set) var audioStalled = false
        private(set) var videoCounterReset = false
        private(set) var audioCounterReset = false
        private(set) var audioDiagnosticsAdvanced = false

        init(
            startingAt sample: StartupContinuitySample,
            expectsAudio: Bool,
            audioDiagnostics: VLCAudioOutputDiagnostics
        ) {
            previousOutput = sample.output
            lastVideoAdvanceAt = sample.timestamp
            lastAudioAdvanceAt = sample.timestamp
            latestTimestamp = sample.timestamp
            initialAudioDiagnostics = audioDiagnostics
            initialLostPictures = sample.output.lostPictures
            initialLostAudioBuffers = sample.output.lostAudioBuffers
            self.expectsAudio = expectsAudio
        }

        var lostPictureDelta: Int {
            max(0, previousOutput.lostPictures - initialLostPictures)
        }

        var lostAudioBufferDelta: Int {
            max(0, previousOutput.lostAudioBuffers - initialLostAudioBuffers)
        }

        mutating func observe(
            _ sample: StartupContinuitySample,
            expectsAudio: Bool,
            audioDiagnostics: VLCAudioOutputDiagnostics
        ) {
            guard sample.timestamp >= latestTimestamp else { return }
            if !self.expectsAudio, expectsAudio {
                self.expectsAudio = true
                lastAudioAdvanceAt = sample.timestamp
            }

            if sample.output.displayedPictures < previousOutput.displayedPictures {
                videoCounterReset = true
                lastVideoAdvanceAt = sample.timestamp
            } else if sample.output.displayedPictures > previousOutput.displayedPictures {
                observedVideoAdvance = true
                maximumVideoGap = max(maximumVideoGap, sample.timestamp - lastVideoAdvanceAt)
                lastVideoAdvanceAt = sample.timestamp
            } else {
                let gap = sample.timestamp - lastVideoAdvanceAt
                maximumVideoGap = max(maximumVideoGap, gap)
                if gap >= 0.75 { videoStalled = true }
            }

            if self.expectsAudio {
                if sample.output.playedAudioBuffers < previousOutput.playedAudioBuffers {
                    audioCounterReset = true
                    lastAudioAdvanceAt = sample.timestamp
                } else if sample.output.playedAudioBuffers > previousOutput.playedAudioBuffers {
                    observedAudioAdvance = true
                    maximumAudioGap = max(maximumAudioGap, sample.timestamp - lastAudioAdvanceAt)
                    lastAudioAdvanceAt = sample.timestamp
                } else {
                    let gap = sample.timestamp - lastAudioAdvanceAt
                    maximumAudioGap = max(maximumAudioGap, gap)
                    // VLC publishes playedAudioBuffers in batches, and healthy
                    // output routinely appears flat for roughly 0.5-0.8 s
                    // without a CoreAudio underrun or audible interruption.
                    // The production startup watchdog uses 1.5 s to identify
                    // a stream that really stopped; use the same boundary here
                    // while retaining shorter gaps as quality warnings.
                    if gap >= 1.5 { audioStalled = true }
                }
            }
            if audioDiagnostics.hasAdvanced(since: initialAudioDiagnostics) {
                audioDiagnosticsAdvanced = true
            }
            previousOutput = sample.output
            latestTimestamp = sample.timestamp
        }

        mutating func finish(
            at timestamp: TimeInterval,
            output: PlaybackOutputCounters,
            audioDiagnostics: VLCAudioOutputDiagnostics
        ) {
            let sample = StartupContinuitySample(
                timestamp: timestamp,
                output: output,
                videoPackets: 0,
                audioPackets: 0,
                queuedBytes: 0
            )
            observe(sample, expectsAudio: expectsAudio, audioDiagnostics: audioDiagnostics)
        }
    }

    private struct StartupContinuityGap {
        let start: StartupContinuitySample
        let end: StartupContinuitySample
        let evidenceEnd: StartupContinuitySample?

        init(
            start: StartupContinuitySample,
            end: StartupContinuitySample,
            evidenceEnd: StartupContinuitySample? = nil
        ) {
            self.start = start
            self.end = end
            self.evidenceEnd = evidenceEnd
        }

        var duration: TimeInterval { max(0, end.timestamp - start.timestamp) }
        private var evidence: StartupContinuitySample { evidenceEnd ?? end }
        var videoPacketDelta: Int64 { max(0, evidence.videoPackets - start.videoPackets) }
        var audioPacketDelta: Int64 { max(0, evidence.audioPackets - start.audioPackets) }
        var decodedVideoDelta: Int {
            max(0, evidence.output.decodedVideo - start.output.decodedVideo)
        }
        var lostPictureDelta: Int {
            max(0, evidence.output.lostPictures - start.output.lostPictures)
        }
        var audioOutputDelta: Int {
            max(0, evidence.output.playedAudioBuffers - start.output.playedAudioBuffers)
        }
        var mediaTimeDelta: Int64 {
            guard let startTime = start.output.playbackTimeMilliseconds,
                  let endTime = evidence.output.playbackTimeMilliseconds
            else { return 0 }
            return max(0, endTime - startTime)
        }
        var isVisibleStall: Bool { duration >= 0.75 }
        var classification: String {
            guard isVisibleStall else { return "continuous" }
            if lostPictureDelta > 0 { return "dropped-video-output" }
            if decodedVideoDelta > 0 {
                return audioOutputDelta > 0 || mediaTimeDelta > 0
                    ? "av-clock-wait"
                    : "video-output-wait"
            }
            if videoPacketDelta > 0 { return "demux/decode-wait" }
            if start.queuedBytes > 0 || evidence.queuedBytes > 0 {
                return "demux/decode-wait"
            }
            return "source-starvation"
        }
    }

    private func longerGap(
        _ current: StartupContinuityGap?,
        _ candidate: StartupContinuityGap
    ) -> StartupContinuityGap {
        guard let current else { return candidate }
        return candidate.duration > current.duration ? candidate : current
    }

    private func startupContinuitySummary(
        _ gap: StartupContinuityGap?,
        confirmedStall: Bool,
        label: String = "startupContinuity"
    ) -> String {
        guard let gap else { return "\(label)={no displayed-picture cadence}" }
        return String(
            format: "\(label)={gap=%.0fms class=%@ confirmed=%@ htsp=%lldv/%llda decoded=%d lost=%d audio=%d clock=%lldms queue=%lld→%lldB}",
            gap.duration * 1_000,
            gap.classification,
            confirmedStall ? "yes" : "no",
            gap.videoPacketDelta,
            gap.audioPacketDelta,
            gap.decodedVideoDelta,
            gap.lostPictureDelta,
            gap.audioOutputDelta,
            gap.mediaTimeDelta,
            gap.start.queuedBytes,
            gap.end.queuedBytes
        )
    }

    private var requestedAttemptCount: Int {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--tuning-attempts=") {
            return max(1, Int(argument.dropFirst("--tuning-attempts=".count)) ?? 20)
        }
        return 20
    }

    private var dwellSeconds: Int {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--tuning-dwell-seconds=") {
            return max(0, Int(argument.dropFirst("--tuning-dwell-seconds=".count)) ?? 10)
        }
        return 10
    }

    private var requestedChannelIndex: Int? {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--tuning-channel-index=") {
            return Int(argument.dropFirst("--tuning-channel-index=".count))
        }
        return nil
    }

    private var tuningMode: TuningMode {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--tuning-mode=") {
            return TuningMode(rawValue: String(argument.dropFirst("--tuning-mode=".count))) ?? .cold
        }
        return .cold
    }

    private var tuningDirection: TuningDirection {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--tuning-direction=") {
            return TuningDirection(
                rawValue: String(argument.dropFirst("--tuning-direction=".count))
            ) ?? .up
        }
        return .up
    }

    private var requestWarmLeadMilliseconds: Int {
        for argument in ProcessInfo.processInfo.arguments
            where argument.hasPrefix("--tuning-request-warm-lead-ms=") {
            return max(
                0,
                Int(argument.dropFirst("--tuning-request-warm-lead-ms=".count)) ?? 2_000
            )
        }
        return 2_000
    }

    private var transportWarmLeadMilliseconds: Int {
        for argument in ProcessInfo.processInfo.arguments
            where argument.hasPrefix("--tuning-transport-warm-lead-ms=") {
            return max(
                0,
                Int(argument.dropFirst("--tuning-transport-warm-lead-ms=".count)) ?? 4_000
            )
        }
        return 4_000
    }

    private var benchmarkVLCCacheMilliseconds: Int {
        for argument in ProcessInfo.processInfo.arguments
            where argument.hasPrefix("--tuning-vlc-cache-ms=") {
            return max(
                0,
                Int(argument.dropFirst("--tuning-vlc-cache-ms=".count)) ?? 1_500
            )
        }
        return 1_500
    }

    private var benchmarkInitialHorizonMilliseconds: Int {
        for argument in ProcessInfo.processInfo.arguments
            where argument.hasPrefix("--tuning-initial-horizon-ms=") {
            return max(
                0,
                Int(argument.dropFirst("--tuning-initial-horizon-ms=".count)) ?? 500
            )
        }
        return 500
    }

    private var benchmarkTuningPolicy: NativeTimeshiftTuningPolicy {
        let production = NativeTimeshiftTuningPolicy()
        return NativeTimeshiftTuningPolicy(
            vlcCacheMilliseconds: benchmarkVLCCacheMilliseconds,
            initialHorizonMilliseconds: benchmarkInitialHorizonMilliseconds,
            // A tuning sweep must not alter seek behavior. Keep the production
            // reserve and every non-tuning gate fixed.
            postSeekReserveMilliseconds: production.postSeekReserveMilliseconds,
            alignedRevealDuration: production.alignedRevealDuration,
            fallbackRevealDuration: production.fallbackRevealDuration,
            revealPollInterval: production.revealPollInterval,
            initialStageTimeout: production.initialStageTimeout
        )
    }

    private func applyingBenchmarkTuningPolicy(
        to request: LiveStreamRequest
    ) -> LiveStreamRequest {
        guard case let .live(.nativeTimeshift(htsp)) = request.kind else { return request }
        let tunedHTSP = HTSPPlaybackConfiguration(
            configuration: htsp.configuration,
            channelID: htsp.channelID,
            tuningPolicy: benchmarkTuningPolicy
        )
        return LiveStreamRequest(
            url: request.url,
            networkCachingMilliseconds: request.networkCachingMilliseconds,
            profile: request.profile,
            kind: .live(.nativeTimeshift(tunedHTSP)),
            expectedDurationSeconds: request.expectedDurationSeconds,
            cachedAddressRoutes: request.cachedAddressRoutes
        )
    }

    private var sampleIntervalMilliseconds: Int {
        for argument in ProcessInfo.processInfo.arguments
            where argument.hasPrefix("--tuning-sample-ms=") {
            return min(
                250,
                max(20, Int(argument.dropFirst("--tuning-sample-ms=".count)) ?? 50)
            )
        }
        return 50
    }

    private var standbyPreconnectEnabled: Bool {
        !ProcessInfo.processInfo.arguments.contains("--tuning-disable-standby-preconnect")
    }

    private var failureCaptureEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--tuning-capture-failures")
    }

    private var tuningProtocolNonce: String? {
        for argument in ProcessInfo.processInfo.arguments
            where argument.hasPrefix("--tuning-protocol-nonce=") {
            let nonce = String(argument.dropFirst("--tuning-protocol-nonce=".count))
            return nonce.isEmpty ? nil : nonce
        }
        return nil
    }

    private var monotonicNow: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func elapsedMilliseconds(from start: TimeInterval, to end: TimeInterval) -> Int {
        Int((max(0, end - start) * 1_000).rounded())
    }

    private func optionalElapsedMilliseconds(
        from start: TimeInterval,
        to end: TimeInterval?
    ) -> Int? {
        end.map { elapsedMilliseconds(from: start, to: $0) }
    }

    private func formattedMilliseconds(_ value: Int?) -> String {
        value.map { "\($0)ms" } ?? "never"
    }

    private func aggregate(
        for samples: [TuningAttemptSample],
        mode: String
    ) -> TuningAggregate {
        let warmHits = samples.filter(\.requestWarmHit).count
        let requestWarmSamples = samples.filter {
            $0.mode == TuningMode.requestWarm.rawValue
                || $0.mode == TuningMode.transportWarm.rawValue
        }
        let candidateSamples = samples.filter(\.candidateExpected)
        return TuningAggregate(
            mode: mode,
            direction: tuningDirection.rawValue,
            vlcCacheMilliseconds: benchmarkTuningPolicy.vlcCacheMilliseconds,
            initialHorizonMilliseconds: benchmarkTuningPolicy.initialHorizonMilliseconds,
            attempts: samples.count,
            successfulAttempts: samples.filter(\.success).count,
            suspiciousAttempts: samples.filter { !$0.success }.count,
            requestWarmHits: warmHits,
            requestWarmMisses: requestWarmSamples.count - warmHits,
            candidateExpectedAttempts: candidateSamples.count,
            candidateHits: candidateSamples.filter(\.candidateHit).count,
            candidateMisses: candidateSamples.filter { !$0.candidateHit }.count,
            candidateAlignedHits: candidateSamples.filter {
                $0.candidateHit && $0.candidateAligned == true
            }.count,
            candidateStageLeadP50Milliseconds: percentile(
                candidateSamples.compactMap(\.candidateStageLeadMilliseconds),
                0.50
            ),
            candidateStagedP50Milliseconds: percentile(
                candidateSamples.compactMap(\.candidateStagedDurationMilliseconds),
                0.50
            ),
            candidatePromotionP50Milliseconds: percentile(
                candidateSamples.compactMap(\.candidatePromotionMilliseconds),
                0.50
            ),
            candidatePayloadP50Bytes: percentile(
                candidateSamples.compactMap(\.candidatePayloadBytes),
                0.50
            ),
            requestP50Milliseconds: percentile(samples.compactMap(\.requestMilliseconds), 0.50),
            requestP95Milliseconds: percentile(samples.compactMap(\.requestMilliseconds), 0.95),
            playToReadyP50Milliseconds: percentile(
                samples.compactMap(\.playToReadyMilliseconds),
                0.50
            ),
            playToReadyP95Milliseconds: percentile(
                samples.compactMap(\.playToReadyMilliseconds),
                0.95
            ),
            playToReadyP99Milliseconds: percentile(
                samples.compactMap(\.playToReadyMilliseconds),
                0.99
            ),
            startupVideoGapP95Milliseconds: percentile(
                samples.compactMap(\.startupMaximumVideoGapMilliseconds),
                0.95
            ),
            dwellVideoGapP95Milliseconds: percentile(
                samples.compactMap(\.dwellMaximumVideoGapMilliseconds),
                0.95
            ),
            dwellAudioGapP95Milliseconds: percentile(
                samples.compactMap(\.dwellMaximumAudioGapMilliseconds),
                0.95
            )
        )
    }

    private func percentile(_ values: [Int], _ quantile: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let ordered = values.sorted()
        let rank = max(0, min(ordered.count - 1, Int(ceil(quantile * Double(ordered.count))) - 1))
        return ordered[rank]
    }

    private func emitStructured<T: Encodable>(_ prefix: String, _ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8)
        else { return }
        if let tuningProtocolNonce {
            print("\(prefix) \(tuningProtocolNonce) \(json)")
        } else {
            print("\(prefix) \(json)")
        }
        fflush(stdout)
    }

    private func finishFailureCapture(
        for sample: TuningAttemptSample,
        diagnosticSummary: String
    ) {
        guard failureCaptureEnabled else { return }
        guard !sample.success else {
            HTSPTuningFailureCaptureRegistry.shared.discardFinishedAttempt(
                attempt: sample.attempt
            )
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let benchmarkSample = try encoder.encode(sample)
            let temporaryRoot = FileManager.default.temporaryDirectory.appending(
                path: "TVApp-VLC-Tuning-Failure-Captures",
                directoryHint: .isDirectory
            )
            if let output = try HTSPTuningFailureCaptureRegistry.shared.persistSuspectAttempt(
                attempt: sample.attempt,
                channelID: sample.channelID,
                channelName: sample.channelName,
                suspiciousReasons: sample.suspiciousReasons,
                diagnosticSummary: diagnosticSummary,
                benchmarkSample: benchmarkSample,
                destinationRoot: temporaryRoot
            ) {
                emitStructured(
                    "VLC_TUNING_CAPTURE",
                    FailureCaptureAnnouncement(
                        attempt: sample.attempt,
                        channelID: sample.channelID,
                        path: output.path
                    )
                )
            }
        } catch {
            append(
                .warning,
                "Could not persist tuning failure capture",
                error.localizedDescription
            )
        }
    }

    private func append(_ kind: VLCTuningEvent.Kind, _ title: String, _ detail: String? = nil) {
        let event = VLCTuningEvent(
            elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
            kind: kind,
            title: title,
            detail: detail
        )
        events.append(event)
        print("VLC_TUNING \(event.timestamp) \(title) \(detail ?? "")")
        fflush(stdout)
    }

    private func finish() {
        canRerun = true
        let result = "attempts=\(completedAttempts) suspicious=\(failureCount) "
            + "mode=\(tuningMode.rawValue) direction=\(tuningDirection.rawValue)"
        if let tuningProtocolNonce {
            print("VLC_TUNING_RESULT \(tuningProtocolNonce) \(result)")
        } else {
            print("VLC_TUNING_RESULT \(result)")
        }
        fflush(stdout)
        guard ProcessInfo.processInfo.arguments.contains("--exit-after-benchmark") else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            NSApplication.shared.terminate(nil)
        }
    }

    private enum TuningError: LocalizedError {
        case noChannels

        var errorDescription: String? {
            switch self {
            case .noChannels: "Tvheadend returned no numeric channel IDs."
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
