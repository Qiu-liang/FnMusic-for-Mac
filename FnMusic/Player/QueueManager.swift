import Foundation
import Observation

/// Repeat-one affects automatic completion only; manual navigation still advances.
/// Shuffle traverses no-replacement passes deduplicated by `Track.guid`; playback
/// asks for a fresh pass at the end of each one through `nextForPlayback`.
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
/// Shuffle passes are deduplicated by Track.guid: duplicate entries remain in the
/// queue, but only one occurrence of each song is scheduled per pass.
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
    // The shuffle bag stores GUIDs, not indices, so duplicate queue entries are
    // scheduled at most once per pass.
    @ObservationIgnored private(set) var sessionID = UUID()
    @ObservationIgnored private var bag: [String] = []
    // GUIDs already played (or explicitly queued with "play next") this pass.
    @ObservationIgnored private var passScheduledGUIDs: Set<String> = []
    @ObservationIgnored private var history: [Int] = []
    @ObservationIgnored private var historyPosition = 0

    func replace(with tracks: [Track], startAt guid: String) {
        sessionID = UUID()
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
        guard shuffle else { return }

        let guid = track.guid
        // The queue entry is kept, but a duplicate GUID must not create a second
        // occurrence in the current shuffle pass.
        guard current?.guid != guid,
              !bag.contains(guid),
              !passScheduledGUIDs.contains(guid) else { return }
        bag.insert(guid, at: Int.random(in: 0...bag.count))
    }

    /// Appends a batch of tracks (e.g. background-loaded pages) while folding
    /// unseen GUIDs uniformly into the active shuffle pass.
    func append(contentsOf newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }
        guard index != nil else {
            tracks = newTracks
            index = 0
            resetShuffle()
            return
        }
        tracks.append(contentsOf: newTracks)
        guard shuffle else { return }

        let currentGUID = current?.guid
        var knownInBag = Set(bag)
        for track in newTracks {
            let guid = track.guid
            guard guid != currentGUID,
                  !passScheduledGUIDs.contains(guid),
                  knownInBag.insert(guid).inserted else { continue }
            bag.insert(guid, at: Int.random(in: 0...bag.count))
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
        remapShuffleHistory { $0 >= insertion ? $0 + 1 : $0 }
        if shuffle {
            // Keep the forward history intact when inserting after stepping back.
            // "Play next" is an explicit override; remove the GUID from the
            // random bag so it cannot also be drawn later in this pass.
            bag.removeAll { $0 == track.guid }
            passScheduledGUIDs.insert(track.guid)
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
            remapShuffleHistory { value in
                if value == position { return nil }
                return value > position ? value - 1 : value
            }
            pruneShuffleBag()
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
        remapShuffleHistory { mappedIndex($0) }
    }

    func clear() {
        sessionID = UUID()
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

    /// One-pass traversal. A shuffle pass visits each distinct Track.guid at
    /// most once. Playback should use `nextForPlayback` so a fully consumed
    /// shuffled pass starts a new one instead of stalling.
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
    /// queue with only one distinct song keep their existing semantics.
    @discardableResult
    func nextForPlayback(automatic: Bool = true) -> Track? {
        if let track = next(automatic: automatic) { return track }
        guard index != nil, shuffle else { return nil }
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

    /// Unique GUIDs in queue order. Duplicate entries of the same song are
    /// represented once in each shuffle pass.
    private var uniqueTrackGUIDs: [String] {
        var seen = Set<String>()
        return tracks.compactMap { seen.insert($0.guid).inserted ? $0.guid : nil }
    }

    private func resetShuffle() {
        bag.removeAll()
        passScheduledGUIDs.removeAll()
        history.removeAll()
        historyPosition = 0
        guard shuffle, let index else { return }
        let currentGUID = tracks[index].guid
        history = [index]
        passScheduledGUIDs = [currentGUID]
        bag = uniqueTrackGUIDs.filter { $0 != currentGUID }.shuffled()
    }

    private func nextShuffled(allowRefill: Bool = false) -> Track? {
        if historyPosition + 1 < history.count {
            historyPosition += 1
            index = history[historyPosition]
            if let guid = current?.guid {
                // Manual backtracking replay counts as this pass's occurrence.
                bag.removeAll { $0 == guid }
                passScheduledGUIDs.insert(guid)
            }
            return current
        }

        if bag.isEmpty {
            // `next` reports a completed one-pass shuffle as nil. Playback calls
            // back with `allowRefill` to begin the next pass instead of stopping.
            guard repeatMode == .all || allowRefill else { return nil }
            let guids = uniqueTrackGUIDs
            guard !guids.isEmpty else { return nil }
            // A single distinct song has no alternative pick; only list loop
            // should replay it automatically.
            guard repeatMode == .all || guids.count > 1 else { return nil }

            bag = guids.shuffled()
            passScheduledGUIDs.removeAll()
            // Every song gets one turn in a refill, without an immediate repeat
            // across the pass boundary (unless there is only one distinct song).
            if let currentGUID = current?.guid, guids.count > 1,
               bag.last == currentGUID,
               let different = bag.firstIndex(where: { $0 != currentGUID }) {
                bag.swapAt(different, bag.count - 1)
            }
        }

        while let nextGUID = bag.popLast() {
            guard let nextIndex = tracks.firstIndex(where: { $0.guid == nextGUID }) else { continue }
            index = nextIndex
            passScheduledGUIDs.insert(nextGUID)
            history.append(nextIndex)
            historyPosition = history.count - 1
            return current
        }
        return nil
    }

    /// Preserve the history cursor across structural edits. The shuffle bag is
    /// GUID-based and does not need index remapping.
    private func remapShuffleHistory(_ transform: (Int) -> Int?) {
        guard shuffle else { return }
        let retainedThroughCurrent = history.prefix(historyPosition + 1)
            .compactMap(transform).count
        history = history.compactMap(transform)
        historyPosition = max(0, retainedThroughCurrent - 1)
    }

    /// Drop GUIDs whose last queue occurrence was removed before they played.
    private func pruneShuffleBag() {
        guard shuffle else { return }
        let existing = Set(tracks.map(\.guid))
        bag.removeAll { !existing.contains($0) }
    }
}
