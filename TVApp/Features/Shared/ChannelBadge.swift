import CryptoKit
import Foundation
import SwiftUI
import UIKit

struct ChannelBadge: View {
    let channel: GuideChannel
    let diameter: CGFloat

    @EnvironmentObject private var settings: ServerSettingsStore
    @State private var loadedArtwork: ChannelLogoArtwork?
    @State private var loadedKey: String?
    @State private var failedKey: String?

    init(channel: GuideChannel, diameter: CGFloat) {
        self.channel = channel
        self.diameter = diameter

        let key = channel.iconURL.map(ChannelLogoImageCache.cacheKey)
        let artwork = channel.iconURL.flatMap(ChannelLogoImageCache.shared.cachedArtwork)
        _loadedArtwork = State(initialValue: artwork)
        _loadedKey = State(initialValue: artwork == nil ? nil : key)
    }

    var body: some View {
        ZStack {
            Circle().fill(channel.tint.gradient)

            if let artwork = displayedArtwork {
                AdaptiveChannelLogo(
                    artwork: artwork,
                    fallbackTint: channel.tint,
                    diameter: diameter
                )
            } else if channel.iconURL == nil || failedKey == currentKey {
                monogram
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay { Circle().stroke(.white.opacity(0.24), lineWidth: 1) }
        .accessibilityHidden(true)
        .task(id: ChannelLogoLoadID(
            url: channel.iconURL,
            settingsRevision: settings.revision
        )) {
            await loadLogo()
        }
    }

    private var currentKey: String? {
        channel.iconURL.map(ChannelLogoImageCache.cacheKey)
    }

    /// Reading the shared cache in `body` is intentional. A badge that is
    /// remounted after another badge loaded the same artwork can paint the
    /// decoded image on its first frame instead of briefly showing a monogram.
    private var displayedArtwork: ChannelLogoArtwork? {
        if loadedKey == currentKey, let loadedArtwork { return loadedArtwork }
        guard let iconURL = channel.iconURL else { return nil }
        return ChannelLogoImageCache.shared.cachedArtwork(for: iconURL)
    }

    private var monogram: some View {
        Text(channel.monogram)
            .font(.system(size: diameter * 0.31, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.6)
    }

    @MainActor
    private func loadLogo() async {
        guard let iconURL = channel.iconURL else {
            loadedArtwork = nil
            loadedKey = nil
            failedKey = nil
            return
        }

        let key = ChannelLogoImageCache.cacheKey(for: iconURL)
        failedKey = nil

        if let artwork = ChannelLogoImageCache.shared.cachedArtwork(for: iconURL) {
            loadedArtwork = artwork
            loadedKey = key
            return
        }

        // Do not replace a previous channel's image with its monogram while a
        // newly reused badge loads. `displayedArtwork` ignores the stale key,
        // leaving a quiet tinted surface until the correct image is ready.
        loadedArtwork = nil
        loadedKey = nil

        do {
            let artwork = try await ChannelLogoDataLoader.shared.artwork(
                at: iconURL,
                configuration: settings.configuration
            )
            guard !Task.isCancelled else { return }
            loadedArtwork = artwork
            loadedKey = key
        } catch {
            guard !Task.isCancelled else { return }
            failedKey = key
        }
    }
}

private struct ChannelLogoLoadID: Hashable {
    let url: URL?
    let settingsRevision: Int
}

struct ChannelLogoArtwork: @unchecked Sendable {
    let image: UIImage
    let backgroundTone: ChannelLogoBackgroundTone?
}

/// A decoded memory cache backed by the app's caches directory. The lookup is
/// synchronous by design so SwiftUI views can paint an already-known logo on
/// their very first frame. Only a SHA-256 digest is used as a filename; server
/// credentials and authentication query values are never persisted.
final class ChannelLogoImageCache: @unchecked Sendable {
    static let shared = ChannelLogoImageCache()

    private final class ArtworkBox: NSObject {
        let artwork: ChannelLogoArtwork

        init(_ artwork: ChannelLogoArtwork) {
            self.artwork = artwork
        }
    }

    private let memory = NSCache<NSString, ArtworkBox>()
    private let lock = NSLock()
    private var checkedDiskKeys: Set<String> = []
    private let directoryURL: URL?

    init(fileManager: FileManager = .default) {
        directoryURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appending(path: "ChannelLogos-v1", directoryHint: .isDirectory)
        memory.countLimit = 256
        memory.totalCostLimit = 32 * 1_024 * 1_024
    }

    func cachedArtwork(for url: URL) -> ChannelLogoArtwork? {
        let key = Self.cacheKey(for: url)
        if let artwork = memory.object(forKey: key as NSString)?.artwork {
            return artwork
        }

        // Avoid synchronous filesystem work on every SwiftUI body evaluation.
        lock.lock()
        let hasCheckedDisk = checkedDiskKeys.contains(key)
        if !hasCheckedDisk { checkedDiskKeys.insert(key) }
        lock.unlock()
        guard !hasCheckedDisk, let fileURL = fileURL(for: key),
              let data = try? Data(contentsOf: fileURL),
              let artwork = Self.decode(data)
        else { return nil }

        storeInMemory(artwork, dataCost: data.count, key: key)
        return artwork
    }

    @discardableResult
    func store(data: Data, for url: URL) -> ChannelLogoArtwork? {
        guard let artwork = Self.decode(data) else { return nil }
        let key = Self.cacheKey(for: url)
        storeInMemory(artwork, dataCost: data.count, key: key)

        lock.lock()
        checkedDiskKeys.insert(key)
        lock.unlock()

        if let fileURL = fileURL(for: key) {
            Task.detached(priority: .utility) {
                do {
                    try FileManager.default.createDirectory(
                        at: fileURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: fileURL, options: .atomic)
                } catch {
                    // This is an opportunistic performance cache. A
                    // filesystem failure must not prevent the decoded
                    // in-memory image from being displayed.
                }
            }
        }
        return artwork
    }

    static func cacheKey(for url: URL) -> String {
        let canonicalURL = canonicalResourceIdentifier(for: url)
        let digest = SHA256.hash(data: Data(canonicalURL.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalResourceIdentifier(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.user = nil
        components.password = nil
        components.fragment = nil

        let credentialNames: Set<String> = [
            "access_token", "auth", "authorization", "pass", "password",
            "ticket", "token", "user", "username",
        ]
        if let queryItems = components.queryItems {
            let retainedItems = queryItems
                .filter { !credentialNames.contains($0.name.lowercased()) }
                .sorted {
                    if $0.name == $1.name { return ($0.value ?? "") < ($1.value ?? "") }
                    return $0.name < $1.name
                }
            components.queryItems = retainedItems.isEmpty ? nil : retainedItems
        }
        return components.string ?? url.absoluteString
    }

    private func fileURL(for key: String) -> URL? {
        directoryURL?.appending(path: key).appendingPathExtension("image")
    }

    private func storeInMemory(_ artwork: ChannelLogoArtwork, dataCost: Int, key: String) {
        memory.setObject(
            ArtworkBox(artwork),
            forKey: key as NSString,
            cost: max(dataCost, artwork.image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        )
    }

    private static func decode(_ data: Data) -> ChannelLogoArtwork? {
        guard let image = UIImage(data: data) else { return nil }
        return ChannelLogoArtwork(
            image: image,
            backgroundTone: image.cgImage.flatMap(ChannelLogoContrast.backgroundTone)
        )
    }
}

/// Shares authenticated requests between the guide, channel list, detail view
/// and player. The decoded cache above handles immediate rendering; this actor
/// only coalesces in-flight network requests.
private actor ChannelLogoDataLoader {
    static let shared = ChannelLogoDataLoader()

    private struct Key: Hashable {
        let imageKey: String
        let configurationIdentifier: String
    }

    private var requestsByKey: [Key: Task<ChannelLogoArtwork, Error>] = [:]
    private var clientConfiguration: TVHeadendConfiguration?
    private var client: TVHeadendClient?

    func artwork(
        at url: URL,
        configuration: TVHeadendConfiguration
    ) async throws -> ChannelLogoArtwork {
        if let artwork = ChannelLogoImageCache.shared.cachedArtwork(for: url) {
            return artwork
        }

        let key = Key(
            imageKey: ChannelLogoImageCache.cacheKey(for: url),
            configurationIdentifier: configuration.guideSnapshotIdentifier
        )
        if let request = requestsByKey[key] { return try await request.value }

        let client: TVHeadendClient
        if clientConfiguration == configuration, let existingClient = self.client {
            client = existingClient
        } else {
            client = TVHeadendClient(configuration: configuration)
            clientConfiguration = configuration
            self.client = client
        }
        let request = Task {
            let data = try await client.fetchChannelIcon(at: url)
            guard let artwork = ChannelLogoImageCache.shared.store(data: data, for: url) else {
                throw TVProviderError.invalidResponse
            }
            return artwork
        }
        requestsByKey[key] = request

        do {
            let artwork = try await request.value
            requestsByKey[key] = nil
            return artwork
        } catch {
            requestsByKey[key] = nil
            throw error
        }
    }
}

private struct AdaptiveChannelLogo: View {
    let artwork: ChannelLogoArtwork
    let fallbackTint: Color
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(backgroundColor)

            Image(uiImage: artwork.image)
                .resizable()
                .scaledToFit()
                .padding(diameter * 0.12)
                .shadow(color: foregroundEdgeColor, radius: 0.8)
        }
    }

    private var backgroundColor: Color {
        switch artwork.backgroundTone {
        case .light:
            Color(red: 0.94, green: 0.95, blue: 0.97)
        case .dark:
            Color(red: 0.055, green: 0.065, blue: 0.085)
        case nil:
            fallbackTint
        }
    }

    private var foregroundEdgeColor: Color {
        switch artwork.backgroundTone {
        case .light: .black.opacity(0.22)
        case .dark: .white.opacity(0.18)
        case nil: .clear
        }
    }
}

enum ChannelLogoBackgroundTone {
    case light
    case dark
}

enum ChannelLogoContrast {
    static func backgroundTone(for image: CGImage) -> ChannelLogoBackgroundTone? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let lightBackgroundLuminance = 0.90
        let darkBackgroundLuminance = 0.006
        var lightScore = 0.0
        var darkScore = 0.0
        var totalWeight = 0.0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha >= 0.08 else { continue }

            let red = min(1, Double(pixels[index]) / 255 / alpha)
            let green = min(1, Double(pixels[index + 1]) / 255 / alpha)
            let blue = min(1, Double(pixels[index + 2]) / 255 / alpha)
            let luminance = relativeLuminance(red: red, green: green, blue: blue)
            let weight = alpha * alpha

            lightScore += log(contrastRatio(luminance, lightBackgroundLuminance)) * weight
            darkScore += log(contrastRatio(luminance, darkBackgroundLuminance)) * weight
            totalWeight += weight
        }

        guard totalWeight > 1 else { return nil }
        return lightScore >= darkScore ? .light : .dark
    }

    private static func contrastRatio(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        (0.2126 * linearized(red)) + (0.7152 * linearized(green)) + (0.0722 * linearized(blue))
    }

    private static func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
