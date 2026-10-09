import Foundation

protocol MusicServiceProtocol: Sendable {
    func tracks(page: Int, sort: String, source: TrackSource) async throws -> Page<Track>
    func albums(page: Int, sort: String, artistGUID: String?) async throws -> Page<Album>
    func searchTracks(query: String) async throws -> Page<Track>
    func searchAlbums(query: String) async throws -> Page<Album>
    func artists(page: Int, sort: String) async throws -> Page<Artist>
    func album(guid: String) async throws -> Album
    func artist(guid: String) async throws -> Artist
}

extension MusicServiceProtocol {
    func searchTracks(query: String) async throws -> Page<Track> {
        throw APIError.unavailable("此音乐服务暂不支持歌曲搜索。")
    }

    func searchAlbums(query: String) async throws -> Page<Album> {
        throw APIError.unavailable("此音乐服务暂不支持专辑搜索。")
    }
}

enum TrackSource: Hashable, Sendable {
    case library, favorites, history, album(String), artist(String), playlist(String), genre(String)
    var path: String {
        switch self {
        case .library: "/track/list"
        case .favorites: "/favorite-track/list"
        case .history: "/play-history/list"
        case .album: "/track/album-detail/list"
        case .artist: "/track/artist-detail/list"
        case .playlist: "/track/playlist-detail/list"
        case .genre: "/track/genre-detail/list"
        }
    }
    var filter: [String: String] {
        switch self {
        case .album(let guid): ["albumGUID": guid]
        case .artist(let guid): ["artistGUID": guid]
        case .playlist(let guid): ["playlistGUID": guid]
        case .genre(let guid): ["genreGUID": guid]
        default: [:]
        }
    }
    var defaultSort: String {
        switch self {
        case .favorites: "favoriteAt,desc"
        case .album: "trackNo,asc"
        case .playlist: "trackAddedAt,desc"
        default: "createdAt,desc"
        }
    }
    var allowsTitleSort: Bool {
        switch self {
        case .history, .artist, .genre: false
        default: true
        }
    }
}

struct MusicService: MusicServiceProtocol {
    let client: APIClient
    static let pageSize = 60

    func tracks(page: Int, sort: String, source: TrackSource = .library) async throws -> Page<Track> {
        var query = source.filter
        query["page"] = String(page)
        query["size"] = String(Self.pageSize)
        // Genre relation accepts a sort parameter, but no specific fields are
        // verified; preserve its server default instead of guessing a whitelist.
        switch source {
        case .history, .genre: break
        default: query["sort"] = sort
        }
        return try await client.value(APIRequest(path: source.path, query: query))
    }

    func albums(page: Int, sort: String = "newTrackAddedAt,desc", artistGUID: String? = nil) async throws -> Page<Album> {
        var query = ["page": String(page), "size": String(Self.pageSize), "sort": sort]
        if let artistGUID { query["artistGUID"] = artistGUID }
        return try await client.value(APIRequest(path: artistGUID == nil ? "/album/list" : "/album/artist-detail/list", query: query))
    }

    // Search is a single server snapshot; pagination and sort are not a verified contract.
    func searchTracks(query: String) async throws -> Page<Track> {
        try await client.value(APIRequest(path: "/search/track", query: ["q": query]))
    }

    func searchAlbums(query: String) async throws -> Page<Album> {
        try await client.value(APIRequest(path: "/search/album", query: ["q": query]))
    }

    func artists(page: Int, sort: String = "name,asc") async throws -> Page<Artist> {
        try await client.value(APIRequest(path: "/artist/list", query: ["page": String(page), "size": String(Self.pageSize), "sort": sort]))
    }

    func album(guid: String) async throws -> Album {
        try await client.value(APIRequest(path: "/album/detail", query: ["guid": guid], cachePolicy: .memory(maxAge: 20)))
    }

    func artist(guid: String) async throws -> Artist {
        try await client.value(APIRequest(path: "/artist/detail", query: ["guid": guid], cachePolicy: .memory(maxAge: 20)))
    }
}

protocol PlaylistServiceProtocol: Sendable {
    func list() async throws -> [Playlist]
    func detail(guid: String) async throws -> Playlist
}

struct PlaylistService: PlaylistServiceProtocol {
    let client: APIClient

    func list() async throws -> [Playlist] {
        let page: Page<Playlist> = try await client.value(APIRequest(path: "/playlist/list"))
        var result: [Playlist] = []
        // Frontend batches by 100; this is not asserted as a server hard limit.
        for start in stride(from: 0, to: page.list.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(page.list[start..<min(start + 100, page.list.count)])
            let details: Page<Playlist> = try await client.value(APIRequest(path: "/playlist/batch-detail", query: ["guids": batch.map(\.guid).joined(separator: ",")]))
            let mapped = Dictionary(details.list.map { ($0.guid, $0) }, uniquingKeysWith: { first, _ in first })
            result += batch.map { mapped[$0.guid] ?? $0 }
        }
        return result
    }

    func detail(guid: String) async throws -> Playlist {
        try await client.value(APIRequest(path: "/playlist/detail", query: ["guid": guid]))
    }
}
