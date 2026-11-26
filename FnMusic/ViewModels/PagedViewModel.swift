import Foundation
import Observation

struct PagedTrackContinuation: Sendable {
    let startPage: Int
    let maxPages: Int
    let loadedGUIDs: Set<String>
    let filter: (@Sendable (Track) -> Bool)?
    let fetchPage: @Sendable (Int) async throws -> Page<Track>

    init(startPage: Int, maxPages: Int = 500,
         loadedGUIDs: Set<String> = [],
         filter: (@Sendable (Track) -> Bool)? = nil,
         fetchPage: @escaping @Sendable (Int) async throws -> Page<Track>) {
        self.startPage = startPage
        self.maxPages = maxPages
        self.loadedGUIDs = loadedGUIDs
        self.filter = filter
        self.fetchPage = fetchPage
    }
}

@MainActor @Observable
final class PagedViewModel<Item: Codable & Identifiable & Sendable> where Item.ID: Sendable {
    var items: [Item] = []
    var isLoading = false
    var error: String?
    var total: Int?
    var returnedSort: String?
    var hasMore = true
    private(set) var nextPage = 1
    private var generation = UUID()
    private let loader: @Sendable (Int, String) async throws -> Page<Item>
    var sort: String
    @ObservationIgnored private var loadWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(sort: String, loader: @escaping @Sendable (Int, String) async throws -> Page<Item>) {
        self.sort = sort
        self.loader = loader
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        generation = UUID()
        nextPage = 1
        items = []
        total = nil
        returnedSort = nil
        hasMore = true
        isLoading = false
        error = nil
        resumeLoadWaiters()
        await loadMore()
    }

    /// Debounced, nonpaginated search. A new generation also invalidates pending list pages.
    func loadSnapshot(query: String, using search: @Sendable (String) async throws -> Page<Item>) async {
        guard !Task.isCancelled else { return }
        let identity = UUID()
        generation = identity
        nextPage = 1
        items = []
        total = nil
        returnedSort = nil
        hasMore = false
        error = nil
        resumeLoadWaiters()
        isLoading = true
        defer {
            if generation == identity {
                isLoading = false
                resumeLoadWaiters()
            }
        }
        do {
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            guard generation == identity else { return }
            let response = try await search(query)
            try Task.checkCancellation()
            guard generation == identity else { return }
            var seen = Set<Item.ID>()
            items = response.list.filter { seen.insert($0.id).inserted }
            total = response.total
            // Search ordering is server relevance, not the list sort setting.
        } catch is CancellationError { }
        catch {
            if generation == identity && !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard !Task.isCancelled, !isLoading, hasMore else { return }
        let identity = generation
        isLoading = true
        error = nil
        defer {
            if generation == identity {
                isLoading = false
                resumeLoadWaiters()
            }
        }
        do {
            let response = try await loader(nextPage, sort)
            try Task.checkCancellation()
            guard identity == generation else { return }
            var seen = Set(items.map(\.id))
            let added = response.list.filter { seen.insert($0.id).inserted }
            items.append(contentsOf: added)
            total = response.total
            returnedSort = response.sort
            // A repeated server page must not create an infinite load loop.
            hasMore = !added.isEmpty && !response.list.isEmpty && (response.total.map { items.count < $0 } ?? (response.list.count >= MusicService.pageSize))
            nextPage += 1
        } catch is CancellationError { }
        catch { if identity == generation && !Task.isCancelled { self.error = error.localizedDescription } }
    }

    @discardableResult
    func loadAll(maxPages: Int = 500) async -> Bool {
        guard !Task.isCancelled else { return false }
        let identity = generation
        if isLoading {
            await waitForCurrentLoad()
            guard !Task.isCancelled, identity == generation, error == nil else { return false }
        }
        var pagesLoaded = 0
        while !Task.isCancelled, identity == generation, hasMore {
            if isLoading {
                await waitForCurrentLoad()
                guard !Task.isCancelled, identity == generation, error == nil else { return false }
                continue
            }
            guard pagesLoaded < maxPages else {
                error = APIError.unavailable("曲目数量超过单次自动加载上限（\(maxPages * MusicService.pageSize) 首）。").localizedDescription
                return false
            }
            let pageBefore = nextPage
            await loadMore()
            guard !Task.isCancelled, identity == generation, error == nil else { return false }
            if nextPage == pageBefore && hasMore { return false }
            pagesLoaded += 1
        }
        return !Task.isCancelled && identity == generation && error == nil && !hasMore
    }

    private func waitForCurrentLoad() async {
        guard isLoading, !Task.isCancelled else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard isLoading, !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                loadWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.loadWaiters.removeValue(forKey: waiterID)?.resume()
            }
        }
    }

    private func resumeLoadWaiters() {
        let waiters = loadWaiters
        loadWaiters.removeAll()
        for continuation in waiters.values {
            continuation.resume()
        }
    }
}

extension PagedViewModel where Item == Track {
    func playbackContinuation(matching query: String = "", maxPages: Int = 500) -> PagedTrackContinuation? {
        guard hasMore else { return nil }
        let startPage = nextPage
        let currentSort = sort
        let loadedGUIDs = Set(items.map(\.guid))
        let loader = self.loader
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter: (@Sendable (Track) -> Bool)?
        if trimmed.isEmpty {
            filter = nil
        } else {
            filter = { @Sendable (track: Track) -> Bool in
                track.displayTitle.localizedStandardContains(trimmed)
                    || track.artistText.localizedStandardContains(trimmed)
                    || (track.album?.displayName.localizedStandardContains(trimmed) ?? false)
            }
        }
        return PagedTrackContinuation(startPage: startPage, maxPages: maxPages,
                                      loadedGUIDs: loadedGUIDs, filter: filter) { page in
            try await loader(page, currentSort)
        }
    }
}

@MainActor @Observable
final class PlaylistListViewModel {
    var items: [Playlist] = []
    var isLoading = false
    var error: String?
    private let service: any PlaylistServiceProtocol
    private var generation = UUID()

    init(service: any PlaylistServiceProtocol) { self.service = service }

    func refresh() async {
        guard !Task.isCancelled else { return }
        // A task(id:) replacement must start even while its cancelled predecessor unwinds.
        let identity = UUID()
        generation = identity
        isLoading = true
        error = nil
        defer { if generation == identity { isLoading = false } }
        do {
            let result = try await service.list()
            try Task.checkCancellation()
            guard generation == identity else { return }
            items = result
        } catch is CancellationError { }
        catch {
            if generation == identity && !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
