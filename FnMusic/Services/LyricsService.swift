import Foundation

protocol LyricsServiceProtocol: Sendable {
    func lyrics(trackGUID: String) async throws -> LyricResponse
}

struct LyricsService: LyricsServiceProtocol {
    let client: APIClient
    func lyrics(trackGUID: String) async throws -> LyricResponse {
        try await client.value(APIRequest(path: "/lyric/list", query: ["trackGUID": trackGUID]))
    }
}
