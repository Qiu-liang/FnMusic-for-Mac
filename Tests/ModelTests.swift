import XCTest
@testable import FnMusic

final class ModelTests: XCTestCase {
    /// JSONScalar does not declare Equatable; compare via pattern matching.
    private func assertJSONScalarEqual(_ actual: JSONScalar, _ expected: JSONScalar,
                                       file: StaticString = #filePath, line: UInt = #line) {
        switch (actual, expected) {
        case (.string(let a), .string(let b)): XCTAssertEqual(a, b, file: file, line: line)
        case (.number(let a), .number(let b)): XCTAssertEqual(a, b, file: file, line: line)
        case (.boolean(let a), .boolean(let b)): XCTAssertEqual(a, b, file: file, line: line)
        case (.null, .null): break
        default: XCTFail("expected \(expected), got \(actual)", file: file, line: line)
        }
    }
    // MARK: - Track display fallbacks

    func testTrackDisplayFallbacks() {
        XCTAssertEqual(Track(guid: "t").displayTitle, "未知歌曲")
        XCTAssertEqual(Track(guid: "t", title: "").displayTitle, "未知歌曲")
        XCTAssertEqual(Track(guid: "t", title: "标题").displayTitle, "标题")

        XCTAssertEqual(Track(guid: "t").artistText, "未知艺人")
        XCTAssertEqual(Track(guid: "t", artists: []).artistText, "未知艺人")
        XCTAssertEqual(Track(guid: "t", artists: [Artist(guid: "a1", name: "甲"), Artist(guid: "a2", name: "乙")]).artistText, "甲、乙")
        XCTAssertEqual(Track(guid: "t", artists: [Artist(guid: "a1"), Artist(guid: "a2", name: "乙")]).artistText, "未知艺人、乙")
    }

    func testDurationSecondsFallbacks() {
        XCTAssertEqual(Track(guid: "t").durationSeconds, 0)
        XCTAssertEqual(Track(guid: "t", duration: 123_456).durationSeconds, 123.456)
        XCTAssertEqual(Track(guid: "t", audioSpec: AudioSpec(duration: 5_000)).durationSeconds, 5)
        XCTAssertEqual(Track(guid: "t", duration: 2_000, audioSpec: AudioSpec(duration: 5_000)).durationSeconds, 2, "duration wins over audioSpec")
        XCTAssertEqual(Track(guid: "t", duration: -1_000).durationSeconds, 0, "negative durations clamp to zero")
    }

    func testGenreNamesOnlyAcceptsNonEmptyStrings() throws {
        let json = #"[{"name":"Rock"},{"name":""},{"name":123},{"year":2020},"plain"]"#
        let genres = try JSONDecoder().decode([GenreRecord].self, from: Data(json.utf8))
        let track = Track(guid: "t", genres: genres)
        XCTAssertEqual(track.genreNames, ["Rock"])
    }

    func testDisplayFallbacksForCatalogEntities() {
        XCTAssertEqual(Album(guid: "al").displayName, "未知专辑")
        XCTAssertEqual(Artist(guid: "ar").displayName, "未知艺人")
        XCTAssertEqual(Playlist(guid: "pl").displayName, "未命名歌单")
    }

    // MARK: - Playback time formatting

    func testPlaybackTimeFormatting() {
        let cases: [(Double, String)] = [
            (0, "0:00"), (59, "0:59"), (65, "1:05"), (3_599, "59:59"),
            (3_600, "1:00:00"), (3_661, "1:01:01"), (86_399, "23:59:59"),
            (359_999, "99:59:59"), (400_000, "99:59:59"),
            (59.9, "0:59"),
            (-5, "0:00"), (.nan, "0:00"), (.infinity, "0:00"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(input.playbackTime, expected, "input \(input)")
        }
    }

    // MARK: - JSONScalar

    func testJSONScalarDecodingAndDisplay() throws {
        let scalars = try JSONDecoder().decode([JSONScalar].self, from: Data(#"["text", 3.5, true, null, 42]"#.utf8))
        let expected: [JSONScalar] = [.string("text"), .number(3.5), .boolean(true), .null, .number(42)]
        XCTAssertEqual(scalars.count, expected.count)
        for (actual, want) in zip(scalars, expected) {
            assertJSONScalarEqual(actual, want)
        }
        XCTAssertEqual(scalars.map(\.display), ["text", "3.5", "true", "—", "42.0"])
    }

    func testJSONScalarRoundTrip() throws {
        let values: [JSONScalar] = [.string("s"), .number(1.5), .boolean(false), .null]
        let decoded = try JSONDecoder().decode([JSONScalar].self, from: JSONEncoder().encode(values))
        XCTAssertEqual(decoded.count, values.count)
        for (actual, want) in zip(decoded, values) {
            assertJSONScalarEqual(actual, want)
        }
    }

    // MARK: - GenreRecord

    func testGenreRecordIdentityIsContentBased() throws {
        let a = try JSONDecoder().decode(GenreRecord.self, from: Data(#"{"name":"Rock","guid":"g"}"#.utf8))
        let b = try JSONDecoder().decode(GenreRecord.self, from: Data(#"{"guid":"g","name":"Rock"}"#.utf8))
        XCTAssertEqual(a, b, "identity must be canonical, not key-order based")
        let c = try JSONDecoder().decode(GenreRecord.self, from: Data(#"{"name":"Pop"}"#.utf8))
        XCTAssertNotEqual(a, c)
    }

    func testGenreRecordAccessorsValidateServerData() throws {
        let full = try JSONDecoder().decode(GenreRecord.self, from: Data(#"{"guid":"g1","name":"Rock"}"#.utf8))
        XCTAssertEqual(full.guid, "g1")
        XCTAssertEqual(full.displayName, "Rock")
        XCTAssertEqual(full.fields?.count, 2)

        let blanks = try JSONDecoder().decode(GenreRecord.self, from: Data(#"{"guid":"  ","name":""}"#.utf8))
        XCTAssertNil(blanks.guid)
        XCTAssertEqual(blanks.displayName, "未命名风格")

        let nonObject = try JSONDecoder().decode(GenreRecord.self, from: Data(#""plain""#.utf8))
        XCTAssertNil(nonObject.fields)
        XCTAssertNil(nonObject.guid)
        XCTAssertEqual(nonObject.displayName, "未命名风格")
    }

    // MARK: - BrowseJSONValue

    func testBrowseJSONValueDecodesNestedStructure() throws {
        let value = try JSONDecoder().decode(BrowseJSONValue.self, from: Data(#"{"list":[1,"two",true,null],"flag":false}"#.utf8))
        XCTAssertEqual(value, .object([
            "list": .array([.number(Decimal(1)), .string("two"), .boolean(true), .null]),
            "flag": .boolean(false),
        ]))
    }

    func testBrowseJSONValuePreservesLargeIntegerPrecision() throws {
        // 2^53 + 1 loses precision as a Double; Decimal must keep it exact.
        let value = try JSONDecoder().decode(BrowseJSONValue.self, from: Data("9007199254740993".utf8))
        XCTAssertEqual(value, .number(Decimal(string: "9007199254740993")!))
    }

    // MARK: - Small entities

    func testUserAdministratorFlag() {
        XCTAssertTrue(User(guid: "u", role: "admin").isAdministrator)
        XCTAssertFalse(User(guid: "u", role: "user").isAdministrator)
        XCTAssertFalse(User(guid: "u").isAdministrator)
    }

    func testSearchResultEmptiness() {
        XCTAssertTrue(SearchResult().isEmpty)
        XCTAssertFalse(SearchResult(tracks: [Track(guid: "t")]).isEmpty)
        XCTAssertFalse(SearchResult(albums: [Album(guid: "a")]).isEmpty)
        XCTAssertFalse(SearchResult(artists: [Artist(guid: "r")]).isEmpty)
        XCTAssertFalse(SearchResult(playlists: [Playlist(guid: "p")]).isEmpty)
    }

    func testNilIfEmpty() {
        XCTAssertEqual("x".nilIfEmpty, "x")
        XCTAssertNil("".nilIfEmpty)
    }

    // MARK: - Codable round trips

    func testTrackCodableRoundTrip() throws {
        let track = Track(guid: "t", title: "标题", duration: 123.4, artists: [Artist(guid: "a", name: "艺人")])
        let decoded = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track))
        XCTAssertEqual(decoded, track)
    }

    func testPageDecodesServerPayload() throws {
        let page = try JSONDecoder().decode(Page<Track>.self, from: Data(#"{"list":[{"guid":"a"},{"guid":"b"}],"total":2,"sort":"year"}"#.utf8))
        XCTAssertEqual(page.list.map(\.guid), ["a", "b"])
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.sort, "year")
    }

    // MARK: - Album date grouping

    func testRecentGroupingDoesNotInventDate() {
        XCTAssertEqual(AlbumDateGroup.group(for: nil), .unknown)
        XCTAssertEqual(AlbumDateGroup.group(for: 0), .unknown)
        XCTAssertEqual(AlbumDateGroup.group(for: Date().timeIntervalSince1970), .threeMonths)
    }
}
