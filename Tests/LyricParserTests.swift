import XCTest
@testable import FnMusic

final class LyricParserTests: XCTestCase {
    private func parse(_ content: String, offset: Double? = nil) -> ParsedLyrics {
        LyricParser.parse(Lyric(guid: "test", content: content, offset: offset))
    }

    // MARK: - LRC timestamps

    func testBasicLRCTimestamps() {
        let parsed = parse("""
        [00:01.00]第一行
        [00:05.50]第二行
        [00:10]第三行
        """)
        XCTAssertTrue(parsed.isTimed)
        XCTAssertEqual(parsed.lines.count, 3)
        XCTAssertEqual(parsed.lines.map(\.text), ["第一行", "第二行", "第三行"])
        XCTAssertEqual(parsed.lines[0].time, 1.0)
        XCTAssertEqual(parsed.lines[1].time, 5.5)
        XCTAssertEqual(parsed.lines[2].time, 10.0)
    }

    func testMultipleTimestampsPerLine() {
        let parsed = parse("[00:01][00:03]重复行")
        XCTAssertTrue(parsed.isTimed)
        XCTAssertEqual(parsed.lines.count, 2)
        XCTAssertEqual(parsed.lines.map(\.text), ["重复行", "重复行"])
        XCTAssertEqual(parsed.lines.map(\.time), [1.0, 3.0])
    }

    func testFractionPrecisionVariants() {
        let parsed = parse("[00:01.125]毫秒\n[00:02:25]冒号")
        XCTAssertEqual(parsed.lines[0].time, 1.125)
        XCTAssertEqual(parsed.lines[1].time, 2.25)
    }

    func testOutOfOrderTimestampsAreSorted() {
        let parsed = parse("[00:10]C\n[00:02]B\n[00:01]A")
        XCTAssertEqual(parsed.lines.map(\.text), ["A", "B", "C"])
    }

    func testSameTimeEntriesKeepSourceOrder() {
        let parsed = parse("[00:01]First\n[00:01]Second")
        XCTAssertEqual(parsed.lines.map(\.text), ["First", "Second"])
    }

    // MARK: - Offsets

    func testEmbeddedOffsetTagShiftsTimes() {
        let parsed = parse("""
        [offset:500]
        [00:01]A
        [00:02]B
        """)
        XCTAssertEqual(parsed.lines.map(\.time), [0.5, 1.5])
        XCTAssertEqual(parsed.lines.map(\.text), ["A", "B"])
    }

    func testServerOffsetShiftsTimes() {
        let parsed = parse("[00:02]A", offset: 1000)
        XCTAssertEqual(parsed.lines[0].time, 1.0)
    }

    func testServerAndEmbeddedOffsetsAddUp() {
        let parsed = parse("[offset:250]\n[00:02]A", offset: 750)
        XCTAssertEqual(parsed.lines[0].time, 1.0)
    }

    // MARK: - Rich text and metadata

    func testRichTextLinesJoinFragments() {
        let parsed = parse(#"{"t":1500,"c":[{"tx":"你"},{"tx":"好"}]}"#)
        XCTAssertEqual(parsed.lines.count, 1)
        XCTAssertEqual(parsed.lines[0].time, 1.5)
        XCTAssertEqual(parsed.lines[0].text, "你好")
    }

    func testMetadataTagsAreFiltered() {
        let parsed = parse("""
        [ti:标题]
        [ar:艺人]
        [al:专辑]
        [00:01]A
        """)
        XCTAssertEqual(parsed.lines.map(\.text), ["A"])
    }

    // MARK: - Untimed content

    func testPlainTextIsNotTimed() {
        let parsed = parse("纯文本歌词\n第二行")
        XCTAssertFalse(parsed.isTimed)
        XCTAssertEqual(parsed.lines.map(\.text), ["纯文本歌词", "第二行"])
        XCTAssertEqual(parsed.lines.map(\.time), [nil, nil])
    }

    func testEmptyTimedTextBecomesNoteGlyph() {
        let parsed = parse("[00:01]")
        XCTAssertEqual(parsed.lines.count, 1)
        XCTAssertEqual(parsed.lines[0].text, "♪")
        XCTAssertEqual(parsed.lines[0].time, 1.0)
    }

    func testUntimedLinesFollowPrecedingTimedEntry() {
        let parsed = parse("""
        [00:01]Hello
        世界
        [00:02]Hi
        你好
        """)
        XCTAssertEqual(parsed.lines.map(\.text), ["Hello", "世界", "Hi", "你好"])
        XCTAssertEqual(parsed.lines.map(\.time), [1.0, nil, 2.0, nil])
    }

    func testLeadingUntimedLinesPrecedeTimedOnes() {
        let parsed = parse("""
        标题行
        [00:01]A
        """)
        XCTAssertEqual(parsed.lines.map(\.text), ["标题行", "A"])
        XCTAssertEqual(parsed.lines[0].time, nil)
        XCTAssertEqual(parsed.lines[1].time, 1.0)
    }

    func testEmptyContentYieldsNoLines() {
        XCTAssertTrue(parse("").lines.isEmpty)
        XCTAssertFalse(parse("").isTimed)
        let nilContent = LyricParser.parse(Lyric(guid: "x"))
        XCTAssertTrue(nilContent.lines.isEmpty)
    }

    // MARK: - Playback lookup

    func testCurrentIndexBinarySearch() {
        let parsed = parse("[00:01]A\n[00:05]B\n[00:10]C")
        XCTAssertNil(parsed.currentIndex(at: 0.5), "before the first line")
        XCTAssertEqual(parsed.currentIndex(at: 1.0), 0)
        XCTAssertEqual(parsed.currentIndex(at: 4.99), 0)
        XCTAssertEqual(parsed.currentIndex(at: 5.0), 1)
        XCTAssertEqual(parsed.currentIndex(at: 9.99), 1)
        XCTAssertEqual(parsed.currentIndex(at: 10.0), 2)
        XCTAssertEqual(parsed.currentIndex(at: 100), 2, "after the last line")
    }

    func testCurrentIndexReturnsDisplayLinePosition() {
        // A leading untimed line shifts the display index of timed lines.
        let parsed = parse("""
        标题
        [00:01]A
        [00:05]B
        """)
        XCTAssertNil(parsed.currentIndex(at: 0.5))
        XCTAssertEqual(parsed.currentIndex(at: 1.0), 1)
        XCTAssertEqual(parsed.currentIndex(at: 5.0), 2)
    }

    // MARK: - LyricResponse selection

    func testLyricResponseSelectionPrefersPreferredGUID() {
        let response = LyricResponse(list: [Lyric(guid: "a"), Lyric(guid: "b")], preferred: "b")
        XCTAssertEqual(response.selected?.guid, "b")
    }

    func testLyricResponseSelectionFallsBackToFirst() {
        let response = LyricResponse(list: [Lyric(guid: "a"), Lyric(guid: "b")], preferred: "missing")
        XCTAssertEqual(response.selected?.guid, "a")
    }

    func testLyricResponseSelectionOfEmptyList() {
        let response = LyricResponse(list: [], preferred: nil)
        XCTAssertNil(response.selected)
    }
}
