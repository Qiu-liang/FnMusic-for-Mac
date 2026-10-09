import Foundation

protocol SearchServiceProtocol: Sendable {
    func search(query: String) async throws -> SearchResult
}

actor SearchService: SearchServiceProtocol {
    private let client: APIClient
    private var cache: [String: (date: Date, result: SearchResult)] = [:]
    private var generation = UUID()
    init(client: APIClient) { self.client = client }

    func search(query: String) async throws -> SearchResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SearchResult() }
        try Task.checkCancellation()
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.date) < 30 }
        if let hit = cache[query] { return hit.result }
        let identity = generation
        // Deliberately no page/size: these were ignored in the documented search samples.
        async let tracks: Page<Track> = client.value(APIRequest(path: "/search/track", query: ["q": query]))
        async let albums: Page<Album> = client.value(APIRequest(path: "/search/album", query: ["q": query]))
        async let artists: Page<Artist> = client.value(APIRequest(path: "/search/artist", query: ["q": query]))
        async let playlists: Page<Playlist> = client.value(APIRequest(path: "/search/playlist", query: ["q": query]))
        let result = try await SearchResult(tracks: tracks.list, albums: albums.list, artists: artists.list, playlists: playlists.list)
        try Task.checkCancellation()
        // A clear during the awaits invalidates cache writes from the previous generation.
        let resultCount = result.tracks.count + result.albums.count + result.artists.count + result.playlists.count
        guard identity == generation, resultCount <= 3_000 else { return result }
        if cache[query] == nil, cache.count >= 12,
           let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[query] = (Date(), result)
        return result
    }

    func clear() {
        generation = UUID()
        cache.removeAll()
    }
}
