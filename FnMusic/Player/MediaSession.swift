import Foundation
import MediaPlayer

@MainActor
final class MediaSession {
    private let center = MPRemoteCommandCenter.shared()
    private var targets: [(MPRemoteCommand, Any)] = []

    init(player: AudioPlayer) {
        register(center.playCommand) { [weak player] in player?.resume() }
        register(center.pauseCommand) { [weak player] in player?.pause() }
        register(center.togglePlayPauseCommand) { [weak player] in player?.toggle() }
        register(center.nextTrackCommand) { [weak player] in player?.next() }
        register(center.previousTrackCommand) { [weak player] in player?.previous() }
        let token = center.changePlaybackPositionCommand.addTarget { [weak player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            Task { @MainActor [weak player] in player?.seek(to: seconds) }
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, token))
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor @Sendable () -> Void) {
        let target = command.addTarget { _ in
            Task { @MainActor in action() }
            return .success
        }
        targets.append((command, target))
    }

    func update(player: AudioPlayer) {
        guard let track = player.currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.artistText,
            MPMediaItemPropertyAlbumTitle: track.album?.displayName ?? "",
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        MPNowPlayingInfoCenter.default().playbackState = player.isPlaying ? .playing : .paused
    }

    func invalidate() {
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
