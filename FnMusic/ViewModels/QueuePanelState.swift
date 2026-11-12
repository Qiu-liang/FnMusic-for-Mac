import Foundation
import Observation

/// Presentation state only. Tracks still belong to the existing queue and
/// server history uses the same paged loader as the library's history page.
@MainActor @Observable
final class QueuePanelState {
    let history: PagedViewModel<Track>
    var query = ""
    private(set) var hiddenHistoryIDs: Set<String> = []
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var historyRefreshPending = false

    init(service: any MusicServiceProtocol) {
        history = PagedViewModel(sort: TrackSource.history.defaultSort) { page, sort in
            try await service.tracks(page: page, sort: sort, source: .history)
        }
    }

    var visibleHistory: [Track] {
        history.items.filter { !hiddenHistoryIDs.contains($0.guid) }
    }

    // Opening/closing the drawer never cancels or restarts an in-flight load.
    // The presentation state lives in LibraryContext, not the conditional view.
    func loadHistoryIfNeeded() async {
        if let historyTask { await historyTask.value; return }
        guard history.total == nil, history.items.isEmpty, history.hasMore else { return }
        await loadHistory()
    }

    func loadHistory(refresh: Bool = false) async {
        if refresh { historyRefreshPending = true }
        if let historyTask { await historyTask.value; return }
        let history = history
        let task = Task {
            defer { historyTask = nil }
            repeat {
                let shouldRefresh = historyRefreshPending
                historyRefreshPending = false
                if shouldRefresh { await history.refresh() }
                else { await history.loadMore() }
            } while historyRefreshPending
        }
        historyTask = task
        await task.value
    }

    /// Explicitly local and reversible; never issues a server deletion request.
    func clearDisplayedHistory() {
        hiddenHistoryIDs.formUnion(visibleHistory.map(\.guid))
    }

    func restoreHistoryDisplay() { hiddenHistoryIDs.removeAll() }

    /// Native menus can outlive the row snapshot that opened them. Never apply
    /// an old positional action to a different entry after structural edits.
    /// GUID lookup cannot solve this: duplicate tracks are valid queue entries.
    @discardableResult
    func performQueueAction(at index: Int, snapshot: [Track], queue: QueueManager,
                            action: (Int) -> Void) -> Bool {
        guard queue.tracks == snapshot, snapshot.indices.contains(index) else { return false }
        action(index)
        return true
    }

    func matchesQueueSearch(_ track: Track) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || track.displayTitle.localizedStandardContains(term)
            || track.artistText.localizedStandardContains(term)
    }
}
