import Foundation
import MediaPlayer
import AppKit

private enum MediaSessionArtworkFactory {
    static func make(from image: CGImage) -> MPMediaItemArtwork {
        let nsImage = NSImage(cgImage: image,
                              size: NSSize(width: image.width, height: image.height))
        return MPMediaItemArtwork(boundsSize: nsImage.size) { _ in nsImage }
    }
}

@MainActor
final class MediaSession {
    private let center = MPRemoteCommandCenter.shared()
    private let artworkCache: ImageCache
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var artworkTrackGUID: String?
    private var artwork: MPMediaItemArtwork?

    init(player: AudioPlayer, artworkCache: ImageCache) {
        self.artworkCache = artworkCache
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
            artworkTask?.cancel()
            artworkTask = nil
            artworkTrackGUID = nil
            artwork = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        if artworkTrackGUID != track.guid {
            artworkTask?.cancel()
            artworkTask = nil
            artworkTrackGUID = track.guid
            artwork = nil
            loadArtwork(for: track, player: player)
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.artistText,
            MPMediaItemPropertyAlbumTitle: track.album?.displayName ?? "",
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if artworkTrackGUID == track.guid, let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = player.isPlaying ? .playing : .paused
    }

    private func loadArtwork(for track: Track, player: AudioPlayer) {
        guard let coverID = track.album?.coverId?.nilIfEmpty ?? track.coverId?.nilIfEmpty else { return }
        let cache = artworkCache
        artworkTask = Task { [weak self, weak player] in
            do {
                let image = try await cache.image(id: coverID, size: 160)
                try Task.checkCancellation()
                guard let self, let player,
                      self.artworkTrackGUID == track.guid,
                      player.currentTrack?.guid == track.guid else { return }
                self.artwork = MediaSessionArtworkFactory.make(from: image)
                self.artworkTask = nil
                self.update(player: player)
            } catch {
                guard let self, self.artworkTrackGUID == track.guid else { return }
                self.artworkTask = nil
            }
        }
    }

    func invalidate() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkTrackGUID = nil
        artwork = nil
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
