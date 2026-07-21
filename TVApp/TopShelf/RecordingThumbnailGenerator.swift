#if os(tvOS)
import Foundation
import TVServices
@preconcurrency import TVVLCKit
import UIKit

actor RecordingThumbnailGenerator {
    static let shared = RecordingThumbnailGenerator()

    private final class Request: NSObject, VLCMediaThumbnailerDelegate {
        private let completion: @Sendable (Data?) -> Void
        private let outputSize: CGSize
        private var thumbnailer: VLCMediaThumbnailer?

        init(
            media: VLCMedia,
            snapshotPosition: Float,
            outputSize: CGSize,
            completion: @escaping @Sendable (Data?) -> Void
        ) {
            self.completion = completion
            self.outputSize = outputSize
            super.init()

            let thumbnailer = VLCMediaThumbnailer(
                media: media,
                delegate: self,
                andVLCLibrary: nil
            )
            thumbnailer.thumbnailWidth = outputSize.width
            thumbnailer.thumbnailHeight = outputSize.height
            thumbnailer.snapshotPosition = snapshotPosition
            self.thumbnailer = thumbnailer
        }

        func start() {
            thumbnailer?.fetchThumbnail()
        }

        func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
            finish(with: nil)
        }

        func mediaThumbnailer(
            _ mediaThumbnailer: VLCMediaThumbnailer,
            didFinishThumbnail thumbnail: CGImage
        ) {
            finish(with: Self.jpegData(from: thumbnail, outputSize: outputSize))
        }

        private func finish(with data: Data?) {
            thumbnailer?.delegate = nil
            thumbnailer = nil
            completion(data)
        }

        private static func jpegData(from image: CGImage, outputSize: CGSize) -> Data? {
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
            }
            return rendered.jpegData(compressionQuality: 0.82)
        }
    }

    private struct ActiveRequest {
        let request: Request
        let continuation: CheckedContinuation<Data?, Never>
    }

    private var activeRequests: [UUID: ActiveRequest] = [:]

    func thumbnailData(
        for recording: TVRecording,
        configuration: TVHeadendConfiguration
    ) async -> Data? {
        guard let url = try? await TVHeadendClient(configuration: configuration)
            .recordingStreamURL(recordingID: recording.id)
        else { return nil }

        let media = VLCMedia(url: url)
        let pointSize = TVTopShelfSectionedContent.imageSize(for: .hdtv)
        let outputSize = CGSize(
            width: max(1_216, pointSize.width * 2),
            height: max(684, pointSize.height * 2)
        )
        let position = RecordingTopShelfArtworkPolicy.snapshotPosition(for: recording.state)

        return await withCheckedContinuation { continuation in
            let id = UUID()
            let request = Request(
                media: media,
                snapshotPosition: position,
                outputSize: outputSize
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
