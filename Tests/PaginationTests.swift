import XCTest
@testable import FnMusic

/// Lock-protected helpers: `@Sendable` loaders run off the main actor, so any
/// shared state they touch must be guarded.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    /// Increments and returns the new count.
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

private enum StubOutcome: Sendable {
    case success([Playlist])
    case failure(APIError)
}

private struct PlaylistServiceStub: PlaylistServiceProtocol {
    var outcome: StubOutcome

    func list() async throws -> [Playlist] {
        switch outcome {
        case .success(let list): return list
        case .failure(let error): throw error
        }
    }

    func detail(guid: String) async throws -> Playlist { Playlist(guid: guid) }
}

@MainActor
final class PaginationTests: XCTestCase {
    private func makeModel(loader: @escaping @Sendable (Int, String) async throws -> Page<Track>) -> PagedViewModel<Track> {
        PagedViewModel<Track>(sort: "default", loader: loader)
    }

    // MARK: - Pagination

    func testLoadMoreAppendsPagesAndDeduplicates() async {
        let pages: [Int: Page<Track>] = [
            1: Page(list: [Track(guid: "a"), Track(guid: "b")], total: 5, sort: nil),
            2: Page(list: [Track(guid: "b"), Track(guid: "c")], total: 5, sort: nil),
        ]
        let model = makeModel { page, _ in pages[page] ?? Page(list: [], total: 5, sort: nil) }
        await model.refresh()
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.guid), ["a", "b", "c"])
        XCTAssertEqual(model.total, 5)
        XCTAssertTrue(model.hasMore, "3 of 5 loaded")
    }

    func testRepeatedServerPageStopsPagination() async {
        let repeated = Page(list: [Track(guid: "a"), Track(guid: "b")], total: 100, sort: nil)
        let model = makeModel { _, _ in repeated }
        await model.refresh()
        XCTAssertTrue(model.hasMore, "first page leaves more")
        await model.loadMore()
        XCTAssertFalse(model.hasMore, "a repeated page must not create an infinite loop")
        XCTAssertEqual(model.items.map(\.guid), ["a", "b"])
    }

    func testHasMoreRespectsServerTotal() async {
        let model = makeModel { _, _ in Page(list: [Track(guid: "a")], total: 1, sort: nil) }
        await model.refresh()
        XCTAssertFalse(model.hasMore, "items.count == total means no more")
        XCTAssertEqual(model.items.count, 1)
    }

    func testEmptyLibraryStopsPagination() async {
        let model = makeModel { _, _ in Page(list: [], total: 0, sort: nil) }
        await model.loadMore()
        XCTAssertFalse(model.hasMore, "an empty library must stop pagination")
        XCTAssertNil(model.error)
    }

    func testHasMoreInfersFromPageSizeWhenTotalMissing() async {
        let full = Page<Track>(list: (0..<60).map { Track(guid: "t\($0)") }, total: nil, sort: nil)
        let model = makeModel { _, _ in full }
        await model.refresh()
        XCTAssertTrue(model.hasMore, "a full page without total implies more")

        let partial = Page<Track>(list: (0..<30).map { Track(guid: "u\($0)") }, total: nil, sort: nil)
        let shortModel = makeModel { _, _ in partial }
        await shortModel.refresh()
        XCTAssertFalse(shortModel.hasMore, "a short page without total ends pagination")
    }

    func testReturnedSortEchoesServerSort() async {
        let model = makeModel { _, _ in Page(list: [Track(guid: "a")], total: 1, sort: "year") }
        await model.refresh()
        XCTAssertEqual(model.returnedSort, "year")
    }

    func testRefreshPassesCurrentSortToLoader() async {
        let model = makeModel { page, sort in
            Page(list: [Track(guid: "sort-\(sort)-\(page)")], total: nil, sort: sort)
        }
        model.sort = "year"
        await model.refresh()
        XCTAssertEqual(model.items.map(\.guid), ["sort-year-1"])
    }

    func testRefreshResetsState() async {
        let model = makeModel { page, _ in
            Page(list: [Track(guid: "p\(page)")], total: 2, sort: nil)
        }
        await model.refresh()
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.guid), ["p1", "p2"])
        await model.refresh()
        XCTAssertEqual(model.items.map(\.guid), ["p1"], "refresh restarts from page 1")
    }

    // MARK: - Error and cancellation guards

    func testCancellationIsNotSurfacedAsError() async {
        let model = makeModel { _, _ in throw CancellationError() }
        await model.refresh()
        XCTAssertNil(model.error, "cancellation must stay silent")
        XCTAssertFalse(model.isLoading)
    }

    func testLoaderFailureSurfacesError() async {
        let model = makeModel { _, _ in throw APIError.network }
        await model.refresh()
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.isLoading)
    }

    func testCancelledTaskSkipsRefresh() async {
        let model = makeModel { _, _ in
            XCTFail("a cancelled task must not call the loader")
            return Page(list: [], total: 0, sort: nil)
        }
        let task = Task { await model.refresh() }
        task.cancel()
        await task.value
        XCTAssertTrue(model.items.isEmpty)
    }

    // MARK: - Stale-result races

    func testStalePageDoesNotOverwriteRefresh() async throws {
        let stale = Page<Track>(list: [Track(guid: "stale")], total: 100, sort: nil)
        let fresh = Page<Track>(list: [Track(guid: "fresh")], total: 100, sort: nil)
        let calls = Counter()
        let model = makeModel { _, _ in
            if calls.increment() == 1 {
                try await Task.sleep(for: .milliseconds(300))
                return stale
            }
            return fresh
        }
        let outdated = Task { await model.refresh() }
        try await Task.sleep(for: .milliseconds(80))
        await model.refresh()
        await outdated.value
        XCTAssertEqual(model.items.map(\.guid), ["fresh"], "the slow stale page must be discarded")
    }

    func testLoadSnapshotDropsStaleQueries() async throws {
        let model = makeModel { _, _ in Page(list: [], total: 0, sort: nil) }
        let slow: @Sendable (String) async throws -> Page<Track> = { query in
            try await Task.sleep(for: .milliseconds(500))
            return Page(list: [Track(guid: "slow-\(query)")], total: 1, sort: nil)
        }
        let fast: @Sendable (String) async throws -> Page<Track> = { query in
            Page(list: [Track(guid: "fast-\(query)")], total: 1, sort: nil)
        }
        let outdated = Task { await model.loadSnapshot(query: "old", using: slow) }
        try await Task.sleep(for: .milliseconds(50))
        await model.loadSnapshot(query: "new", using: fast)
        await outdated.value
        XCTAssertEqual(model.items.map(\.guid), ["fast-new"])
    }

    func testLoadSnapshotDeduplicatesResults() async {
        let model = makeModel { _, _ in Page(list: [], total: 0, sort: nil) }
        let search: @Sendable (String) async throws -> Page<Track> = { _ in
            Page(list: [Track(guid: "a"), Track(guid: "a"), Track(guid: "b")], total: 3, sort: nil)
        }
        await model.loadSnapshot(query: "q", using: search)
        XCTAssertEqual(model.items.map(\.guid), ["a", "b"])
        XCTAssertEqual(model.total, 3)
        XCTAssertFalse(model.hasMore, "search results are not paginated")
    }

    // MARK: - PlaylistListViewModel

    func testPlaylistListSuccessAndFailure() async {
        let model = PlaylistListViewModel(service: PlaylistServiceStub(outcome: .success([Playlist(guid: "p1", name: "歌单一")])))
        await model.refresh()
        XCTAssertEqual(model.items.map(\.guid), ["p1"])
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)

        let failing = PlaylistListViewModel(service: PlaylistServiceStub(outcome: .failure(.network)))
        await failing.refresh()
        XCTAssertNotNil(failing.error)
        XCTAssertFalse(failing.isLoading)
    }
}
