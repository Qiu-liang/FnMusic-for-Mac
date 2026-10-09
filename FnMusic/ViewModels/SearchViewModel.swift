import Foundation
import Observation

@MainActor @Observable
final class SearchViewModel {
    var query = ""
    var result = SearchResult()
    var isLoading = false
    var error: String?
    var displayLimit = 60
    private var generation = UUID()
    private let service: any SearchServiceProtocol

    init(service: any SearchServiceProtocol) { self.service = service }

    // Called by SwiftUI .task(id: query), so leaving the page or typing again
    // cancels the complete debounce + HTTP task tree.
    func search() async {
        let identity = UUID()
        generation = identity
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        result = SearchResult()
        error = nil
        displayLimit = 60
        isLoading = !trimmed.isEmpty
        guard !trimmed.isEmpty else { return }
        defer { if generation == identity { isLoading = false } }
        do {
            try await Task.sleep(for: .milliseconds(300))
            let response = try await service.search(query: trimmed)
            try Task.checkCancellation()
            guard generation == identity else { return }
            result = response
        } catch is CancellationError { }
        catch { if generation == identity { self.error = error.localizedDescription } }
    }
}
