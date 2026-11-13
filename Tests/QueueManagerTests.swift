import XCTest
@testable import FnMusic

/// Queue navigation, repeat modes and the no-replacement shuffle traversal.
/// Shuffle randomness has no injectable RNG, so these tests assert traversal
/// invariants (per-pass uniqueness, coverage, no immediate repeat across a
/// refill) instead of exact sequences.
@MainActor
final class QueueManagerTests: XCTestCase {
    private func makeQueue(_ ids: [String] = ["a", "b", "c"]) -> QueueManager {
        let queue = QueueManager()
        queue.replace(with: ids.map { Track(guid: $0) }, startAt: ids.first ?? "")
        return queue
    }

    /// Guards against a broken traversal spinning forever in a `while next()` loop.
    private func drain(_ queue: QueueManager, includeCurrent: Bool = true) -> [String] {
        var played = includeCurrent ? [queue.current?.guid ?? ""] : []
        var steps = 0
        while let track = queue.next() {
            played.append(track.guid)
            steps += 1
            if steps > 20 { XCTFail("shuffle traversal did not terminate"); break }
        }
        return played
    }

    // MARK: - Sequential navigation

    func testSequentialNavigationBoundaries() {
        let queue = makeQueue()
        XCTAssertEqual(queue.current?.guid, "a")
        XCTAssertNil(queue.previous())
        XCTAssertEqual(queue.next()?.guid, "b")
        XCTAssertEqual(queue.next()?.guid, "c")
        // Exhausting a sequential queue keeps the selection for context.
        XCTAssertNil(queue.next())
        XCTAssertEqual(queue.index, 2)
        XCTAssertEqual(queue.current?.guid, "c")
        XCTAssertEqual(queue.previous()?.guid, "b")
    }

    func testRepeatAllWrapsInBothDirections() {
        let queue = makeQueue()
        queue.repeatMode = .all
        XCTAssertEqual(queue.previous()?.guid, "c")
        XCTAssertEqual(queue.next()?.guid, "a")
        queue.select(index: 2)
        XCTAssertEqual(queue.next(automatic: false)?.guid, "a")
    }

    func testRepeatOneRepeatsOnlyAutomaticAdvances() {
        let queue = makeQueue()
        queue.repeatMode = .one
        XCTAssertEqual(queue.next()?.guid, "a")
        XCTAssertEqual(queue.next(automatic: false)?.guid, "b")
        XCTAssertEqual(queue.next()?.guid, "b")
        XCTAssertEqual(queue.previous()?.guid, "a")
        queue.select(index: 2)
        XCTAssertNil(queue.next(automatic: false))
        XCTAssertEqual(queue.current?.guid, "c")
    }

    func testCycleRepeatModeVisitsAllModes() {
        let queue = makeQueue()
        XCTAssertEqual(queue.repeatMode, .off)
        queue.cycleRepeatMode()
        XCTAssertEqual(queue.repeatMode, .all)
        queue.cycleRepeatMode()
        XCTAssertEqual(queue.repeatMode, .one)
        queue.cycleRepeatMode()
        XCTAssertEqual(queue.repeatMode, .off)
    }

    // MARK: - replace / append

    func testReplaceSelectsMatchingGuidOrFallsBack() {
        let queue = makeQueue()
        queue.replace(with: [Track(guid: "x"), Track(guid: "x")], startAt: "x")
        XCTAssertEqual(queue.index, 0)
        queue.replace(with: [Track(guid: "z")], startAt: "missing")
        XCTAssertEqual(queue.index, 0)
        XCTAssertEqual(queue.current?.guid, "z")
        queue.replace(with: [], startAt: "z")
        XCTAssertNil(queue.index)
        XCTAssertNil(queue.current)
    }

    func testAppendToEmptyQueueStartsPlayback() {
        let queue = QueueManager()
        queue.append(Track(guid: "only"))
        XCTAssertEqual(queue.index, 0)
        XCTAssertEqual(queue.current?.guid, "only")
    }

    // MARK: - Structural edits

    func testInsertNextAndAppendPreserveCurrent() {
        let queue = makeQueue()
        queue.insertNext(Track(guid: "next"))
        queue.append(Track(guid: "last"))
        XCTAssertEqual(queue.tracks.map(\.guid), ["a", "next", "b", "c", "last"])
        XCTAssertEqual(queue.index, 0)
        XCTAssertEqual(queue.next()?.guid, "next")
        XCTAssertEqual(queue.next()?.guid, "b")
    }

    func testRemoveCurrentSelectsSuccessorThenWrapsToStart() {
        let queue = makeQueue()
        queue.select(index: 1)
        queue.remove(at: 1)
        XCTAssertEqual(queue.current?.guid, "c")
        XCTAssertEqual(queue.index, 1)
        queue.remove(at: 1)
        XCTAssertEqual(queue.current?.guid, "a")
        XCTAssertEqual(queue.index, 0)
        queue.remove(at: 0)
        XCTAssertNil(queue.index)
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.tracks.isEmpty)
    }

    func testRemovingBeforeCurrentShiftsIndex() {
        let queue = makeQueue(["a", "same", "same", "b"])
        queue.select(index: 2)
        queue.remove(at: 0)
        XCTAssertEqual(queue.index, 1)
        XCTAssertEqual(queue.current?.guid, "same")
        XCTAssertEqual(queue.next()?.guid, "b")
    }

    func testMovingEntriesTracksCurrentByPositionNotGuid() {
        let queue = makeQueue(["same", "b", "same", "c"])
        queue.select(index: 2)
        queue.move(from: 2, to: 0)
        XCTAssertEqual(queue.index, 0)
        queue.move(from: 3, to: 0)
        XCTAssertEqual(queue.index, 1)
        queue.move(from: 0, to: 3)
        XCTAssertEqual(queue.index, 0)
        XCTAssertEqual(queue.next()?.guid, "same")
        XCTAssertEqual(queue.index, 1)
    }

    func testInvalidOperationsAreSafe() {
        let queue = QueueManager()
        XCTAssertNil(queue.next())
        XCTAssertNil(queue.previous())
        XCTAssertNil(queue.select(index: -1))
        queue.remove(at: 0)
        queue.move(from: 0, to: 1)
        queue.insertNext(Track(guid: "first"))
        XCTAssertEqual(queue.current?.guid, "first")
        queue.remove(at: -1)
        queue.move(from: 0, to: 1)
        XCTAssertEqual(queue.tracks.count, 1)
    }

    // MARK: - Shuffle pass invariants

    func testShufflePassVisitsEachDistinctGuidOnceIncludingDuplicates() {
        let queue = makeQueue(["a", "b", "a", "c", "b"])
        queue.shuffle = true
        let played = drain(queue)
        XCTAssertEqual(played.count, 3)
        XCTAssertEqual(Set(played), ["a", "b", "c"])
        XCTAssertNil(queue.next())
    }

    func testShufflePassCoversAllUniqueGuids() {
        let ids = (0..<9).map { "t\($0)" }
        let queue = makeQueue(ids)
        queue.shuffle = true
        let played = drain(queue)
        XCTAssertEqual(played.count, ids.count)
        XCTAssertEqual(Set(played), Set(ids))
    }

    func testShuffledAppendOfExistingGuidDoesNotDoubleSchedule() {
        let queue = makeQueue(["a", "b", "c"])
        queue.shuffle = true
        queue.append(Track(guid: "b"))
        let played = drain(queue)
        XCTAssertEqual(played.count, 3)
        XCTAssertEqual(Set(played), ["a", "b", "c"])
    }

    func testShufflePreviousWalksHistoryBackwardToStart() {
        let queue = makeQueue(["a", "b", "c"])
        queue.shuffle = true
        XCTAssertEqual(drain(queue).count, 3)
        var reversed: [String] = []
        var steps = 0
        while let track = queue.previous() {
            reversed.append(track.guid)
            steps += 1
            if steps > 20 { XCTFail("history rewind did not terminate"); break }
        }
        XCTAssertEqual(reversed.count, 2)
        XCTAssertEqual(queue.current?.guid, "a")
        XCTAssertNil(queue.previous())
    }

    // MARK: - nextForPlayback (exhausted-pass refill)

    func testNextForPlaybackRefillsExhaustedPass() {
        let queue = makeQueue(["a", "b", "c", "d"])
        queue.shuffle = true
        var pass1 = [queue.current?.guid ?? ""]
        for _ in 0..<3 { pass1.append(queue.nextForPlayback()!.guid) }
        XCTAssertEqual(Set(pass1), Set(["a", "b", "c", "d"]))
        // One-pass traversal reports exhaustion…
        XCTAssertNil(queue.next())
        // …while the playback-facing advance starts a fresh pass.
        let refillStart = queue.nextForPlayback()
        XCTAssertNotNil(refillStart)
        XCTAssertEqual(refillStart?.guid, queue.current?.guid)
    }

    func testNextForPlaybackRefillAvoidsImmediateRepeatAcrossBoundary() {
        let queue = makeQueue(["a", "b", "c", "d"])
        queue.shuffle = true
        for _ in 0..<3 { _ = queue.nextForPlayback() }
        let lastOfPass1 = queue.current?.guid
        let firstOfPass2 = queue.nextForPlayback()?.guid
        XCTAssertNotEqual(firstOfPass2, lastOfPass1)
    }

    func testNextForPlaybackSecondPassIsAlsoUniqueAndComplete() {
        let ids = ["a", "b", "c", "d", "e"]
        let queue = makeQueue(ids)
        queue.shuffle = true
        // Consume pass 1.
        for _ in 0..<(ids.count - 1) { _ = queue.nextForPlayback() }
        // Consume pass 2 (first step refills).
        var pass2: [String] = []
        for _ in 0..<ids.count {
            guard let guid = queue.nextForPlayback()?.guid else {
                XCTFail("refilled pass must keep advancing")
                return
            }
            pass2.append(guid)
        }
        XCTAssertEqual(pass2.count, ids.count)
        XCTAssertEqual(Set(pass2), Set(ids))
    }

    func testNextForPlaybackPreservesHistoryAcrossPassBoundary() {
        let queue = makeQueue(["a", "b", "c", "d"])
        queue.shuffle = true
        for _ in 0..<3 { _ = queue.nextForPlayback() }
        let lastOfPass1 = queue.current?.guid
        _ = queue.nextForPlayback()
        XCTAssertEqual(queue.previous()?.guid, lastOfPass1)
    }

    func testNextForPlaybackSingleDistinctSongDoesNotRefillWithoutRepeatAll() {
        let queue = makeQueue(["only"])
        queue.shuffle = true
        XCTAssertNil(queue.next())
        XCTAssertNil(queue.nextForPlayback())
        XCTAssertEqual(queue.current?.guid, "only")
    }

    func testNextForPlaybackSingleDistinctSongLoopsWithRepeatAll() {
        let queue = makeQueue(["only"])
        queue.shuffle = true
        queue.repeatMode = .all
        XCTAssertEqual(queue.nextForPlayback()?.guid, "only")
    }

    // MARK: - Structural edits during shuffle

    func testShuffleInsertNextReplaysImmediatelyWithoutDoubleScheduling() {
        let queue = makeQueue(["a", "b", "c", "d"])
        queue.shuffle = true
        let firstStep = queue.next()?.guid
        XCTAssertNotNil(firstStep)
        queue.insertNext(Track(guid: "b"))
        // Inserting does not move the current selection.
        XCTAssertEqual(queue.current?.guid, firstStep)
        // "Play next" is an explicit override: it replays immediately…
        XCTAssertEqual(queue.next()?.guid, "b")
        // …and the remainder of the pass must not schedule it again.
        var rest: [String] = []
        var steps = 0
        while let track = queue.next() {
            rest.append(track.guid)
            steps += 1
            if steps > 20 { XCTFail("shuffle traversal did not terminate"); break }
        }
        XCTAssertFalse(rest.contains("b"))
    }

    func testShuffleRemovePrunesBagForRemovedGuids() {
        let queue = makeQueue(["a", "b", "b", "c"])
        queue.shuffle = true
        queue.remove(at: 1)
        queue.remove(at: 1)
        XCTAssertEqual(queue.tracks.map(\.guid), ["a", "c"])
        let played = drain(queue)
        XCTAssertEqual(played, ["a", "c"])
    }

    func testShuffleRemoveCurrentResetsPass() {
        let queue = makeQueue(["a", "b", "c", "d"])
        queue.shuffle = true
        queue.remove(at: 0)
        XCTAssertEqual(queue.current?.guid, "b")
        let played = drain(queue)
        XCTAssertEqual(played.count, 3)
        XCTAssertEqual(Set(played), Set(["b", "c", "d"]))
    }

    // MARK: - Shuffle bag membership edge cases

    func testShuffleAllDuplicateEntriesStopsUnlessLooping() {
        let queue = makeQueue(["same", "same", "same"])
        queue.shuffle = true
        XCTAssertNil(queue.next())
        XCTAssertNil(queue.nextForPlayback())
        XCTAssertEqual(queue.current?.guid, "same")

        queue.repeatMode = .all
        XCTAssertEqual(queue.nextForPlayback()?.guid, "same")
    }

    func testShuffleAppendPlayedDuplicateDoesNotReplayInSamePass() throws {
        let queue = makeQueue(["a", "b", "c"])
        queue.shuffle = true
        XCTAssertNotNil(queue.next())
        let playedGUID = try XCTUnwrap(queue.current?.guid)
        queue.append(Track(guid: playedGUID))

        var guids = [playedGUID]
        while let next = queue.next() { guids.append(next.guid) }
        XCTAssertEqual(guids.filter { $0 == playedGUID }.count, 1,
                       "a duplicate of an already played entry must not replay this pass")
    }

    func testShuffleAppendNewGUIDJoinsCurrentPass() throws {
        let queue = makeQueue(["a", "b"])
        queue.shuffle = true
        queue.append(Track(guid: "c"))

        var guids = [try XCTUnwrap(queue.current?.guid)]
        while let next = queue.next() { guids.append(next.guid) }
        XCTAssertEqual(Set(guids), Set(["a", "b", "c"]))
        XCTAssertEqual(guids.count, 3, "an appended new guid joins the current pass")
    }

    // MARK: - Shuffle history invariants

    func testShufflePreviousRetracesAndNextReplaysHistory() throws {
        let queue = makeQueue(["a", "b", "c", "d", "e"])
        queue.shuffle = true
        var path = [try XCTUnwrap(queue.index)]
        for _ in 1..<queue.tracks.count {
            queue.next()
            path.append(try XCTUnwrap(queue.index))
        }
        for index in path.dropLast().reversed() {
            XCTAssertNotNil(queue.previous())
            XCTAssertEqual(queue.index, index)
        }
        XCTAssertNil(queue.previous())
        for index in path.dropFirst() {
            XCTAssertNotNil(queue.next())
            XCTAssertEqual(queue.index, index, "forward history replays the exact path")
        }
        XCTAssertNil(queue.next())
    }

    func testShuffleRepeatAllRefillsWithoutImmediateRepeat() throws {
        let queue = makeQueue(["a", "b", "c", "d"])
        queue.shuffle = true
        queue.repeatMode = .all
        for _ in 1..<queue.tracks.count {
            queue.next()
        }
        var previous = queue.index
        for _ in 0..<20 {
            var cycle: Set<Int> = []
            for _ in queue.tracks.indices {
                XCTAssertNotNil(queue.next())
                let index = try XCTUnwrap(queue.index)
                XCTAssertNotEqual(index, previous, "refill must not repeat the boundary entry")
                cycle.insert(index)
                previous = index
            }
            XCTAssertEqual(cycle, Set(queue.tracks.indices), "every cycle covers each position once")
        }
    }

    func testShuffleRepeatOneDoesNotConsumeBagOrHistory() {
        let queue = makeQueue()
        queue.shuffle = true
        queue.repeatMode = .one
        XCTAssertEqual(queue.next()?.guid, "a")
        XCTAssertEqual(queue.index, 0)
        XCTAssertNil(queue.previous())
        XCTAssertNotNil(queue.next(automatic: false))
        XCTAssertNotEqual(queue.index, 0)
        XCTAssertEqual(queue.previous()?.guid, "a")
    }

    func testShuffleInsertNextWhileBacktrackingPreservesForwardHistory() {
        let queue = makeQueue()
        queue.shuffle = true
        let forward = queue.next()?.guid
        XCTAssertEqual(queue.previous()?.guid, "a")
        queue.insertNext(Track(guid: "inserted"))
        XCTAssertEqual(queue.next()?.guid, "inserted")
        XCTAssertEqual(queue.next()?.guid, forward, "the pre-insertion forward entry is preserved")
        XCTAssertNotNil(queue.next())
        XCTAssertNil(queue.next())
    }

    func testShuffleStructuralEditsRemapHistoryAndBag() throws {
        let queue = makeQueue(["a", "b", "c", "d", "e"])
        queue.shuffle = true
        let second = try XCTUnwrap(queue.next()?.guid)
        queue.move(from: 0, to: 4)
        XCTAssertEqual(queue.current?.guid, second)
        XCTAssertEqual(queue.previous()?.guid, "a", "history positions are remapped by the move")
        XCTAssertEqual(queue.next()?.guid, second)
        queue.remove(at: 4)
        XCTAssertEqual(queue.current?.guid, second)
        XCTAssertNil(queue.previous(), "removing the history predecessor clears history")
        queue.append(Track(guid: "new"))
        var remaining = Set(queue.tracks.map(\.guid))
        remaining.remove(second)
        while let next = queue.next() {
            XCTAssertNotNil(remaining.remove(next.guid))
        }
        XCTAssertTrue(remaining.isEmpty, "the appended guid is drawn exactly once")
    }

    func testShuffleToggleAndSelectResetTraversal() {
        let queue = makeQueue()
        queue.shuffle = true
        queue.next()
        queue.select(index: 1)
        XCTAssertNil(queue.previous(), "an explicit selection clears shuffle history")
        queue.shuffle = false
        XCTAssertEqual(queue.next()?.guid, "c")
        queue.shuffle = true
        XCTAssertNil(queue.previous(), "re-enabling shuffle clears history again")
        XCTAssertNotNil(queue.next())
        XCTAssertNotNil(queue.next())
        XCTAssertNil(queue.next())
    }

    // MARK: - nextForPlayback edge cases

    func testPlaybackAdvanceStopsAtSequentialQueueEnd() {
        let queue = makeQueue()
        queue.repeatMode = .off
        queue.select(index: 2)
        XCTAssertNil(queue.nextForPlayback())
        XCTAssertEqual(queue.index, 2)
    }

    func testPlaybackAdvancePreservesRepeatOne() {
        let queue = makeQueue()
        queue.shuffle = true
        queue.repeatMode = .one
        XCTAssertEqual(queue.nextForPlayback()?.guid, "a")
        XCTAssertEqual(queue.index, 0)

        // Manual navigation still advances, including into a fresh pass at the end.
        XCTAssertNotNil(queue.nextForPlayback(automatic: false))
        XCTAssertNotEqual(queue.index, 0)
        XCTAssertNotNil(queue.nextForPlayback(automatic: false))
        let beforeBoundary = queue.index
        XCTAssertNotNil(queue.nextForPlayback(automatic: false))
        XCTAssertNotEqual(queue.index, beforeBoundary)
    }

    // MARK: - Single-entry and enum surface

    func testSingleEntryRepeatModesAndShuffle() {
        let queue = makeQueue(["only"])
        queue.shuffle = true
        XCTAssertNil(queue.next())
        queue.repeatMode = .one
        XCTAssertEqual(queue.next()?.guid, "only")
        XCTAssertNil(queue.next(automatic: false))
        queue.repeatMode = .all
        XCTAssertEqual(queue.next()?.guid, "only")
        XCTAssertEqual(queue.previous()?.guid, "only")
    }

    func testRepeatModeConveniences() {
        XCTAssertEqual(RepeatMode.allCases.map(\.rawValue), ["off", "all", "one"])
        for mode in RepeatMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.symbol.isEmpty)
        }
        XCTAssertEqual(RepeatMode.one.symbol, "repeat.1")
    }
}
