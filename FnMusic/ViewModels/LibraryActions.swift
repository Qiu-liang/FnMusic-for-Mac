import Foundation
import Observation

@MainActor @Observable
final class LibraryActions {
    var favoriteOverrides: [String: Bool] = [:]
    var busyTracks: Set<String> = []
    var notice: String?
    var error: String?
    var revision = 0
    var pendingPlaylistTrack: Track?
    private let favoriteService: any FavoriteServiceProtocol

    init(favoriteService: any FavoriteServiceProtocol) { self.favoriteService = favoriteService }

    var experimentalWrites: Bool { UserDefaults.standard.bool(forKey: "experimentalWrites") }
    func isFavorite(_ track: Track) -> Bool { favoriteOverrides[track.guid] ?? track.isFavorite ?? false }

    func reconcile(_ tracks: [Track]) {
        for track in tracks where !busyTracks.contains(track.guid) {
            favoriteOverrides.removeValue(forKey: track.guid)
        }
    }

    func remove(_ track: Track, playlistGUID: String, service: any PlaylistMutationServiceProtocol) async {
        guard experimentalWrites else { error = "请先启用实验性写操作。"; return }
        guard busyTracks.insert(track.guid).inserted else { return }
        defer { busyTracks.remove(track.guid) }
        do {
            try await service.remove(track: track, from: Playlist(guid: playlistGUID))
            revision += 1
            notice = "已从歌单移除并读回确认"
        } catch { self.error = error.localizedDescription }
    }

    func toggleFavorite(_ track: Track) async {
        guard experimentalWrites else {
            error = "收藏修改为 H 级历史接口，请先在设置中明确启用实验性写操作。"
            return
        }
        guard busyTracks.insert(track.guid).inserted else { return }
        defer { busyTracks.remove(track.guid) }
        do {
            let value = try await favoriteService.setFavorite(trackGUID: track.guid, favorite: !isFavorite(track))
            favoriteOverrides[track.guid] = value
            revision += 1
            notice = value ? "已收藏，并确认服务器状态" : "已取消收藏，并确认服务器状态"
        } catch { self.error = error.localizedDescription }
    }
}
