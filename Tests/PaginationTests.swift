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

    // MARK: - Deterministic replacement races

    func testCancelledPageCannotFinishReplacementRefresh() async {
        let requests = ControlledResponses<Page<Track>>()
        let model = makeModel { _, _ in try await requests.load() }
        let old = Task { await model.loadMore() }
        await fulfillment(of: [requests.firstStarted], timeout: 2)
        old.cancel()
        let replacement = Task { await model.refresh() }
        await fulfillment(of: [requests.secondStarted], timeout: 2)

        // Model a transport that completes cancellation only after the replacement starts.
        await requests.fail(0, with: URLError(.cancelled))
        await old.value
        XCTAssertTrue(model.isLoading)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.error)

        await requests.succeed(1, with: Page(list: [Track(guid: "new")], total: 1))
        await replacement.value
        XCTAssertEqual(model.items.map(\.guid), ["new"])
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.hasMore)
    }

    func testStalePageFailureCannotReplaceNewRefreshState() async {
        let requests = ControlledResponses<Page<Track>>()
        let model = makeModel { _, _ in try await requests.load() }
        let old = Task { await model.loadMore() }
        await fulfillment(of: [requests.firstStarted], timeout: 2)
        let replacement = Task { await model.refresh() }
        await fulfillment(of: [requests.secondStarted], timeout: 2)
        await requests.succeed(1, with: Page(list: [Track(guid: "new")], total: 1))
        await replacement.value
        await requests.fail(0, with: URLError(.timedOut))
        await old.value

        XCTAssertEqual(model.items.map(\.guid), ["new"])
        XCTAssertEqual(model.total, 1)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.hasMore)
    }

    func testCancelledPlaylistRefreshDoesNotSwallowReplacement() async {
        let requests = ControlledResponses<[Playlist]>()
        let model = PlaylistListViewModel(service: ControlledPlaylistService(requests: requests))
        let old = Task { await model.refresh() }
        await fulfillment(of: [requests.firstStarted], timeout: 2)
        old.cancel()
        let replacement = Task { await model.refresh() }
        await fulfillment(of: [requests.secondStarted], timeout: 2)

        await requests.succeed(0, with: [Playlist(guid: "old")])
        await old.value
        XCTAssertTrue(model.isLoading, "The old defer must not finish the replacement's loading state")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.error)

        await requests.succeed(1, with: [Playlist(guid: "new")])
        await replacement.value
        XCTAssertEqual(model.items.map(\.guid), ["new"])
        XCTAssertFalse(model.isLoading)
    }

    func testStalePlaylistSuccessCannotOverwriteNewRefresh() async {
        let requests = ControlledResponses<[Playlist]>()
        let model = PlaylistListViewModel(service: ControlledPlaylistService(requests: requests))
        let old = Task { await model.refresh() }
        await fulfillment(of: [requests.firstStarted], timeout: 2)
        let replacement = Task { await model.refresh() }
        await fulfillment(of: [requests.secondStarted], timeout: 2)
        await requests.succeed(1, with: [Playlist(guid: "new")])
        await replacement.value
        // No cancellation: generation identity alone must reject the older result.
        await requests.succeed(0, with: [Playlist(guid: "old")])
        await old.value

        XCTAssertEqual(model.items.map(\.guid), ["new"])
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
    }

    // MARK: - Full-collection drainage and playback continuation

    func testLoadAllReusesFirstPageAndDrainsRemainingPages() async {
        let requestedPages = RecordedPages()
        let page1 = (0..<60).map { Track(guid: "t\($0)") }
        let page2 = [Track(guid: "t59")] + (60..<120).map { Track(guid: "t\($0)") }
        let page3 = (120..<150).map { Track(guid: "t\($0)") }
        let pages: [Int: Page<Track>] = [
            1: Page(list: page1, total: 150, sort: nil),
            2: Page(list: page2, total: 150, sort: nil),
            3: Page(list: page3, total: 150, sort: nil),
        ]
        let model = makeModel { page, _ in
            await requestedPages.append(page)
            return pages[page] ?? Page(list: [], total: 150, sort: nil)
        }

        await model.refresh()
        XCTAssertEqual(model.items.count, 60)
        XCTAssertTrue(model.hasMore)

        let completed = await model.loadAll()
        XCTAssertTrue(completed)
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.items.count, 150)
        XCTAssertEqual(Set(model.items.map(\.guid)).count, 150)
        let recorded = await requestedPages.values()
        XCTAssertEqual(recorded, [1, 2, 3], "First page must be reused without a duplicate request")
    }

    func testLoadAllWaitsForInFlightLoadMoreWithoutDuplicateRequests() async {
        let requests = ControlledResponses<Page<Track>>()
        let requestedPages = RecordedPages()
        let model = makeModel { page, _ in
            await requestedPages.append(page)
            return try await requests.load()
        }

        let initialLoad = Task { await model.loadMore() }
        await fulfillment(of: [requests.firstStarted], timeout: 2)

        let loadAllTask = Task { await model.loadAll() }
        await requests.succeed(0, with: Page(list: [Track(guid: "p1")], total: 2))
        await fulfillment(of: [requests.secondStarted], timeout: 2)
        await requests.succeed(1, with: Page(list: [Track(guid: "p2")], total: 2))

        await initialLoad.value
        let completed = await loadAllTask.value
        XCTAssertTrue(completed)
        XCTAssertEqual(model.items.map(\.guid), ["p1", "p2"])
        XCTAssertFalse(model.hasMore)
        let recorded = await requestedPages.values()
        XCTAssertEqual(recorded, [1, 2])
    }

    func testLoadAllStopsOnErrorAndPreservesLoadedPages() async {
        let page1 = (0..<60).map { Track(guid: "t\($0)") }
        let model = makeModel { page, _ in
            if page == 1 { return Page(list: page1, total: 120, sort: nil) }
            throw APIError.network
        }

        await model.refresh()
        let completed = await model.loadAll()
        XCTAssertFalse(completed)
        XCTAssertEqual(model.items.count, 60)
        XCTAssertEqual(model.error, APIError.network.localizedDescription)
        XCTAssertTrue(model.hasMore)
    }

    func testPlaybackContinuationCapturesNextPageSortAndFilter() async throws {
        let recorded = RecordedPageSorts()
        let page1 = [
            Track(guid: "1", title: "Love Story"),
            Track(guid: "2", title: "Nocturne")
        ]
        let model = makeModel { page, sort in
            await recorded.append(page: page, sort: sort)
            if page == 1 { return Page(list: page1, total: 3, sort: sort) }
            return Page(list: [Track(guid: "3", title: "My Love")], total: 3, sort: sort)
        }
        model.sort = "title,asc"
        await model.refresh()

        let continuation = try XCTUnwrap(model.playbackContinuation(matching: "  love "))
        XCTAssertEqual(continuation.startPage, 2)
        XCTAssertEqual(continuation.loadedGUIDs, Set(["1", "2"]))
        XCTAssertEqual(continuation.filter?(Track(guid: "3", title: "My Love")), true)
        XCTAssertEqual(continuation.filter?(Track(guid: "4", title: "Prelude")), false)

        let nextPage = try await continuation.fetchPage(2)
        XCTAssertEqual(nextPage.list.map(\.guid), ["3"])
        let calls = await recorded.values()
        XCTAssertEqual(calls.map(\.page), [1, 2])
        XCTAssertEqual(calls.map(\.sort), ["title,asc", "title,asc"])

        await model.loadMore()
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.playbackContinuation())
    }
}

private actor RecordedPages {
    private var pages: [Int] = []
    func append(_ page: Int) { pages.append(page) }
    func values() -> [Int] { pages }
}

private actor RecordedPageSorts {
    struct Entry: Equatable, Sendable { let page: Int; let sort: String }
    private var entries: [Entry] = []
    func append(page: Int, sort: String) { entries.append(Entry(page: page, sort: sort)) }
    func values() -> [Entry] { entries }
}

/// Deliberately ignores cancellation until the test resolves each request.
private actor ControlledResponses<Value: Sendable> {
    nonisolated let firstStarted = XCTestExpectation(description: "First request started")
    nonisolated let secondStarted = XCTestExpectation(description: "Replacement request started")
    private var count = 0
    private var pending: [Int: CheckedContinuation<Value, Error>] = [:]

    func load() async throws -> Value {
        let index = count
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            if index == 0 { firstStarted.fulfill() }
            if index == 1 { secondStarted.fulfill() }
        }
    }

    func succeed(_ index: Int, with value: Value) {
        guard let continuation = pending.removeValue(forKey: index) else {
            XCTFail("Missing controlled request \(index)")
            return
        }
        continuation.resume(returning: value)
    }

    func fail(_ index: Int, with error: any Error) {
        guard let continuation = pending.removeValue(forKey: index) else {
            XCTFail("Missing controlled request \(index)")
            return
        }
        continuation.resume(throwing: error)
    }
}

private struct ControlledPlaylistService: PlaylistServiceProtocol {
    let requests: ControlledResponses<[Playlist]>
    func list() async throws -> [Playlist] { try await requests.load() }
    func detail(guid: String) async throws -> Playlist { Playlist(guid: guid) }
}
