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
    @Published private(set) var phase = "Discovering TVHeadend…"
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
        append(.success, "Discovered TVHeadend", settings.baseURL.host)
        startRun(settings: settings)
    }

    private func startRun(settings: DiscoveredTVHeadendSettings) {
        runTask?.cancel()
        engine.stop()
        events.removeAll()
        completedAttempts = 0
        failureCount = 0
        totalAttempts = requestedAttemptCount
        canRerun = false
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await run(settings: settings)
            } catch is CancellationError {
                return
            } catch {
                phase = "Tuning benchmark failed"
                append(.failure, "Benchmark stopped", error.localizedDescription)
                finish()
            }
        }
    }

    private func run(settings: DiscoveredTVHeadendSettings) async throws {
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
        phase = "Loading channels…"
        let loadedChannels = try await loadChannels(configuration: configuration)
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

        for attempt in 1...totalAttempts {
            try Task.checkCancellation()
            let channel = channels[(attempt - 1) % channels.count]
            try await tune(channel, attempt: attempt, configuration: configuration, baseURL: settings.baseURL)
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
        finish()
    }

    private func tune(
        _ channel: Channel,
        attempt: Int,
        configuration: TVHeadendConfiguration,
        baseURL: URL
    ) async throws {
        channelName = channel.name
        phase = "Attempt \(attempt) of \(totalAttempts): \(channel.name)"
        engine.stop()
        let started = Date()
        let request = LiveStreamRequest(
            url: baseURL.appending(path: "stream/channelid/\(channel.id)"),
            networkCachingMilliseconds: 1_500,
            profile: configuration.streamProfile,
            kind: .live(
                .nativeTimeshift(
                    HTSPPlaybackConfiguration(configuration: configuration, channelID: channel.id)
                )
            )
        )

        do {
            try await engine.prepare(request)
        } catch {
            failureCount += 1
            append(.failure, "#\(attempt) \(channel.name) could not tune", error.localizedDescription)
            return
        }
        let preparedAt = Date()
        engine.refreshPlaybackInformation()
        let prePlayOutput = counters
        let playStarted = Date()
        engine.play()
        videoAttachmentRevision &+= 1
        await HTSPConnectionPrewarmer.shared.preconnect(configuration: configuration)
        let productionReadinessProbe = ProductionReadinessProbe()
        let productionReadinessTask = Task { @MainActor [weak self, engine] () -> Date? in
            defer { productionReadinessProbe.isComplete = true }
            guard await engine.waitForPlaybackStart(),
                  await engine.waitForInitialPlaybackOutput(),
                  let self
            else { return nil }

            let readyAt = Date()
            let health = engine.nativeTimeshiftHealthSnapshot
            productionReadinessProbe.readySample = StartupContinuitySample(
                date: readyAt,
                output: self.counters,
                videoPackets: health?.videoPacketCount ?? 0,
                audioPackets: health?.audioPacketCount ?? 0,
                queuedBytes: engine.bufferedBytes
            )
            return readyAt
        }
        defer { productionReadinessTask.cancel() }

        var firstHTSPVideoAt: Date?
        var firstHTSPAudioAt: Date?
        var firstVLCPictureAt: Date?
        var firstVLCAudioAt: Date?
        var lastPictureAdvance: StartupContinuitySample?
        var lastFlatPictureSample: StartupContinuitySample?
        var longestPictureGap: StartupContinuityGap?
        var longestConfirmedPictureStall: StartupContinuityGap?
        var continuityWindowEnd: Date?
        var continuityWindowFinished = false
        var previousOutput = prePlayOutput
        var postRevealContinuity: PictureContinuityWindow?
        var expectsAudio = false
        let deadline = playStarted.addingTimeInterval(15)

        while Date() < deadline {
            try Task.checkCancellation()
            engine.refreshPlaybackInformation()
            let now = Date()
            let health = engine.nativeTimeshiftHealthSnapshot
            firstHTSPVideoAt = earliest(firstHTSPVideoAt, health?.firstVideoPacketAt)
            firstHTSPAudioAt = earliest(firstHTSPAudioAt, health?.firstAudioPacketAt)
            expectsAudio = expectsAudio || health?.expectsAudio == true
            let output = counters
            let sample = StartupContinuitySample(
                date: now,
                output: output,
                videoPackets: health?.videoPacketCount ?? 0,
                audioPackets: health?.audioPacketCount ?? 0,
                queuedBytes: engine.bufferedBytes
            )
            let pictureCountersReset = output.displayedPictures
                < previousOutput.displayedPictures
            let pictureAdvanced = output.displayedPictures
                > previousOutput.displayedPictures
            let audioAdvanced = output.playedAudioBuffers
                > previousOutput.playedAudioBuffers
            if pictureCountersReset {
                lastPictureAdvance = nil
                lastFlatPictureSample = nil
                continuityWindowEnd = nil
                continuityWindowFinished = false
            }
            if !continuityWindowFinished, pictureAdvanced {
                continuityWindowEnd = continuityWindowEnd
                    ?? now.addingTimeInterval(2)
                if firstHTSPVideoAt != nil {
                    firstVLCPictureAt = firstVLCPictureAt ?? now
                }
                if let lastPictureAdvance {
                    let closedGap = StartupContinuityGap(
                        start: lastPictureAdvance,
                        end: sample,
                        evidenceEnd: lastFlatPictureSample
                    )
                    longestPictureGap = longerGap(longestPictureGap, closedGap)
                    let hasRecentFlatEvidence = lastFlatPictureSample.map {
                        sample.date.timeIntervalSince($0.date) <= 0.15
                    } == true
                    if closedGap.isVisibleStall, hasRecentFlatEvidence {
                        longestConfirmedPictureStall = longerGap(
                            longestConfirmedPictureStall,
                            closedGap
                        )
                    }
                }
                lastPictureAdvance = sample
                lastFlatPictureSample = nil
            }
            if firstHTSPAudioAt != nil, audioAdvanced {
                firstVLCAudioAt = firstVLCAudioAt ?? now
            }
            if !continuityWindowFinished,
               !pictureAdvanced,
               let lastPictureAdvance {
                let openGap = StartupContinuityGap(start: lastPictureAdvance, end: sample)
                longestPictureGap = longerGap(longestPictureGap, openGap)
                if openGap.isVisibleStall {
                    longestConfirmedPictureStall = longerGap(
                        longestConfirmedPictureStall,
                        openGap
                    )
                }
                lastFlatPictureSample = sample
            }
            previousOutput = output

            if postRevealContinuity == nil,
               let readySample = productionReadinessProbe.readySample {
                postRevealContinuity = PictureContinuityWindow(startingAt: readySample)
            }
            if var window = postRevealContinuity {
                window.observe(sample)
                postRevealContinuity = window
            }

            if !continuityWindowFinished,
               let continuityWindowEnd,
               now >= continuityWindowEnd,
               pictureAdvanced || longestConfirmedPictureStall != nil {
                continuityWindowFinished = true
            }

            if continuityWindowFinished,
               firstVLCPictureAt != nil,
               !expectsAudio || firstVLCAudioAt != nil {
                let productionObservationFinished: Bool
                if productionReadinessProbe.isComplete {
                    productionObservationFinished = productionReadinessProbe.readySample == nil
                        || postRevealContinuity?.isFinished == true
                } else {
                    productionObservationFinished = false
                }
                if productionObservationFinished { break }
            }
            if case .failed = engine.state { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        if !productionReadinessProbe.isComplete { productionReadinessTask.cancel() }
        let productionReadyAt = await productionReadinessTask.value
        let reachedRawReadyOutput = continuityWindowFinished
            && firstVLCPictureAt != nil
            && (!expectsAudio || firstVLCAudioAt != nil)
        let reachedProductionReadyOutput = productionReadyAt != nil
            && postRevealContinuity?.isFinished == true
        let reachedReadyOutput = reachedRawReadyOutput && reachedProductionReadyOutput
        if reachedReadyOutput {
            phase = "Attempt \(attempt) of \(totalAttempts): playing \(channel.name) for \(dwellSeconds) seconds"
            for _ in 0..<(dwellSeconds * 10) {
                try Task.checkCancellation()
                engine.refreshPlaybackInformation()
                if case .failed = engine.state { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        let output = counters
        let health = engine.nativeTimeshiftHealthSnapshot
        let didFail: Bool
        if case .failed = engine.state {
            didFail = true
        } else {
            didFail = false
        }
        let ready = reachedReadyOutput && !didFail
        let recovered = engine.nativeTimeshiftRecoveryCount > 0
        let startupStalled = longestConfirmedPictureStall != nil
        let postRevealStalled = postRevealContinuity?.longestConfirmedPictureStall != nil
        // Raw VLC preroll can pause while the launch surface is still
        // concealing it. Only continuity after the production reveal boundary
        // is a user-visible tuning failure; retain the raw result as a
        // diagnostic without failing the attempt.
        let suspicious = !ready || recovered || postRevealStalled
        if suspicious { failureCount += 1 }

        let codecs = health?.audioStreamTypes.joined(separator: ",").nilIfEmpty ?? "none"
        var detail = "prepare=\(milliseconds(preparedAt, since: started)) "
            + "htspVideo=\(milliseconds(firstHTSPVideoAt, since: started)) "
            + "htspAudio=\(milliseconds(firstHTSPAudioAt, since: started)) "
            + "vlcVideo=\(milliseconds(firstVLCPictureAt, since: started)) "
            + "vlcAudio=\(milliseconds(firstVLCAudioAt, since: started)) "
            + "revealPlayFirst=\(milliseconds(firstVLCPictureAt, since: playStarted)) "
            + "revealFirstReady=\(milliseconds(from: firstVLCPictureAt, to: productionReadyAt)) "
            + "revealPlayReady=\(milliseconds(productionReadyAt, since: playStarted)) "
            + "codec=\(codecs) packets=\(health?.videoPacketCount ?? 0)v/\(health?.audioPacketCount ?? 0)a "
            + "output=\(output.displayedPictures)v/\(output.playedAudioBuffers)a recoveries=\(engine.nativeTimeshiftRecoveryCount)"
        if let startup = health?.transportStartup {
            detail += " | tsStartup={\(startup.summary)}"
        }
        if let diagnostic = engine.lastNativePipelineDiagnostic {
            detail += " | \(diagnostic)"
        }
        let continuitySummary = startupContinuitySummary(
            longestConfirmedPictureStall ?? longestPictureGap,
            confirmedStall: startupStalled
        )
        detail += " | \(continuitySummary)"
        let postRevealSummary = startupContinuitySummary(
            postRevealContinuity?.longestConfirmedPictureStall
                ?? postRevealContinuity?.longestPictureGap,
            confirmedStall: postRevealStalled,
            label: "postRevealContinuity"
        )
        detail += " | \(postRevealSummary)"

        let kind: VLCTuningEvent.Kind = !ready
            ? .failure
            : (recovered || postRevealStalled ? .warning : .success)
        let outcome = !ready
            ? "failed"
            : (recovered
                ? "recovered"
                : (postRevealStalled
                    ? "post-reveal stalled"
                    : (startupStalled ? "ready (startup stall concealed)" : "ready")))
        append(kind, "#\(attempt) \(channel.name): \(outcome)", detail)
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
        let date: Date
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

    private struct PictureContinuityWindow {
        private let targetEnd: Date
        private var previousOutput: PlaybackOutputCounters
        private var lastPictureAdvance: StartupContinuitySample
        private var lastFlatPictureSample: StartupContinuitySample?

        private(set) var longestPictureGap: StartupContinuityGap?
        private(set) var longestConfirmedPictureStall: StartupContinuityGap?
        private(set) var isFinished = false

        init(startingAt sample: StartupContinuitySample) {
            targetEnd = sample.date.addingTimeInterval(2)
            previousOutput = sample.output
            lastPictureAdvance = sample
        }

        mutating func observe(_ sample: StartupContinuitySample) {
            guard !isFinished, sample.date >= lastPictureAdvance.date else { return }

            let countersReset = sample.output.displayedPictures
                < previousOutput.displayedPictures
            let pictureAdvanced = sample.output.displayedPictures
                > previousOutput.displayedPictures
            if countersReset {
                lastPictureAdvance = sample
                lastFlatPictureSample = nil
            } else if pictureAdvanced {
                let closedGap = StartupContinuityGap(
                    start: lastPictureAdvance,
                    end: sample,
                    evidenceEnd: lastFlatPictureSample
                )
                longestPictureGap = longer(longestPictureGap, closedGap)
                let hasRecentFlatEvidence = lastFlatPictureSample.map {
                    sample.date.timeIntervalSince($0.date) <= 0.15
                } == true
                if closedGap.isVisibleStall, hasRecentFlatEvidence {
                    longestConfirmedPictureStall = longer(
                        longestConfirmedPictureStall,
                        closedGap
                    )
                }
                lastPictureAdvance = sample
                lastFlatPictureSample = nil
            } else {
                let openGap = StartupContinuityGap(start: lastPictureAdvance, end: sample)
                longestPictureGap = longer(longestPictureGap, openGap)
                if openGap.isVisibleStall {
                    longestConfirmedPictureStall = longer(
                        longestConfirmedPictureStall,
                        openGap
                    )
                }
                lastFlatPictureSample = sample
            }
            previousOutput = sample.output

            if sample.date >= targetEnd,
               pictureAdvanced || longestConfirmedPictureStall != nil {
                isFinished = true
            }
        }

        private func longer(
            _ current: StartupContinuityGap?,
            _ candidate: StartupContinuityGap
        ) -> StartupContinuityGap {
            guard let current else { return candidate }
            return candidate.duration > current.duration ? candidate : current
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

        var duration: TimeInterval { max(0, end.date.timeIntervalSince(start.date)) }
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

    private func loadChannels(configuration: TVHeadendConfiguration) async throws -> [Channel] {
        try await TVHeadendClient(configuration: configuration).ticketedChannels()
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

    private func earliest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return min(lhs, rhs)
    }

    private func milliseconds(_ date: Date?, since start: Date) -> String {
        guard let date else { return "never" }
        return String(format: "%.0fms", max(0, date.timeIntervalSince(start)) * 1_000)
    }

    private func milliseconds(from start: Date?, to end: Date?) -> String {
        guard let start, let end else { return "never" }
        return String(format: "%.0fms", max(0, end.timeIntervalSince(start)) * 1_000)
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
        print("VLC_TUNING_RESULT attempts=\(completedAttempts) suspicious=\(failureCount)")
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
            case .noChannels: "TVHeadend returned no numeric channel IDs."
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
