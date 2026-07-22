#if os(tvOS)
import AVKit
import Combine
import SwiftUI

@MainActor
final class PictureInPictureCoordinator: NSObject,
    @preconcurrency AVPictureInPictureControllerDelegate,
    @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate
{
    // Keep the implementation wired in while PiP is temporarily unavailable.
    // Flip this flag to restore the control and controller setup.
    private static let isFeatureEnabled = false

    private weak var playback: PlaybackCoordinator?
    private let engine: VLCPlaybackEngine
    private var controller: AVPictureInPictureController?
    private var startTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(engine: VLCPlaybackEngine) {
        self.engine = engine
        super.init()
        engine.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                await Task.yield()
                self?.configureIfReady()
                self?.controller?.invalidatePlaybackState()
            }
        }
        .store(in: &cancellables)
    }

    var isActive: Bool { controller?.isPictureInPictureActive == true }
    var isSupported: Bool {
        Self.isFeatureEnabled && AVPictureInPictureController.isPictureInPictureSupported()
    }
    var isPossible: Bool {
        engine.isPictureInPictureReady && controller?.isPictureInPicturePossible == true
    }

    func connect(to playback: PlaybackCoordinator) {
        self.playback = playback
        configureIfReady()
    }

    func start() {
        guard isSupported else { return }
        startTask?.cancel()
        startTask = Task { @MainActor [weak self] in
            guard let self,
                  await engine.prepareForPictureInPicture(),
                  !Task.isCancelled
            else { return }
            configureIfReady()
            controller?.startPictureInPicture()
            startTask = nil
        }
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    private func configureIfReady() {
        guard Self.isFeatureEnabled,
              controller == nil,
              engine.isPictureInPictureReady
        else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: engine.sampleBufferBridge.displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        self.controller = controller
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        playing ? engine.play() : engine.pause()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        guard let presentation = playback?.presentation else { return .invalid }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if presentation.recording == nil {
            return CMTimeRange(start: now, duration: .positiveInfinity)
        }
        let duration = engine.durationSeconds ?? presentation.recording?.duration ?? 0
        let elapsed = min(max(0, engine.elapsedSeconds), duration)
        return CMTimeRange(
            start: now - CMTime(seconds: elapsed, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        engine.state == .paused
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion: @escaping () -> Void
    ) {
        let seconds = skipInterval.seconds
        if seconds >= 0 {
            _ = engine.skipForward(by: seconds)
        } else {
            engine.skipBackward(by: abs(seconds))
        }
        completion()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        playback?.restorePlayerFromPictureInPicture()
        completionHandler(playback != nil)
    }
}

struct VLCSampleBufferVideoSurface: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let fadesLeadingEdge: Bool
    let leadingFadeInset: CGFloat

    func makeUIView(context: Context) -> SampleBufferHostView {
        SampleBufferHostView(
            displayLayer: displayLayer,
            fadesLeadingEdge: fadesLeadingEdge,
            leadingFadeInset: leadingFadeInset
        )
    }

    func updateUIView(_ view: SampleBufferHostView, context: Context) {
        view.updateFade(fadesLeadingEdge: fadesLeadingEdge, leadingFadeInset: leadingFadeInset)
    }
}

final class SampleBufferHostView: UIView {
    private let displayLayer: AVSampleBufferDisplayLayer
    private let leadingFadeMask = CAGradientLayer()
    private var fadesLeadingEdge: Bool
    private var leadingFadeInset: CGFloat

    init(
        displayLayer: AVSampleBufferDisplayLayer,
        fadesLeadingEdge: Bool,
        leadingFadeInset: CGFloat
    ) {
        self.displayLayer = displayLayer
        self.fadesLeadingEdge = fadesLeadingEdge
        self.leadingFadeInset = leadingFadeInset
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        layer.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
        updateMask()
    }

    func updateFade(fadesLeadingEdge: Bool, leadingFadeInset: CGFloat) {
        self.fadesLeadingEdge = fadesLeadingEdge
        self.leadingFadeInset = leadingFadeInset
        updateMask()
    }

    private func updateMask() {
        guard fadesLeadingEdge else {
            layer.mask = nil
            return
        }
        GuideArtworkStyle.applyLeadingFadeMask(
            leadingFadeMask,
            to: layer,
            bounds: bounds,
            leadingInset: leadingFadeInset,
            clearColor: UIColor.clear.cgColor,
            translucentColor: UIColor.black.withAlphaComponent(0.48).cgColor,
            opaqueColor: UIColor.black.cgColor
        )
    }
}
#endif
