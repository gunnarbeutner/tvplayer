#if os(macOS)
import AppKit
import Foundation
import SwiftUI

struct VLCTimeshiftBenchmarkView: View {
    @StateObject private var benchmark = VLCTimeshiftBenchmarkModel()

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let presentation = benchmark.presentation {
                    PlaybackView(engine: benchmark.engine, presentation: presentation)
                        .environmentObject(benchmark.settings)
                        .environmentObject(benchmark.playback)
                } else {
                    BenchmarkVideoPane(benchmark: benchmark)
                }
            }
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
            VLCVideoSurface(
                mediaPlayer: engine.mediaPlayer,
                isOutputConcealed: engine.isPlaybackOutputConcealed,
                concealmentImage: engine.pausedFrame
            )

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
    @Published private(set) var presentation: PlaybackPresentation?

    let engine = VLCPlaybackEngine()
    let settings = ServerSettingsStore(
        startsDiscovery: false,
        automaticallyTestsConnections: false
    )
    let playback = PlaybackCoordinator()

    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var discovery: TVHeadendDiscovery?
    private var runTask: Task<Void, Never>?
    private var hasStarted = false
    private var completedCycleCount = 0
    private var maximumObservedTimeshiftWindow: TimeInterval = 0
    private var expectedRecoveryCount = 0

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
        // Mount PlaybackView before opening the media so its real video
        // surface owns VLC attachment for the entire fill and seek run.
        presentation = makePresentation(channel: channel, request: request)
        await Task.yield()
        try await engine.prepare(request)
        guard engine.activeLivePlaybackMode == .tvHeadend else {
            let reason: String? = if case let .liveOnly(reason) = engine.activeLivePlaybackMode {
                reason
            } else {
                nil
            }
            throw BenchmarkError.nativeTimeshiftUnavailable(reason)
        }
        engine.play()
        guard await engine.waitForPlaybackStart() else { throw BenchmarkError.playbackDidNotStart }
        try validateSessionContinuity()
        append(.success, "VLC playback started", "Video output is attached to the left pane.")

        let bufferFillSeconds = automaticBufferFillSeconds
        phase = "Filling the timeshift buffer (\(bufferFillSeconds) seconds)…"
        for second in 1...bufferFillSeconds {
            try await Task.sleep(for: .seconds(1))
            engine.refreshPlaybackInformation()
            try validateSessionContinuity()
            progress = Double(second) / Double(bufferFillSeconds + 6)
            if second.isMultiple(of: 5) {
                append(
                    .information,
                    "Buffer fill \(second)s / \(bufferFillSeconds)s",
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
                    if error is BenchmarkContinuityError { throw error }
                    cycleFailures.append("cycle \(cycle) reset: \(error.localizedDescription)")
                    append(.failure, "Cycle \(cycle) could not reset", error.localizedDescription)
                    continue
                }
            }
            do {
                try await runSeekCycle(number: cycle)
            } catch {
                if error is BenchmarkContinuityError { throw error }
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
        engine.refreshPlaybackInformation()
        let seekableWindow = engine.timeshiftWindowSeconds
        let targetPercentages: [Double] = [0.10, 0.50, 0.90, 0.20, 0.80, 0]
        let seekCount = targetPercentages.count
        append(
            .information,
            "Seek targets based on buffer window",
            String(
                format: "Window %.2fs; targets 10%%, 50%%, 90%%, 20%%, 80%%, then live.",
                seekableWindow
            )
        )
        var samples: [SeekSample] = []
        for index in 0..<seekCount {
            phase = "Cycle \(number) · seek \(index + 1) of \(seekCount)…"
            let targetPercentage = targetPercentages[index]
            samples.append(
                try await measureSeek(
                    targetLiveDelay: seekableWindow * targetPercentage,
                    targetPercentage: targetPercentage,
                    number: index + 1
                )
            )
            phase = "Playing for 10 seconds after seek \(index + 1)…"
            append(
                .information,
                "Post-seek playback dwell",
                "Monitoring normal-rate audio and uninterrupted video for 10 seconds."
            )
            try await validatePostSeekDwell(seekNumber: index + 1)
            append(.success, "Post-seek dwell complete", debugState)
            progress = Double(automaticBufferFillSeconds + index + 1)
                / Double(automaticBufferFillSeconds + seekCount)
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
        engine.refreshPlaybackInformation()
        try validateSessionContinuity()
        if isReadyAtLiveEdge {
            append(.success, "Already ready for another seek cycle", debugState)
            return
        }
        engine.returnToLive()
        let started = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - started < 10 {
            try await Task.sleep(for: .milliseconds(50))
            engine.refreshPlaybackInformation()
            try validateSessionContinuity()
            if isReadyAtLiveEdge {
                append(.success, "Ready for another seek cycle", debugState)
                return
            }
        }
        throw BenchmarkError.resetTimedOut(debugState)
    }

    private var isReadyAtLiveEdge: Bool {
        engine.liveDelaySeconds < 2
            && engine.state == .playing
            && !engine.isPlaybackOutputConcealed
    }

    private func measureSeek(delta: TimeInterval, number: Int) async throws -> SeekSample {
        try await measureSeek(delta: delta, targetLiveDelay: nil, number: number)
    }

    private func measureSeek(
        targetLiveDelay: TimeInterval,
        targetPercentage: Double,
        number: Int
    ) async throws -> SeekSample {
        engine.refreshPlaybackInformation()
        let delta = engine.liveDelaySeconds - targetLiveDelay
        return try await measureSeek(
            delta: delta,
            targetLiveDelay: targetLiveDelay,
            targetPercentage: targetPercentage,
            number: number
        )
    }

    private func measureSeek(
        delta: TimeInterval,
        targetLiveDelay: TimeInterval?,
        targetPercentage: Double? = nil,
        number: Int
    ) async throws -> SeekSample {
        engine.refreshPlaybackInformation()
        var baseline = counters
        var mediaIdentity = engine.mediaPlayer.media.map(ObjectIdentifier.init)
        let initialNavigationState = engine.timeshiftNavigationDebugState
        var navigationStarted = false
        let started = ProcessInfo.processInfo.systemUptime
        append(
            .navigation,
            targetLiveDelay.map {
                if let targetPercentage {
                    return String(
                        format: "Seek %d: target %.0f%% (\(formatDuration($0)) behind live)",
                        number,
                        targetPercentage * 100
                    )
                }
                return "Seek \(number): target \(formatDuration($0)) behind live"
            } ?? "Seek \(number): \(delta < 0 ? "back" : "forward") \(Int(abs(delta)))s",
            String(format: "Starting %.2fs behind live; VLC pictures: %d.", engine.liveDelaySeconds, baseline.displayedPictures)
        )
        try await sendPlayerSeek(delta: delta)

        var discontinuityAt: Double?
        var videoAt: Double?
        var audioAt: Double?
        var atDiscontinuity: PlaybackOutputCounters?
        var loggedConcealment = false
        var validatedHeldFrame = false
        while ProcessInfo.processInfo.systemUptime - started < 10 {
            try await Task.sleep(for: .milliseconds(10))
            engine.refreshPlaybackInformation()
            try validateSessionContinuity()
            try validateNormalPlaybackRate(context: "seek \(number)")
            let now = ProcessInfo.processInfo.systemUptime
            let current = counters
            let currentMediaIdentity = engine.mediaPlayer.media.map(ObjectIdentifier.init)
            let health = engine.nativeTimeshiftHealthSnapshot
            if !navigationStarted,
               engine.state == .paused
                || engine.isPlaybackOutputConcealed
                || health?.isNavigating == true
                || engine.timeshiftNavigationDebugState != initialNavigationState {
                navigationStarted = true
                baseline = current
            }
            if navigationStarted, currentMediaIdentity != mediaIdentity {
                mediaIdentity = currentMediaIdentity
                discontinuityAt = now
                atDiscontinuity = current
                videoAt = nil
                audioAt = nil
                append(.information, "VLC pipeline replaced at destination", elapsedDetail(since: started))
            }
            if navigationStarted,
               discontinuityAt == nil,
               current.demuxDiscontinuities > baseline.demuxDiscontinuities {
                discontinuityAt = now
                atDiscontinuity = current
                append(.information, "VLC consumed discontinuity", elapsedDetail(since: started))
            }
            if engine.isPlaybackOutputConcealed, !loggedConcealment {
                loggedConcealment = true
                append(.information, "Output gate concealed stale frames", elapsedDetail(since: started))
            }
            if engine.isPlaybackOutputConcealed {
                if engine.mediaPlayer.audio?.isMuted == false {
                    throw BenchmarkError.outputInvariant(
                        "Seek \(number) exposed audio while post-seek output was concealed."
                    )
                }
                if !validatedHeldFrame {
                    guard let heldFrame = engine.pausedFrame else {
                        throw BenchmarkError.outputInvariant(
                            "Seek \(number) concealed output without a held pre-seek frame."
                        )
                    }
                    guard heldFrameMaximumLuminance(heldFrame) >= 0.025 else {
                        throw BenchmarkError.outputInvariant(
                            "Seek \(number) held an effectively black pre-seek frame."
                        )
                    }
                    validatedHeldFrame = true
                    append(.success, "Held pre-seek frame verified", elapsedDetail(since: started))
                }
            }
            if navigationStarted, let atDiscontinuity {
                if videoAt == nil, current.displayedPictures > atDiscontinuity.displayedPictures {
                    videoAt = now
                    append(.success, "First new VLC video frame", elapsedDetail(since: started))
                }
                if audioAt == nil, current.playedAudioBuffers > atDiscontinuity.playedAudioBuffers {
                    audioAt = now
                    append(.success, "First new VLC audio buffer", elapsedDetail(since: started))
                }
            } else if navigationStarted, videoAt == nil,
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

    private func validatePostSeekDwell(seekNumber: Int) async throws {
        var previous = counters
        var lastVideoAdvance = ProcessInfo.processInfo.systemUptime
        var maximumVideoGap: TimeInterval = 0

        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            engine.refreshPlaybackInformation()
            try validateSessionContinuity()
            try validateNormalPlaybackRate(context: "seek \(seekNumber) dwell")

            let now = ProcessInfo.processInfo.systemUptime
            let current = counters
            if current.displayedPictures > previous.displayedPictures {
                maximumVideoGap = max(maximumVideoGap, now - lastVideoAdvance)
                lastVideoAdvance = now
            } else if current.playedAudioBuffers > previous.playedAudioBuffers,
                      now - lastVideoAdvance >= 0.5 {
                throw BenchmarkError.outputInvariant(
                    String(
                        format: "Seek %d audio advanced while video stalled for %.0fms after reveal.",
                        seekNumber,
                        (now - lastVideoAdvance) * 1_000
                    )
                )
            }
            previous = current
        }

        append(
            .success,
            "Post-seek video remained continuous",
            String(format: "Longest observed frame interval %.1fms.", maximumVideoGap * 1_000)
        )
    }

    private func validateNormalPlaybackRate(context: String) throws {
        let rate = engine.mediaPlayer.rate
        guard rate <= 1.01 else {
            throw BenchmarkError.outputInvariant(
                String(format: "%@ used accelerated VLC playback at %.2f×.", context, rate)
            )
        }
    }

    private func heldFrameMaximumLuminance(_ image: NSImage) -> Double {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let width = 32
        let height = 18
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        var maximum = 0.0
        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let red = Double(pixels[offset]) / 255
            let green = Double(pixels[offset + 1]) / 255
            let blue = Double(pixels[offset + 2]) / 255
            maximum = max(maximum, red * 0.2126 + green * 0.7152 + blue * 0.0722)
        }
        return maximum
    }

    private func sendPlayerSeek(delta: TimeInterval) async throws {
        let backward = delta < 0
        var remaining = abs(delta)
        while remaining > NativeTimeshiftActionPlan.liveEdgeTolerance {
            let step = min(15, remaining)
            sendPlayerCommand(backward ? .seekBackward(step) : .seekForward(step))
            remaining -= step
            if remaining > NativeTimeshiftActionPlan.liveEdgeTolerance {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private var debugState: String {
        let current = counters
        let health = engine.nativeTimeshiftHealthSnapshot
        let packetAge = health?.lastMuxPacketAt.map { String(format: "%.2fs", -$0.timeIntervalSinceNow) } ?? "nil"
        return "engine=\(playerState), vlc=\(engine.mediaPlayer.state), playing=\(engine.mediaPlayer.isPlaying), concealed=\(engine.isPlaybackOutputConcealed), navigation=\(engine.timeshiftNavigationDebugState), streamNavigating=\(health?.isNavigating.description ?? "nil"), desiredSpeed=\(health.map { String($0.desiredSpeed) } ?? "nil"), lastPacketAge=\(packetAge), delay=\(String(format: "%.2f", engine.liveDelaySeconds))s, recoveries=\(engine.nativeTimeshiftRecoveryCount), discontinuities=\(current.demuxDiscontinuities), pictures=\(current.displayedPictures), audio=\(current.playedAudioBuffers), time=\(current.playbackTimeMilliseconds.map(String.init) ?? "nil")ms"
    }

    private var automaticCycleCount: Int {
        for argument in ProcessInfo.processInfo.arguments {
            guard argument.hasPrefix("--benchmark-cycles=") else { continue }
            return max(1, Int(argument.dropFirst("--benchmark-cycles=".count)) ?? 1)
        }
        return 1
    }

    private var automaticBufferFillSeconds: Int {
        for argument in ProcessInfo.processInfo.arguments {
            guard argument.hasPrefix("--benchmark-buffer-seconds=") else { continue }
            return max(1, Int(argument.dropFirst("--benchmark-buffer-seconds=".count)) ?? 40)
        }
        return 40
    }

    private func sendPlayerCommand(_ command: MacOSPlayerKeyboardCommand) {
        NotificationCenter.default.post(
            name: .vlcTimeshiftBenchmarkPlayerCommand,
            object: command
        )
    }

    private func validateSessionContinuity() throws {
        let recoveryCount = engine.nativeTimeshiftRecoveryCount
        guard recoveryCount == expectedRecoveryCount else {
            throw BenchmarkContinuityError.reconnected(
                count: recoveryCount - expectedRecoveryCount,
                state: debugState
            )
        }

        let window = engine.timeshiftWindowSeconds
        if maximumObservedTimeshiftWindow >= 10,
           window < maximumObservedTimeshiftWindow * 0.5,
           maximumObservedTimeshiftWindow - window >= 5 {
            throw BenchmarkContinuityError.bufferReset(
                previous: maximumObservedTimeshiftWindow,
                current: window,
                state: debugState
            )
        }
        maximumObservedTimeshiftWindow = max(maximumObservedTimeshiftWindow, window)
    }

    private func makePresentation(
        channel: (id: UInt32, name: String),
        request: LiveStreamRequest
    ) -> PlaybackPresentation {
        let now = Date()
        let channelID = String(channel.id)
        let program = GuideProgram(
            id: "benchmark-program",
            channelID: channelID,
            title: "VLC Timeshift Benchmark",
            subtitle: nil,
            overview: "Automated seeks through the real player timeline.",
            start: now.addingTimeInterval(-12 * 60 * 60),
            end: now.addingTimeInterval(12 * 60 * 60)
        )
        let words = channel.name.split(whereSeparator: { $0.isWhitespace || $0 == "." })
        let monogram = words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let guideChannel = GuideChannel(
            id: channelID,
            number: 0,
            name: channel.name,
            monogram: monogram.isEmpty ? "TV" : monogram,
            tint: .blue,
            iconURL: nil,
            programs: [program]
        )
        return PlaybackPresentation(
            channel: guideChannel,
            program: program,
            recording: nil,
            request: request
        )
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

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
    }

    private struct SeekSample {
        let discontinuityMilliseconds: Double?
        let videoMilliseconds: Double
        let audioMilliseconds: Double?
        let readyMilliseconds: Double
    }

    private enum BenchmarkError: LocalizedError {
        case invalidPlaylist
        case nativeTimeshiftUnavailable(String?)
        case playbackDidNotStart
        case seekTimedOut(Int, String)
        case resetTimedOut(String)
        case cyclesFailed(String)
        case outputInvariant(String)

        var errorDescription: String? {
            switch self {
            case .invalidPlaylist: "TVHeadend did not return a usable channel playlist."
            case let .nativeTimeshiftUnavailable(reason):
                "The player fell back instead of opening native timeshift. \(reason ?? "No reason reported.")"
            case .playbackDidNotStart: "VLC did not begin playback within 10 seconds."
            case let .seekTimedOut(number, state):
                "Seek \(number) produced no post-discontinuity VLC video within 10 seconds. \(state)"
            case let .resetTimedOut(state): "Returning to live timed out. \(state)"
            case let .cyclesFailed(detail): detail
            case let .outputInvariant(detail): detail
            }
        }
    }
}

private enum BenchmarkContinuityError: LocalizedError {
    case reconnected(count: Int, state: String)
    case bufferReset(previous: TimeInterval, current: TimeInterval, state: String)

    var errorDescription: String? {
        switch self {
        case let .reconnected(count, state):
            "Native timeshift reconnected \(count) time(s); session continuity was lost. \(state)"
        case let .bufferReset(previous, current, state):
            String(
                format: "Timeshift buffer reset from %.2fs to %.2fs. %@",
                previous,
                current,
                state
            )
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
