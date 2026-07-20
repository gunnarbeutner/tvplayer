import AVFoundation
import Foundation

/// A short, low-volume confirmation sound for custom SwiftUI focus items.
///
/// The guide disables tvOS's standard focus effect so it can draw a stable,
/// accessible selection state. That also leaves focus movement feeling quiet,
/// so these screens explicitly play a restrained tick when focus really moves.
@MainActor
final class NavigationSoundPlayer {
    static let shared = NavigationSoundPlayer()

    private let player: AVAudioPlayer?
    private var lastPlayedAt: TimeInterval = 0

    private init() {
#if os(tvOS)
        player = try? AVAudioPlayer(data: Self.makeSound())
        player?.volume = 0.22
        player?.prepareToPlay()
#else
        player = nil
#endif
    }

    func play() {
#if os(tvOS)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPlayedAt >= 0.045 else { return }
        lastPlayedAt = now

        player?.currentTime = 0
        player?.play()
#endif
    }

    private static func makeSound() -> Data {
        let sampleRate: UInt32 = 48_000
        let duration = 0.032
        let sampleCount = Int(Double(sampleRate) * duration)
        let bytesPerSample: UInt16 = 2
        let dataSize = UInt32(sampleCount) * UInt32(bytesPerSample)

        var data = Data()
        data.append(contentsOf: Data("RIFF".utf8))
        append(UInt32(36) + dataSize, to: &data)
        data.append(contentsOf: Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(sampleRate, to: &data)
        append(sampleRate * UInt32(bytesPerSample), to: &data)
        append(bytesPerSample, to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: Data("data".utf8))
        append(dataSize, to: &data)

        for index in 0..<sampleCount {
            let time = Double(index) / Double(sampleRate)
            let attack = min(1, time / 0.002)
            let decay = exp(-92 * time)
            let phase = 2 * Double.pi * (560 * time - 1_800 * time * time)
            let tone = sin(phase) + 0.08 * sin(phase * 2)
            let value = Int16(clamping: Int(tone * attack * decay * 6_200))
            append(value, to: &data)
        }

        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
