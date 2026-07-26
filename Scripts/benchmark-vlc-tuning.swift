#!/usr/bin/env swift

import Foundation
import Darwin

enum RunnerError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case commandFailed(String, Int32)
    case benchmarkFailed(String)

    var description: String {
        switch self {
        case let .invalidArgument(message): message
        case let .commandFailed(command, status): "\(command) failed with status \(status)."
        case let .benchmarkFailed(result): "VLC tuning benchmark failed: \(result)"
        }
    }
}

struct Options {
    var attempts = 20
    var dwellSeconds = 10
    var mode = "cold"
    var direction = "up"
    var channelIndex: Int?
    var requestWarmLeadMilliseconds = 2_000
    var transportWarmLeadMilliseconds = 4_000
    var vlcCacheMilliseconds = 1_500
    var initialHorizonMilliseconds = 500
    var sampleMilliseconds = 50
    var disableStandbyPreconnect = false
    var failureCaptureOutput: String?
    var attemptTimeoutSeconds: Int?
    var startupTimeoutSeconds = 60
    var completionTimeoutSeconds = 15
    var skipBuild = false
}

struct TuningAttemptBeginAnnouncement: Decodable, Encodable {
    let attempt: Int
    let channelID: UInt32
    let channelName: String
    let mode: String
    let direction: String
    let unixTimeSeconds: TimeInterval
    let monotonicSeconds: TimeInterval
}

struct TuningAttemptCompletionAnnouncement: Decodable {
    let attempt: Int
}

struct FailureCaptureAnnouncement: Decodable {
    let attempt: Int?
    let channelID: UInt32?
    let path: String
}

private enum AnnouncedCaptureKind: String, Hashable {
    case finalized
    case session
}

private struct AnnouncedCapture: Hashable {
    let kind: AnnouncedCaptureKind
    let path: String
}

private struct ActiveTuningAttempt {
    let announcement: TuningAttemptBeginAnnouncement
    let observedAt: TimeInterval
}

private enum ProtocolWaitState {
    case startup(since: TimeInterval)
    case attempt(ActiveTuningAttempt)
    case progress(since: TimeInterval, phase: String)
}

private struct WatchdogViolation {
    let reason: String
    let phase: String
    let timeoutSeconds: Int
    let attempt: ActiveTuningAttempt?
}

private final class BenchmarkOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let logHandle: FileHandle?
    private let protocolNonce: String
    private var pendingOutput = Data()
    private var benchmarkResult: String?
    private var captureAnnouncements: [AnnouncedCapture] = []
    private var activeAttempt: ActiveTuningAttempt?
    private var waitState: ProtocolWaitState
    private var watchdogViolation: WatchdogViolation?
    private var watchdogForcedKill = false
    private var firstLogWriteError: String?

    init(
        logHandle: FileHandle?,
        protocolNonce: String,
        startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.logHandle = logHandle
        self.protocolNonce = protocolNonce
        waitState = .startup(since: startedAt)
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        var echoedLines: [String] = []
        lock.lock()
        do {
            try logHandle?.write(contentsOf: data)
        } catch {
            if firstLogWriteError == nil {
                firstLogWriteError = error.localizedDescription
            }
        }
        pendingOutput.append(data)
        while let newline = pendingOutput.firstIndex(of: 0x0A) {
            let lineData = pendingOutput[..<newline]
            pendingOutput.removeSubrange(...newline)
            observeLocked(String(decoding: lineData, as: UTF8.self), echoingInto: &echoedLines)
        }
        lock.unlock()
        echo(echoedLines)
    }

    func finishInput() {
        var echoedLines: [String] = []
        lock.lock()
        if !pendingOutput.isEmpty {
            observeLocked(
                String(decoding: pendingOutput, as: UTF8.self),
                echoingInto: &echoedLines
            )
            pendingOutput.removeAll(keepingCapacity: false)
        }
        lock.unlock()
        echo(echoedLines)
    }

    func claimWatchdogViolation(
        at now: TimeInterval,
        attemptTimeoutSeconds: Int,
        startupTimeoutSeconds: Int,
        progressTimeoutSeconds: Int
    ) -> WatchdogViolation? {
        lock.lock()
        defer { lock.unlock() }
        guard watchdogViolation == nil else { return nil }

        let violation: WatchdogViolation?
        switch waitState {
        case let .startup(since):
            violation = now - since >= TimeInterval(startupTimeoutSeconds)
                ? WatchdogViolation(
                    reason: "startup-timeout",
                    phase: "startup",
                    timeoutSeconds: startupTimeoutSeconds,
                    attempt: nil
                )
                : nil
        case let .attempt(attempt):
            violation = now - attempt.observedAt >= TimeInterval(attemptTimeoutSeconds)
                ? WatchdogViolation(
                    reason: "attempt-timeout",
                    phase: "attempt",
                    timeoutSeconds: attemptTimeoutSeconds,
                    attempt: attempt
                )
                : nil
        case let .progress(since, phase):
            violation = now - since >= TimeInterval(progressTimeoutSeconds)
                ? WatchdogViolation(
                    reason: "protocol-progress-timeout",
                    phase: phase,
                    timeoutSeconds: progressTimeoutSeconds,
                    attempt: nil
                )
                : nil
        }
        watchdogViolation = violation
        return violation
    }

    func snapshot() -> (
        result: String?,
        captures: [AnnouncedCapture],
        activeAttempt: ActiveTuningAttempt?,
        watchdogViolation: WatchdogViolation?,
        forcedKill: Bool,
        logWriteError: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            benchmarkResult,
            captureAnnouncements,
            activeAttempt,
            watchdogViolation,
            watchdogForcedKill,
            firstLogWriteError
        )
    }

    func markWatchdogForcedKill() {
        lock.lock()
        watchdogForcedKill = true
        lock.unlock()
    }

    func synchronizeLog() {
        lock.lock()
        defer { lock.unlock() }
        do {
            try logHandle?.synchronize()
        } catch {
            if firstLogWriteError == nil {
                firstLogWriteError = error.localizedDescription
            }
        }
    }

    func closeLog() {
        lock.lock()
        defer { lock.unlock() }
        do {
            try logHandle?.close()
        } catch {
            if firstLogWriteError == nil {
                firstLogWriteError = error.localizedDescription
            }
        }
    }

    private func observeLocked(_ rawLine: String, echoingInto echoedLines: inout [String]) {
        let line = rawLine.last == "\r" ? String(rawLine.dropLast()) : rawLine
        guard line.hasPrefix("VLC_TUNING") else { return }
        echoedLines.append(line)

        if let payload = authenticatedPayload(
            for: "VLC_TUNING_ATTEMPT_BEGIN",
            in: line
        ), let announcement: TuningAttemptBeginAnnouncement = decodeJSON(payload) {
            let attempt = ActiveTuningAttempt(
                announcement: announcement,
                observedAt: ProcessInfo.processInfo.systemUptime
            )
            activeAttempt = attempt
            waitState = .attempt(attempt)
            return
        }

        if let payload = authenticatedPayload(for: "VLC_TUNING_SAMPLE", in: line),
           let completion: TuningAttemptCompletionAnnouncement = decodeJSON(payload),
           activeAttempt?.announcement.attempt == completion.attempt {
            activeAttempt = nil
            waitState = .progress(
                since: ProcessInfo.processInfo.systemUptime,
                phase: "post-sample"
            )
        }

        if let payload = authenticatedPayload(for: "VLC_TUNING_RESULT", in: line) {
            benchmarkResult = payload
            activeAttempt = nil
            waitState = .progress(
                since: ProcessInfo.processInfo.systemUptime,
                phase: "post-result"
            )
        }

        for (event, kind) in [
            ("VLC_TUNING_CAPTURE", AnnouncedCaptureKind.finalized),
            ("VLC_TUNING_CAPTURE_SESSION", AnnouncedCaptureKind.session),
        ] {
            if let payload = authenticatedPayload(for: event, in: line),
               let announcement: FailureCaptureAnnouncement = decodeJSON(payload) {
                captureAnnouncements.append(
                    AnnouncedCapture(kind: kind, path: announcement.path)
                )
            }
        }
    }

    private func authenticatedPayload(for event: String, in line: String) -> String? {
        let prefix = "\(event) \(protocolNonce) "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private func decodeJSON<T: Decodable>(_ payload: String) -> T? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func echo(_ lines: [String]) {
        for line in lines { print(sanitizedProtocolEcho(line)) }
        if !lines.isEmpty { fflush(stdout) }
    }
}

private final class OutputDrainCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didComplete = false

    func complete() {
        lock.lock()
        let shouldSignal = !didComplete
        didComplete = true
        lock.unlock()
        if shouldSignal { semaphore.signal() }
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }
}

private struct CaptureCollectionResult {
    let savedPaths: [String]
    let errors: [String]
}

private struct RunnerTerminationReport: Encodable {
    let formatVersion: Int
    let reason: String
    let createdAt: String
    let timeoutSeconds: Int?
    let watchdogPhase: String?
    let attempt: TuningAttemptBeginAnnouncement?
    let processIdentifier: Int32
    let forcedKill: Bool
    let terminationStatus: Int32
    let terminationReason: String
    let childOutputLog: String?
    let outputDrainTimedOut: Bool
    let outputDrainError: String?
    let savedCaptureDirectories: [String]
    let captureCollectionErrors: [String]
}

private enum CaptureSourceValidationError: LocalizedError {
    case invalidPath(String)
    case unexpectedLocation(String)
    case invalidDirectory(String)
    case invalidMarker(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPath(path): "Capture announcement has an invalid path: \(path)"
        case let .unexpectedLocation(path): "Capture is outside the expected app temp root: \(path)"
        case let .invalidDirectory(path): "Capture is not a real non-symlink directory: \(path)"
        case let .invalidMarker(path): "Capture marker is not a regular non-symlink file: \(path)"
        }
    }
}

private func iso8601String(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func createChildOutputLog(
    in outputRoot: URL
) throws -> (url: URL, handle: FileHandle) {
    try FileManager.default.createDirectory(
        at: outputRoot,
        withIntermediateDirectories: true
    )
    let timestamp = iso8601String()
        .replacingOccurrences(of: ":", with: "-")
    let url = outputRoot.appending(
        path: "benchmark-child-output-\(timestamp)-\(UUID().uuidString.lowercased()).log"
    )
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return (url, try FileHandle(forWritingTo: url))
}

private func sanitizedProtocolEcho(_ line: String) -> String {
    var sanitized = ""
    sanitized.reserveCapacity(line.utf8.count)
    for scalar in line.unicodeScalars {
        if scalar.value < 0x20 || scalar.value == 0x7F {
            sanitized += String(format: "\\u{%02X}", scalar.value)
        } else {
            sanitized.unicodeScalars.append(scalar)
        }
    }
    return sanitized
}

private func isNonSymlinkDirectory(_ url: URL) -> Bool {
    var metadata = stat()
    let status = url.path.withCString { Darwin.lstat($0, &metadata) }
    return status == 0 && (metadata.st_mode & S_IFMT) == S_IFDIR
}

private func isNonSymlinkRegularFile(_ url: URL) -> Bool {
    var metadata = stat()
    let status = url.path.withCString { Darwin.lstat($0, &metadata) }
    return status == 0 && (metadata.st_mode & S_IFMT) == S_IFREG
}

private func canonicalExistingDirectory(_ url: URL) -> URL? {
    let canonical = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    return isNonSymlinkDirectory(canonical) ? canonical : nil
}

private func expectedAppTemporaryDirectories(for app: URL) -> [URL] {
    var candidates = [FileManager.default.temporaryDirectory]
    if let bundleIdentifier = Bundle(url: app)?.bundleIdentifier,
       !bundleIdentifier.isEmpty,
       !bundleIdentifier.contains("/"),
       bundleIdentifier != ".",
       bundleIdentifier != ".." {
        candidates.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Containers", directoryHint: .isDirectory)
                .appending(path: bundleIdentifier, directoryHint: .isDirectory)
                .appending(path: "Data/tmp", directoryHint: .isDirectory)
        )
    }
    var seen: Set<String> = []
    return candidates.compactMap(canonicalExistingDirectory).filter {
        seen.insert($0.path).inserted
    }
}

private func validatedCaptureSource(
    _ announcement: AnnouncedCapture,
    expectedTempDirectories: [URL]
) throws -> URL {
    guard announcement.path.hasPrefix("/"),
          !announcement.path.utf8.contains(0)
    else {
        throw CaptureSourceValidationError.invalidPath(announcement.path)
    }

    let submitted = URL(fileURLWithPath: announcement.path).standardizedFileURL
    guard isNonSymlinkDirectory(submitted) else {
        throw CaptureSourceValidationError.invalidDirectory(submitted.path)
    }
    let source = submitted.resolvingSymlinksInPath().standardizedFileURL
    guard isNonSymlinkDirectory(source) else {
        throw CaptureSourceValidationError.invalidDirectory(source.path)
    }

    let markerName: String
    let isExpectedLocation: Bool
    switch announcement.kind {
    case .finalized:
        markerName = "manifest.json"
        isExpectedLocation = expectedTempDirectories.contains { temporaryDirectory in
            let captureRoot = temporaryDirectory.appending(
                path: "TVPlayer-VLC-Tuning-Failure-Captures",
                directoryHint: .isDirectory
            ).standardizedFileURL
            guard isNonSymlinkDirectory(captureRoot),
                  source.deletingLastPathComponent().standardizedFileURL == captureRoot
            else { return false }
            let name = source.lastPathComponent
            return name.hasPrefix("attempt-") && name.count > "attempt-".count
        }
    case .session:
        markerName = "session.json"
        isExpectedLocation = expectedTempDirectories.contains { temporaryDirectory in
            guard source.deletingLastPathComponent().standardizedFileURL
                    == temporaryDirectory.standardizedFileURL
            else { return false }
            let prefix = "TVPlayer-VLC-Tuning-Capture-Session-"
            let name = source.lastPathComponent
            return name.hasPrefix(prefix) && name.count > prefix.count
        }
    }
    guard isExpectedLocation else {
        throw CaptureSourceValidationError.unexpectedLocation(source.path)
    }

    let marker = source.appending(path: markerName)
    guard isNonSymlinkRegularFile(marker) else {
        throw CaptureSourceValidationError.invalidMarker(marker.path)
    }
    return source
}

private func collectCaptures(
    _ announcements: [AnnouncedCapture],
    into outputRoot: URL,
    expectedTempDirectories: [URL]
) -> CaptureCollectionResult {
    var seenSources: Set<String> = []
    var savedPaths: [String] = []
    var errors: [String] = []
    for announcement in announcements {
        let source: URL
        do {
            source = try validatedCaptureSource(
                announcement,
                expectedTempDirectories: expectedTempDirectories
            )
        } catch {
            errors.append(
                "Rejected \(announcement.kind.rawValue) capture announcement: "
                    + error.localizedDescription
            )
            continue
        }
        guard seenSources.insert(source.path).inserted else { continue }
        var destination = outputRoot.appending(
            path: source.lastPathComponent,
            directoryHint: .isDirectory
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = outputRoot.appending(
                path: "\(source.lastPathComponent)-\(UUID().uuidString.lowercased())",
                directoryHint: .isDirectory
            )
        }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            savedPaths.append(destination.path)
            print("VLC_TUNING_CAPTURE_SAVED \(destination.path)")
        } catch {
            errors.append(
                "Could not collect \(announcement.kind.rawValue) capture at \(source.path): "
                    + error.localizedDescription
            )
        }
    }
    return CaptureCollectionResult(savedPaths: savedPaths, errors: errors)
}

private func terminationReasonDescription(_ reason: Process.TerminationReason) -> String {
    switch reason {
    case .exit: "exit"
    case .uncaughtSignal: "uncaught-signal"
    @unknown default: "unknown"
    }
}

@discardableResult
private func writeRunnerTerminationReport(
    to artifactRoot: URL,
    reason: String,
    timeoutSeconds: Int?,
    watchdogPhase: String?,
    attempt: TuningAttemptBeginAnnouncement?,
    process: Process,
    forcedKill: Bool,
    childOutputLog: URL?,
    outputDrainTimedOut: Bool,
    outputDrainError: String?,
    captureCollection: CaptureCollectionResult
) throws -> URL {
    try FileManager.default.createDirectory(
        at: artifactRoot,
        withIntermediateDirectories: true
    )
    let report = RunnerTerminationReport(
        formatVersion: 1,
        reason: reason,
        createdAt: iso8601String(),
        timeoutSeconds: timeoutSeconds,
        watchdogPhase: watchdogPhase,
        attempt: attempt,
        processIdentifier: process.processIdentifier,
        forcedKill: forcedKill,
        terminationStatus: process.terminationStatus,
        terminationReason: terminationReasonDescription(process.terminationReason),
        childOutputLog: childOutputLog?.path,
        outputDrainTimedOut: outputDrainTimedOut,
        outputDrainError: outputDrainError,
        savedCaptureDirectories: captureCollection.savedPaths,
        captureCollectionErrors: captureCollection.errors
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let reportURL = artifactRoot.appending(path: "runner-termination.json")
    try encoder.encode(report).write(to: reportURL, options: .atomic)
    print("VLC_TUNING_RUNNER_TERMINATION \(reportURL.path)")
    fflush(stdout)
    return reportURL
}

@discardableResult
func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        output.split(whereSeparator: \.isNewline).suffix(80).forEach { print($0) }
        throw RunnerError.commandFailed(arguments.first ?? executable, process.terminationStatus)
    }
    return output
}

func value(after flag: String, in arguments: [String]) throws -> String? {
    if let joined = arguments.first(where: { $0.hasPrefix("\(flag)=") }) {
        return String(joined.dropFirst(flag.count + 1))
    }
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    guard arguments.indices.contains(index + 1) else {
        throw RunnerError.invalidArgument("\(flag) requires a value.")
    }
    return arguments[index + 1]
}

func positiveInt(_ value: String?, flag: String, default fallback: Int) throws -> Int {
    guard let value else { return fallback }
    guard let parsed = Int(value), parsed > 0 else {
        throw RunnerError.invalidArgument("\(flag) requires a positive integer.")
    }
    return parsed
}

func nonnegativeInt(_ value: String?, flag: String, default fallback: Int) throws -> Int {
    guard let value else { return fallback }
    guard let parsed = Int(value), parsed >= 0 else {
        throw RunnerError.invalidArgument("\(flag) requires a nonnegative integer.")
    }
    return parsed
}

func parseOptions(_ arguments: [String]) throws -> Options {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(
            """
            Usage: Scripts/benchmark-vlc-tuning.swift [options]

              --mode MODE                     cold, request-warm, transport-warm, or paired
              --direction up|down             Monotonic channel traversal (default: up)
              --attempts N                    Number of tunes (default: 20)
              --dwell-seconds N               Continuous playback after readiness (default: 10)
              --channel-index N               Repeat one 1-based playlist channel
              --request-warm-lead-ms N        Prefetch lead before the next tune (default: 2000)
              --transport-warm-lead-ms N      Candidate staging lead (default: 4000)
              --vlc-cache-ms N                 Native VLC cache policy (default: 1500)
              --initial-horizon-ms N           Initial aligned horizon (default: 500)
              --sample-ms N                   Continuity sampling interval (default: 50)
              --capture-failures DIR          Save bounded replay bundles for suspect attempts
              --attempt-timeout-seconds N     Abort a stuck tune (default: dwell seconds + 30)
              --startup-timeout-seconds N     Abort before the first tune (default: 60)
              --completion-timeout-seconds N  Abort stalled result/teardown (default: 15)
              --disable-standby-preconnect     Disable production's idle HTSP standby connection
              --skip-build                     Reuse the existing benchmark build
            """
        )
        exit(0)
    }

    var options = Options()
    options.attempts = try positiveInt(
        value(after: "--attempts", in: arguments),
        flag: "--attempts",
        default: options.attempts
    )
    options.dwellSeconds = try nonnegativeInt(
        value(after: "--dwell-seconds", in: arguments),
        flag: "--dwell-seconds",
        default: options.dwellSeconds
    )
    if let timeout = try value(after: "--attempt-timeout-seconds", in: arguments) {
        options.attemptTimeoutSeconds = try positiveInt(
            timeout,
            flag: "--attempt-timeout-seconds",
            default: options.dwellSeconds + 30
        )
    }
    options.startupTimeoutSeconds = try positiveInt(
        value(after: "--startup-timeout-seconds", in: arguments),
        flag: "--startup-timeout-seconds",
        default: options.startupTimeoutSeconds
    )
    options.completionTimeoutSeconds = try positiveInt(
        value(after: "--completion-timeout-seconds", in: arguments),
        flag: "--completion-timeout-seconds",
        default: options.completionTimeoutSeconds
    )
    options.requestWarmLeadMilliseconds = try nonnegativeInt(
        value(after: "--request-warm-lead-ms", in: arguments),
        flag: "--request-warm-lead-ms",
        default: options.requestWarmLeadMilliseconds
    )
    options.transportWarmLeadMilliseconds = try nonnegativeInt(
        value(after: "--transport-warm-lead-ms", in: arguments),
        flag: "--transport-warm-lead-ms",
        default: options.transportWarmLeadMilliseconds
    )
    options.vlcCacheMilliseconds = try nonnegativeInt(
        value(after: "--vlc-cache-ms", in: arguments),
        flag: "--vlc-cache-ms",
        default: options.vlcCacheMilliseconds
    )
    options.initialHorizonMilliseconds = try nonnegativeInt(
        value(after: "--initial-horizon-ms", in: arguments),
        flag: "--initial-horizon-ms",
        default: options.initialHorizonMilliseconds
    )
    options.sampleMilliseconds = try positiveInt(
        value(after: "--sample-ms", in: arguments),
        flag: "--sample-ms",
        default: options.sampleMilliseconds
    )
    if let channel = try value(after: "--channel-index", in: arguments) {
        options.channelIndex = try positiveInt(channel, flag: "--channel-index", default: 1)
    }
    if let mode = try value(after: "--mode", in: arguments) {
        guard ["cold", "request-warm", "transport-warm", "paired"].contains(mode) else {
            throw RunnerError.invalidArgument(
                "--mode must be cold, request-warm, transport-warm, or paired."
            )
        }
        options.mode = mode
    }
    if let direction = try value(after: "--direction", in: arguments) {
        guard ["up", "down"].contains(direction) else {
            throw RunnerError.invalidArgument("--direction must be up or down.")
        }
        options.direction = direction
    }
    options.failureCaptureOutput = try value(after: "--capture-failures", in: arguments)
    options.disableStandbyPreconnect = arguments.contains("--disable-standby-preconnect")
    options.skipBuild = arguments.contains("--skip-build")
    return options
}

do {
    let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
    let options = try parseOptions(arguments)
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let derivedData = root.appending(path: ".build/DerivedData-VLCTuningBenchmarkMac")

    if !options.skipBuild {
        print("Building the signed macOS VLC tuning benchmark…")
        _ = try run(
            "/usr/bin/xcrun",
            [
                "xcodebuild", "build", "-quiet",
                "-project", "TVPlayer.xcodeproj",
                "-scheme", "TVPlayer-macOS",
                "-destination", "platform=macOS",
                "-derivedDataPath", derivedData.path,
            ]
        )
    }

    let app = derivedData.appending(path: "Build/Products/Debug/TVPlayer.app")
    // Kept as an environment-only integration-test seam so the runner's
    // crash/report lifecycle can be exercised without crashing a signed app.
    let executable = ProcessInfo.processInfo.environment[
        "TVPLAYER_TUNING_BENCHMARK_EXECUTABLE"
    ].map(URL.init(fileURLWithPath:))
        ?? app.appending(path: "Contents/MacOS/TVPlayer")
    let protocolNonce = UUID().uuidString.lowercased()
    let captureOutputRoot = options.failureCaptureOutput.map {
        URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL
    }
    let childOutputLog: (url: URL, handle: FileHandle)?
    if let captureOutputRoot {
        let log = try createChildOutputLog(in: captureOutputRoot)
        childOutputLog = log
        print("VLC_TUNING_CHILD_LOG \(log.url.path)")
    } else {
        childOutputLog = nil
    }

    let benchmark = Process()
    let benchmarkOutput = Pipe()
    let collector = BenchmarkOutputCollector(
        logHandle: childOutputLog?.handle,
        protocolNonce: protocolNonce
    )
    benchmark.executableURL = executable
    var benchmarkArguments = [
        "-ApplePersistenceIgnoreState", "YES",
        "--vlc-tuning-benchmark",
        "--exit-after-benchmark",
        "--tuning-attempts=\(options.attempts)",
        "--tuning-dwell-seconds=\(options.dwellSeconds)",
        "--tuning-mode=\(options.mode)",
        "--tuning-direction=\(options.direction)",
        "--tuning-request-warm-lead-ms=\(options.requestWarmLeadMilliseconds)",
        "--tuning-transport-warm-lead-ms=\(options.transportWarmLeadMilliseconds)",
        "--tuning-vlc-cache-ms=\(options.vlcCacheMilliseconds)",
        "--tuning-initial-horizon-ms=\(options.initialHorizonMilliseconds)",
        "--tuning-sample-ms=\(options.sampleMilliseconds)",
        "--tuning-protocol-nonce=\(protocolNonce)",
    ]
    if let channelIndex = options.channelIndex {
        benchmarkArguments.append("--tuning-channel-index=\(channelIndex)")
    }
    if options.disableStandbyPreconnect {
        benchmarkArguments.append("--tuning-disable-standby-preconnect")
    }
    if options.failureCaptureOutput != nil {
        benchmarkArguments.append("--tuning-capture-failures")
    }
    benchmark.arguments = benchmarkArguments
    benchmark.standardOutput = benchmarkOutput
    benchmark.standardError = benchmarkOutput
    let processFinished = DispatchSemaphore(value: 0)
    benchmark.terminationHandler = { _ in processFinished.signal() }
    try benchmark.run()

    let outputHandle = benchmarkOutput.fileHandleForReading
    let outputDrainQueue = DispatchQueue(label: "TVPlayer.VLCTuningBenchmark.output-drain")
    let outputDrainCompletion = OutputDrainCompletion()
    outputHandle.readabilityHandler = { handle in
        let data = handle.availableData
        outputDrainQueue.async {
            if data.isEmpty {
                handle.readabilityHandler = nil
                collector.finishInput()
                outputDrainCompletion.complete()
            } else {
                collector.consume(data)
            }
        }
    }

    let attemptTimeoutSeconds = options.attemptTimeoutSeconds
        ?? options.dwellSeconds + 30
    let watchdogQueue = DispatchQueue(label: "TVPlayer.VLCTuningBenchmark.watchdog")
    let watchdog = DispatchSource.makeTimerSource(queue: watchdogQueue)
    watchdog.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
    watchdog.setEventHandler {
        guard let violation = collector.claimWatchdogViolation(
            at: ProcessInfo.processInfo.systemUptime,
            attemptTimeoutSeconds: attemptTimeoutSeconds,
            startupTimeoutSeconds: options.startupTimeoutSeconds,
            progressTimeoutSeconds: options.completionTimeoutSeconds
        ) else { return }

        var detail = "reason=\(violation.reason) phase=\(violation.phase) "
            + "timeout=\(violation.timeoutSeconds)s"
        if let announcement = violation.attempt?.announcement {
            detail += " attempt=\(announcement.attempt) channel=\(announcement.channelID) "
                + "mode=\(announcement.mode)"
        }
        print("VLC_TUNING_WATCHDOG \(detail)")
        fflush(stdout)
        collector.synchronizeLog()
        if benchmark.isRunning {
            benchmark.terminate()
        }
        watchdogQueue.asyncAfter(deadline: .now() + .seconds(2)) {
            guard benchmark.isRunning else { return }
            collector.markWatchdogForcedKill()
            _ = Darwin.kill(benchmark.processIdentifier, SIGKILL)
        }
    }
    watchdog.resume()

    processFinished.wait()
    watchdog.cancel()
    var outputDrainTimedOut = false
    var outputDrainError: String?
    if outputDrainCompletion.wait(timeout: .now() + .seconds(5)) == .timedOut {
        outputDrainTimedOut = true
        outputDrainError = "Child exited but its stdout/stderr pipe remained open for 5 seconds."
        outputHandle.readabilityHandler = nil
    }
    outputDrainQueue.sync {
        outputHandle.readabilityHandler = nil
        do {
            try outputHandle.close()
        } catch {
            let closeError = "Could not close benchmark output after child exit: "
                + error.localizedDescription
            outputDrainError = outputDrainError.map { "\($0) \(closeError)" } ?? closeError
        }
        if outputDrainTimedOut {
            collector.finishInput()
            outputDrainCompletion.complete()
        }
    }
    collector.synchronizeLog()
    collector.closeLog()

    let observed = collector.snapshot()
    let appTemporaryDirectories = expectedAppTemporaryDirectories(for: app)
    let captureCollection: CaptureCollectionResult
    if let captureOutputRoot {
        captureCollection = collectCaptures(
            observed.captures,
            into: captureOutputRoot,
            expectedTempDirectories: appTemporaryDirectories
        )
    } else {
        captureCollection = CaptureCollectionResult(savedPaths: [], errors: [])
    }
    for error in captureCollection.errors {
        fputs("warning: \(error)\n", stderr)
    }
    if let logWriteError = observed.logWriteError {
        fputs("warning: could not completely mirror benchmark output: \(logWriteError)\n", stderr)
    }
    if let outputDrainError {
        fputs("warning: \(outputDrainError)\n", stderr)
    }

    let artifactRoot = captureOutputRoot
        ?? root.appending(path: ".build/VLCTuningBenchmark", directoryHint: .isDirectory)
    if let violation = observed.watchdogViolation {
        try writeRunnerTerminationReport(
            to: artifactRoot,
            reason: violation.reason,
            timeoutSeconds: violation.timeoutSeconds,
            watchdogPhase: violation.phase,
            attempt: violation.attempt?.announcement,
            process: benchmark,
            forcedKill: observed.forcedKill,
            childOutputLog: childOutputLog?.url,
            outputDrainTimedOut: outputDrainTimedOut,
            outputDrainError: outputDrainError,
            captureCollection: captureCollection
        )
        let attemptDetail = violation.attempt.map {
            " during attempt \($0.announcement.attempt)"
        } ?? ""
        throw RunnerError.benchmarkFailed(
            "\(violation.phase) exceeded \(violation.timeoutSeconds)s\(attemptDetail)"
        )
    }

    guard benchmark.terminationStatus == 0 else {
        try writeRunnerTerminationReport(
            to: artifactRoot,
            reason: "child-nonzero-exit",
            timeoutSeconds: nil,
            watchdogPhase: nil,
            attempt: observed.activeAttempt?.announcement,
            process: benchmark,
            forcedKill: false,
            childOutputLog: childOutputLog?.url,
            outputDrainTimedOut: outputDrainTimedOut,
            outputDrainError: outputDrainError,
            captureCollection: captureCollection
        )
        throw RunnerError.commandFailed("TVPlayer", benchmark.terminationStatus)
    }
    if outputDrainTimedOut {
        try writeRunnerTerminationReport(
            to: artifactRoot,
            reason: "output-drain-timeout",
            timeoutSeconds: 5,
            watchdogPhase: "output-drain",
            attempt: observed.activeAttempt?.announcement,
            process: benchmark,
            forcedKill: false,
            childOutputLog: childOutputLog?.url,
            outputDrainTimedOut: true,
            outputDrainError: outputDrainError,
            captureCollection: captureCollection
        )
        throw RunnerError.benchmarkFailed("stdout/stderr drain exceeded 5s")
    }
    guard let result = observed.result, result.contains("suspicious=0") else {
        throw RunnerError.benchmarkFailed(observed.result ?? "missing VLC_TUNING_RESULT")
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
