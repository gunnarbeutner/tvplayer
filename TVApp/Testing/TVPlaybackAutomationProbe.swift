import SwiftUI

#if DEBUG && os(tvOS)
import UIKit

private struct TVGuideAutomationSnapshot: Codable {
    let version: Int
    let sampledAt: TimeInterval
    let focusedProgramID: String?
    let focusedProgramChannelID: String?
    let focusedChannelID: String?
    let programMarkerIDs: [String]
    let channelMarkerIDs: [String]
    let displayedChannelIDs: [String]
    let focusableChannelIDs: [String]
    let favoriteChannelIDs: [String]
    let channelRestorationPending: Bool
    let markerOverlapCount: Int
    let programMarkerDuringChannelRestorationCount: Int
}

@MainActor
final class TVGuideAutomationFocusRecorder: ObservableObject {
    static let shared = TVGuideAutomationFocusRecorder()

    @Published private(set) var revision = 0
    private var focusedProgramID: String?
    private var focusedChannelID: String?
    private var programChannelByID: [String: String] = [:]
    private var programMarkerIDs: Set<String> = []
    private var channelMarkerIDs: Set<String> = []
    private var displayedChannelIDs: [String] = []
    private var focusableChannelIDs: [String] = []
    private var favoriteChannelIDs: Set<String> = []
    private var channelRestorationPending = false
    private var markerOverlapCount = 0
    private var programMarkerDuringChannelRestorationCount = 0
    private var overlapViolationActive = false
    private var restorationViolationActive = false

    private init() {}

    func updateGuide(
        channelIDs: [String],
        favoriteChannelIDs: Set<String>
    ) {
        guard TVGuideAutomation.isEnabled else { return }
        displayedChannelIDs = channelIDs
        self.favoriteChannelIDs = favoriteChannelIDs
        publish()
    }

    func updateProgram(
        id: String,
        channelID: String,
        isFocused: Bool,
        presentsMarker: Bool
    ) {
        guard TVGuideAutomation.isEnabled else { return }
        programChannelByID[id] = channelID
        if isFocused {
            focusedProgramID = id
        } else if focusedProgramID == id {
            focusedProgramID = nil
        }
        if presentsMarker {
            programMarkerIDs.insert(id)
        } else {
            programMarkerIDs.remove(id)
        }
        evaluateViolations()
        publish()
    }

    func removeProgram(id: String) {
        guard TVGuideAutomation.isEnabled else { return }
        if focusedProgramID == id { focusedProgramID = nil }
        programChannelByID.removeValue(forKey: id)
        programMarkerIDs.remove(id)
        evaluateViolations()
        publish()
    }

    func updateChannel(id: String, isFocused: Bool) {
        guard TVGuideAutomation.isEnabled else { return }
        if isFocused {
            focusedChannelID = id
            channelMarkerIDs.insert(id)
        } else {
            if focusedChannelID == id { focusedChannelID = nil }
            channelMarkerIDs.remove(id)
        }
        evaluateViolations()
        publish()
    }

    func removeChannel(id: String) {
        guard TVGuideAutomation.isEnabled else { return }
        if focusedChannelID == id { focusedChannelID = nil }
        channelMarkerIDs.remove(id)
        evaluateViolations()
        publish()
    }

    func updateFocusOrder(channelIDs: [String]) {
        guard TVGuideAutomation.isEnabled else { return }
        focusableChannelIDs = channelIDs
        publish()
    }

    func beginChannelRestoration(channelID: String) {
        guard TVGuideAutomation.isEnabled else { return }
        channelRestorationPending = true
        focusedChannelID = channelID
        evaluateViolations()
        publish()
    }

    func endChannelRestoration() {
        guard TVGuideAutomation.isEnabled else { return }
        channelRestorationPending = false
        evaluateViolations()
        publish()
    }

    var encodedSnapshot: String {
        let snapshot = TVGuideAutomationSnapshot(
            version: 2,
            sampledAt: ProcessInfo.processInfo.systemUptime,
            focusedProgramID: focusedProgramID,
            focusedProgramChannelID: focusedProgramID.flatMap {
                programChannelByID[$0]
            },
            focusedChannelID: focusedChannelID,
            programMarkerIDs: programMarkerIDs.sorted(),
            channelMarkerIDs: channelMarkerIDs.sorted(),
            displayedChannelIDs: displayedChannelIDs,
            focusableChannelIDs: focusableChannelIDs,
            favoriteChannelIDs: favoriteChannelIDs.sorted(),
            channelRestorationPending: channelRestorationPending,
            markerOverlapCount: markerOverlapCount,
            programMarkerDuringChannelRestorationCount:
                programMarkerDuringChannelRestorationCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(snapshot),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    private func evaluateViolations() {
        let hasOverlap = !programMarkerIDs.isEmpty && !channelMarkerIDs.isEmpty
        if hasOverlap, !overlapViolationActive {
            markerOverlapCount += 1
        }
        overlapViolationActive = hasOverlap

        let hasRestorationViolation =
            channelRestorationPending && !programMarkerIDs.isEmpty
        if hasRestorationViolation, !restorationViolationActive {
            programMarkerDuringChannelRestorationCount += 1
        }
        restorationViolationActive = hasRestorationViolation
    }

    private func publish() {
        revision &+= 1
    }
}

struct TVGuideAutomationProbe: View {
    @ObservedObject private var recorder =
        TVGuideAutomationFocusRecorder.shared

    var body: some View {
        Text("Guide automation probe")
            .font(.system(size: 1))
            .opacity(0.001)
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(TVGuideAutomation.probeIdentifier)
            .accessibilityLabel("Guide automation probe")
            .accessibilityValue(recorder.encodedSnapshot)
    }
}

private struct TVPlaybackAutomationSnapshot: Codable {
    let version: Int
    let sampledAt: TimeInterval
    let channelID: String?
    let presentationID: String?
    let playerPresented: Bool
    let launchVisible: Bool
    let engineState: String
    let vlcState: String
    let isPlaying: Bool
    let isSeekable: Bool
    let audioTrackCount: Int
    let displayedPictures: Int
    let playedAudioBuffers: Int
    let decodedVideo: Int
    let decodedAudio: Int
    let lostPictures: Int
    let lostAudioBuffers: Int
    let playbackTimeMilliseconds: Int64?
    let audioUnderruns: Int
    let lateClockCorrections: Int
    let earlyClockCorrections: Int
    let timeshiftWindowSeconds: TimeInterval
    let liveDelaySeconds: TimeInterval
    let bufferedBytes: Int64
    let concealed: Bool
    let navigationState: String
    let recoveryCount: Int
    let pipelineDiagnostic: String?
    let surfaceMode: String
    let surfaceWidth: Double
    let surfaceHeight: Double
    let videoTrackWidth: Int
    let videoTrackHeight: Int
    let videoSizeWidth: Double
    let videoSizeHeight: Double
}

struct TVPlaybackAutomationProbe: View {
    @ObservedObject var playback: PlaybackCoordinator
    @ObservedObject private var engine: VLCPlaybackEngine
    let showsGuidePreview: Bool
    @State private var encodedSnapshot = "{}"

    init(playback: PlaybackCoordinator, showsGuidePreview: Bool) {
        self.playback = playback
        _engine = ObservedObject(wrappedValue: playback.engine)
        self.showsGuidePreview = showsGuidePreview
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                TVPlaybackAutomationRemoteBridge()
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)

                Text("Playback automation probe")
                    .font(.system(size: 1))
                    .opacity(0.001)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier(TVPlaybackAutomation.probeIdentifier)
                    .accessibilityLabel("Playback automation probe")
                    .accessibilityValue(encodedSnapshot)
                    .task(id: probeTaskID(size: proxy.size)) {
                        while !Task.isCancelled {
                            engine.refreshPlaybackInformation()
                            encodedSnapshot = encodeSnapshot(size: proxy.size)
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(false)
    }

    private func probeTaskID(size: CGSize) -> String {
        [
            playback.presentation?.id.uuidString ?? "none",
            playback.isPlayerPresented.description,
            showsGuidePreview.description,
            "\(Int(size.width))x\(Int(size.height))",
        ].joined(separator: ":")
    }

    private func encodeSnapshot(size: CGSize) -> String {
        let output = engine.playbackOutputSnapshot
        let audio = engine.vlcAudioOutputDiagnostics
        let selectedVideo = engine.mediaPlayer.videoTracks
            .first(where: \.isSelected)?
            .video
        let videoSize = engine.mediaPlayer.videoSize
        let snapshot = TVPlaybackAutomationSnapshot(
            version: 1,
            sampledAt: ProcessInfo.processInfo.systemUptime,
            channelID: playback.presentation?.channel.id,
            presentationID: playback.presentation?.id.uuidString,
            playerPresented: playback.isPlayerPresented,
            launchVisible: playback.launchPresentation != nil,
            engineState: String(describing: engine.state),
            vlcState: String(describing: engine.mediaPlayer.state),
            isPlaying: engine.mediaPlayer.isPlaying,
            isSeekable: engine.isSeekable,
            audioTrackCount: engine.audioTracks.count,
            displayedPictures: output.displayedPictures,
            playedAudioBuffers: output.playedAudioBuffers,
            decodedVideo: output.decodedVideo,
            decodedAudio: output.decodedAudio,
            lostPictures: output.lostPictures,
            lostAudioBuffers: output.lostAudioBuffers,
            playbackTimeMilliseconds: output.playbackTimeMilliseconds,
            audioUnderruns: audio.coreAudioUnderruns,
            lateClockCorrections: audio.lateClockCorrections,
            earlyClockCorrections: audio.earlyClockCorrections,
            timeshiftWindowSeconds: engine.timeshiftWindowSeconds,
            liveDelaySeconds: engine.liveDelaySeconds,
            bufferedBytes: engine.bufferedBytes,
            concealed: engine.isPlaybackOutputConcealed,
            navigationState: engine.timeshiftNavigationDebugState,
            recoveryCount: engine.nativeTimeshiftRecoveryCount,
            pipelineDiagnostic: engine.lastNativePipelineDiagnostic,
            surfaceMode: playback.isPlayerPresented
                ? "fullScreen"
                : (showsGuidePreview ? "guidePreview" : "hidden"),
            surfaceWidth: size.width,
            surfaceHeight: size.height,
            videoTrackWidth: Int(selectedVideo?.width ?? 0),
            videoTrackHeight: Int(selectedVideo?.height ?? 0),
            videoSizeWidth: videoSize.width,
            videoSizeHeight: videoSize.height
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(snapshot),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}

private struct TVPlaybackAutomationRemoteBridge: UIViewRepresentable {
    func makeUIView(context: Context) -> TVPlaybackAutomationRemoteBridgeView {
        TVPlaybackAutomationRemoteBridgeView()
    }

    func updateUIView(
        _ uiView: TVPlaybackAutomationRemoteBridgeView,
        context: Context
    ) {}
}

@MainActor
private final class TVPlaybackAutomationRemoteBridgeView: UIView,
    UIGestureRecognizerDelegate {
    private weak var installedWindow: UIWindow?
    private var recognizers: [UIGestureRecognizer] = []

    override func didMoveToWindow() {
        super.didMoveToWindow()
        uninstall()
        guard let window else { return }
        installedWindow = window
        installPagePress(.pageUp, direction: .up, in: window)
        // XCTest only delivers held directional presses to SwiftUI as a
        // release-time move. Page Down is therefore the automation-only
        // carrier for the same begin/end seek handler used by a real remote.
        installSeekPress(.pageDown, direction: .backward, in: window)
        installSeekPress(.leftArrow, direction: .backward, in: window)
        installSeekPress(.rightArrow, direction: .forward, in: window)
    }

    private func installPagePress(
        _ pressType: UIPress.PressType,
        direction: TVPageDirection,
        in window: UIWindow
    ) {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handlePagePress(_:))
        )
        recognizer.minimumPressDuration = 0
        recognizer.cancelsTouchesInView = false
        recognizer.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
        recognizer.delegate = self
        recognizer.name = direction == .up ? "page-up" : "page-down"
        window.addGestureRecognizer(recognizer)
        recognizers.append(recognizer)
    }

    private func installSeekPress(
        _ pressType: UIPress.PressType,
        direction: TVPlayerSeekDirection,
        in window: UIWindow
    ) {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleSeekPress(_:))
        )
        recognizer.minimumPressDuration = 0
        recognizer.cancelsTouchesInView = false
        recognizer.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
        recognizer.delegate = self
        recognizer.name = direction == .backward ? "seek-backward" : "seek-forward"
        window.addGestureRecognizer(recognizer)
        recognizers.append(recognizer)
    }

    @objc private func handlePagePress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let direction: TVPageDirection = recognizer.name == "page-up" ? .up : .down
        _ = TVRemoteCommandCenter.pageHandler?(direction)
    }

    @objc private func handleSeekPress(_ recognizer: UILongPressGestureRecognizer) {
        let direction: TVPlayerSeekDirection = recognizer.name == "seek-backward"
            ? .backward
            : .forward
        switch recognizer.state {
        case .began:
            postSeekPress(direction, isPressed: true)
        case .ended, .cancelled, .failed:
            postSeekPress(direction, isPressed: false)
        default:
            break
        }
    }

    private func postSeekPress(
        _ direction: TVPlayerSeekDirection,
        isPressed: Bool
    ) {
        NotificationCenter.default.post(
            name: .tvPlaybackAutomationSeekPress,
            object: nil,
            userInfo: [
                "direction": direction == .backward ? "backward" : "forward",
                "pressed": isPressed,
            ]
        )
    }

    nonisolated func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    private func uninstall() {
        guard let installedWindow else { return }
        recognizers.forEach(installedWindow.removeGestureRecognizer)
        recognizers.removeAll()
        self.installedWindow = nil
    }
}
#endif
