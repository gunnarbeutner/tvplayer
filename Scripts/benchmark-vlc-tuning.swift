#!/usr/bin/env swift

import Foundation

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
    var skipBuild = false
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
                "-project", "TVApp.xcodeproj",
                "-scheme", "TVApp-macOS",
                "-destination", "platform=macOS",
                "-derivedDataPath", derivedData.path,
            ]
        )
    }

    let app = derivedData.appending(path: "Build/Products/Debug/TVApp.app")
    let executable = app.appending(path: "Contents/MacOS/TVApp")
    let benchmark = Process()
    let benchmarkOutput = Pipe()
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
    ]
    if let channelIndex = options.channelIndex {
        benchmarkArguments.append("--tuning-channel-index=\(channelIndex)")
    }
    if options.disableStandbyPreconnect {
        benchmarkArguments.append("--tuning-disable-standby-preconnect")
    }
    benchmark.arguments = benchmarkArguments
    benchmark.standardOutput = benchmarkOutput
    benchmark.standardError = benchmarkOutput
    try benchmark.run()

    var buffered = ""
    var result: String?
    while true {
        let data = benchmarkOutput.fileHandleForReading.availableData
        if data.isEmpty { break }
        buffered += String(data: data, encoding: .utf8) ?? ""
        let lines = buffered.split(separator: "\n", omittingEmptySubsequences: false)
        buffered = String(lines.last ?? "")
        for line in lines.dropLast() where line.hasPrefix("VLC_TUNING") {
            print(line)
            if line.hasPrefix("VLC_TUNING_RESULT ") {
                result = String(line.dropFirst("VLC_TUNING_RESULT ".count))
            }
        }
    }
    benchmark.waitUntilExit()
    if buffered.hasPrefix("VLC_TUNING") {
        print(buffered)
        if buffered.hasPrefix("VLC_TUNING_RESULT ") {
            result = String(buffered.dropFirst("VLC_TUNING_RESULT ".count))
        }
    }
    guard benchmark.terminationStatus == 0 else {
        throw RunnerError.commandFailed("TVApp", benchmark.terminationStatus)
    }
    guard let result, result.contains("suspicious=0") else {
        throw RunnerError.benchmarkFailed(result ?? "missing VLC_TUNING_RESULT")
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
