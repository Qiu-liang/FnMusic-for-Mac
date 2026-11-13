import XCTest
@testable import FnMusic

/// No real server, credential or mutation is used by these transport fixtures.
private struct StubResponse: Sendable {
    var status = 200
    var mimeType = "application/json"
    var headers: [String: String] = [:]
    var body = Data()
    var failure: (any Error)?
    /// Deliver the body across several didLoad callbacks instead of one,
    /// simulating a chunked transfer. 0 or 1 means a single delivery.
    var fragmentCount = 0
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock(); value = true; lock.unlock()
    }
}

/// Free function so `@Sendable` stub closures can use it without captures.
private func envelopeJSON(_ json: String) -> StubResponse {
    StubResponse(body: Data(json.utf8))
}

/// Configurable URLProtocol fixture with request counting. Handlers run on
/// URLSession's internal threads, so all shared state is lock-protected.
private final class TransportStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> StubResponse)?
    nonisolated(unsafe) private static var count = 0

    static func configure(_ block: @escaping @Sendable (URLRequest) -> StubResponse) {
        lock.lock()
        handler = block
        count = 0
        lock.unlock()
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let block = Self.handler
        Self.lock.unlock()

        let stub = block?(request) ?? StubResponse(body: Data(#"{"code":0,"data":null}"#.utf8))
        if let failure = stub.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let fields = ["Content-Type": stub.mimeType].merging(stub.headers) { _, new in new }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: fields) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        } else {
            let stride = max(stub.body.count / max(stub.fragmentCount, 1), 1)
            var offset = 0
            while offset < stub.body.count {
                let end = min(offset + stride, stub.body.count)
                client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end))
                offset = end
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class APIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TransportStub.configure { _ in
            StubResponse(body: Data(#"{"code":0,"data":{"list":[],"total":0}}"#.utf8))
        }
    }

    private func makeClient(token: String? = "unit-test-only") throws -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TransportStub.self]
        return APIClient(origin: try APIClient.serverURL("https://example.invalid"), token: token, session: URLSession(configuration: config))
    }

    // MARK: - Pure validation helpers

    func testServerURLAcceptsValidOrigins() throws {
        XCTAssertEqual(try APIClient.serverURL("https://example.com"), URL(string: "https://example.com"))
        XCTAssertEqual(try APIClient.serverURL("http://192.168.1.5:5666"), URL(string: "http://192.168.1.5:5666"))
        XCTAssertEqual(try APIClient.serverURL("https://example.com/music"), URL(string: "https://example.com"))
        XCTAssertEqual(try APIClient.serverURL("https://example.com/music/"), URL(string: "https://example.com"))
        XCTAssertEqual(try APIClient.serverURL("  HTTPS://Example.COM  "), URL(string: "https://Example.COM"))
    }

    func testServerURLRejectsInvalidOrigins() {
        let invalid = [
            "", "example.com", "ftp://example.com", "https://user:pass@example.com",
            "https://example.com?query=1", "https://example.com#fragment",
            "https://example.com/other", "https:///path", "http://",
        ]
        for text in invalid {
            XCTAssertThrowsError(try APIClient.serverURL(text), "must reject: \(text)") { error in
                XCTAssertEqual(error as? APIError, .invalidServer, "wrong error for: \(text)")
            }
        }
    }

    func testParseContentRangeValidValues() {
        let parsed = APIClient.parseContentRange("bytes 0-1023/2048")
        XCTAssertEqual(parsed?.start, 0)
        XCTAssertEqual(parsed?.end, 1023)
        XCTAssertEqual(parsed?.total, 2048)

        let later = APIClient.parseContentRange("bytes 1048576-2097151/5242880")
        XCTAssertEqual(later?.start, 1_048_576)
        XCTAssertEqual(later?.end, 2_097_151)
        XCTAssertEqual(later?.total, 5_242_880)
    }

    func testParseContentRangeRejectsMalformedValues() {
        let malformed = [
            "", "bytes ", "0-1023/2048", "Bytes 0-1023/2048",
            "bytes 0-1023", "bytes 0-/2048", "bytes -1023/2048",
            "bytes 5-4/10", "bytes 0-10/10", "bytes 0-5/0", "bytes 0-5/-1",
            "bytes 0-5/10/20", "bytes a-b/10",
        ]
        for value in malformed {
            XCTAssertNil(APIClient.parseContentRange(value), "must reject: \(value)")
        }
    }

    func testEveryAPIErrorHasReadableDescription() {
        let errors: [APIError] = [
            .invalidServer, .network, .http(500), .business(100005), .decoding,
            .unexpectedContent, .sessionExpired, .invalidRange, .unsupportedAudio,
            .keychain(-25300), .unavailable("自定义说明"),
        ]
        for error in errors {
            let text = error.errorDescription
            XCTAssertNotNil(text, "missing description for \(error)")
            XCTAssertFalse(text?.isEmpty ?? true, "empty description for \(error)")
        }
    }

    // MARK: - Envelope validation

    func testBusinessFailureDespiteHTTP200() async throws {
        let client = try makeClient()
        TransportStub.configure { _ in envelopeJSON(#"{"code":100005,"data":null}"#) }
        do {
            let _: Page<Track> = try await client.value(APIRequest(path: "/business"))
            XCTFail("HTTP 200 must not bypass the business code")
        } catch { XCTAssertEqual(error as? APIError, .business(100005)) }
    }

    func testHTMLFallbackIsNotAPISuccess() async throws {
        let client = try makeClient()
        TransportStub.configure { _ in
            StubResponse(mimeType: "text/html", body: Data("<html>SPA fallback</html>".utf8))
        }
        do {
            let _: Page<Track> = try await client.value(APIRequest(path: "/html"))
            XCTFail("HTML must be rejected")
        } catch { XCTAssertEqual(error as? APIError, .unexpectedContent) }
    }

    func testMalformedSuccessPayloadFailsDecoding() async throws {
        let client = try makeClient()
        TransportStub.configure { _ in envelopeJSON(#"{"code":0,"data":{"wrong":true}}"#) }
        do {
            let _: Page<Track> = try await client.value(APIRequest(path: "/malformed"))
            XCTFail("invalid payload must fail")
        } catch { XCTAssertEqual(error as? APIError, .decoding) }
    }

    func testNullDataPayloadFailsDecodingForValueReads() async throws {
        let client = try makeClient()
        TransportStub.configure { _ in envelopeJSON(#"{"code":0,"data":null}"#) }
        do {
            let _: Page<Track> = try await client.value(APIRequest(path: "/null"))
            XCTFail("null data must not decode as a value")
        } catch { XCTAssertEqual(error as? APIError, .decoding) }
    }

    func testNullMutationSuccess() async throws {
        let client = try makeClient()
        TransportStub.configure { _ in envelopeJSON(#"{"code":0,"data":null}"#) }
        try await client.perform(.post("/null", body: EmptyBody()))
        XCTAssertEqual(TransportStub.requestCount, 1)
    }

    func testHTTP401InvalidatesSessionAndReportsExpiry() async throws {
        let client = try makeClient(token: "unit-test-token")
        let invalidated = Flag()
        await client.onSessionInvalidated { invalidated.set() }
        TransportStub.configure { _ in
            StubResponse(status: 401, mimeType: "text/html", body: Data("<html></html>".utf8))
        }
        do {
            let _: Page<Track> = try await client.value(APIRequest(path: "/list"))
            XCTFail("401 must fail")
        } catch { XCTAssertEqual(error as? APIError, .sessionExpired) }
        XCTAssertTrue(invalidated.isSet, "invalidation callback must fire")
        let hasSession = await client.hasSession()
        XCTAssertFalse(hasSession, "token must be cleared")
    }

    func testBusinessCode99999InvalidatesSession() async throws {
        let client = try makeClient(token: "unit-test-token")
        let invalidated = Flag()
        await client.onSessionInvalidated { invalidated.set() }
        TransportStub.configure { _ in envelopeJSON(#"{"code":99999,"data":null}"#) }
        do {
            let _: Page<Track> = try await client.value(APIRequest(path: "/expired"))
            XCTFail("business code 99999 must fail")
        } catch { XCTAssertEqual(error as? APIError, .sessionExpired) }
        XCTAssertTrue(invalidated.isSet)
    }

    // MARK: - Request construction

    func testURLForRequestSortsQueryAndKeepsCase() async throws {
        let client = try makeClient()
        let url = try await client.url(for: APIRequest(path: "/lyric/list", query: ["trackGUID": "a b", "aKey": "1"]))
        XCTAssertEqual(url.path, "/music/api/v1/lyric/list")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.map(\.name), ["aKey", "trackGUID"])
        XCTAssertEqual(items?.first?.value, "1")
        XCTAssertEqual(items?.last?.value, "a b")
    }

    func testMalformedTokenIsRejectedBeforeTransport() async throws {
        let client = try makeClient(token: "bad\ntoken")
        do {
            let _: Page<Track> = try await client.value(APIRequest(path: "/list"))
            XCTFail("malformed token must be rejected")
        } catch { XCTAssertEqual(error as? APIError, .sessionExpired) }
        XCTAssertEqual(TransportStub.requestCount, 0, "no request may leave the client")
    }

    // MARK: - Memory cache

    func testMemoryCacheHitAvoidsSecondRequest() async throws {
        let client = try makeClient()
        let spec = APIRequest(path: "/cached", cachePolicy: .memory(maxAge: 60))
        let first: Page<Track> = try await client.value(spec)
        XCTAssertEqual(first.total, 0)
        let second: Page<Track> = try await client.value(spec)
        XCTAssertEqual(second.total, 0)
        XCTAssertEqual(TransportStub.requestCount, 1)
    }

    func testPostFlushesMemoryCache() async throws {
        let client = try makeClient()
        TransportStub.configure { request in
            request.httpMethod == "POST"
                ? envelopeJSON(#"{"code":0,"data":null}"#)
                : envelopeJSON(#"{"code":0,"data":{"list":[],"total":0}}"#)
        }
        let spec = APIRequest(path: "/cached", cachePolicy: .memory(maxAge: 60))
        let _: Page<Track> = try await client.value(spec)
        try await client.perform(.post("/mutation", body: EmptyBody()))
        let _: Page<Track> = try await client.value(spec)
        XCTAssertEqual(TransportStub.requestCount, 3, "GET, POST, then GET must all hit the transport")
    }

    func testMemoryCacheExpiresAfterMaxAge() async throws {
        let client = try makeClient()
        let spec = APIRequest(path: "/cached", cachePolicy: .memory(maxAge: 0.05))
        let _: Page<Track> = try await client.value(spec)
        try await Task.sleep(for: .milliseconds(120))
        let _: Page<Track> = try await client.value(spec)
        XCTAssertEqual(TransportStub.requestCount, 2)
    }

    // MARK: - Cancellation and retry

    func testURLErrorCancelledSurfacesAsCancellationError() async throws {
        let client = try makeClient()
        TransportStub.configure { _ in StubResponse(failure: URLError(.cancelled)) }
        do {
            let _: Page<Track> = try await client.value(APIRequest(path: "/cancel"))
            XCTFail("cancelled transport must not succeed")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }

    func testClosedClientThrowsCancellationError() async throws {
        let client = try makeClient()
        await client.close()
        do {
            let _: Page<Track> = try await client.value(APIRequest(path: "/list"))
            XCTFail("closed client must not serve requests")
        } catch {
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
        XCTAssertEqual(TransportStub.requestCount, 0)
    }

    func testGETRetriesOnceOnTransientURLError() async throws {
        let client = try makeClient()
        TransportStub.configure { _ in
            TransportStub.requestCount == 1
                ? StubResponse(failure: URLError(.timedOut))
                : envelopeJSON(#"{"code":0,"data":{"list":[],"total":0}}"#)
        }
        let page: Page<Track> = try await client.value(APIRequest(path: "/flaky"))
        XCTAssertEqual(page.total, 0)
        XCTAssertEqual(TransportStub.requestCount, 2)
    }

    func testPOSTDoesNotRetryTransientURLError() async throws {
        let client = try makeClient()
        TransportStub.configure { _ in StubResponse(failure: URLError(.timedOut)) }
        do {
            try await client.perform(.post("/mutation", body: EmptyBody()))
            XCTFail("POST transport failure must surface")
        } catch {
            XCTAssertEqual(error as? APIError, .network, "got \(error)")
        }
        XCTAssertEqual(TransportStub.requestCount, 1)
    }

    // MARK: - Media helpers

    func testCoverReturnsImageData() async throws {
        let client = try makeClient()
        let payload = Data([0x89, 0x50, 0x4E, 0x47])
        TransportStub.configure { _ in StubResponse(mimeType: "image/png", body: payload) }
        let data = try await client.cover(id: "c", size: 300)
        XCTAssertEqual(data, payload)
    }

    func testCoverRejectsNonImageContent() async throws {
        let client = try makeClient()
        TransportStub.configure { _ in
            StubResponse(mimeType: "text/html", body: Data("<html/>".utf8))
        }
        do {
            _ = try await client.cover(id: "c", size: 300)
            XCTFail("non-image cover must fail")
        } catch { XCTAssertEqual(error as? APIError, .unexpectedContent) }
    }

    func testStreamValidatesRangeContract() async throws {
        let client = try makeClient()

        // A plain 200 answer must not satisfy a range request.
        TransportStub.configure { _ in
            StubResponse(mimeType: "audio/flac", body: Data([0, 1, 2, 3]))
        }
        do {
            _ = try await client.stream(guid: "g", offset: 0, length: 4)
            XCTFail("200 must not satisfy a range request")
        } catch { XCTAssertEqual(error as? APIError, .invalidRange) }

        // 206 with a mismatched Content-Range must fail.
        TransportStub.configure { _ in
            StubResponse(status: 206, mimeType: "audio/flac",
                         headers: ["Content-Range": "bytes 100-103/1000"],
                         body: Data([0, 1, 2, 3]))
        }
        do {
            _ = try await client.stream(guid: "g", offset: 0, length: 4)
            XCTFail("mismatched Content-Range must fail")
        } catch { XCTAssertEqual(error as? APIError, .invalidRange) }

        // A precise 206 answer produces a well-formed chunk.
        TransportStub.configure { _ in
            StubResponse(status: 206, mimeType: "audio/flac",
                         headers: ["Content-Range": "bytes 0-3/1000"],
                         body: Data([0, 1, 2, 3]))
        }
        let chunk = try await client.stream(guid: "g", offset: 0, length: 4)
        XCTAssertEqual(chunk.rangeStart, 0)
        XCTAssertEqual(chunk.totalLength, 1000)
        XCTAssertEqual(chunk.data, Data([0, 1, 2, 3]))
        XCTAssertTrue(chunk.supportsRanges)

        // Out-of-contract arguments are rejected before the transport.
        do {
            _ = try await client.stream(guid: "g", offset: -1, length: 4)
            XCTFail("negative offset must fail")
        } catch { XCTAssertEqual(error as? APIError, .invalidRange) }
        do {
            _ = try await client.stream(guid: "g", offset: 0, length: 0)
            XCTFail("zero length must fail")
        } catch { XCTAssertEqual(error as? APIError, .invalidRange) }
    }

    // MARK: - Chunked transport

    func testChunkedTransportReassemblesFragmentedJSON() async throws {
        let client = try makeClient()
        TransportStub.configure { _ in
            StubResponse(body: Data(#"{"code":0,"data":{"list":[],"total":0}}"#.utf8), fragmentCount: 3)
        }
        let page: Page<Track> = try await client.value(APIRequest(path: "/chunked"))
        XCTAssertEqual(page.list, [])
        XCTAssertEqual(page.total, 0, "fragmented didLoad callbacks must reassemble into one body")
    }

    func testChunkedTransportRejectsOverflowAcrossDataCallbacks() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        TransportStub.configure { _ in
            StubResponse(body: Data(#"{"code":0,"data":{"list":[],"total":0}}"#.utf8), fragmentCount: 3)
        }
        let request = URLRequest(url: URL(string: "https://example.invalid/music/api/v1/chunked")!)

        do {
            _ = try await ChunkedDataTask.data(
                for: request,
                session: session,
                responsePolicy: { _ in 4 },
                overflowError: { APIError.invalidRange }
            )
            XCTFail("A cap must apply to the accumulated body, not each Data callback")
        } catch {
            XCTAssertEqual(error as? APIError, .invalidRange, "got \(error)")
        }
    }
}
