import Foundation

protocol FavoriteServiceProtocol: Sendable {
    func setFavorite(trackGUID: String, favorite: Bool) async throws -> Bool
}

struct FavoriteService: FavoriteServiceProtocol {
    let client: APIClient

    func setFavorite(trackGUID: String, favorite: Bool) async throws -> Bool {
        struct Body: Encodable { let trackGUID: String }
        let path = favorite ? "/favorite-track/create" : "/favorite-track/delete"
        try await client.perform(.post(path, body: Body(trackGUID: trackGUID)))
        let metadata: TrackMetadata = try await client.value(APIRequest(path: "/track/metadata", query: ["guid": trackGUID]))
        guard metadata.track.isFavorite == favorite else {
            throw APIError.unavailable("服务器接受了请求，但收藏状态读回未确认。请刷新后检查，不要重复提交。")
        }
        return favorite
    }
}

protocol PlaylistMutationServiceProtocol: Sendable {
    func create(name: String) async throws -> Playlist
    func rename(_ playlist: Playlist, name: String) async throws
    func delete(_ playlist: Playlist) async throws
    func add(track: Track, to playlist: Playlist) async throws
    func remove(track: Track, from playlist: Playlist) async throws
}

struct PlaylistMutationService: PlaylistMutationServiceProtocol {
    let client: APIClient

    private struct NameBody: Encodable {
        let guid: String?
        let name: String
        let coverId: String?
        enum CodingKeys: String, CodingKey { case guid, name, coverId }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(guid, forKey: .guid)
            try container.encode(name, forKey: .name)
            // Documented create shape explicitly uses coverId:null.
            try container.encode(coverId, forKey: .coverId)
        }
    }
    private struct GUIDBody: Encodable { let guid: String }
    private struct TracksBody: Encodable { let guid: String; let trackGUIDs: [String] }

    func create(name: String) async throws -> Playlist {
        let created: Playlist = try await client.value(.post("/playlist/create", body: NameBody(guid: nil, name: name, coverId: nil)))
        let detail = try await PlaylistService(client: client).detail(guid: created.guid)
        guard detail.name == name else { throw notConfirmed }
        return detail
    }

    func rename(_ playlist: Playlist, name: String) async throws {
        try await client.perform(.post("/playlist/edit", body: NameBody(guid: playlist.guid, name: name, coverId: playlist.coverId)))
        let detail = try await PlaylistService(client: client).detail(guid: playlist.guid)
        guard detail.name == name else { throw notConfirmed }
    }

    func delete(_ playlist: Playlist) async throws {
        try await client.perform(.post("/playlist/delete", body: GUIDBody(guid: playlist.guid)))
        do {
            _ = try await PlaylistService(client: client).detail(guid: playlist.guid)
            throw notConfirmed
        } catch APIError.business(100005) {
            // Only the documented NotFound branch confirms deletion.
        }
    }

    func add(track: Track, to playlist: Playlist) async throws {
        try await client.perform(.post("/playlist/add-track", body: TracksBody(guid: playlist.guid, trackGUIDs: [track.guid])))
        guard try await contains(track.guid, playlist: playlist.guid) else { throw notConfirmed }
    }

    func remove(track: Track, from playlist: Playlist) async throws {
        try await client.perform(.post("/playlist/remove-track", body: TracksBody(guid: playlist.guid, trackGUIDs: [track.guid])))
        guard try await !contains(track.guid, playlist: playlist.guid) else { throw notConfirmed }
    }

    private func contains(_ trackGUID: String, playlist: String) async throws -> Bool {
        var page = 1
        var seen = Set<String>()
        // Stream verification pages without retaining all Track objects. Bound the
        // work for very large playlists rather than claiming unverified success.
        while page <= 100 {
            try Task.checkCancellation()
            let response = try await MusicService(client: client).tracks(page: page, sort: "trackAddedAt,desc", source: .playlist(playlist))
            if response.list.contains(where: { $0.guid == trackGUID }) { return true }
            let added = response.list.filter { seen.insert($0.guid).inserted }
            if response.list.isEmpty { return false }
            if let total = response.total, seen.count >= total { return false }
            if added.isEmpty { throw notConfirmed }
            page += 1
        }
        throw notConfirmed
    }

    private var notConfirmed: APIError {
        .unavailable("请求已发送，但歌单状态读回未确认。请刷新检查；不要假定失败就没有产生修改。")
    }
}
