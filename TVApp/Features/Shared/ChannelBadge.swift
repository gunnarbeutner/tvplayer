import CryptoKit
import Foundation
import ImageIO
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
#endif

private extension PlatformImage {
    var channelLogoCGImage: CGImage? {
#if canImport(UIKit)
        cgImage
#else
        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
#endif
    }
}

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
        let artwork = channel.iconURL.flatMap {
            ChannelLogoImageCache.shared.memoryArtwork(for: $0)
        }
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

    /// Reading the memory cache in `body` is intentional. A badge that is
    /// remounted after another badge loaded the same artwork can paint the
    /// decoded image on its first frame without doing disk work while SwiftUI
    /// is rendering.
    private var displayedArtwork: ChannelLogoArtwork? {
        if loadedKey == currentKey, let loadedArtwork { return loadedArtwork }
        guard let iconURL = channel.iconURL else { return nil }
        return ChannelLogoImageCache.shared.memoryArtwork(for: iconURL)
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

        if let artwork = ChannelLogoImageCache.shared.memoryArtwork(for: iconURL) {
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
    let image: PlatformImage
    let backgroundTone: ChannelLogoBackgroundTone?
}

enum CachedArtworkKind: String, Hashable, Sendable {
    case channelLogo
    case programmeArtwork
}

/// A decoded memory cache backed by raw image data in the app's caches
/// directory. SwiftUI render paths use the memory-only lookup; disk access and
/// decoding are performed by `ChannelLogoDataLoader` on its actor executor.
/// Only a SHA-256 digest is used as a filename; server credentials and
/// authentication query values are never persisted.
final class ChannelLogoImageCache: @unchecked Sendable {
    static let shared = ChannelLogoImageCache()

    private final class ArtworkBox: NSObject {
        let artwork: ChannelLogoArtwork

        init(_ artwork: ChannelLogoArtwork) {
            self.artwork = artwork
        }
    }

    private let memory = NSCache<NSString, ArtworkBox>()
    private let directoryURL: URL?

    convenience init(fileManager: FileManager = .default) {
        self.init(directoryURL: fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appending(path: "ChannelLogos-v1", directoryHint: .isDirectory))
    }

    init(directoryURL: URL?) {
        self.directoryURL = directoryURL
        memory.countLimit = 256
        memory.totalCostLimit = 32 * 1_024 * 1_024
    }

    fileprivate func loadArtworkFromDisk(
        for url: URL,
        kind: CachedArtworkKind
    ) -> ChannelLogoArtwork? {
        let resourceKey = Self.cacheKey(for: url)
        let memoryKey = Self.memoryKey(resourceKey: resourceKey, kind: kind)
        if let artwork = memoryArtwork(forKey: memoryKey) {
            return artwork
        }

        guard let fileURL = fileURL(for: resourceKey),
              let data = try? Data(contentsOf: fileURL),
              let artwork = Self.decode(data, kind: kind)
        else { return nil }

        storeInMemory(artwork, dataCost: data.count, key: memoryKey)
        return artwork
    }

    /// Safe to call from view construction and other latency-sensitive paths.
    /// This never reads or decodes a file synchronously on the caller.
    func memoryArtwork(
        for url: URL,
        kind: CachedArtworkKind = .channelLogo
    ) -> ChannelLogoArtwork? {
        let resourceKey = Self.cacheKey(for: url)
        return memoryArtwork(forKey: Self.memoryKey(resourceKey: resourceKey, kind: kind))
    }

    @discardableResult
    func store(
        data: Data,
        for url: URL,
        kind: CachedArtworkKind = .channelLogo
    ) -> ChannelLogoArtwork? {
        guard let artwork = Self.decode(data, kind: kind) else { return nil }
        let resourceKey = Self.cacheKey(for: url)
        let memoryKey = Self.memoryKey(resourceKey: resourceKey, kind: kind)
        storeInMemory(artwork, dataCost: data.count, key: memoryKey)

        if let fileURL = fileURL(for: resourceKey) {
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

    private static func memoryKey(
        resourceKey: String,
        kind: CachedArtworkKind
    ) -> String {
        "\(kind.rawValue):\(resourceKey)"
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
            cost: max(dataCost, artwork.image.channelLogoCGImage.map { $0.bytesPerRow * $0.height } ?? 0)
        )
    }

    private func memoryArtwork(forKey key: String) -> ChannelLogoArtwork? {
        memory.object(forKey: key as NSString)?.artwork
    }

    private static func decode(
        _ data: Data,
        kind: CachedArtworkKind
    ) -> ChannelLogoArtwork? {
        guard let image = image(from: data, kind: kind) else { return nil }
        return ChannelLogoArtwork(
            image: image,
            backgroundTone: kind == .channelLogo
                ? image.channelLogoCGImage.flatMap(ChannelLogoContrast.backgroundTone)
                : nil
        )
    }

    private static func image(
        from data: Data,
        kind: CachedArtworkKind
    ) -> PlatformImage? {
        guard kind == .programmeArtwork else {
            return PlatformImage(data: data)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_280,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }

#if canImport(UIKit)
        return PlatformImage(cgImage: image)
#else
        return PlatformImage(cgImage: image, size: .zero)
#endif
    }
}

/// Shares authenticated requests between the guide, channel list, detail view
/// and player. The decoded cache above handles immediate rendering; this actor
/// only coalesces in-flight network requests.
actor ChannelLogoDataLoader {
    static let shared = ChannelLogoDataLoader()

    private struct Key: Hashable {
        let imageKey: String
        let configurationIdentifier: String
        let kind: CachedArtworkKind
    }

    private var requestsByKey: [Key: Task<ChannelLogoArtwork, Error>] = [:]
    private var clientConfiguration: TVHeadendConfiguration?
    private var client: TVHeadendClient?

    func artwork(
        at url: URL,
        configuration: TVHeadendConfiguration,
        kind: CachedArtworkKind = .channelLogo
    ) async throws -> ChannelLogoArtwork {
        if let artwork = ChannelLogoImageCache.shared.memoryArtwork(for: url, kind: kind) {
            return artwork
        }
        if let artwork = ChannelLogoImageCache.shared.loadArtworkFromDisk(for: url, kind: kind) {
            return artwork
        }

        let key = Key(
            imageKey: ChannelLogoImageCache.cacheKey(for: url),
            configurationIdentifier: configuration.guideSnapshotIdentifier,
            kind: kind
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
            guard let artwork = ChannelLogoImageCache.shared.store(
                data: data,
                for: url,
                kind: kind
            ) else {
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

            platformImage
                .resizable()
                .scaledToFit()
                .padding(diameter * 0.12)
                .shadow(color: foregroundEdgeColor, radius: 0.8)
        }
    }

    private var platformImage: Image {
#if canImport(UIKit)
        Image(uiImage: artwork.image)
#else
        Image(nsImage: artwork.image)
#endif
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
