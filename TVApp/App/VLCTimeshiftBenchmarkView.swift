#if os(macOS)
import AppKit
import Foundation
import SwiftUI

struct VLCTimeshiftBenchmarkView: View {
    @StateObject private var benchmark = VLCTimeshiftBenchmarkModel()

    var body: some View {
        HStack(spacing: 0) {
            BenchmarkVideoPane(benchmark: benchmark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("VLC Timeshift Benchmark")
                        .font(.title2.bold())
                    Text(benchmark.phase)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: benchmark.progress)
                    .tint(benchmark.isFailed ? .red : .blue)

                Button("Run seeks again") {
                    benchmark.rerunSeeks()
                }
                .disabled(!benchmark.canRerun)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(benchmark.events) { event in
                                BenchmarkEventRow(event: event)
                                    .id(event.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: benchmark.events.count) {
                        guard let last = benchmark.events.last else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(24)
            .frame(width: 520)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(.black)
    }
}

private struct BenchmarkVideoPane: View {
    @ObservedObject var benchmark: VLCTimeshiftBenchmarkModel
    @ObservedObject private var engine: VLCPlaybackEngine

    init(benchmark: VLCTimeshiftBenchmarkModel) {
        self.benchmark = benchmark
        _engine = ObservedObject(wrappedValue: benchmark.engine)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            VLCVideoSurface(mediaPlayer: engine.mediaPlayer)

            if engine.isPlaybackOutputConcealed {
                Color.black
                    .overlay {
                        ProgressView("Waiting for post-seek VLC output…")
                            .controlSize(.large)
                    }
            }

            HStack(spacing: 14) {
                metric("Window", String(format: "%.1fs", engine.timeshiftWindowSeconds))
                metric("Live delay", String(format: "%.1fs", engine.liveDelaySeconds))
                metric("VLC", benchmark.playerState)
            }
            .padding(14)
            .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 12))
            .padding(20)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.medium))
        }
    }
}

private struct BenchmarkEventRow: View {
    let event: VLCTimeshiftBenchmarkEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.symbol)
                .foregroundStyle(event.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.title)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(event.timestamp)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let detail = event.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct VLCTimeshiftBenchmarkEvent: Identifiable {
    enum Kind { case information, navigation, success, failure }

    let id = UUID()
    let elapsed: TimeInterval
    let kind: Kind
    let title: String
    let detail: String?

    var timestamp: String { String(format: "+%06.2fs", elapsed) }
    var symbol: String {
        switch kind {
        case .information: "info.circle.fill"
        case .navigation: "arrow.left.arrow.right.circle.fill"
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }
    var color: Color {
        switch kind {
        case .information: .blue
        case .navigation: .orange
        case .success: .green
        case .failure: .red
        }
    }
}

@MainActor
final class VLCTimeshiftBenchmarkModel: ObservableObject {
    @Published private(set) var events: [VLCTimeshiftBenchmarkEvent] = []
    @Published private(set) var phase = "Discovering TVHeadend…"
    @Published private(set) var progress = 0.0
    @Published private(set) var isFailed = false
    @Published private(set) var canRerun = false

    let engine = VLCPlaybackEngine()

    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var discovery: TVHeadendDiscovery?
    private var runTask: Task<Void, Never>?
    private var hasStarted = false
    private var completedCycleCount = 0

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
            self.start(service: service)
        }
        self.discovery = discovery
        discovery.start()
    }

    private func start(service: DiscoveredTVHeadendService) {
        guard !hasStarted else { return }
        hasStarted = true
        discovery?.stop()
        discovery = nil
        append(.success, "Discovered \(service.name)", service.settings.baseURL.host)

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await run(settings: service.settings)
            } catch {
                fail(error.localizedDescription)
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
        phase = "Resolving a live channel…"
        let channel = try await firstChannel(configuration: configuration)
        append(.information, "Selected \(channel.name)", "HTSP channel ID \(channel.id)")

        let request = LiveStreamRequest(
            url: settings.baseURL.appending(path: "stream/channelid/\(channel.id)"),
            networkCachingMilliseconds: 1_500,
            profile: settings.streamProfile,
            kind: .live(
                .nativeTimeshift(
                    HTSPPlaybackConfiguration(configuration: configuration, channelID: channel.id)
                )
            )
        )
        phase = "Opening VLC playback…"
        try await engine.prepare(request)
        guard engine.activeLivePlaybackMode == .tvHeadend else {
            throw BenchmarkError.nativeTimeshiftUnavailable
        }
        engine.play()
        guard await engine.waitForPlaybackStart() else { throw BenchmarkError.playbackDidNotStart }
        append(.success, "VLC playback started", "Video output is attached to the left pane.")

        phase = "Filling the timeshift buffer (40 seconds)…"
        for second in 1...40 {
            try await Task.sleep(for: .seconds(1))
            engine.refreshPlaybackInformation()
            progress = Double(second) / 46
            if second.isMultiple(of: 5) {
                append(
                    .information,
                    "Buffer fill \(second)s / 40s",
                    String(format: "TVHeadend reports a %.2fs window.", engine.timeshiftWindowSeconds)
                )
            }
        }

        let requestedCycles = automaticCycleCount
        var cycleFailures: [String] = []
        for cycle in 1...requestedCycles {
            if cycle > 1 {
                do {
                    try await resetAtLiveEdge()
                } catch {
                    cycleFailures.append("cycle \(cycle) reset: \(error.localizedDescription)")
                    append(.failure, "Cycle \(cycle) could not reset", error.localizedDescription)
                    continue
                }
            }
            do {
                try await runSeekCycle(number: cycle)
            } catch {
                cycleFailures.append("cycle \(cycle): \(error.localizedDescription)")
                append(.failure, "Cycle \(cycle) failed", error.localizedDescription)
            }
        }
        canRerun = true
        guard cycleFailures.isEmpty else {
            throw BenchmarkError.cyclesFailed(cycleFailures.joined(separator: "; "))
        }
        conclude(succeeded: true)
    }

    func rerunSeeks() {
        guard canRerun else { return }
        canRerun = false
        isFailed = false
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await resetAtLiveEdge()
                try await runSeekCycle(number: completedCycleCount + 1)
                canRerun = true
                conclude(succeeded: true)
            } catch {
                canRerun = true
                fail(error.localizedDescription)
            }
        }
    }

    private func runSeekCycle(number: Int) async throws {
        append(.navigation, "Starting seek cycle \(number)", "Reusing the existing TVHeadend buffer.")
        let deltas: [TimeInterval] = [-25, 15, -15, 15, -15, 15]
        var samples: [SeekSample] = []
        for (index, delta) in deltas.enumerated() {
            phase = "Cycle \(number) · seek \(index + 1) of \(deltas.count)…"
            samples.append(try await measureSeek(delta: delta, number: index + 1))
            phase = "Playing for 3 seconds after seek \(index + 1)…"
            append(.information, "Post-seek playback dwell", "Allowing VLC to run for 3 seconds.")
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                engine.refreshPlaybackInformation()
            }
            append(.success, "Post-seek dwell complete", debugState)
            progress = Double(40 + index + 1) / 46
        }

        completedCycleCount = max(completedCycleCount, number)
        phase = "Seek cycle \(number) complete"
        progress = 1
        appendSummary(
            "Cycle \(number) discontinuity",
            samples.compactMap(\.discontinuityMilliseconds)
        )
        appendSummary("Cycle \(number) first video", samples.map(\.videoMilliseconds))
        appendSummary("Cycle \(number) player ready", samples.map(\.readyMilliseconds))
        append(.success, "Seek cycle \(number) completed", "The TVHeadend session remains available for another run.")
    }

    private func resetAtLiveEdge() async throws {
        phase = "Returning to live before the next cycle…"
        append(.navigation, "Resetting at the live edge", debugState)
        engine.returnToLive()
        let started = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - started < 10 {
            try await Task.sleep(for: .milliseconds(50))
            engine.refreshPlaybackInformation()
            if engine.liveDelaySeconds < 1,
               engine.state == .playing,
               !engine.isPlaybackOutputConcealed {
                append(.success, "Ready for another seek cycle", debugState)
                return
            }
        }
        throw BenchmarkError.resetTimedOut(debugState)
    }

    private func measureSeek(delta: TimeInterval, number: Int) async throws -> SeekSample {
        engine.refreshPlaybackInformation()
        let baseline = counters
        let started = ProcessInfo.processInfo.systemUptime
        append(
            .navigation,
            "Seek \(number): \(delta < 0 ? "back" : "forward") \(Int(abs(delta)))s",
            String(format: "Starting %.2fs behind live; VLC pictures: %d.", engine.liveDelaySeconds, baseline.displayedPictures)
        )
        if delta < 0 {
            engine.skipBackward(by: -delta)
        } else {
            _ = engine.skipForward(by: delta)
        }

        var discontinuityAt: Double?
        var videoAt: Double?
        var audioAt: Double?
        var atDiscontinuity: PlaybackOutputCounters?
        var loggedConcealment = false
        while ProcessInfo.processInfo.systemUptime - started < 10 {
            try await Task.sleep(for: .milliseconds(10))
            engine.refreshPlaybackInformation()
            let now = ProcessInfo.processInfo.systemUptime
            let current = counters
            if discontinuityAt == nil,
               current.demuxDiscontinuities > baseline.demuxDiscontinuities {
                discontinuityAt = now
                atDiscontinuity = current
                append(.information, "VLC consumed discontinuity", elapsedDetail(since: started))
            }
            if engine.isPlaybackOutputConcealed, !loggedConcealment {
                loggedConcealment = true
                append(.information, "Output gate concealed stale frames", elapsedDetail(since: started))
            }
            if let atDiscontinuity {
                if videoAt == nil, current.displayedPictures > atDiscontinuity.displayedPictures {
                    videoAt = now
                    append(.success, "First new VLC video frame", elapsedDetail(since: started))
                }
                if audioAt == nil, current.playedAudioBuffers > atDiscontinuity.playedAudioBuffers {
                    audioAt = now
                    append(.success, "First new VLC audio buffer", elapsedDetail(since: started))
                }
            } else if videoAt == nil,
                      current.displayedPictures > baseline.displayedPictures {
                videoAt = now
            }
            if let videoAt,
               engine.state == .playing, !engine.isPlaybackOutputConcealed {
                let sample = SeekSample(
                    discontinuityMilliseconds: discontinuityAt.map { ($0 - started) * 1_000 },
                    videoMilliseconds: (videoAt - started) * 1_000,
                    audioMilliseconds: audioAt.map { ($0 - started) * 1_000 },
                    readyMilliseconds: (now - started) * 1_000
                )
                append(
                    .success,
                    "Seek \(number) ready in \(format(sample.readyMilliseconds))",
                    "Discontinuity \(sample.discontinuityMilliseconds.map(format) ?? "not reported") · video \(format(sample.videoMilliseconds)) · audio \(sample.audioMilliseconds.map(format) ?? "n/a")"
                )
                return sample
            }
        }
        throw BenchmarkError.seekTimedOut(number, debugState)
    }

    private var debugState: String {
        let current = counters
        let health = engine.nativeTimeshiftHealthSnapshot
        let packetAge = health?.lastMuxPacketAt.map { String(format: "%.2fs", -$0.timeIntervalSinceNow) } ?? "nil"
        return "engine=\(playerState), vlc=\(engine.mediaPlayer.state), playing=\(engine.mediaPlayer.isPlaying), concealed=\(engine.isPlaybackOutputConcealed), navigation=\(engine.timeshiftNavigationDebugState), streamNavigating=\(health?.isNavigating.description ?? "nil"), desiredSpeed=\(health.map { String($0.desiredSpeed) } ?? "nil"), lastPacketAge=\(packetAge), delay=\(String(format: "%.2f", engine.liveDelaySeconds))s, discontinuities=\(current.demuxDiscontinuities), pictures=\(current.displayedPictures), audio=\(current.playedAudioBuffers), time=\(current.playbackTimeMilliseconds.map(String.init) ?? "nil")ms"
    }

    private var automaticCycleCount: Int {
        for argument in ProcessInfo.processInfo.arguments {
            guard argument.hasPrefix("--benchmark-cycles=") else { continue }
            return max(1, Int(argument.dropFirst("--benchmark-cycles=".count)) ?? 1)
        }
        return 1
    }

    private var counters: PlaybackOutputCounters {
        let statistics = engine.mediaPlayer.media?.statistics
        return PlaybackOutputCounters(
            displayedPictures: Int(statistics?.displayedPictures ?? 0),
            playedAudioBuffers: Int(statistics?.playedAudioBuffers ?? 0),
            demuxDiscontinuities: Int(statistics?.demuxDiscontinuity ?? 0),
            playbackTimeMilliseconds: engine.mediaPlayer.time.intValue > 0
                ? Int64(engine.mediaPlayer.time.intValue)
                : nil
        )
    }

    private func firstChannel(
        configuration: TVHeadendConfiguration
    ) async throws -> (id: UInt32, name: String) {
        guard let baseURL = configuration.baseURL else { throw BenchmarkError.invalidPlaylist }
        let url = baseURL
            .appending(path: "playlist/ticket/channels")
            .appending(queryItems: [URLQueryItem(name: "profile", value: configuration.streamProfile)])
        let delegate = VLCTimeshiftBenchmarkAuthentication(configuration: configuration)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let playlist = String(data: data, encoding: .utf8)
        else { throw BenchmarkError.invalidPlaylist }

        var name = "Live channel"
        for rawLine in playlist.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("#EXTINF:") {
                name = line.split(separator: ",", maxSplits: 1).last.map(String.init) ?? name
            } else if !line.hasPrefix("#"), let streamURL = URL(string: line),
                      let channelID = TVHeadendClient.numericChannelID(from: streamURL) {
                return (channelID, name)
            }
        }
        throw BenchmarkError.invalidPlaylist
    }

    private func appendSummary(_ name: String, _ values: [Double]) {
        guard !values.isEmpty else {
            append(.information, "\(name) summary", "VLC did not report this statistic.")
            return
        }
        let sorted = values.sorted()
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
        let p95 = sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        append(
            .information,
            "\(name) summary",
            "min \(format(sorted.first ?? 0)) · median \(format(median)) · p95 \(format(p95)) · max \(format(sorted.last ?? 0))"
        )
    }

    private func append(
        _ kind: VLCTimeshiftBenchmarkEvent.Kind,
        _ title: String,
        _ detail: String? = nil
    ) {
        let event = VLCTimeshiftBenchmarkEvent(
            elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
            kind: kind,
            title: title,
            detail: detail
        )
        events.append(event)
        print("VLC_TIMESHIFT \(event.timestamp) \(title) \(detail ?? "")")
        fflush(stdout)
    }

    private func fail(_ message: String) {
        isFailed = true
        phase = "Benchmark failed"
        append(.failure, "Benchmark failed", message)
        conclude(succeeded: false, detail: message)
    }

    private func conclude(succeeded: Bool, detail: String? = nil) {
        let status = succeeded ? "success" : "failure"
        print("VLC_TIMESHIFT_RESULT \(status) \(detail ?? "")")
        fflush(stdout)
        guard ProcessInfo.processInfo.arguments.contains("--exit-after-benchmark") else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            NSApplication.shared.terminate(nil)
        }
    }

    private func elapsedDetail(since start: TimeInterval) -> String {
        format((ProcessInfo.processInfo.systemUptime - start) * 1_000)
    }

    private func format(_ milliseconds: Double) -> String {
        String(format: "%.1fms", milliseconds)
    }

    private struct SeekSample {
        let discontinuityMilliseconds: Double?
        let videoMilliseconds: Double
        let audioMilliseconds: Double?
        let readyMilliseconds: Double
    }

    private enum BenchmarkError: LocalizedError {
        case invalidPlaylist
        case nativeTimeshiftUnavailable
        case playbackDidNotStart
        case seekTimedOut(Int, String)
        case resetTimedOut(String)
        case cyclesFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPlaylist: "TVHeadend did not return a usable channel playlist."
            case .nativeTimeshiftUnavailable: "The player fell back instead of opening native timeshift."
            case .playbackDidNotStart: "VLC did not begin playback within 10 seconds."
            case let .seekTimedOut(number, state):
                "Seek \(number) produced no post-discontinuity VLC video within 10 seconds. \(state)"
            case let .resetTimedOut(state): "Returning to live timed out. \(state)"
            case let .cyclesFailed(detail): detail
            }
        }
    }
}

private final class VLCTimeshiftBenchmarkAuthentication: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: TVHeadendConfiguration

    init(configuration: TVHeadendConfiguration) {
        self.configuration = configuration
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodHTTPDigest
            || method == NSURLAuthenticationMethodHTTPBasic {
            completionHandler(
                .useCredential,
                URLCredential(
                    user: configuration.username,
                    password: configuration.password,
                    persistence: .forSession
                )
            )
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
#endif
