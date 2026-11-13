import XCTest
@testable import FnMusic

/// The only URLSession in this feature is this test-only injected APIClient session.
/// All responses are local URLProtocol fixtures; no real host/files/credentials are used.
private final class DownloadURLProtocol: URLProtocol, @unchecked Sendable {
    static let payload = Data((0..<(512 * 1024 + 257)).map { UInt8($0 % 251) })
    static let requests = RequestLog()
    static let serverPath = "/server/private/DO_NOT_USE_SECRET.wav"

    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: [URLRequest]] = [:]
        func record(_ request: URLRequest, guid: String) {
            lock.lock(); defer { lock.unlock() }
            values[guid, default: []].append(request)
        }
        func entries(_ guid: String) -> [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return values[guid] ?? []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url,
              let guid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "guid" })?.value else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        Self.requests.record(request, guid: guid)
        guard request.httpMethod == "GET", request.value(forHTTPHeaderField: "Cookie") == "music-token=download-test",
              !url.absoluteString.contains("DO_NOT_USE_SECRET") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        if url.path == "/music/api/v1/track/metadata" {
            var spec: [String: Any] = ["path": Self.serverPath]
            if !guid.hasPrefix("noformat") { spec["format"] = "flac" }
            let object: [String: Any] = ["code": 0, "data": [
                "track": ["guid": guid, "title": "Metadata title", "isCue": guid.hasPrefix("cue")],
                "audioSpec": spec
            ]]
            do {
                send(url, status: 200, headers: ["Content-Type": "application/json"],
                     data: try JSONSerialization.data(withJSONObject: object))
            } catch { client?.urlProtocol(self, didFailWithError: error) }
            return
        }
        guard url.path == "/music/api/v1/track/stream",
              let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes=") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
        guard bounds.count == 2, bounds[0] >= 0, bounds[1] >= bounds[0],
              bounds[1] - bounds[0] + 1 <= 512 * 1024, bounds[0] < Self.payload.count else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let start = bounds[0]
        let end = min(bounds[1], Self.payload.count - 1)
        var data = Self.payload.subdata(in: start..<(end + 1))
        let total = Self.payload.count + (guid.hasPrefix("totalchange") && start > 0 ? 1 : 0)
        let headerStart = guid.hasPrefix("badstart") ? start + 1 : start
        if guid.hasPrefix("short") { data = Data(data.dropLast()) }
        if guid.hasPrefix("empty") { data = Data() }
        send(url, status: guid.hasPrefix("ignored") ? 200 : 206,
             headers: ["Content-Type": "audio/flac", "Content-Range": "bytes \(headerStart)-\(end)/\(total)"], data: data)
    }

    private func send(_ url: URL, status: Int, headers: [String: String], data: Data) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor DownloadProgressLog {
    var values: [Double] = []
    func append(_ value: Double) { values.append(value) }
}

@MainActor
final class TrackDownloadTests: XCTestCase {
    /// Own only this freshly created, unique directory. Never operate on user files.
    private struct TestDirectory {
        let url: URL
        let parent: URL
        let name: String
        init() throws {
            parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
            name = "FnMusic-TrackDownloadTests-" + UUID().uuidString
            url = parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        func file(_ name: String = "saved.flac") -> URL { url.appendingPathComponent(name) }
        func entries() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        }
        func cleanup() throws {
            // Resolve/check every deletion target BEFORE removeItem. Flat fixture files only;
            // refuse symlinks, directories, unexpected parents and any escape from our UUID root.
            guard url.standardizedFileURL.path == parent.appendingPathComponent(name).path,
                  url.resolvingSymlinksInPath().path == url.path,
                  url.deletingLastPathComponent().path == parent.path,
                  name.hasPrefix("FnMusic-TrackDownloadTests-"),
                  UUID(uuidString: String(name.dropFirst("FnMusic-TrackDownloadTests-".count))) != nil,
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw TrackDownloadError.unsafeDestination
            }
            for child in try entries() {
                let flags = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard child.standardizedFileURL.deletingLastPathComponent().path == url.path,
                      child.resolvingSymlinksInPath().path == child.standardizedFileURL.path,
                      flags.isSymbolicLink != true, flags.isRegularFile == true else {
                    throw TrackDownloadError.unsafeDestination
                }
                try FileManager.default.removeItem(at: child)
            }
            guard try entries().isEmpty,
                  url.resolvingSymlinksInPath().path == parent.appendingPathComponent(name).path else {
                throw TrackDownloadError.unsafeDestination
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func client() throws -> (APIClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (APIClient(origin: try APIClient.serverURL("https://download.invalid"), token: "download-test", session: session), session)
    }

    private func track(_ scenario: String = "valid", title: String = "A title") -> Track {
        Track(guid: scenario + "-" + UUID().uuidString, title: title)
    }

    func testCompleteBytesThroughAPIClientAndNoServerPathLeak() async throws {
        let directory = try TestDirectory()
        defer { do { try directory.cleanup() } catch { XCTFail("Unsafe fixture cleanup: \(error)") } }
        let (client, session) = try client()
        defer { session.invalidateAndCancel() }
        let service = TrackDownloadService(client: client)
        let track = track()
        let filename = try await service.suggestedFilename(for: track)
        XCTAssertEqual(filename, "A title.flac")
        let authorization = try await DownloadSaveAuthorization.recordPanelSelection(directory.file())
        let progress = DownloadProgressLog()
        try await service.download(track, to: directory.file()) { await progress.append($0) }
        await DownloadSaveAuthorization.revoke(authorization)
        XCTAssertEqual(try Data(contentsOf: directory.file()), DownloadURLProtocol.payload)
        XCTAssertEqual(try directory.entries().count, 1)
        let values = await progress.values
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted())
        let requests = DownloadURLProtocol.requests.entries(track.guid)
        XCTAssertTrue(requests.allSatisfy {
            $0.url?.host == "download.invalid" && $0.httpMethod == "GET"
                && $0.value(forHTTPHeaderField: "Cookie") == "music-token=download-test"
                && $0.url?.absoluteString.contains("DO_NOT_USE_SECRET") == false
        })
        XCTAssertEqual(requests.compactMap { $0.value(forHTTPHeaderField: "Range") },
                       ["bytes=0-524287", "bytes=524288-524544"])
        XCTAssertTrue(requests.allSatisfy {
            ["/music/api/v1/track/metadata", "/music/api/v1/track/stream"].contains($0.url?.path ?? "")
        })
    }

    func testCancellationRemovesOnlyTemporaryAndPreservesOriginal() async throws {
        for hasOriginal in [false, true] {
            let directory = try TestDirectory()
            defer { do { try directory.cleanup() } catch { XCTFail("Unsafe fixture cleanup: \(error)") } }
            let (client, session) = try client()
            defer { session.invalidateAndCancel() }
            let original = Data("original user bytes in test fixture".utf8)
            if hasOriginal { try original.write(to: directory.file()) }
            let authorization = try await DownloadSaveAuthorization.recordPanelSelection(directory.file())
            let service = TrackDownloadService(client: client)
            let track = track()
            let task = Task {
                try await service.download(track, to: directory.file()) { progress in
                    if progress > 0 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            do { try await task.value; XCTFail("Cancellation must not commit") }
            catch is CancellationError {} catch { XCTFail("Wrong cancellation: \(error)") }
            await DownloadSaveAuthorization.revoke(authorization)
            if hasOriginal { XCTAssertEqual(try Data(contentsOf: directory.file()), original) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.file().path)) }
            XCTAssertEqual(try directory.entries().count, hasOriginal ? 1 : 0)
            XCTAssertEqual(DownloadURLProtocol.requests.entries(track.guid).filter {
                $0.value(forHTTPHeaderField: "Range") != nil
            }.count, 1)
        }
    }

    func testRangeFailuresStopAndKeepOriginal() async throws {
        for scenario in ["badstart", "short", "empty", "ignored", "totalchange"] {
            let directory = try TestDirectory()
            defer { do { try directory.cleanup() } catch { XCTFail("Unsafe fixture cleanup: \(error)") } }
            let (client, session) = try client()
            defer { session.invalidateAndCancel() }
            let original = Data("do not replace".utf8)
            try original.write(to: directory.file())
            let authorization = try await DownloadSaveAuthorization.recordPanelSelection(directory.file())
            let track = track(scenario)
            do {
                try await TrackDownloadService(client: client).download(track, to: directory.file()) { _ in }
                XCTFail("Invalid Range must fail: \(scenario)")
            } catch { XCTAssertEqual(error as? APIError, .invalidRange) }
            await DownloadSaveAuthorization.revoke(authorization)
            XCTAssertEqual(try Data(contentsOf: directory.file()), original)
            XCTAssertEqual(try directory.entries().count, 1)
            XCTAssertEqual(DownloadURLProtocol.requests.entries(track.guid).filter {
                $0.value(forHTTPHeaderField: "Range") != nil
            }.count, scenario == "totalchange" ? 2 : 1)
        }
    }

    func testFilenameSanitizationAndMissingFormat() async throws {
        let (client, session) = try client()
        defer { session.invalidateAndCancel() }
        let service = TrackDownloadService(client: client)
        let unsafe = "../\\:\u{0000}\n" + String(repeating: "曲", count: 200)
        let filename = try await service.suggestedFilename(for: track(title: unsafe))
        XCTAssertTrue(filename.hasSuffix(".flac"))
        XCTAssertLessThanOrEqual(filename.utf8.count, 185)
        XCTAssertFalse(filename.hasPrefix("."))
        XCTAssertFalse(filename.contains("/")); XCTAssertFalse(filename.contains("\\")); XCTAssertFalse(filename.contains(":"))
        XCTAssertFalse(filename.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        let unknown = try await service.suggestedFilename(for: track("noformat", title: ".."))
        XCTAssertEqual(unknown, "未知歌曲.audio")
        XCTAssertFalse(unknown.contains("DO_NOT_USE_SECRET"))
    }

    func testCueIsRejectedBeforeStreamIncludingMetadataCue() async throws {
        let (client, session) = try client()
        defer { session.invalidateAndCancel() }
        let service = TrackDownloadService(client: client)
        var known = track()
        known.isCue = true
        do { _ = try await service.suggestedFilename(for: known); XCTFail("CUE must be rejected") }
        catch { XCTAssertEqual(error as? TrackDownloadError, .cueTrack) }
        XCTAssertTrue(DownloadURLProtocol.requests.entries(known.guid).isEmpty)
        let hidden = track("cue")
        do { _ = try await service.suggestedFilename(for: hidden); XCTFail("Metadata CUE must be rejected") }
        catch { XCTAssertEqual(error as? TrackDownloadError, .cueTrack) }
        XCTAssertTrue(DownloadURLProtocol.requests.entries(hidden.guid).allSatisfy {
            $0.value(forHTTPHeaderField: "Range") == nil
        })
    }

    func testExplicitOverwriteAuthorizationAndAtomicReplacement() async throws {
        let directory = try TestDirectory()
        defer { do { try directory.cleanup() } catch { XCTFail("Unsafe fixture cleanup: \(error)") } }
        let (client, session) = try client()
        defer { session.invalidateAndCancel() }
        let original = Data("original".utf8)
        try original.write(to: directory.file())
        let service = TrackDownloadService(client: client)
        do {
            try await service.download(track(), to: directory.file()) { _ in }
            XCTFail("Existing file is not implicit overwrite consent")
        } catch { XCTAssertEqual(error as? TrackDownloadError, .authorizationRequired) }
        XCTAssertEqual(try Data(contentsOf: directory.file()), original)
        let authorization = try await DownloadSaveAuthorization.recordPanelSelection(directory.file())
        try await service.download(track(), to: directory.file()) { _ in }
        await DownloadSaveAuthorization.revoke(authorization)
        XCTAssertEqual(try Data(contentsOf: directory.file()), DownloadURLProtocol.payload)
        XCTAssertEqual(try directory.entries().count, 1)
    }

    func testSameDestinationLeaseRejectsConcurrentDownload() async throws {
        let directory = try TestDirectory()
        defer { do { try directory.cleanup() } catch { XCTFail("Unsafe fixture cleanup: \(error)") } }
        let (client, session) = try client()
        defer { session.invalidateAndCancel() }
        let service = TrackDownloadService(client: client)
        let authorization = try await DownloadSaveAuthorization.recordPanelSelection(directory.file())
        let second = track()
        let destination = directory.file()
        let outcomes = DownloadProgressLog()
        try await service.download(track(), to: destination) { value in
            guard value == 0 else { return }
            do {
                try await service.download(second, to: destination) { _ in }
                await outcomes.append(-1)
            } catch TrackDownloadError.busy { await outcomes.append(1) }
            catch { await outcomes.append(-2) }
        }
        await DownloadSaveAuthorization.revoke(authorization)
        let result = await outcomes.values
        XCTAssertEqual(result, [1])
        XCTAssertEqual(try Data(contentsOf: directory.file()), DownloadURLProtocol.payload)
    }

    func testChangedOrNewlyAppearedDestinationIsNeverOverwritten() async throws {
        for hadOriginal in [false, true] {
            let directory = try TestDirectory()
            defer { do { try directory.cleanup() } catch { XCTFail("Unsafe fixture cleanup: \(error)") } }
            let (client, session) = try client()
            defer { session.invalidateAndCancel() }
            let destination = directory.file()
            if hadOriginal { try Data("old".utf8).write(to: destination) }
            let authorization = try await DownloadSaveAuthorization.recordPanelSelection(destination)
            let newBytes = Data("newly created or edited by another writer".utf8)
            let changes = DownloadProgressLog()
            do {
                try await TrackDownloadService(client: client).download(track(), to: destination) { value in
                    if value == 0 {
                        do { try newBytes.write(to: destination); await changes.append(1) }
                        catch { await changes.append(-1) }
                    }
                }
                XCTFail("Must not overwrite a target changed since authorization")
            } catch { XCTAssertEqual(error as? TrackDownloadError, .destinationChanged) }
            await DownloadSaveAuthorization.revoke(authorization)
            let result = await changes.values
            XCTAssertEqual(result, [1])
            XCTAssertEqual(try Data(contentsOf: destination), newBytes)
            XCTAssertEqual(try directory.entries().count, 1)
        }
    }

    func testRejectsNonFileDirectoryAndTraversalDestinations() async throws {
        let directory = try TestDirectory()
        defer { do { try directory.cleanup() } catch { XCTFail("Unsafe fixture cleanup: \(error)") } }
        let destinations = [URL(string: "https://download.invalid/save")!, directory.url,
                            directory.url.appendingPathComponent("../escape.flac")]
        for destination in destinations {
            do {
                let authorization = try await DownloadSaveAuthorization.recordPanelSelection(destination)
                await DownloadSaveAuthorization.revoke(authorization)
                XCTFail("Unsafe destination must not acquire authorization")
            } catch { XCTAssertEqual(error as? TrackDownloadError, .unsafeDestination) }
        }
        XCTAssertTrue(try directory.entries().isEmpty)
    }

    func testMalformedInjectedChunkCannotBypassServiceChecks() async throws {
        let directory = try TestDirectory()
        defer { do { try directory.cleanup() } catch { XCTFail("Unsafe fixture cleanup: \(error)") } }
        let (client, session) = try client()
        defer { session.invalidateAndCancel() }
        let service = TrackDownloadService(client: client, stream: { _, _, _ in
            MediaChunk(data: Data([1]), mimeType: "audio/flac", totalLength: 8, rangeStart: 0, supportsRanges: true)
        })
        let authorization = try await DownloadSaveAuthorization.recordPanelSelection(directory.file())
        do {
            try await service.download(track(), to: directory.file()) { _ in }
            XCTFail("A short chunk cannot silently truncate the song")
        } catch { XCTAssertEqual(error as? APIError, .invalidRange) }
        await DownloadSaveAuthorization.revoke(authorization)
        XCTAssertTrue(try directory.entries().isEmpty)
    }
}
