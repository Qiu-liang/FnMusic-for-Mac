import XCTest
@testable import FnMusic

/// Lyric loading races: clearing state with a nil load must invalidate both
/// in-flight requests and their late responses.
@MainActor
final class LyricsViewModelTests: XCTestCase {
    func testLoadingNilClearsPreviouslySelectedLyrics() async {
        let service = SuspendedLyricsService()
        let model = LyricsViewModel(service: service)
        await model.load(trackGUID: "initial")
        XCTAssertEqual(model.selectedGUID, "lyric")
        XCTAssertFalse(model.parsed.lines.isEmpty)

        await model.load(trackGUID: nil)

        XCTAssertFalse(model.loading)
        XCTAssertNil(model.selectedGUID)
        XCTAssertTrue(model.variants.isEmpty)
        XCTAssertTrue(model.parsed.lines.isEmpty)
        XCTAssertNil(model.error)
    }

    func testLoadingNilWhileRequestIsPendingIgnoresStaleSuccess() async {
        await assertLoadingNilIgnoresPendingRequest(failing: false)
    }

    func testLoadingNilWhileRequestIsPendingIgnoresStaleFailure() async {
        await assertLoadingNilIgnoresPendingRequest(failing: true)
    }

    private func assertLoadingNilIgnoresPendingRequest(failing: Bool) async {
        let service = SuspendedLyricsService()
        let model = LyricsViewModel(service: service)
        await model.load(trackGUID: "initial")
        let oldLoad = Task { await model.load(trackGUID: "pending") }
        await service.waitUntilPending()
        XCTAssertTrue(model.loading)

        await model.load(trackGUID: nil)
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.selectedGUID)
        XCTAssertTrue(model.variants.isEmpty)
        XCTAssertTrue(model.parsed.lines.isEmpty)
        XCTAssertNil(model.error)

        await service.complete(failing: failing)
        await oldLoad.value
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.selectedGUID)
        XCTAssertTrue(model.variants.isEmpty)
        XCTAssertTrue(model.parsed.lines.isEmpty)
        XCTAssertNil(model.error, "a late response after a nil load must not repopulate state")
    }
}

/// Continuations make the race deterministic without sleeps or shared mutable
/// state crossing actors. Only the test/view model run on the main actor.
private actor SuspendedLyricsService: LyricsServiceProtocol {
    private var pending: CheckedContinuation<LyricResponse, any Error>?
    private var pendingWaiter: CheckedContinuation<Void, Never>?
    private let response = LyricResponse(
        list: [Lyric(guid: "lyric", content: "[00:01]Hello", isLRC: true)],
        preferred: "lyric"
    )

    func lyrics(trackGUID: String) async throws -> LyricResponse {
        if trackGUID == "initial" { return response }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            pendingWaiter?.resume()
            pendingWaiter = nil
        }
    }

    func waitUntilPending() async {
        if pending != nil { return }
        await withCheckedContinuation { pendingWaiter = $0 }
    }

    func complete(failing: Bool) {
        if failing {
            pending?.resume(throwing: Failure.request)
        } else {
            pending?.resume(returning: response)
        }
        pending = nil
    }

    private enum Failure: Error { case request }
}
