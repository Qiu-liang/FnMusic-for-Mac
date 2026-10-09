import Foundation
import Observation

@MainActor @Observable
final class PagedViewModel<Item: Codable & Identifiable & Sendable> where Item.ID: Sendable {
    var items: [Item] = []
    var isLoading = false
    var error: String?
    var total: Int?
    var returnedSort: String?
    var hasMore = true
    private var page = 1
    private var generation = UUID()
    private let loader: @Sendable (Int, String) async throws -> Page<Item>
    var sort: String

    init(sort: String, loader: @escaping @Sendable (Int, String) async throws -> Page<Item>) {
        self.sort = sort
        self.loader = loader
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        generation = UUID()
        page = 1
        items = []
        total = nil
        returnedSort = nil
        hasMore = true
        isLoading = false
        error = nil
        await loadMore()
    }

    /// Debounced, nonpaginated search. A new generation also invalidates pending list pages.
    func loadSnapshot(query: String, using search: @Sendable (String) async throws -> Page<Item>) async {
        guard !Task.isCancelled else { return }
        let identity = UUID()
        generation = identity
        page = 1
        items = []
        total = nil
        returnedSort = nil
        hasMore = false
        error = nil
        isLoading = true
        defer { if generation == identity { isLoading = false } }
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
        defer { if generation == identity { isLoading = false } }
        do {
            let response = try await loader(page, sort)
            try Task.checkCancellation()
            guard identity == generation else { return }
            var seen = Set(items.map(\.id))
            let added = response.list.filter { seen.insert($0.id).inserted }
            items.append(contentsOf: added)
            total = response.total
            returnedSort = response.sort
            // A repeated server page must not create an infinite load loop.
            hasMore = !added.isEmpty && !response.list.isEmpty && (response.total.map { items.count < $0 } ?? (response.list.count >= MusicService.pageSize))
            page += 1
        } catch is CancellationError { }
        catch { if identity == generation && !Task.isCancelled { self.error = error.localizedDescription } }
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
