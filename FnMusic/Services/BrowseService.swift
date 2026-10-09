import Foundation

protocol BrowseServiceProtocol: Sendable {
    func genres(page: Int, sort: String) async throws -> Page<GenreRecord>
    func libraries() async throws -> [SharedLibrary]
    func library(guid: String) async throws -> SharedLibrary
}

struct BrowseService: BrowseServiceProtocol {
    let client: APIClient

    func genres(page: Int, sort: String) async throws -> Page<GenreRecord> {
        try await client.value(APIRequest(path: "/genre/list", query: [
            "page": String(page), "size": String(MusicService.pageSize), "sort": sort
        ]))
    }

    func libraries() async throws -> [SharedLibrary] {
        let response: LibraryList = try await client.value(APIRequest(path: "/shared-library/list"))
        return response.list
    }

    func library(guid: String) async throws -> SharedLibrary {
        try await client.value(APIRequest(path: "/shared-library/detail", query: ["guid": guid]))
    }

    private struct LibraryList: Decodable, Sendable {
        let list: [SharedLibrary]
    }
}
