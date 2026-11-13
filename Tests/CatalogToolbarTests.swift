import XCTest
@testable import FnMusic

@MainActor
final class CatalogToolbarTests: XCTestCase {
    func testControlsRefreshPreservesSearchAndSort() {
        let controls = CatalogControls(sort: "favoriteAt,desc")
        XCTAssertEqual(controls.query, "")
        XCTAssertEqual(controls.refreshRevision, 0)
        controls.query = "  周杰伦\n"
        controls.refresh()
        controls.refresh()
        XCTAssertEqual(controls.refreshRevision, 2)
        XCTAssertEqual(controls.sort, "favoriteAt,desc")
        XCTAssertEqual(controls.query, "  周杰伦\n")
        XCTAssertEqual(controls.trimmedQuery, "周杰伦")
    }

    func testTrackSearchUsesOnlyGETAndQ() async throws {
        try await withService("track.invalid") { service in
            let page = try await service.searchTracks(query: "周 /+?& 音乐")
            XCTAssertEqual(page.list.map(\.guid), ["track-hit"])
            XCTAssertEqual(page.total, 1)
        }
    }

    func testAlbumSearchUsesOnlyGETAndQ() async throws {
        try await withService("album.invalid") { service in
            let page = try await service.searchAlbums(query: "周 /+?& 音乐")
            XCTAssertEqual(page.list.map(\.guid), ["album-hit"])
            XCTAssertEqual(page.total, 1)
        }
    }

    func testLegacyServiceDefaultsReportUnavailable() async {
        let service = LegacyCatalogService()
        do {
            _ = try await service.searchTracks(query: "x")
            XCTFail("Legacy services must explicitly report unavailable search")
        } catch {
            guard case APIError.unavailable = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            _ = try await service.searchAlbums(query: "x")
            XCTFail("Legacy services must explicitly report unavailable search")
        } catch {
            guard case APIError.unavailable = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testSnapshotEmptyResultFinishesLoading() async {
        let model = makeModel()
        await model.loadSnapshot(query: "nothing") { _ in Page(list: [], total: 0) }
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.total, 0)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.error)
    }

    func testSnapshotFailureClearsPreviousMetadataAndShowsError() async {
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.returnedSort, "title,asc")
        await model.loadSnapshot(query: "error") { _ in throw APIError.network }
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.total)
        XCTAssertNil(model.returnedSort)
        XCTAssertEqual(model.error, APIError.network.localizedDescription)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.hasMore)
    }

    func testSnapshotCancellationDuringDebounceNeverInvokesSearch() async throws {
        let model = makeModel()
        let started = XCTestExpectation(description: "Snapshot entered debounce")
        let task = Task {
            started.fulfill()
            await model.loadSnapshot(query: "cancel") { _ in
                XCTFail("Cancelled debounce must not issue a request")
                return Page(list: [], total: 0)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.isLoading)
        task.cancel()
        await task.value
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.error)
    }

    func testCancelledInFlightSnapshotCannotPublishResult() async {
        let responses = CatalogSnapshotResponses()
        let model = makeModel()
        let task = Task { await model.loadSnapshot(query: "old") { _ in try await responses.load() } }
        await fulfillment(of: [responses.firstStarted], timeout: 2)
        task.cancel()
        await responses.resolve(0, track: "old")
        await task.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
    }

    func testNormalRefreshAfterSnapshotRestoresPaginationAndOriginalSort() async {
        let model = makeModel()
        await model.loadSnapshot(query: "search") { _ in Page(list: [], total: 0) }
        await model.refresh()
        XCTAssertEqual(model.items.map(\.guid), ["list"])
        XCTAssertEqual(model.sort, "title,asc")
        XCTAssertEqual(model.returnedSort, "title,asc")
        XCTAssertTrue(model.hasMore)
    }

    private func makeModel() -> PagedViewModel<Track> {
        PagedViewModel(sort: "title,asc") { _, sort in
            Page(list: [Track(guid: "list")], total: 100, sort: sort)
        }
    }

    private func withService<T>(_ host: String, operation: (MusicService) async throws -> T) async throws -> T {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogSearchURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = APIClient(origin: try APIClient.serverURL("https://\(host)"), token: "catalog-test", session: session)
        return try await operation(MusicService(client: client))
    }
}

private final class CatalogSearchURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return XCTFail("Missing URL") }
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.count, 1, "Search must not send page, size or sort")
        XCTAssertEqual(items.first?.name, "q")
        XCTAssertEqual(items.first?.value, "周 /+?& 音乐")
        let kind = url.host == "track.invalid" ? "track" : "album"
        XCTAssertEqual(url.path, "/music/api/v1/search/\(kind)")
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            return XCTFail("Could not create HTTP response")
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = "{\"code\":0,\"data\":{\"list\":[{\"guid\":\"\(kind)-hit\"}],\"total\":1}}"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor CatalogSnapshotResponses {
    nonisolated let firstStarted = XCTestExpectation(description: "First snapshot started")
    private var count = 0
    private var pending: [Int: CheckedContinuation<Page<Track>, Error>] = [:]

    func load() async throws -> Page<Track> {
        let index = count
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            if index == 0 { firstStarted.fulfill() }
        }
    }

    func resolve(_ index: Int, track: String) {
        pending.removeValue(forKey: index)?.resume(returning: Page(list: [Track(guid: track)], total: 1))
    }
}

/// Intentionally implements the original protocol only, ensuring old mocks remain source-compatible.
private struct LegacyCatalogService: MusicServiceProtocol {
    func tracks(page: Int, sort: String, source: TrackSource) async throws -> Page<Track> { Page(list: []) }
    func albums(page: Int, sort: String, artistGUID: String?) async throws -> Page<Album> { Page(list: []) }
    func artists(page: Int, sort: String) async throws -> Page<Artist> { Page(list: []) }
    func album(guid: String) async throws -> Album { Album(guid: guid) }
    func artist(guid: String) async throws -> Artist { Artist(guid: guid) }
}
