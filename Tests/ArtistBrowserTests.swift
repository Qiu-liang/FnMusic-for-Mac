import XCTest
@testable import FnMusic

/// Per-session fixture, with no mutable global handler or live server dependency.
private final class ArtistSearchFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(items.count, query.count)
        let body: String
        if url.path == "/music/api/v1/search/artist" {
            XCTAssertEqual(query, ["q": "A & 中文/+?"])
            body = #"{"code":0,"data":{"list":[{"guid":"a","name":"Artist","score":3}],"total":1}}"#
        } else {
            XCTAssertEqual(url.path, "/music/api/v1/artist/list")
            XCTAssertEqual(query, ["page": "2", "size": "60", "sort": "name,asc"])
            body = #"{"code":0,"data":{"list":[],"total":60}}"#
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Controlled actor deliberately returns suspended responses even after their
/// caller was cancelled. This verifies generation guards, not just URLSession.
private actor ArtistBrowserMock: MusicServiceProtocol, ArtistSearchServiceProtocol {
    enum Request: Hashable, Sendable {
        case directory(Int, String)
        case search(String)
        case tracks(Int, TrackSource)
        case albums(Int, String?)
        case artist(String)
        case album(String)

        var kind: String {
            switch self {
            case .directory: "directory"
            case .search: "search"
            case .tracks: "tracks"
            case .albums: "albums"
            case .artist: "artist"
            case .album: "album"
            }
        }
    }

    enum Reply: Sendable {
        case artists(Page<Artist>)
        case tracks(Page<Track>)
        case albums(Page<Album>)
        case artist(Artist)
        case failure
    }

    private struct PendingKey: Hashable { let request: Request; let occurrence: Int }
    private let replies: [Request: Reply]
    private let suspendedKinds: Set<String>
    private var calls: [Request] = []
    private var cancelledCalls = Set<Request>()
    private var pending: [PendingKey: CheckedContinuation<Reply, Never>] = [:]
    private var waiters: [(PendingKey, CheckedContinuation<Void, Never>)] = []

    init(replies: [Request: Reply] = [:], suspendedKinds: Set<String> = []) {
        self.replies = replies
        self.suspendedKinds = suspendedKinds
    }

    func recordedCalls() -> [Request] { calls }
    func observedCancellation(_ request: Request) -> Bool { cancelledCalls.contains(request) }

    func waitFor(_ request: Request, occurrence: Int = 1) async {
        let key = PendingKey(request: request, occurrence: occurrence)
        if calls.filter({ $0 == request }).count >= occurrence { return }
        await withCheckedContinuation { waiters.append((key, $0)) }
    }

    func resolve(_ request: Request, occurrence: Int = 1, with reply: Reply) {
        pending.removeValue(forKey: PendingKey(request: request, occurrence: occurrence))?.resume(returning: reply)
    }

    private func response(_ request: Request, default defaultReply: Reply) async throws -> Reply {
        calls.append(request)
        let key = PendingKey(request: request, occurrence: calls.filter { $0 == request }.count)
        let reply: Reply
        if suspendedKinds.contains(request.kind) {
            reply = await withCheckedContinuation { continuation in
                pending[key] = continuation
                notifyWaiters()
            }
        } else {
            notifyWaiters()
            reply = replies[request] ?? defaultReply
        }
        if Task.isCancelled { cancelledCalls.insert(request) }
        if case .failure = reply { throw APIError.unavailable("Fixture metadata/request failure") }
        return reply
    }

    private func notifyWaiters() {
        let ready = waiters.filter { waiter in
            calls.filter { $0 == waiter.0.request }.count >= waiter.0.occurrence
        }
        waiters.removeAll { waiter in
            calls.filter { $0 == waiter.0.request }.count >= waiter.0.occurrence
        }
        for (_, continuation) in ready { continuation.resume() }
    }

    func artists(page: Int, sort: String) async throws -> Page<Artist> {
        guard case .artists(let result) = try await response(.directory(page, sort), default: .artists(Page(list: [], total: 0))) else {
            throw APIError.decoding
        }
        return result
    }

    func artists(query: String) async throws -> Page<Artist> {
        guard case .artists(let result) = try await response(.search(query), default: .artists(Page(list: [], total: 0))) else {
            throw APIError.decoding
        }
        return result
    }

    func tracks(page: Int, sort: String, source: TrackSource) async throws -> Page<Track> {
        XCTAssertEqual(sort, source.defaultSort)
        guard case .tracks(let result) = try await response(.tracks(page, source), default: .tracks(Page(list: [], total: 0))) else {
            throw APIError.decoding
        }
        return result
    }

    func albums(page: Int, sort: String, artistGUID: String?) async throws -> Page<Album> {
        XCTAssertEqual(sort, "newTrackAddedAt,desc")
        guard case .albums(let result) = try await response(.albums(page, artistGUID), default: .albums(Page(list: [], total: 0))) else {
            throw APIError.decoding
        }
        return result
    }

    func artist(guid: String) async throws -> Artist {
        guard case .artist(let result) = try await response(.artist(guid), default: .artist(Artist(guid: guid))) else {
            throw APIError.decoding
        }
        return result
    }

    func album(guid: String) async throws -> Album {
        _ = try await response(.album(guid), default: .failure)
        throw APIError.decoding
    }
}

@MainActor
final class ArtistBrowserTests: XCTestCase {
    func testReenteringDirectoryPreservesLoadedPagesAndSelection() async {
        let first = Artist(guid: "first", name: "第一页")
        let second = Artist(guid: "second", name: "第二页")
        let mock = ArtistBrowserMock(replies: [
            .directory(1, "name,asc"): .artists(Page(list: [first], total: 2)),
            .directory(2, "name,asc"): .artists(Page(list: [second], total: 2)),
            .search("needle"): .artists(Page(list: [second], total: 1))
        ])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        await model.ensureDirectory()
        await model.loadMoreArtists()
        model.selectArtist(second)
        await model.ensureDirectory()
        XCTAssertEqual(model.artists.map(\.guid), ["first", "second"])
        XCTAssertEqual(model.selectedScope.id, "artist:second")
        let calls = await mock.recordedCalls()
        XCTAssertEqual(calls.filter { $0.kind == "directory" }.count, 2)
        model.query = "needle"
        XCTAssertFalse(model.hasDirectorySnapshot)
        await model.ensureDirectory()
        XCTAssertEqual(model.artists.map(\.guid), ["second"])
        XCTAssertTrue(model.hasDirectorySnapshot)
    }

    private func decodeTrack(_ json: String) throws -> Track {
        try JSONDecoder().decode(Track.self, from: Data(json.utf8))
    }

    func testSearchOnlySendsQAndDirectoryKeepsPageSize60() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtistSearchFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = APIClient(origin: try APIClient.serverURL("https://artist-fixture.invalid"),
                               token: "fixture-only", session: session)
        let page = try await ArtistSearchService(client: client).artists(query: "A & 中文/+?")
        XCTAssertEqual(page.list.map(\.guid), ["a"])
        XCTAssertEqual(page.list.first?.score, 3)
        _ = try await MusicService(client: client).artists(page: 2, sort: "name,asc")
    }

    func testDirectoryDeduplicatesGUIDNotNameAndStopsRepeatedPage() async {
        let a = Artist(guid: "a", name: "Same name")
        let b = Artist(guid: "b", name: "Same name")
        let mock = ArtistBrowserMock(replies: [
            .directory(1, "name,asc"): .artists(Page(list: [a, a, b], total: 90)),
            .directory(2, "name,asc"): .artists(Page(list: [b, a], total: 90))
        ])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        await model.reloadDirectory()
        XCTAssertEqual(model.artists.map(\.guid), ["a", "b"])
        XCTAssertEqual(model.selectedScope.id, "artist:a")
        XCTAssertTrue(model.directoryHasMore)
        XCTAssertEqual(model.directoryTotal, 90)
        await model.loadMoreArtists()
        await model.loadMoreArtists()
        XCTAssertFalse(model.directoryHasMore)
        let calls = await mock.recordedCalls()
        XCTAssertEqual(calls, [.directory(1, "name,asc"), .directory(2, "name,asc")])
    }

    func testSelectionIsAutomaticOnlyOnceAndHistoryBranchesByGUID() async {
        let a = Artist(guid: "a", name: "Same")
        let b = Artist(guid: "b", name: "Same")
        let mock = ArtistBrowserMock(replies: [
            .directory(1, "name,asc"): .artists(Page(list: [a], total: 1)),
            .search("other"): .artists(Page(list: [b, b], total: 2))
        ])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        await model.reloadDirectory()
        model.select(.collaborations)
        model.query = "other"
        await model.reloadDirectory()
        XCTAssertEqual(model.selectedScope, .collaborations)
        XCTAssertEqual(model.artists.map(\.guid), ["b"])
        XCTAssertFalse(model.directoryHasMore)
        model.back()
        XCTAssertEqual(model.selectedScope.id, "artist:a")
        model.forward()
        XCTAssertEqual(model.selectedScope, .collaborations)
        model.back()
        model.selectArtist(b)
        XCTAssertFalse(model.canGoForward)
        model.back()
        XCTAssertEqual(model.selectedScope.id, "artist:a")
        model.back()
        XCTAssertEqual(model.selectedScope, .all)
        XCTAssertFalse(model.canGoBack)
    }

    func testExplicitAllBeforeFirstPagePreventsAutomaticSelection() async {
        let mock = ArtistBrowserMock(replies: [
            .directory(1, "name,asc"): .artists(Page(list: [Artist(guid: "a")], total: 1))
        ])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        model.select(.all)
        await model.reloadDirectory()
        XCTAssertEqual(model.selectedScope, .all)
    }

    func testSearchHasNoPagingAndCancelledDebounceDoesNotRequest() async {
        let mock = ArtistBrowserMock()
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        model.query = "cancelled"
        let cancelled = Task { await model.reloadDirectory() }
        cancelled.cancel()
        await cancelled.value
        model.query = "live"
        await model.reloadDirectory()
        await model.loadMoreArtists()
        let calls = await mock.recordedCalls()
        XCTAssertEqual(calls, [.search("live")])
        XCTAssertFalse(model.directoryLoading)
    }

    func testStaleDirectorySearchCannotReplaceNewSearchOrSelection() async {
        let mock = ArtistBrowserMock(suspendedKinds: ["search"])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        model.query = "old"
        let old = Task { await model.reloadDirectory() }
        await mock.waitFor(.search("old"))
        model.query = "new"
        let new = Task { await model.reloadDirectory() }
        await mock.waitFor(.search("new"))
        await mock.resolve(.search("new"), with: .artists(Page(list: [Artist(guid: "new")], total: 1)))
        await new.value
        await mock.resolve(.search("old"), with: .artists(Page(list: [Artist(guid: "old")], total: 1)))
        await old.value
        XCTAssertEqual(model.artists.map(\.guid), ["new"])
        XCTAssertEqual(model.selectedScope.id, "artist:new")
        XCTAssertNil(model.directoryError)
        let cancelled = await mock.observedCancellation(.search("old"))
        XCTAssertTrue(cancelled)
    }

    func testDirectorySortChangeDiscardsInflightPageBeforeReloadStarts() async {
        let mock = ArtistBrowserMock(suspendedKinds: ["directory"])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        let request = Task { await model.reloadDirectory() }
        await mock.waitFor(.directory(1, "name,asc"))
        model.sort = "trackCount,desc"
        await mock.resolve(.directory(1, "name,asc"), with: .artists(Page(list: [Artist(guid: "stale")], total: 1)))
        await request.value
        XCTAssertTrue(model.artists.isEmpty)
        XCTAssertFalse(model.directoryLoading)
    }

    func testArtistTracksAreGroupedWithoutFetchingWholeAlbums() async throws {
        let first = try decodeTrack(#"{"guid":"first","discNo":1,"trackNo":2,"album":{"guid":"one","name":"Same"},"artists":[{"guid":"chosen"}]}"#)
        let second = try decodeTrack(#"{"guid":"second","discNo":1,"trackNo":1,"album":{"guid":"one","name":"Same"}}"#)
        let third = try decodeTrack(#"{"guid":"third","discNo":1,"trackNo":1,"album":{"guid":"two","name":"Same"}}"#)
        let mock = ArtistBrowserMock(replies: [
            .tracks(1, .artist("chosen")): .tracks(Page(list: [first, third, second], total: 3)),
            .albums(1, "chosen"): .albums(Page(list: [
                Album(guid: "one", name: "Enriched", coverId: "cover", releaseDate: "1999-01-01"),
                Album(guid: "unrelated", name: "Must not create section")
            ], total: 2))
        ])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        model.selectArtist(Artist(guid: "chosen"))
        await model.loadDetail()
        XCTAssertEqual(model.sections.map(\.id), ["album:one", "album:two"])
        XCTAssertEqual(model.loadedTracks.map(\.guid), ["second", "first", "third"])
        XCTAssertEqual(model.sections.first?.title, "Enriched")
        XCTAssertEqual(model.sections.first?.coverId, "cover")
        XCTAssertTrue(model.sections.first?.subtitle.contains("1999") == true)
        let calls = await mock.recordedCalls()
        XCTAssertEqual(calls, [.tracks(1, .artist("chosen")), .albums(1, "chosen"), .artist("chosen")])
    }

    func testMissingAlbumStableNumberSortRawYearAndNoInventedGenre() async throws {
        let tracks = try [
            #"{"guid":"missing","year":2001,"coverId":"track-cover"}"#,
            #"{"guid":"tie1","discNo":1,"trackNo":2,"year":2001}"#,
            #"{"guid":"tie2","discNo":1,"trackNo":2,"year":2002}"#,
            #"{"guid":"no-track","discNo":1}"#,
            #"{"guid":"disc2","discNo":2,"trackNo":1}"#
        ].map(decodeTrack)
        let mock = ArtistBrowserMock(replies: [.tracks(1, .library): .tracks(Page(list: tracks, total: tracks.count))])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        await model.loadDetail()
        XCTAssertEqual(model.sections.count, 1)
        XCTAssertNil(model.sections.first?.album)
        XCTAssertEqual(model.sections.first?.title, "未归类")
        XCTAssertEqual(model.sections.first?.coverId, "track-cover")
        XCTAssertEqual(model.loadedTracks.map(\.guid), ["tie1", "tie2", "no-track", "disc2", "missing"])
        XCTAssertEqual(model.sections.first?.subtitle, "2001、2002 · 5 首歌曲")
        XCTAssertNotNil(model.warning)
    }

    func testSubtitleUsesOnlyRealGenreNamesAndTrackYearBeforeAlbumYear() throws {
        let track = try decodeTrack(#"{"guid":"g","year":1987,"genres":[{"name":"Jazz"},{"name":"Jazz"},{"guid":"unknown"}],"album":{"guid":"a","releaseDate":"2020-01-01"}}"#)
        let section = ArtistAlbumSection(id: "a", album: track.album, tracks: [track])
        XCTAssertEqual(section.subtitle, "Jazz · 1987 · 1 首歌曲")
    }

    func testMetadataAndArtistFailuresRemainWarningsNotTrackErrors() async throws {
        let track = try decodeTrack(#"{"guid":"t","album":{"guid":"a","name":"Embedded","coverId":"embedded-cover"}}"#)
        let mock = ArtistBrowserMock(replies: [
            .tracks(1, .artist("chosen")): .tracks(Page(list: [track], total: 1)),
            .albums(1, "chosen"): .failure,
            .artist("chosen"): .failure
        ])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        model.selectArtist(Artist(guid: "chosen", name: "Directory fallback"))
        await model.loadDetail()
        XCTAssertEqual(model.loadedTracks.map(\.guid), ["t"])
        XCTAssertEqual(model.detailArtist?.name, "Directory fallback")
        XCTAssertEqual(model.sections.first?.coverId, "embedded-cover")
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.warning)
        XCTAssertFalse(model.loading)
    }

    func testCollaborationUsesUniqueGUIDsAndUnmatchedPageCanContinue() async throws {
        let solo = try decodeTrack(#"{"guid":"solo","artists":[{"guid":"one","name":"A, B"}]}"#)
        let duplicate = try decodeTrack(#"{"guid":"duplicate","artists":[{"guid":"one"},{"guid":"one"}]}"#)
        let duet = try decodeTrack(#"{"guid":"duet","artists":[{"guid":"one","name":"Same"},{"guid":"two","name":"Same"}]}"#)
        let mock = ArtistBrowserMock(replies: [
            .tracks(1, .library): .tracks(Page(list: [solo, duplicate], total: 3)),
            .tracks(2, .library): .tracks(Page(list: [duet], total: 3))
        ])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        model.select(.collaborations)
        await model.loadDetail()
        XCTAssertTrue(model.isPartialCollaborationFilter)
        XCTAssertTrue(model.loadedTracks.isEmpty)
        XCTAssertEqual(model.scannedTracks, 2)
        XCTAssertTrue(model.hasMoreTracks)
        await model.loadMoreTracks()
        XCTAssertEqual(model.loadedTracks.map(\.guid), ["duet"])
        XCTAssertEqual(model.scannedTracks, 3)
        XCTAssertEqual(model.totalTracks, 3, "Candidate total is not the filtered duet count")
        XCTAssertFalse(model.hasMoreTracks)
    }

    func testTrackPaginationDeduplicatesAndRepeatedPageStopsWithoutEagerDrain() async throws {
        let track = try decodeTrack(#"{"guid":"t","album":{"guid":"a","name":"Album"}}"#)
        let mock = ArtistBrowserMock(replies: [
            .tracks(1, .library): .tracks(Page(list: [track, track], total: 100)),
            .tracks(2, .library): .tracks(Page(list: [track], total: 100)),
            .albums(1, nil): .albums(Page(list: [Album(guid: "a", name: "Album")], total: 80)),
            .albums(2, nil): .albums(Page(list: [Album(guid: "a", name: "Album")], total: 80))
        ])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        await model.loadDetail()
        XCTAssertEqual(model.loadedTracks.count, 1)
        var calls = await mock.recordedCalls()
        XCTAssertEqual(calls, [.tracks(1, .library), .albums(1, nil)])
        XCTAssertNotNil(model.warning, "Incomplete metadata must be disclosed")
        await model.loadMoreTracks()
        await model.loadMoreTracks()
        XCTAssertFalse(model.hasMoreTracks)
        XCTAssertEqual(model.scannedTracks, 1)
        calls = await mock.recordedCalls()
        XCTAssertEqual(calls.filter { $0.kind == "tracks" }.count, 2)
    }

    func testScopeChangeCancelsAndRejectsLateTracks() async throws {
        let oldTrack = try decodeTrack(#"{"guid":"old"}"#)
        let newTrack = try decodeTrack(#"{"guid":"new"}"#)
        let mock = ArtistBrowserMock(suspendedKinds: ["tracks"])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        model.selectArtist(Artist(guid: "old"))
        let old = Task { await model.loadDetail() }
        await mock.waitFor(.tracks(1, .artist("old")))
        model.select(.all)
        let new = Task { await model.loadDetail() }
        await mock.waitFor(.tracks(1, .library))
        await mock.resolve(.tracks(1, .library), with: .tracks(Page(list: [newTrack], total: 1)))
        await new.value
        await mock.resolve(.tracks(1, .artist("old")), with: .tracks(Page(list: [oldTrack], total: 1)))
        await old.value
        XCTAssertEqual(model.loadedTracks.map(\.guid), ["new"])
        XCTAssertNil(model.detailArtist)
        let cancelled = await mock.observedCancellation(.tracks(1, .artist("old")))
        XCTAssertTrue(cancelled)
        XCTAssertFalse(model.loading)
    }

    func testTaskCancellationWithoutExplicitInvalidateRejectsLateResult() async throws {
        let track = try decodeTrack(#"{"guid":"late"}"#)
        let mock = ArtistBrowserMock(suspendedKinds: ["tracks"])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        let request = Task { await model.loadDetail() }
        await mock.waitFor(.tracks(1, .library))
        request.cancel()
        await mock.resolve(.tracks(1, .library), with: .tracks(Page(list: [track], total: 1)))
        await request.value
        XCTAssertTrue(model.loadedTracks.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.loading)
        let cancelled = await mock.observedCancellation(.tracks(1, .library))
        XCTAssertTrue(cancelled)
    }

    func testSuccessfulTracksPublishBeforeMetadataAndLateMetadataCannotLeak() async throws {
        let track = try decodeTrack(#"{"guid":"t","album":{"guid":"a","name":"Embedded"}}"#)
        let mock = ArtistBrowserMock(replies: [
            .tracks(1, .library): .tracks(Page(list: [track], total: 1))
        ], suspendedKinds: ["albums"])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        let request = Task { await model.loadDetail() }
        await mock.waitFor(.albums(1, nil))
        XCTAssertEqual(model.loadedTracks.map(\.guid), ["t"])
        model.selectArtist(Artist(guid: "new"))
        await mock.resolve(.albums(1, nil), with: .albums(Page(list: [Album(guid: "a", name: "Stale")], total: 1)))
        await request.value
        XCTAssertTrue(model.sections.isEmpty)
        XCTAssertEqual(model.detailArtist?.guid, "new")
        XCTAssertNil(model.warning)
        XCTAssertFalse(model.loading)
    }

    func testInvalidateCancelsButtonPaginationAndDirectoryTogether() async throws {
        let track = try decodeTrack(#"{"guid":"late"}"#)
        let mock = ArtistBrowserMock(suspendedKinds: ["tracks", "directory"])
        let model = ArtistBrowserViewModel(music: mock, search: mock)
        let directory = Task { await model.reloadDirectory() }
        let detail = Task { await model.loadMoreTracks() }
        await mock.waitFor(.directory(1, "name,asc"))
        await mock.waitFor(.tracks(1, .library))
        model.invalidate()
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.directoryLoading)
        await mock.resolve(.directory(1, "name,asc"), with: .artists(Page(list: [Artist(guid: "late")], total: 1)))
        await mock.resolve(.tracks(1, .library), with: .tracks(Page(list: [track], total: 1)))
        await directory.value
        await detail.value
        XCTAssertTrue(model.artists.isEmpty)
        XCTAssertTrue(model.loadedTracks.isEmpty)
        XCTAssertEqual(model.selectedScope, .all)
    }
}
