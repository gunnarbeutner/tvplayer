#if os(tvOS)
import Foundation
import TVServices
@preconcurrency import VLCKit
import UIKit

enum RecordingTopShelfArtworkLayout {
    static let horizontalPadding: CGFloat = 64
    static let bottomPadding: CGFloat = 48

    static func logoPlateRect(in size: CGSize) -> CGRect {
        let plateSize = CGSize(width: 220, height: 112)
        return CGRect(
            x: size.width - horizontalPadding - plateSize.width,
            y: size.height - bottomPadding - plateSize.height,
            width: plateSize.width,
            height: plateSize.height
        )
    }

    static func textRect(in size: CGSize) -> CGRect {
        let logoPlate = logoPlateRect(in: size)
        return CGRect(
            x: horizontalPadding,
            y: size.height - 224,
            width: max(1, logoPlate.minX - horizontalPadding - 36),
            height: 176
        )
    }
}

enum RecordingTopShelfArtworkRenderer {
    static func drawOverlay(
        _ overlay: RecordingThumbnailOverlay,
        channelLogo: UIImage?,
        fallbackMonogram: String?,
        size: CGSize,
        context: CGContext
    ) {
        let horizontalPadding = RecordingTopShelfArtworkLayout.horizontalPadding
        let textRect = RecordingTopShelfArtworkLayout.textRect(in: size)
        let logoPlateRect = RecordingTopShelfArtworkLayout.logoPlateRect(in: size)

        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                UIColor.clear.cgColor,
                UIColor.black.withAlphaComponent(0.72).cgColor,
                UIColor.black.withAlphaComponent(0.94).cgColor,
            ] as CFArray,
            locations: [0, 0.54, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: size.height * 0.30),
                end: CGPoint(x: 0, y: size.height),
                options: []
            )
        }

        let badgeFont = UIFont.systemFont(ofSize: 25, weight: .bold)
        let badgeAttributes: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: UIColor.white,
        ]
        let badgeSize = (overlay.badge as NSString).size(withAttributes: badgeAttributes)
        let badgeRect = CGRect(
            x: horizontalPadding,
            y: 48,
            width: badgeSize.width + 36,
            height: badgeSize.height + 20
        )
        UIColor.black.withAlphaComponent(0.78).setFill()
        UIBezierPath(roundedRect: badgeRect, cornerRadius: 12).fill()
        (overlay.badge as NSString).draw(
            at: CGPoint(x: badgeRect.minX + 18, y: badgeRect.minY + 10),
            withAttributes: badgeAttributes
        )

        let logoPlateStyle = channelLogo
            .flatMap(contentLuminance)
            .map(RecordingTopShelfLogoPlateStyle.forContentLuminance)
            ?? .light
        let plateColor: UIColor
        let monogramColor: UIColor
        switch logoPlateStyle {
        case .light:
            plateColor = UIColor.white.withAlphaComponent(0.94)
            monogramColor = UIColor.black.withAlphaComponent(0.76)
        case .dark:
            plateColor = UIColor(
                red: 0.035,
                green: 0.043,
                blue: 0.059,
                alpha: 0.94
            )
            monogramColor = UIColor.white.withAlphaComponent(0.92)
        }
        plateColor.setFill()
        UIBezierPath(roundedRect: logoPlateRect, cornerRadius: 18).fill()
        let logoBounds = logoPlateRect.insetBy(dx: 20, dy: 16)
        if let channelLogo {
            channelLogo.draw(
                in: aspectFitRect(for: channelLogo.size, in: logoBounds)
            )
        } else if let fallbackMonogram, !fallbackMonogram.isEmpty {
            let monogramAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 54, weight: .black),
                .foregroundColor: monogramColor,
            ]
            let monogramSize = (fallbackMonogram as NSString).size(
                withAttributes: monogramAttributes
            )
            (fallbackMonogram as NSString).draw(
                at: CGPoint(
                    x: logoPlateRect.midX - monogramSize.width / 2,
                    y: logoPlateRect.midY - monogramSize.height / 2
                ),
                withAttributes: monogramAttributes
            )
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 56, weight: .bold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ]
        (overlay.title as NSString).draw(
            with: CGRect(
                x: textRect.minX,
                y: textRect.minY,
                width: textRect.width,
                height: 70
            ),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: titleAttributes,
            context: nil
        )

        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 30, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.90),
            .paragraphStyle: paragraph,
        ]
        if let detail = overlay.detail {
            (detail as NSString).draw(
                with: CGRect(
                    x: textRect.minX,
                    y: textRect.minY + 78,
                    width: textRect.width,
                    height: 40
                ),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: detailAttributes,
                context: nil
            )
        }

        let channelAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 25, weight: .medium),
            .foregroundColor: UIColor.white.withAlphaComponent(0.76),
        ]
        (overlay.channelName as NSString).draw(
            at: CGPoint(x: textRect.minX, y: textRect.maxY - 30),
            withAttributes: channelAttributes
        )
    }

    private static func aspectFitRect(
        for sourceSize: CGSize,
        in bounds: CGRect
    ) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return bounds }
        let scale = min(
            bounds.width / sourceSize.width,
            bounds.height / sourceSize.height
        )
        let size = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func contentLuminance(of image: UIImage) -> CGFloat? {
        guard let image = image.cgImage else { return nil }
        let dimension = 32
        let bytesPerRow = dimension * 4
        var pixels = [UInt8](
            repeating: 0,
            count: dimension * bytesPerRow
        )
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.clear(CGRect(x: 0, y: 0, width: dimension, height: dimension))
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: dimension, height: dimension)
            )
            return true
        }
        guard rendered else { return nil }

        var weightedLuminance: CGFloat = 0
        var totalWeight: CGFloat = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = CGFloat(pixels[index + 3]) / 255
            guard alpha > 0.04 else { continue }
            let red = min(1, CGFloat(pixels[index]) / 255 / alpha)
            let green = min(1, CGFloat(pixels[index + 1]) / 255 / alpha)
            let blue = min(1, CGFloat(pixels[index + 2]) / 255 / alpha)
            weightedLuminance += (
                red * 0.2126 + green * 0.7152 + blue * 0.0722
            ) * alpha
            totalWeight += alpha
        }
        guard totalWeight > 0 else { return nil }
        return weightedLuminance / totalWeight
    }
}

@MainActor
final class RecordingThumbnailGenerator {
    static let shared = RecordingThumbnailGenerator()

    private final class Request: NSObject, VLCMediaThumbnailerDelegate, @unchecked Sendable {
        private let completion: @Sendable (Data?) -> Void
        private let outputSize: CGSize
        private let overlay: RecordingThumbnailOverlay
        private let channelLogo: UIImage?
        private let media: VLCMedia
        private let library: VLCLibrary
        private var thumbnailer: VLCMediaThumbnailer?
        private var hasFinished = false

        init(
            media: VLCMedia,
            library: VLCLibrary,
            seekTarget: RecordingTopShelfThumbnailSeekTarget,
            outputSize: CGSize,
            overlay: RecordingThumbnailOverlay,
            channelLogoData: Data?,
            completion: @escaping @Sendable (Data?) -> Void
        ) {
            self.completion = completion
            self.outputSize = outputSize
            self.overlay = overlay
            self.channelLogo = channelLogoData.flatMap(UIImage.init(data:))
            self.media = media
            self.library = library
            super.init()

            let thumbnailer = VLCMediaThumbnailer(
                media: media,
                delegate: self,
                andVLCLibrary: library
            )
            thumbnailer.thumbnailWidth = outputSize.width
            thumbnailer.thumbnailHeight = outputSize.height
            switch seekTarget {
            case let .position(position):
                thumbnailer.snapshotPosition = position
            case let .time(milliseconds):
                thumbnailer.snapshotTime = VLCTime(
                    number: NSNumber(value: milliseconds)
                )
            }
            self.thumbnailer = thumbnailer
        }

        func start() {
            thumbnailer?.fetchThumbnail()
        }

        nonisolated func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
            Task { @MainActor [weak self] in
                self?.finish(with: nil)
            }
        }

        nonisolated func mediaThumbnailer(
            _ mediaThumbnailer: VLCMediaThumbnailer,
            didFinishThumbnail thumbnail: CGImage
        ) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                finish(
                    with: Self.jpegData(
                        from: thumbnail,
                        outputSize: outputSize,
                        overlay: overlay,
                        channelLogo: channelLogo
                    )
                )
            }
        }

        private func finish(with data: Data?) {
            guard !hasFinished else { return }
            hasFinished = true
            thumbnailer?.delegate = nil
            completion(data)
            // VLC invokes its delegate while the parser task is still
            // unwinding. Releasing VLCMediaThumbnailer from inside that
            // callback destroys the parser before VLCKit releases the task,
            // corrupting the next thumbnail request. Defer the final release
            // until the delegate stack has returned to VLCKit.
            DispatchQueue.main.async { [self] in
                thumbnailer = nil
            }
        }

        private static func jpegData(
            from image: CGImage,
            outputSize: CGSize,
            overlay: RecordingThumbnailOverlay,
            channelLogo: UIImage?
        ) -> Data? {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
            let rendered = renderer.image { context in
                UIColor.black.setFill()
                context.fill(CGRect(origin: .zero, size: outputSize))

                let sourceSize = CGSize(width: image.width, height: image.height)
                let scale = max(
                    outputSize.width / max(1, sourceSize.width),
                    outputSize.height / max(1, sourceSize.height)
                )
                let drawnSize = CGSize(
                    width: sourceSize.width * scale,
                    height: sourceSize.height * scale
                )
                let rect = CGRect(
                    x: (outputSize.width - drawnSize.width) / 2,
                    y: (outputSize.height - drawnSize.height) / 2,
                    width: drawnSize.width,
                    height: drawnSize.height
                )
                UIImage(cgImage: image).draw(in: rect)
                RecordingTopShelfArtworkRenderer.drawOverlay(
                    overlay,
                    channelLogo: channelLogo,
                    fallbackMonogram: Self.monogram(for: overlay.channelName),
                    size: outputSize,
                    context: context.cgContext
                )
            }
            return rendered.jpegData(compressionQuality: 0.82)
        }

        private static func monogram(for channelName: String) -> String {
            channelName.split(separator: " ").prefix(2)
                .compactMap(\.first)
                .map(String.init)
                .joined()
                .uppercased()
        }
    }

    private struct ActiveRequest {
        let request: Request
        let continuation: CheckedContinuation<Data?, Never>
    }

    private var activeRequests: [UUID: ActiveRequest] = [:]
    private let library = VLCLibrary.shared()

    func thumbnailData(
        for recording: TVRecording,
        overlay: RecordingThumbnailOverlay,
        channelLogoData: Data?,
        configuration: TVHeadendConfiguration
    ) async -> Data? {
        guard let url = try? await TVHeadendClient(configuration: configuration)
            .recordingStreamURL(recordingID: recording.id)
        else { return nil }

        guard let media = VLCMedia(url: url) else { return nil }
        let pointSize = TVTopShelfSectionedContent.imageSize(for: .hdtv)
        let outputSize = CGSize(
            width: max(1_216, pointSize.width * 2),
            height: max(684, pointSize.height * 2)
        )
        let seekTarget = RecordingTopShelfArtworkPolicy.thumbnailSeekTarget(
            for: recording,
            now: Date()
        )

        return await withCheckedContinuation { continuation in
            let id = UUID()
            let request = Request(
                media: media,
                library: library,
                seekTarget: seekTarget,
                outputSize: outputSize,
                overlay: overlay,
                channelLogoData: channelLogoData
            ) { [weak self] data in
                Task { await self?.completeRequest(id: id, data: data) }
            }
            activeRequests[id] = ActiveRequest(
                request: request,
                continuation: continuation
            )
            request.start()
        }
    }

    private func completeRequest(id: UUID, data: Data?) {
        guard let activeRequest = activeRequests.removeValue(forKey: id) else { return }
        activeRequest.continuation.resume(returning: data)
    }
}
#endif
