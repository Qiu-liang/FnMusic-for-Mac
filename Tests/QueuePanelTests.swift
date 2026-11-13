import Foundation
import XCTest
@testable import FnMusic

/// All history responses are local actor fixtures, never live server requests.
private actor QueuePanelMusicService: MusicServiceProtocol {
    struct Request: Equatable, Sendable {
        let page: Int
        let sort: String
        let source: TrackSource
    }

    private let pages: [Int: Page<Track>]
    private let onRequest: (@Sendable (Int) -> Void)?
    private var holdResponses: Bool
    private var responseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [Request] = []
    private(set) var cancelledAtResponse: [Bool] = []

    init(pages: [Int: Page<Track>] = [:], holdResponses: Bool = false,
         onRequest: (@Sendable (Int) -> Void)? = nil) {
        self.pages = pages
        self.holdResponses = holdResponses
        self.onRequest = onRequest
    }

    func releaseResponses() {
        holdResponses = false
        let waiters = responseWaiters
        responseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func tracks(page: Int, sort: String, source: TrackSource) async throws -> Page<Track> {
        requests.append(Request(page: page, sort: sort, source: source))
        onRequest?(requests.count)
        if holdResponses {
            await withCheckedContinuation { responseWaiters.append($0) }
        }
        cancelledAtResponse.append(Task.isCancelled)
        try Task.checkCancellation()
        guard source == .history, let response = pages[page] else {
            throw APIError.unavailable("Unexpected queue-panel fixture request")
        }
        return response
    }

    func albums(page: Int, sort: String, artistGUID: String?) async throws -> Page<Album> {
        throw APIError.unavailable("Queue panel must not request albums")
    }

    func artists(page: Int, sort: String) async throws -> Page<Artist> {
        throw APIError.unavailable("Queue panel must not request artists")
    }

    func album(guid: String) async throws -> Album {
        throw APIError.unavailable("Queue panel must not request album details")
    }

    func artist(guid: String) async throws -> Artist {
        throw APIError.unavailable("Queue panel must not request artist details")
    }
}

@MainActor
final class QueuePanelTests: XCTestCase {
    func testHistoryUsesHistorySourcePreservesServerOrderAndDoesNotReloadOnReopen() async {
        // Deliberately neither title nor GUID order: the server owns history order.
        let tracks = [
            Track(guid: "z", title: "Middle"),
            Track(guid: "a", title: "Zulu"),
            Track(guid: "m", title: "Alpha")
        ]
        let service = QueuePanelMusicService(pages: [
            1: Page(list: tracks, total: 4, sort: "server-history-order")
        ])
        let state = QueuePanelState(service: service)
        let history = state.history

        await state.loadHistoryIfNeeded()
        for _ in 0..<5 {
            await state.loadHistoryIfNeeded()
        }

        XCTAssertTrue(state.history === history)
        XCTAssertEqual(state.history.items, tracks)
        XCTAssertEqual(state.visibleHistory, tracks)
        XCTAssertEqual(state.history.returnedSort, "server-history-order")
        XCTAssertTrue(state.history.hasMore, "Reopening must not implicitly fetch the next page")
        XCTAssertNil(state.history.error)
        let requests = await service.requests
        XCTAssertEqual(requests, [
            .init(page: 1, sort: TrackSource.history.defaultSort, source: .history)
        ])
    }

    func testEmptyHistoryIsLoadedOnlyOnceAcrossRepeatedOpens() async {
        let service = QueuePanelMusicService(pages: [1: Page(list: [], total: 0)])
        let state = QueuePanelState(service: service)

        for _ in 0..<5 {
            await state.loadHistoryIfNeeded()
        }

        XCTAssertTrue(state.history.items.isEmpty)
        XCTAssertEqual(state.history.total, 0)
        XCTAssertFalse(state.history.hasMore)
        XCTAssertNil(state.history.error)
        let requests = await service.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.source, .history)
    }

    func testEmptyHistoryWithoutTotalIsNotReloadedOnReopen() async {
        let service = QueuePanelMusicService(pages: [1: Page(list: [], total: nil)])
        let state = QueuePanelState(service: service)

        await state.loadHistoryIfNeeded()
        XCTAssertTrue(state.history.items.isEmpty)
        XCTAssertNil(state.history.total)
        XCTAssertFalse(state.history.hasMore)
        for _ in 0..<5 {
            await state.loadHistoryIfNeeded()
        }

        XCTAssertTrue(state.visibleHistory.isEmpty)
        XCTAssertNil(state.history.error)
        let requests = await service.requests
        XCTAssertEqual(requests, [
            .init(page: 1, sort: TrackSource.history.defaultSort, source: .history)
        ])
    }

    func testConcurrentHistoryOpensShareLoadAndOuterCancellationDoesNotCancelResponse() async {
        let requestStarted = expectation(description: "History request reached the local response gate")
        requestStarted.assertForOverFulfill = true
        let secondOpenStarted = expectation(description: "Second open joined the in-flight load")
        let tracks = [Track(guid: "slow-history", title: "Local delayed response")]
        let service = QueuePanelMusicService(
            pages: [1: Page(list: tracks, total: 1)], holdResponses: true,
            onRequest: { _ in requestStarted.fulfill() }
        )
        let state = QueuePanelState(service: service)
        let firstOpen = Task { await state.loadHistoryIfNeeded() }
        await fulfillment(of: [requestStarted], timeout: 2)

        let secondOpen = Task { @MainActor in
            secondOpenStarted.fulfill()
            await state.loadHistoryIfNeeded()
        }
        await fulfillment(of: [secondOpenStarted], timeout: 2)
        firstOpen.cancel()

        XCTAssertTrue(firstOpen.isCancelled)
        XCTAssertTrue(state.history.isLoading, "Closing the first panel must not cancel the shared loader")
        XCTAssertTrue(state.history.items.isEmpty, "The response gate has not been released yet")
        let pendingRequests = await service.requests
        XCTAssertEqual(pendingRequests.count, 1)

        await service.releaseResponses()
        await firstOpen.value
        await secondOpen.value

        XCTAssertEqual(state.history.items, tracks)
        XCTAssertEqual(state.visibleHistory, tracks)
        XCTAssertFalse(state.history.isLoading)
        XCTAssertNil(state.history.error)
        let cancellationFlags = await service.cancelledAtResponse
        XCTAssertEqual(cancellationFlags, [false], "The internal load must outlive a cancelled caller")
        await state.loadHistoryIfNeeded()
        let completedRequests = await service.requests
        XCTAssertEqual(completedRequests, [
            .init(page: 1, sort: TrackSource.history.defaultSort, source: .history)
        ])
    }

    func testRefreshDuringHistoryLoadRunsAfterCurrentLoad() async {
        let firstRequest = expectation(description: "Initial history request")
        let refreshRequest = expectation(description: "Queued refresh request")
        let service = QueuePanelMusicService(
            pages: [1: Page(list: [Track(guid: "history")], total: 1)],
            holdResponses: true,
            onRequest: { count in
                if count == 1 { firstRequest.fulfill() }
                if count == 2 { refreshRequest.fulfill() }
            }
        )
        let state = QueuePanelState(service: service)
        let initial = Task { await state.loadHistory() }
        await fulfillment(of: [firstRequest], timeout: 2)

        let refresh = Task { await state.loadHistory(refresh: true) }
        await service.releaseResponses()
        await fulfillment(of: [refreshRequest], timeout: 2)
        await service.releaseResponses()
        await initial.value
        await refresh.value

        let requests = await service.requests
        XCTAssertEqual(requests.map(\.page), [1, 1])
        XCTAssertEqual(state.history.items.map(\.guid), ["history"])
        XCTAssertFalse(state.history.isLoading)
    }

    func testClearHistoryOnlyHidesLocallyAndRestoreDoesNotReload() async {
        let tracks = [Track(guid: "second"), Track(guid: "first")]
        let service = QueuePanelMusicService(pages: [1: Page(list: tracks, total: 2)])
        let state = QueuePanelState(service: service)
        await state.loadHistoryIfNeeded()
        let requestsBeforeClear = await service.requests

        state.clearDisplayedHistory()
        state.clearDisplayedHistory()
        await state.loadHistoryIfNeeded()

        XCTAssertTrue(state.visibleHistory.isEmpty)
        XCTAssertEqual(state.hiddenHistoryIDs, Set(["second", "first"]))
        XCTAssertEqual(state.history.items, tracks, "Clearing is not a mutation of paged history")
        XCTAssertEqual(state.history.total, 2)

        state.restoreHistoryDisplay()
        state.restoreHistoryDisplay()
        XCTAssertTrue(state.hiddenHistoryIDs.isEmpty)
        XCTAssertEqual(state.visibleHistory, tracks)
        XCTAssertEqual(state.history.items, tracks)
        let requestsAfterRestore = await service.requests
        XCTAssertEqual(requestsAfterRestore, requestsBeforeClear)
    }

    func testLaterHistoryPagesShowNewRecordsButKeepPreviouslyDisplayedRecordsHidden() async {
        let first = [Track(guid: "old-z"), Track(guid: "old-a")]
        let new = [Track(guid: "new-z"), Track(guid: "new-a")]
        let service = QueuePanelMusicService(pages: [
            1: Page(list: first, total: 4),
            // A repeated record at the page boundary must not reappear after clear.
            2: Page(list: [first[1]] + new, total: 4)
        ])
        let state = QueuePanelState(service: service)
        await state.loadHistoryIfNeeded()
        XCTAssertTrue(state.history.hasMore)
        state.clearDisplayedHistory()

        await state.loadHistory()

        XCTAssertNil(state.history.error)
        XCTAssertEqual(state.hiddenHistoryIDs, Set(first.map(\.guid)))
        XCTAssertEqual(state.visibleHistory, new)
        XCTAssertEqual(state.history.items, first + new)
        XCTAssertEqual(state.history.total, 4)
        XCTAssertFalse(state.history.hasMore)

        state.restoreHistoryDisplay()
        XCTAssertEqual(state.visibleHistory, first + new)
        XCTAssertEqual(state.history.items, first + new)
        let requests = await service.requests
        XCTAssertEqual(requests.map(\.page), [1, 2])
        XCTAssertEqual(requests.map(\.source), [.history, .history])
    }

    func testQueueSearchOnlyFiltersAndPreservesDuplicateGUIDPositions() async {
        let service = QueuePanelMusicService()
        let state = QueuePanelState(service: service)
        let queue = QueueManager()
        let duplicate = Track(guid: "same", title: "Night Song",
                              artists: [Artist(guid: "artist", name: "Blue Ensemble")])
        let tracks = [Track(guid: "before", title: "Morning"), duplicate,
                      Track(guid: "between", title: "Afternoon"), duplicate]
        queue.replace(with: tracks, startAt: "same")
        queue.select(index: 3)

        for query in ["  NIGHT \n", "blue ensemble"] {
            state.query = query
            // Match the sidebar's enumerate-before-filter positional identity.
            let rows = Array(queue.tracks.enumerated()).filter { state.matchesQueueSearch($0.element) }
            XCTAssertEqual(rows.map(\.offset), [1, 3])
            XCTAssertEqual(rows.map { $0.element.guid }, ["same", "same"])
            XCTAssertEqual(Set(rows.map(\.offset)).count, 2)
            XCTAssertEqual(queue.tracks, tracks)
            XCTAssertEqual(queue.index, 3)
        }

        state.query = "no match"
        XCTAssertTrue(queue.tracks.filter { state.matchesQueueSearch($0) }.isEmpty)
        XCTAssertEqual(queue.tracks, tracks)
        XCTAssertEqual(queue.index, 3)

        state.query = " \n\t "
        let restoredRows = Array(queue.tracks.enumerated()).filter { state.matchesQueueSearch($0.element) }
        XCTAssertEqual(restoredRows.map(\.offset), [0, 1, 2, 3])
        XCTAssertEqual(restoredRows.map(\.element), tracks)
        XCTAssertEqual(queue.index, 3)
        XCTAssertTrue(state.history.items.isEmpty)
        let requests = await service.requests
        XCTAssertTrue(requests.isEmpty, "Queue search is local and must not load server history")
    }

    func testQueueActionUsesTheSecondDuplicatePositionForSelectionAndRemoval() {
        let state = QueuePanelState(service: QueuePanelMusicService())
        let queue = QueueManager()
        let duplicate = Track(guid: "same", title: "Repeated song")
        let snapshot = [Track(guid: "before"), duplicate, Track(guid: "between"),
                        duplicate, Track(guid: "after")]
        queue.replace(with: snapshot, startAt: "same")
        XCTAssertEqual(queue.index, 1)
        var actionPositions: [Int] = []

        let selected = state.performQueueAction(at: 3, snapshot: snapshot, queue: queue) { position in
            actionPositions.append(position)
            queue.select(index: position)
        }
        XCTAssertTrue(selected)
        XCTAssertEqual(queue.index, 3, "The second occurrence must not resolve to the first matching GUID")
        XCTAssertEqual(queue.tracks, snapshot)

        let removed = state.performQueueAction(at: 3, snapshot: snapshot, queue: queue) { position in
            actionPositions.append(position)
            queue.remove(at: position)
        }
        XCTAssertTrue(removed)
        XCTAssertEqual(actionPositions, [3, 3])
        XCTAssertEqual(queue.tracks.map(\.guid), ["before", "same", "between", "after"])
        XCTAssertEqual(queue.current?.guid, "after")
        XCTAssertEqual(queue.index, 3)
    }

    func testQueueActionRejectsOldSnapshotAfterStructuralChanges() {
        let state = QueuePanelState(service: QueuePanelMusicService())
        let duplicate = Track(guid: "same")
        let snapshot = [Track(guid: "before"), duplicate, Track(guid: "between"),
                        duplicate, Track(guid: "after")]

        for change in ["remove", "append", "move", "replace"] {
            let queue = QueueManager()
            queue.replace(with: snapshot, startAt: "same")
            switch change {
            case "remove": queue.remove(at: 0)
            case "append": queue.append(Track(guid: "new"))
            case "move": queue.move(from: 0, to: 2)
            default:
                var replacement = snapshot
                replacement[0] = Track(guid: "replacement")
                queue.replace(with: replacement, startAt: "same")
            }
            let tracksAfterChange = queue.tracks
            let indexAfterChange = queue.index
            XCTAssertNotEqual(tracksAfterChange, snapshot)
            XCTAssertTrue(queue.tracks.indices.contains(3), "The stale index still exists; snapshot validation must reject it")
            var actionExecuted = false

            let accepted = state.performQueueAction(at: 3, snapshot: snapshot, queue: queue) { position in
                actionExecuted = true
                queue.remove(at: position)
            }

            XCTAssertFalse(accepted, "Stale menu action must be rejected after \(change)")
            XCTAssertFalse(actionExecuted, "No side effect is allowed after \(change)")
            XCTAssertEqual(queue.tracks, tracksAfterChange)
            XCTAssertEqual(queue.index, indexAfterChange)
        }
    }

    func testQueueActionRejectsOutOfBoundsPositionsEvenWithCurrentSnapshot() {
        let state = QueuePanelState(service: QueuePanelMusicService())
        let queue = QueueManager()
        let snapshot = [Track(guid: "only")]
        queue.replace(with: snapshot, startAt: "only")
        for position in [-1, snapshot.count] {
            var actionExecuted = false
            let accepted = state.performQueueAction(at: position, snapshot: snapshot, queue: queue) { _ in
                actionExecuted = true
            }
            XCTAssertFalse(accepted)
            XCTAssertFalse(actionExecuted)
            XCTAssertEqual(queue.tracks, snapshot)
            XCTAssertEqual(queue.index, 0)
        }
    }

    func testCycleRepeatModeLoopsOffAllOneWithoutChangingQueue() {
        let queue = QueueManager()
        let tracks = [Track(guid: "a"), Track(guid: "b")]
        queue.replace(with: tracks, startAt: "b")
        XCTAssertEqual(queue.repeatMode, .off)

        for expected in [RepeatMode.all, .one, .off, .all, .one, .off] {
            queue.cycleRepeatMode()
            XCTAssertEqual(queue.repeatMode, expected)
            XCTAssertEqual(queue.tracks, tracks)
            XCTAssertEqual(queue.index, 1)
            XCTAssertFalse(queue.shuffle)
        }
    }

    func testDockedMetricsKeepPanelBetween280And320AndMainContentAtLeast590() {
        XCTAssertEqual(QueueSidebarMetrics.minimumMainWidth, 590)
        XCTAssertEqual(QueueSidebarMetrics.minimumDockedWidth, 280)

        for sidebarVisible in [false, true] {
            let sidebarWidth: CGFloat = sidebarVisible ? MusicSidebarMetrics.width : 0
            let threshold: CGFloat = 590 + 280 + sidebarWidth
            XCTAssertFalse(QueueSidebarMetrics.isDocked(windowWidth: threshold - 1,
                                                        sidebarVisible: sidebarVisible))
            for windowWidth in [threshold, CGFloat(1180), CGFloat(1440), CGFloat(1920)] {
                XCTAssertTrue(QueueSidebarMetrics.isDocked(windowWidth: windowWidth,
                                                           sidebarVisible: sidebarVisible))
                let panelWidth = QueueSidebarMetrics.width(windowWidth: windowWidth,
                                                          sidebarVisible: sidebarVisible)
                XCTAssertGreaterThanOrEqual(panelWidth, 280)
                XCTAssertLessThanOrEqual(panelWidth, 320)
                XCTAssertGreaterThanOrEqual(windowWidth - sidebarWidth - panelWidth, 590)
            }
        }
    }

    func testCompactMetricsUseFallbackAt820AndStayBetween240And280() {
        for sidebarVisible in [false, true] {
            XCTAssertFalse(QueueSidebarMetrics.isDocked(windowWidth: 820, sidebarVisible: sidebarVisible))
            for windowWidth in [CGFloat(640), 800, 820, 869] {
                XCTAssertFalse(QueueSidebarMetrics.isDocked(windowWidth: windowWidth,
                                                            sidebarVisible: sidebarVisible))
                let width = QueueSidebarMetrics.width(windowWidth: windowWidth, sidebarVisible: sidebarVisible)
                XCTAssertGreaterThanOrEqual(width, 240)
                XCTAssertLessThanOrEqual(width, 280)
            }
            XCTAssertEqual(QueueSidebarMetrics.width(windowWidth: 640, sidebarVisible: sidebarVisible), 240)
        }
        XCTAssertEqual(QueueSidebarMetrics.width(windowWidth: 1000, sidebarVisible: true), 280)
        XCTAssertFalse(QueueSidebarMetrics.isDocked(windowWidth: 1000, sidebarVisible: true))
    }

    func testRepeatedShowQueueTogglePreservesPlayerQueueAndPanelWithoutLoadingHistory() throws {
        // No view is mounted, no playback is started, and no history loader is called.
        let client = APIClient(origin: try APIClient.serverURL("https://queue-panel-test.invalid"),
                               token: "test-only")
        let library = LibraryContext(client: client, user: User(guid: "queue-panel-test"))
        defer { library.player.shutdown() }
        let player = library.player
        let queue = player.queue
        let panel = library.queuePanel
        let history = panel.history
        let tracks = [Track(guid: "same"), Track(guid: "middle"), Track(guid: "same")]
        queue.replace(with: tracks, startAt: "same")
        queue.select(index: 2)
        panel.query = "retained search"
        XCTAssertNotEqual(library.rightPanel, .queue)

        for _ in 0..<10 {
            library.rightPanel = library.rightPanel == .queue ? nil : .queue
            XCTAssertTrue(library.player === player)
            XCTAssertTrue(library.player.queue === queue)
            XCTAssertTrue(library.queuePanel === panel)
            XCTAssertTrue(library.queuePanel.history === history)
            XCTAssertEqual(queue.tracks, tracks)
            XCTAssertEqual(queue.index, 2)
            XCTAssertEqual(panel.query, "retained search")
            XCTAssertTrue(history.items.isEmpty)
            XCTAssertNil(history.total)
            XCTAssertFalse(history.isLoading)
        }
        XCTAssertNotEqual(library.rightPanel, .queue)
    }
}
