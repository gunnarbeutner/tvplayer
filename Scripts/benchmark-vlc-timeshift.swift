#!/usr/bin/env swift

import Foundation

enum RunnerError: Error, CustomStringConvertible {
    case commandFailed(String, Int32)

    var description: String {
        switch self {
        case let .commandFailed(command, status): "\(command) failed with status \(status)."
        }
    }
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

func buildSetting(_ name: String, from output: String) -> String? {
    let prefix = "\(name) = "
    return output.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix(prefix) }
        .map { String($0.dropFirst(prefix.count)) }
}

do {
    let arguments = ProcessInfo.processInfo.arguments
    let cycles: Int = {
        guard let index = arguments.firstIndex(of: "--cycles"), arguments.indices.contains(index + 1) else {
            return 1
        }
        return max(1, Int(arguments[index + 1]) ?? 1)
    }()
    let bufferSeconds: Int = {
        guard let index = arguments.firstIndex(of: "--buffer-seconds"), arguments.indices.contains(index + 1) else {
            return 40
        }
        return max(1, Int(arguments[index + 1]) ?? 40)
    }()
    print("Building the macOS VLC benchmark…")
    let buildArguments = [
        "xcodebuild", "build", "-quiet",
        "-project", "TVApp.xcodeproj",
        "-scheme", "TVApp-macOS",
        "-destination", "platform=macOS",
    ]
    _ = try run(
        "/usr/bin/xcrun",
        buildArguments
    )
    let buildSettings = try run(
        "/usr/bin/xcrun",
        [
            "xcodebuild", "-showBuildSettings",
            "-project", "TVApp.xcodeproj",
            "-scheme", "TVApp-macOS",
            "-destination", "platform=macOS",
        ]
    )
    guard let targetBuildDirectory = buildSetting(
        "TARGET_BUILD_DIR",
        from: buildSettings
    ), let wrapperName = buildSetting("WRAPPER_NAME", from: buildSettings) else {
        throw RunnerError.commandFailed("xcodebuild -showBuildSettings", 1)
    }
    let app = URL(fileURLWithPath: targetBuildDirectory)
        .appending(path: wrapperName)
    print("Launching the player and event timeline…")
    let executable = app.appending(path: "Contents/MacOS/TVApp")
    let benchmark = Process()
    let benchmarkOutput = Pipe()
    benchmark.executableURL = executable
    benchmark.arguments = [
        "-ApplePersistenceIgnoreState", "YES",
        "--vlc-timeshift-benchmark",
        "--exit-after-benchmark",
        "--benchmark-cycles=\(cycles)",
        "--benchmark-buffer-seconds=\(bufferSeconds)",
    ]
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
        for line in lines.dropLast() {
            guard line.hasPrefix("VLC_TIMESHIFT") else { continue }
            print(line)
            if line.hasPrefix("VLC_TIMESHIFT_RESULT ") {
                result = String(line.dropFirst("VLC_TIMESHIFT_RESULT ".count))
            }
        }
    }
    benchmark.waitUntilExit()
    if buffered.hasPrefix("VLC_TIMESHIFT") {
        print(buffered)
        if buffered.hasPrefix("VLC_TIMESHIFT_RESULT ") {
            result = String(buffered.dropFirst("VLC_TIMESHIFT_RESULT ".count))
        }
    }
    guard benchmark.terminationStatus == 0 else {
        throw RunnerError.commandFailed("TVApp", benchmark.terminationStatus)
    }
    guard result?.hasPrefix("success") == true else {
        throw RunnerError.commandFailed("VLC timeshift benchmark", 1)
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
