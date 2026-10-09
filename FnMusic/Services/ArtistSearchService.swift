import Foundation

/// Artist search has no verified paging or sorting contract. Keep it separate
/// from MusicServiceProtocol so existing service implementations remain valid.
protocol ArtistSearchServiceProtocol: Sendable {
    func artists(query: String) async throws -> Page<Artist>
}

struct ArtistSearchService: ArtistSearchServiceProtocol {
    let client: APIClient

    func artists(query: String) async throws -> Page<Artist> {
        try await client.value(APIRequest(path: "/search/artist", query: ["q": query]))
    }
}
