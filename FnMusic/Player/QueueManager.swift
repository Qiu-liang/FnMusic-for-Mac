import Observation

/// Repeat-one affects automatic completion only; manual navigation still advances.
/// Shuffle traverses no-replacement passes; playback asks for a fresh pass at the
/// end of each one through `QueueManager.nextForPlayback`.
enum RepeatMode: String, CaseIterable, Sendable {
    case off
    case all
    case one

    var title: String {
        switch self {
        case .off:
            return "顺序播放"
        case .all:
            return "列表循环"
        case .one:
            return "单曲循环"
        }
    }

    var symbol: String {
        switch self {
        case .off, .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }
}

/// Queue entries are identified by position, not by Track.guid: duplicates are valid.
@MainActor
@Observable
final class QueueManager {
    private(set) var tracks: [Track] = []
    private(set) var index: Int?

    var current: Track? {
        guard let index else { return nil }
        return tracks[index]
    }

    var shuffle = false {
        didSet {
            if shuffle != oldValue {
                resetShuffle()
            }
        }
    }

    var repeatMode: RepeatMode = .off

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // Internal traversal state must not create observation dependencies for views.
    @ObservationIgnored private var bag: [Int] = []
    @ObservationIgnored private var history: [Int] = []
    @ObservationIgnored private var historyPosition = 0

    func replace(with tracks: [Track], startAt guid: String) {
        self.tracks = tracks
        index = tracks.firstIndex { $0.guid == guid } ?? tracks.indices.first
        resetShuffle()
    }

    func append(_ track: Track) {
        tracks.append(track)
        guard index != nil else {
            index = 0
            resetShuffle()
            return
        }

        if shuffle {
            bag.insert(tracks.count - 1, at: Int.random(in: 0...bag.count))
        }
    }

    /// Inserts directly after the current entry, including in shuffle traversal.
    func insertNext(_ track: Track) {
        guard let index else {
            append(track)
            return
        }

        let insertion = index + 1
        tracks.insert(track, at: insertion)
        remapShuffle { $0 >= insertion ? $0 + 1 : $0 }
        if shuffle {
            // Keep the forward history intact when inserting after stepping back.
            history.insert(insertion, at: historyPosition + 1)
        }
    }

    /// Removing the current entry selects its successor, or the new last entry.
    func remove(at position: Int) {
        guard tracks.indices.contains(position) else { return }
        let oldIndex = index
        tracks.remove(at: position)

        guard !tracks.isEmpty else {
            clear()
            return
        }
        guard let oldIndex else { return }

        if position == oldIndex {
            index = min(position, tracks.count - 1)
            resetShuffle()
        } else {
            index = position < oldIndex ? oldIndex - 1 : oldIndex
            remapShuffle { value in
                if value == position { return nil }
                return value > position ? value - 1 : value
            }
        }
    }

    /// `to` is the entry's final index (not a SwiftUI onMove insertion offset).
    func move(from source: Int, to destination: Int) {
        guard tracks.indices.contains(source),
              tracks.indices.contains(destination),
              source != destination else { return }

        let track = tracks.remove(at: source)
        tracks.insert(track, at: destination)

        let mappedIndex: (Int) -> Int = { value in
            if value == source { return destination }
            if source < destination, value > source, value <= destination {
                return value - 1
            }
            if destination < source, value >= destination, value < source {
                return value + 1
            }
            return value
        }
        index = index.map(mappedIndex)
        remapShuffle { mappedIndex($0) }
    }

    func clear() {
        tracks.removeAll()
        index = nil
        resetShuffle()
    }

    @discardableResult
    func select(index: Int) -> Track? {
        guard tracks.indices.contains(index) else { return nil }
        self.index = index
        resetShuffle()
        return current
    }

    /// One-pass traversal. Playback should use `nextForPlayback` so a fully
    /// consumed shuffled pass starts a new one instead of stalling.
    @discardableResult
    func next(automatic: Bool = true) -> Track? {
        guard let index else { return nil }
        if automatic, repeatMode == .one {
            return current
        }
        if shuffle {
            return nextShuffled()
        }

        if index + 1 < tracks.count {
            self.index = index + 1
        } else if repeatMode == .all {
            self.index = 0
        } else {
            // Keep the selection so the UI and playback completion retain context.
            return nil
        }
        return current
    }

    /// Playback-facing advance. When a no-replacement shuffle pass has been
    /// fully consumed, start a fresh pass so automatic completion and the Next
    /// command keep working. The shuffle history is preserved, so `previous()`
    /// can still cross the pass boundary.
    ///
    /// Sequential playback, `repeatMode == .one` automatic completion, and a
    /// single-entry queue keep their existing semantics.
    @discardableResult
    func nextForPlayback(automatic: Bool = true) -> Track? {
        if let track = next(automatic: automatic) { return track }
        guard index != nil, shuffle, tracks.count > 1 else { return nil }
        return nextShuffled(allowRefill: true)
    }

    @discardableResult
    func previous() -> Track? {
        guard let index else { return nil }
        if shuffle {
            guard historyPosition > 0 else { return nil }
            historyPosition -= 1
            self.index = history[historyPosition]
        } else if index > 0 {
            self.index = index - 1
        } else if repeatMode == .all {
            self.index = tracks.count - 1
        } else {
            return nil
        }
        return current
    }

    // MARK: - Local shuffle bag and reversible history

    private func resetShuffle() {
        bag.removeAll()
        history.removeAll()
        historyPosition = 0
        guard shuffle, let index else { return }
        history = [index]
        bag = tracks.indices.filter { $0 != index }.shuffled()
    }

    private func nextShuffled(allowRefill: Bool = false) -> Track? {
        if historyPosition + 1 < history.count {
            historyPosition += 1
            index = history[historyPosition]
            return current
        }

        if bag.isEmpty {
            // `next` reports a completed one-pass shuffle as nil. Playback calls
            // back with `allowRefill` to begin the next pass instead of stopping.
            guard repeatMode == .all || allowRefill else { return nil }
            bag = Array(tracks.indices).shuffled()
            // Every entry gets one turn in a refill, without an immediate repeat
            // across the cycle boundary (unless the queue has only one entry).
            if bag.last == index,
               let different = bag.firstIndex(where: { $0 != index }) {
                bag.swapAt(different, bag.count - 1)
            }
        }
        guard let nextIndex = bag.popLast() else { return nil }
        index = nextIndex
        history.append(nextIndex)
        historyPosition = history.count - 1
        return current
    }

    /// Preserve entry identity and the history cursor across structural edits.
    private func remapShuffle(_ transform: (Int) -> Int?) {
        guard shuffle else { return }
        bag = bag.compactMap(transform)
        let retainedThroughCurrent = history.prefix(historyPosition + 1)
            .compactMap(transform).count
        history = history.compactMap(transform)
        historyPosition = max(0, retainedThroughCurrent - 1)
    }
}
