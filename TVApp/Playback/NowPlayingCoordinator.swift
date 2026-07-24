#if os(tvOS) || os(iOS) || os(macOS)
import Combine
import MediaPlayer
#if os(tvOS) || os(iOS)
import AVFAudio
import UIKit
private typealias NowPlayingImage = UIImage
#else
import AppKit
private typealias NowPlayingImage = NSImage
#endif

// MediaPlayer invokes an artwork request handler on its own callout queue.
// Keep that callback free of MainActor isolation even though the coordinator
// itself is main-actor bound.
private final class NowPlayingArtworkProvider: @unchecked Sendable {
    private let image: NowPlayingImage

    init(image: NowPlayingImage) {
        self.image = image
    }

    func image(for _: CGSize) -> NowPlayingImage {
        image
    }
}

@MainActor
final class NowPlayingCoordinator {
    static let shared = NowPlayingCoordinator()

    private weak var playback: PlaybackCoordinator?
    private var cancellables: Set<AnyCancellable> = []
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var transportCommandTargets: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?

    private init() {}

    func connect(to playback: PlaybackCoordinator) {
        guard self.playback !== playback else { return }
        disconnect()
        self.playback = playback

#if os(tvOS) || os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
#endif

        playback.objectWillChange
            .merge(with: playback.engine.objectWillChange)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    self?.refresh()
                }
            }
            .store(in: &cancellables)

        installCommands()
        refresh()
    }

    func disconnect() {
        cancellables.removeAll()
        artworkTask?.cancel()
        artworkTask = nil
        for (command, token) in commandTargets { command.removeTarget(token) }
        commandTargets.removeAll()
        removeTransportCommands()
        playback = nil
        refreshCommandAvailability(for: nil)
    }

    private func installCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [
            NSNumber(value: PlayerNavigationPolicy.skipInterval)
        ]
        add(center.skipForwardCommand) { [weak self] event in
            guard let engine = self?.playback?.engine, engine.isSeekable else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
                ?? PlayerNavigationPolicy.skipInterval
            _ = engine.skipForward(by: interval)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [
            NSNumber(value: PlayerNavigationPolicy.skipInterval)
        ]
        add(center.skipBackwardCommand) { [weak self] event in
            guard let engine = self?.playback?.engine, engine.isSeekable else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
                ?? PlayerNavigationPolicy.skipInterval
            engine.skipBackward(by: interval)
            return .success
        }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            guard let playback = self?.playback,
                  playback.presentation?.isRecording == true,
                  playback.engine.isSeekable,
                  let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            playback.engine.seek(to: event.positionTime)
            return .success
        }

        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    private func ownsTransportCommands(_ playback: PlaybackCoordinator) -> Bool {
#if os(tvOS)
        playback.isPlayerPresented || playback.pictureInPicture.isActive
#else
        playback.isPlayerPresented
#endif
    }

    private func installTransportCommandsIfNeeded() {
        guard transportCommandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        addTransport(center.playCommand) { [weak self] _ in
            guard let self, let playback = self.playback else {
                return .noActionableNowPlayingItem
            }
#if os(tvOS)
            if TVRemoteCommandCenter.playerPlayPauseHandler?() == true {
                return .success
            }
            if TVRemoteCommandCenter.ignoresDuplicatePlayPauseCommand {
                return .success
            }
#endif
            if self.ownsTransportCommands(playback) {
                playback.engine.play()
                return .success
            }
            return self.handleContextualPlayPauseCommand()
        }
        addTransport(center.pauseCommand) { [weak self] _ in
            guard let self, let playback = self.playback else {
                return .noActionableNowPlayingItem
            }
#if os(tvOS)
            if TVRemoteCommandCenter.playerPlayPauseHandler?() == true {
                return .success
            }
            if TVRemoteCommandCenter.ignoresDuplicatePlayPauseCommand {
                return .success
            }
#endif
            if self.ownsTransportCommands(playback) {
                guard playback.engine.canPause else { return .commandFailed }
                playback.engine.pause()
                return .success
            }
            return self.handleContextualPlayPauseCommand()
        }
        addTransport(center.togglePlayPauseCommand) { [weak self] _ in
            guard let self, let playback = self.playback else {
                return .noActionableNowPlayingItem
            }
#if os(tvOS)
            if TVRemoteCommandCenter.playerPlayPauseHandler?() == true {
                return .success
            }
            if TVRemoteCommandCenter.ignoresDuplicatePlayPauseCommand {
                return .success
            }
#endif
            if self.ownsTransportCommands(playback) {
                playback.engine.togglePlayPause()
                return .success
            }
            return self.handleContextualPlayPauseCommand()
        }
    }

    private func handleContextualPlayPauseCommand() -> MPRemoteCommandHandlerStatus {
#if os(tvOS)
        TVRemoteCommandCenter.playPauseHandler?() == true
            ? .success
            : .noActionableNowPlayingItem
#else
        .noActionableNowPlayingItem
#endif
    }

    private func removeTransportCommands() {
        for (command, token) in transportCommandTargets { command.removeTarget(token) }
        transportCommandTargets.removeAll()
    }

    private func refreshCommandAvailability(for playback: PlaybackCoordinator?) {
        let center = MPRemoteCommandCenter.shared()
        guard let playback else {
            removeTransportCommands()
            center.playCommand.isEnabled = false
            center.pauseCommand.isEnabled = false
            center.togglePlayPauseCommand.isEnabled = false
            center.skipForwardCommand.isEnabled = false
            center.skipBackwardCommand.isEnabled = false
            center.changePlaybackPositionCommand.isEnabled = false
            return
        }

        guard ownsTransportCommands(playback) else {
            installTransportCommandsIfNeeded()
            center.playCommand.isEnabled = true
            center.pauseCommand.isEnabled = true
            center.togglePlayPauseCommand.isEnabled = true
            center.skipForwardCommand.isEnabled = false
            center.skipBackwardCommand.isEnabled = false
            center.changePlaybackPositionCommand.isEnabled = false
            return
        }

        installTransportCommandsIfNeeded()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = playback.engine.canPause
        center.togglePlayPauseCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = playback.engine.isSeekable
        center.skipBackwardCommand.isEnabled = playback.engine.isSeekable
        center.changePlaybackPositionCommand.isEnabled = playback.engine.isSeekable
            && playback.presentation?.isRecording == true
    }

    private func add(
        _ command: MPRemoteCommand,
        handler: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let token = command.addTarget { event in
            if Thread.isMainThread {
                return MainActor.assumeIsolated { handler(event) }
            }
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated { handler(event) }
            }
        }
        commandTargets.append((command, token))
    }

    private func addTransport(
        _ command: MPRemoteCommand,
        handler: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let token = command.addTarget { event in
            if Thread.isMainThread {
                return MainActor.assumeIsolated { handler(event) }
            }
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated { handler(event) }
            }
        }
        transportCommandTargets.append((command, token))
    }

    private func refresh() {
        refreshCommandAvailability(for: playback)

        guard let playback,
              let presentation = playback.presentation,
              playback.engine.state != .idle
        else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }

        let engine = playback.engine
        let isPlaying = engine.state == .playing || {
            if case .recovering = engine.state { return true }
            return false
        }()
        var info: [String: Any] = [
            MPMediaItemPropertyMediaType: MPMediaType.anyVideo.rawValue,
            MPMediaItemPropertyArtist: presentation.channel.name,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]

        let imageURL: URL?
        if let recording = presentation.recording {
            info[MPMediaItemPropertyTitle] = recording.title
            if let subtitle = recording.subtitle, !subtitle.isEmpty {
                info[MPMediaItemPropertyAlbumTitle] = subtitle
            }
            info[MPMediaItemPropertyPlaybackDuration] = engine.durationSeconds ?? recording.duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.elapsedSeconds
            imageURL = nil
        } else {
            let playbackDate = engine.livePlaybackDate()
            let program = presentation.channel.programs.first { $0.isAiring(at: playbackDate) }
                ?? presentation.program
            info[MPMediaItemPropertyTitle] = program?.title ?? presentation.channel.name
            if let subtitle = program?.subtitle, !subtitle.isEmpty {
                info[MPMediaItemPropertyAlbumTitle] = subtitle
            }
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
            imageURL = program?.metadata.imageURL.flatMap(URL.init(string:))
        }

        if imageURL == artworkURL,
           let artwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            loadArtwork(from: imageURL)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func loadArtwork(from url: URL?) {
        artworkURL = url
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled,
                  let image = NowPlayingImage(data: data)
            else { return }
            await MainActor.run {
                guard let self, self.artworkURL == url else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                let provider = NowPlayingArtworkProvider(image: image)
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                    boundsSize: image.size,
                    requestHandler: provider.image(for:)
                )
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}
#endif
