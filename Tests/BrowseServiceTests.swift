import XCTest
@testable import FnMusic

/// Synthetic transport fixtures, NOT verification of a real nonempty genre API.
/// No mutable global handler: each test chooses a fixture through its mock origin.
private final class BrowseFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "music-token=browse-fixture-only")
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(queryItems.count, query.count, "No duplicate query keys")
        let body: String
        switch url.host {
        case "genre-empty.invalid":
            XCTAssertEqual(url.path, "/music/api/v1/genre/list")
            XCTAssertEqual(query, ["page": "1", "size": String(MusicService.pageSize), "sort": "name,asc"])
            body = #"{"code":0,"data":{"list":[],"total":0,"sort":"name,asc"}}"#
        case "genre-unknown.invalid":
            XCTAssertEqual(url.path, "/music/api/v1/genre/list")
            XCTAssertEqual(query, ["page": "2", "size": String(MusicService.pageSize), "sort": "trackCount,desc"])
            body = #"{"code":0,"data":{"list":[{"guid":"fixture-genre","name":"Fixture only","future":{"values":[true,null,9007199254740993]}},{"name":"No guid","unknown":42},{"guid":123,"name":false}],"total":63,"sort":"trackCount,desc"}}"#
        case "libraries.invalid":
            XCTAssertEqual(url.path, "/music/api/v1/shared-library/list")
            XCTAssertEqual(query, [:])
            body = #"{"code":0,"data":{"list":[{"guid":"library-1","name":null,"path":"/server/music","autoDownloadLyric":false,"metadataPreference":"local_only","contentLastChangedAt":1700000000000,"accessStatus":98765}]}}"#
        case "libraries-empty.invalid":
            XCTAssertEqual(url.path, "/music/api/v1/shared-library/list")
            XCTAssertEqual(query, [:])
            body = #"{"code":0,"data":{"list":[]}}"#
        case "library-detail.invalid":
            XCTAssertEqual(url.path, "/music/api/v1/shared-library/detail")
            XCTAssertEqual(query, ["guid": "library /+?中文"])
            body = #"{"code":0,"data":{"guid":"library /+?中文","name":"Fixture library","path":"https://not-a-link.invalid/music","autoDownloadLyric":true,"metadataPreference":"future_preference","contentLastChangedAt":null,"accessStatus":"future_status"}}"#
        case "libraries-error.invalid":
            XCTAssertEqual(url.path, "/music/api/v1/shared-library/list")
            XCTAssertEqual(query, [:])
            body = #"{"code":100005,"data":null}"#
        case "libraries-unwrapped.invalid":
            XCTAssertEqual(url.path, "/music/api/v1/shared-library/list")
            XCTAssertEqual(query, [:])
            body = #"{"code":0,"data":[]}"#
        default:
            XCTFail("Unexpected network request: \(url)")
            body = #"{"code":100005,"data":null}"#
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Deliberately ignores cancellation so generation guards can be exercised.
private actor SuspendedBrowseService: BrowseServiceProtocol {
    private var continuations: [Int: CheckedContinuation<[SharedLibrary], any Error>] = [:]
    private var requestCount = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func genres(page: Int, sort: String) async throws -> Page<GenreRecord> {
        Page(list: [], total: 0, sort: sort)
    }

    func libraries() async throws -> [SharedLibrary] {
        try await withCheckedThrowingContinuation { continuation in
            requestCount += 1
            continuations[requestCount] = continuation
            let ready = waiters.filter { $0.0 <= requestCount }
            waiters.removeAll { $0.0 <= requestCount }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func library(guid: String) async throws -> SharedLibrary {
        let result = try await libraries()
        guard let first = result.first else { throw APIError.decoding }
        return first
    }

    func waitForRequests(_ count: Int) async {
        if requestCount >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func resolve(_ request: Int, with libraries: [SharedLibrary]) {
        continuations.removeValue(forKey: request)?.resume(returning: libraries)
    }
}

@MainActor
final class BrowseServiceTests: XCTestCase {
    private func withService<T>(_ host: String, operation: (BrowseService) async throws -> T) async throws -> T {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrowseFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = APIClient(origin: try APIClient.serverURL("https://\(host)"),
                               token: "browse-fixture-only", session: session)
        return try await operation(BrowseService(client: client))
    }

    private func decodeGenre(_ json: String) throws -> GenreRecord {
        try JSONDecoder().decode(GenreRecord.self, from: Data(json.utf8))
    }

    func testGenresEmptyPageUsesDocumentedGETQuery() async throws {
        try await withService("genre-empty.invalid") { service in
            let page = try await service.genres(page: 1, sort: "name,asc")
            XCTAssertTrue(page.list.isEmpty)
            XCTAssertEqual(page.total, 0)
            XCTAssertEqual(page.sort, "name,asc")
        }
    }

    func testGenresSyntheticNonemptyPagePreservesUnknownFieldsAndMissingGUID() async throws {
        try await withService("genre-unknown.invalid") { service in
            let page = try await service.genres(page: 2, sort: "trackCount,desc")
            XCTAssertEqual(page.total, 63)
            XCTAssertEqual(page.sort, "trackCount,desc")
            XCTAssertEqual(page.list.count, 3)
            let first = try XCTUnwrap(page.list.first)
            XCTAssertEqual(first.guid, "fixture-genre")
            let exactInteger = try XCTUnwrap(Decimal(string: "9007199254740993"))
            XCTAssertEqual(first.fields?["future"], .object([
                "values": .array([.boolean(true), .null, .number(exactInteger)])
            ]))
            XCTAssertNil(page.list[1].guid)
            XCTAssertEqual(page.list[1].displayName, "No guid")
            XCTAssertNil(page.list[2].guid)
            XCTAssertEqual(page.list[2].displayName, "未命名风格")
        }
    }

    func testGenreRoundTripRetainsUnknownNestedJSON() throws {
        let original = try decodeGenre(#"{"guid":"g","future":{"null":null,"array":[1,2.5,true,"text",{"nested":[]}],"object":{}},"unrecognized":"kept"}"#)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GenreRecord.self, from: data)
        XCTAssertEqual(original.rawValue, decoded.rawValue)
        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(decoded.fields?["unrecognized"], .string("kept"))
    }

    func testGenreIdentityIsStableAcrossObjectKeyOrder() throws {
        let first = try decodeGenre(#"{"name":"Same","nested":{"b":2,"a":1}}"#)
        let reordered = try decodeGenre(#"{"nested":{"a":1,"b":2},"name":"Same"}"#)
        let different = try decodeGenre(#"{"name":"Different","nested":{"b":2,"a":1}}"#)
        XCTAssertEqual(first.id, reordered.id)
        XCTAssertNotEqual(first.id, different.id)
        XCTAssertNil(first.guid, "UI fingerprint must never become an API guid")
    }

    func testGenreOnlyNonemptyStringGUIDNavigates() throws {
        for json in [#"{}"#, #"{"guid":null}"#, #"{"guid":false}"#, #"{"guid":23}"#,
                     #"{"guid":{}}"#, #"{"guid":""}"#, #"{"guid":"  "}"#] {
            XCTAssertNil(try decodeGenre(json).guid)
        }
        XCTAssertEqual(try decodeGenre(#"{"guid":"server-returned"}"#).guid, "server-returned")
    }

    func testGenreUnknownRootValuesRemainVisibleWithoutInventedNameOrGUID() throws {
        for json in ["null", "42", "true", #""opaque""#, "[]", #"{"name":17}"#] {
            let record = try decodeGenre(json)
            XCTAssertNil(record.guid)
            XCTAssertEqual(record.displayName, "未命名风格")
            let roundTrip = try JSONDecoder().decode(GenreRecord.self, from: JSONEncoder().encode(record))
            XCTAssertEqual(roundTrip.rawValue, record.rawValue)
        }
    }

    func testSharedLibrariesDecodeListWrapperNullableNameAndUnknownNumericStatus() async throws {
        try await withService("libraries.invalid") { service in
            let libraries = try await service.libraries()
            XCTAssertEqual(libraries.count, 1)
            let library = try XCTUnwrap(libraries.first)
            XCTAssertEqual(library.guid, "library-1")
            XCTAssertNil(library.name)
            XCTAssertEqual(library.displayName, "未命名共享音乐库")
            XCTAssertEqual(library.path, "/server/music")
            XCTAssertEqual(library.autoDownloadLyric, false)
            XCTAssertEqual(library.metadataPreference, "local_only")
            guard case .number(let status) = library.accessStatus else { return XCTFail("Keep raw status") }
            XCTAssertEqual(status, 98765)
        }
    }

    func testSharedLibrariesEmptyWrapper() async throws {
        try await withService("libraries-empty.invalid") { service in
            let libraries = try await service.libraries()
            XCTAssertTrue(libraries.isEmpty)
        }
    }

    func testSharedLibraryDetailUsesGUIDAndPreservesUnknownStringStatus() async throws {
        try await withService("library-detail.invalid") { service in
            let library = try await service.library(guid: "library /+?中文")
            XCTAssertEqual(library.guid, "library /+?中文")
            XCTAssertEqual(library.path, "https://not-a-link.invalid/music")
            XCTAssertEqual(library.accessStatus?.display, "future_status")
            XCTAssertEqual(library.metadataPreference, "future_preference")
            XCTAssertNil(library.contentLastChangedAt)
        }
    }

    func testSharedLibraryMissingOptionalFieldsAndNullStatus() throws {
        let library = try JSONDecoder().decode(SharedLibrary.self, from: Data(#"{"guid":"g","accessStatus":null}"#.utf8))
        XCTAssertNil(library.name)
        XCTAssertNil(library.path)
        XCTAssertNil(library.accessStatus)
        XCTAssertEqual(library.displayName, "未命名共享音乐库")
    }

    func testSharedLibrariesBusinessFailurePropagates() async throws {
        try await withService("libraries-error.invalid") { service in
            do {
                _ = try await service.libraries()
                XCTFail("Business failure must not become an empty list")
            } catch { XCTAssertEqual(error as? APIError, .business(100005)) }
        }
    }

    func testSharedLibrariesGenerationDiscardsOlderResponse() async throws {
        let service = SuspendedBrowseService()
        let model = SharedLibrariesViewModel(service: service)
        let older = Task { await model.refresh() }
        await service.waitForRequests(1)
        let newer = Task { await model.refresh() }
        await service.waitForRequests(2)
        let oldLibrary = try JSONDecoder().decode(SharedLibrary.self, from: Data(#"{"guid":"old"}"#.utf8))
        let newLibrary = try JSONDecoder().decode(SharedLibrary.self, from: Data(#"{"guid":"new"}"#.utf8))
        await service.resolve(2, with: [newLibrary])
        await newer.value
        await service.resolve(1, with: [oldLibrary])
        await older.value
        XCTAssertEqual(model.items.map(\.guid), ["new"])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
    }

    func testSharedLibraryDetailGenerationDiscardsOlderResponse() async throws {
        let service = SuspendedBrowseService()
        let model = SharedLibraryDetailViewModel(guid: "g", service: service)
        let older = Task { await model.refresh() }
        await service.waitForRequests(1)
        let newer = Task { await model.refresh() }
        await service.waitForRequests(2)
        let oldLibrary = try JSONDecoder().decode(SharedLibrary.self, from: Data(#"{"guid":"g","name":"old"}"#.utf8))
        let newLibrary = try JSONDecoder().decode(SharedLibrary.self, from: Data(#"{"guid":"g","name":"new"}"#.utf8))
        await service.resolve(2, with: [newLibrary])
        await newer.value
        await service.resolve(1, with: [oldLibrary])
        await older.value
        XCTAssertEqual(model.library?.name, "new")
        XCTAssertFalse(model.isLoading)
    }

    func testCancelledSharedLibrariesRequestDoesNotPublishLateResult() async throws {
        let service = SuspendedBrowseService()
        let model = SharedLibrariesViewModel(service: service)
        let request = Task { await model.refresh() }
        await service.waitForRequests(1)
        request.cancel()
        model.invalidate()
        let library = try JSONDecoder().decode(SharedLibrary.self, from: Data(#"{"guid":"late"}"#.utf8))
        await service.resolve(1, with: [library])
        await request.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
    }

    func testSharedLibrariesRequiresDocumentedListWrapper() async throws {
        try await withService("libraries-unwrapped.invalid") { service in
            do {
                _ = try await service.libraries()
                XCTFail("Do not silently accept an undocumented array payload")
            } catch { XCTAssertEqual(error as? APIError, .decoding) }
        }
    }
}
