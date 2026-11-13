import AppKit
import XCTest
@testable import FnMusic

@MainActor
final class NowPlayingViewTests: XCTestCase {
    func testArtworkSizeFollowsReferenceWindowProportions() {
        XCTAssertEqual(NowPlayingMetrics.artworkSize(for: CGSize(width: 820, height: 600)), 229.6, accuracy: 0.01)
        XCTAssertEqual(NowPlayingMetrics.artworkSize(for: CGSize(width: 1280, height: 880)), 358.4, accuracy: 0.01)
        XCTAssertEqual(NowPlayingMetrics.artworkSize(for: CGSize(width: 1379, height: 1047)), 386.12, accuracy: 0.01)
        XCTAssertEqual(NowPlayingMetrics.artworkSize(for: CGSize(width: 2560, height: 1440)), 716.8, accuracy: 0.01)
        XCTAssertEqual(NowPlayingMetrics.artworkSize(for: CGSize(width: 500, height: 400)), 200, accuracy: 0.01)
        XCTAssertEqual(NowPlayingMetrics.artworkSize(for: .zero), 300, accuracy: 0.01)
    }

    func testPaneWidthUsesRemainingReferenceColumnWithLargeScreenCap() {
        XCTAssertEqual(NowPlayingMetrics.paneWidth(for: CGSize(width: 820, height: 600)), 362.44, accuracy: 0.01)
        XCTAssertEqual(NowPlayingMetrics.paneWidth(for: CGSize(width: 1280, height: 880)), 565.76, accuracy: 0.01)
        XCTAssertEqual(NowPlayingMetrics.paneWidth(for: CGSize(width: 1379, height: 1047)), 609.518, accuracy: 0.001)
        XCTAssertEqual(NowPlayingMetrics.paneWidth(for: CGSize(width: 2560, height: 1440)), 780, accuracy: 0.01)
        XCTAssertEqual(NowPlayingMetrics.paneWidth(for: CGSize(width: 200, height: 200)), 88.4, accuracy: 0.01)
    }

    func testVerticalScrollerBridgeHidesLegacyLyricsScroller() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        let contentView = NSView(frame: scrollView.bounds)
        scrollView.documentView = contentView
        scrollView.hasVerticalScroller = true
        let bridge = HideVerticalScroller.Bridge(frame: .zero)
        contentView.addSubview(bridge)

        bridge.apply()

        XCTAssertFalse(scrollView.hasVerticalScroller)
        XCTAssertEqual(scrollView.verticalScroller?.isHidden, true)
    }

    func testLyricFocusIsCrispOnCurrentLineAndDecaysOutward() {
        let active = NowPlayingLyricFocus.style(distance: 0)
        XCTAssertEqual(active.blur, 0)
        XCTAssertEqual(active.opacity, 1)
        XCTAssertEqual(NowPlayingLyricFocus.style(distance: -3), active)

        var previousOpacity = 1.0
        var previousBlur = CGFloat.zero
        for distance in 1...14 {
            let style = NowPlayingLyricFocus.style(distance: distance)
            XCTAssertLessThanOrEqual(style.opacity, previousOpacity)
            XCTAssertGreaterThanOrEqual(style.blur, previousBlur)
            XCTAssertGreaterThanOrEqual(style.blur, 0)
            XCTAssertLessThanOrEqual(style.blur, NowPlayingLyricFocus.maximumBlur)
            XCTAssertGreaterThanOrEqual(style.opacity, 0.18)
            previousOpacity = style.opacity
            previousBlur = style.blur
        }
    }

    func testDisplayEntriesFoldUntimedLinesIntoThePrecedingTimedLine() {
        let model = LyricsViewModel(service: StubLyricsService())
        model.parsed = ParsedLyrics(lines: [
            LyricLine(id: 0, time: nil, text: "前言"),
            LyricLine(id: 1, time: 1, text: "第一句"),
            LyricLine(id: 2, time: nil, text: "First line"),
            LyricLine(id: 3, time: 2, text: "第二句"),
            LyricLine(id: 4, time: nil, text: "Second line"),
            LyricLine(id: 5, time: nil, text: "Second line again")
        ])

        let entries = model.displayEntries
        XCTAssertEqual(entries.map(\.id), [0, 1, 3])
        XCTAssertEqual(entries.map(\.text), ["前言", "第一句", "第二句"])
        XCTAssertEqual(entries[0].translations, [])
        XCTAssertEqual(entries[1].translations, ["First line"])
        XCTAssertEqual(entries[2].translations, ["Second line", "Second line again"])
    }
}

private struct StubLyricsService: LyricsServiceProtocol {
    func lyrics(trackGUID: String) async throws -> LyricResponse {
        throw APIError.unavailable("未配置")
    }
}
