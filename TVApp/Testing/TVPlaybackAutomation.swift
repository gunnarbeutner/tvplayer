import Foundation
import SwiftUI

enum TVGuideAutomation {
    static let launchArgument = "--guide-ui-testing"
    static let probeIdentifier = "tvplayer.guide.automation.probe"
    static let preferencesSuiteName = "de.beutner.TVPlayer.guide-ui-testing"

    static var isEnabled: Bool {
#if DEBUG && os(tvOS)
        ProcessInfo.processInfo.arguments.contains(launchArgument)
#else
        false
#endif
    }

    static func guideSnapshot(at date: Date) -> TVProviderSnapshot? {
        guard isEnabled else { return nil }
        let channels = (1...40).map { ordinal in
            let channelID = String(format: "guide-test-channel-%02d", ordinal)
            let currentEnd = date.addingTimeInterval(
                1_200 + TimeInterval(ordinal % 6) * 600
            )
            let programs = [
                GuideProgram(
                    id: String(format: "guide-test-current-%02d", ordinal),
                    channelID: channelID,
                    title: "Guide Test Current \(ordinal)",
                    subtitle: "Deterministic focus fixture",
                    overview: "Current programme for guide focus automation.",
                    start: date.addingTimeInterval(-7_200),
                    end: currentEnd
                ),
                GuideProgram(
                    id: String(format: "guide-test-future-%02d", ordinal),
                    channelID: channelID,
                    title: "Guide Test Future \(ordinal)",
                    subtitle: nil,
                    overview: "Future programme for horizontal navigation.",
                    start: currentEnd,
                    end: date.addingTimeInterval(26 * 3_600)
                ),
            ]
            return GuideChannel(
                id: channelID,
                number: ordinal,
                name: "Guide Test Channel \(ordinal)",
                monogram: "G\(ordinal)",
                tint: GuideChannelAppearance.tint(for: channelID),
                iconURL: nil,
                programs: programs
            )
        }
        return TVProviderSnapshot(
            channels: channels,
            serverName: "Guide Focus Automation"
        )
    }
}

enum TVPlaybackAutomation {
    static let launchArgument = "--playback-ui-testing"
    static let probeIdentifier = "tvplayer.playback.automation.probe"
    private static let replayEnvironmentKey = "TVPLAYER_PLAYBACK_REPLAY"

    static var isEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains(launchArgument)
#else
        false
#endif
    }

    static var usesReplay: Bool {
#if DEBUG
        isEnabled
            && ProcessInfo.processInfo.environment[replayEnvironmentKey] == "1"
#else
        false
#endif
    }

    static func guideSnapshot(at date: Date) -> TVProviderSnapshot? {
        guard usesReplay else { return nil }
        let channels = (1...3).map { ordinal in
            let channelID = String(1_000 + ordinal)
            let program = GuideProgram(
                id: "replay-\(channelID)-current",
                channelID: channelID,
                title: "Playback Replay \(ordinal)",
                subtitle: "Synthetic audio and video",
                overview: "Deterministic production-player automation fixture.",
                start: date.addingTimeInterval(-3_600),
                end: date.addingTimeInterval(3_600)
            )
            return GuideChannel(
                id: channelID,
                number: ordinal,
                name: "Replay \(ordinal)",
                monogram: "R\(ordinal)",
                tint: [.blue, .purple, .orange][ordinal - 1],
                iconURL: nil,
                programs: [program]
            )
        }
        return TVProviderSnapshot(channels: channels, serverName: "Playback Replay")
    }

    static func livePlaybackRequest(
        channelID: String,
        configuration: TVHeadendConfiguration,
        profile: String,
        networkCachingMilliseconds: Int
    ) -> LiveStreamRequest? {
        guard usesReplay, let numericChannelID = UInt32(channelID) else { return nil }
        return LiveStreamRequest(
            url: URL(string: "http://playback-replay.invalid/channel/\(channelID)")!,
            networkCachingMilliseconds: networkCachingMilliseconds,
            profile: profile,
            kind: .live(.nativeTimeshift(HTSPPlaybackConfiguration(
                configuration: configuration,
                channelID: numericChannelID
            )))
        )
    }

    static func connectionFactory(channelID: UInt32) -> HTSPConnectionFactory? {
#if DEBUG
        guard usesReplay else { return nil }
        return {
            try HTSPReplayConnection(channelID: channelID)
        }
#else
        nil
#endif
    }
}

#if DEBUG
private struct HTSPReplayPacket: Decodable, Sendable {
    let streamIndex: Int
    let frameType: UInt8
    let presentationTime: Int64?
    let decodeTime: Int64?
    let durationMicroseconds: Int64?
    let payload: Data
}

private final class HTSPReplayConnection: HTSPConnectionTransport, @unchecked Sendable {
    let capabilities: Set<String> = ["timeshift"]

    private static let timeshiftPeriod: Int64 = 3_600
    private static let timelineStart: Int64 = 3_600_000_000

    private let channelID: UInt32
    private let condition = NSCondition()
    private let packets: [HTSPReplayPacket]
    private let fixtureDuration: Int64
    private var queuedMessages: [[String: HTSPValue]] = []
    private var closed = false
    private var nextSequence: Int64 = 1
    private var packetIndex = 0
    private var timestampOffset = HTSPReplayConnection.timelineStart
    private var liveEdge = HTSPReplayConnection.timelineStart
    private var speed: Int32 = 100
    private var nextPacketDeadline = Date()
    private var lastPacingTimestamp: Int64?
    private var packetsSinceStatus = 0

    init(channelID: UInt32) throws {
        self.channelID = channelID
        guard let fixtureURL = Bundle.main.url(
            forResource: "playback-replay",
            withExtension: "jsonl"
        ) else {
            throw HTSPError.server("The playback replay fixture is missing.")
        }
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        packets = try data.split(separator: 0x0a).map {
            try decoder.decode(HTSPReplayPacket.self, from: Data($0))
        }
        guard !packets.isEmpty else {
            throw HTSPError.server("The playback replay fixture is empty.")
        }
        let firstTime = packets.compactMap { $0.decodeTime ?? $0.presentationTime }.min() ?? 0
        let finalTime = packets.compactMap { packet -> Int64? in
            guard let time = packet.presentationTime ?? packet.decodeTime else { return nil }
            return time + (packet.durationMicroseconds ?? 0)
        }.max() ?? firstTime + 1_000_000
        fixtureDuration = max(1_000_000, finalTime - firstTime)
        timestampOffset -= firstTime
        liveEdge += fixtureDuration
        queuedMessages.append(timeshiftStatus(playhead: Self.timelineStart))
    }

    func handshake(username: String, password: String) throws {}

    func subscribe(
        channelID: UInt32,
        profile: String,
        weight: UInt32
    ) throws -> HTSPSubscriptionStart {
        guard channelID == self.channelID else { throw HTSPError.channelUnavailable }
        return HTSPSubscriptionStart(
            timeshiftPeriod: Self.timeshiftPeriod,
            streams: [
                HTSPStreamInfo(index: 1, type: "H264", language: nil, metadata: nil),
                HTSPStreamInfo(index: 2, type: "AAC", language: "eng", metadata: nil),
            ],
            sourceInfo: HTSPSourceInfo(
                adapter: "Replay",
                mux: "Synthetic",
                network: "Automation",
                provider: "TV Player",
                service: "Replay \(channelID)",
                satellitePosition: nil
            )
        )
    }

    func reserveSequence() -> Int64 {
        condition.withLock {
            defer { nextSequence += 1 }
            return nextSequence
        }
    }

    func sendRequest(
        method: String,
        sequence: Int64,
        fields: [String: HTSPValue],
        includesSubscriptionID: Bool
    ) throws {
        condition.withLock {
            queuedMessages.append(["seq": .int(sequence)])
            switch method {
            case "subscriptionSpeed":
                speed = Int32(clamping: fields["speed"]?.intValue ?? 100)
                queuedMessages.append([
                    "method": .string("subscriptionSpeed"),
                    "speed": .int(Int64(speed)),
                ])
                nextPacketDeadline = Date()
                lastPacingTimestamp = nil
            case "subscriptionSkip":
                let target = fields["time"]?.intValue ?? liveEdge
                land(at: target)
            case "subscriptionLive":
                land(at: liveEdge)
            default:
                break
            }
            condition.broadcast()
        }
    }

    func readMessage() throws -> [String: HTSPValue] {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if closed { throw HTSPError.disconnected }
            if !queuedMessages.isEmpty {
                return queuedMessages.removeFirst()
            }
            guard speed != 0 else {
                condition.wait()
                continue
            }

            let now = Date()
            if now < nextPacketDeadline {
                condition.wait(until: nextPacketDeadline)
                continue
            }
            let packet = packets[packetIndex]
            let message = packetMessage(packet)
            scheduleNextPacket(after: packet)
            packetIndex += 1
            packetsSinceStatus += 1
            if packetIndex == packets.count {
                packetIndex = 0
                timestampOffset += fixtureDuration
                liveEdge += fixtureDuration
            }
            if packetsSinceStatus >= 25 {
                packetsSinceStatus = 0
                let playhead = (packet.presentationTime ?? packet.decodeTime ?? 0) + timestampOffset
                queuedMessages.append(timeshiftStatus(playhead: playhead))
            }
            return message
        }
    }

    func close() {
        condition.withLock {
            closed = true
            condition.broadcast()
        }
    }

    private func land(at requestedTime: Int64) {
        let target = min(max(Self.timelineStart, requestedTime), liveEdge)
        let relative = positiveModulo(target - Self.timelineStart, fixtureDuration)
        let keyframeIndex = packets.indices
            .filter { packets[$0].frameType == Character("I").asciiValue }
            .last {
                let packetTime = packets[$0].presentationTime
                    ?? packets[$0].decodeTime
                    ?? 0
                return positiveModulo(packetTime, fixtureDuration) <= relative
            } ?? 0
        let packetTime = packets[keyframeIndex].presentationTime
            ?? packets[keyframeIndex].decodeTime
            ?? 0
        packetIndex = keyframeIndex
        timestampOffset = target - packetTime
        nextPacketDeadline = Date()
        lastPacingTimestamp = nil
        queuedMessages.append([
            "method": .string("subscriptionSkip"),
            "time": .int(target),
        ])
        queuedMessages.append(timeshiftStatus(playhead: target))
    }

    private func packetMessage(_ packet: HTSPReplayPacket) -> [String: HTSPValue] {
        var message: [String: HTSPValue] = [
            "method": .string("muxpkt"),
            "stream": .int(Int64(packet.streamIndex)),
            "frametype": .int(Int64(packet.frameType)),
            "payload": .data(packet.payload),
        ]
        if let presentationTime = packet.presentationTime {
            message["pts"] = .int(presentationTime + timestampOffset)
        }
        if let decodeTime = packet.decodeTime {
            message["dts"] = .int(decodeTime + timestampOffset)
        }
        if let duration = packet.durationMicroseconds {
            message["duration"] = .int(duration)
        }
        return message
    }

    private func scheduleNextPacket(after packet: HTSPReplayPacket) {
        let timestamp = (packet.decodeTime ?? packet.presentationTime ?? 0) + timestampOffset
        let mediaInterval = lastPacingTimestamp.map {
            max(0, timestamp - $0)
        } ?? 0
        lastPacingTimestamp = max(lastPacingTimestamp ?? timestamp, timestamp)
        let normalizedSpeed = max(100, abs(Int(speed)))
        let interval = TimeInterval(mediaInterval) / 1_000_000
            * 100 / TimeInterval(normalizedSpeed)
        nextPacketDeadline.addTimeInterval(interval)
    }

    private func timeshiftStatus(playhead: Int64) -> [String: HTSPValue] {
        let end = max(liveEdge, playhead)
        return [
            "method": .string("timeshiftStatus"),
            "start": .int(end - Self.timeshiftPeriod * 1_000_000),
            "end": .int(end),
            "shift": .int(playhead - end),
        ]
    }

    private func positiveModulo(_ value: Int64, _ divisor: Int64) -> Int64 {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}
#endif
