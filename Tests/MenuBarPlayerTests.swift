import AppKit
import SwiftUI
import XCTest
@testable import FnMusic

/// Menu bar presentation: which lyric line is shown, how wide the item is, when
/// long lyrics scroll, where each click lands, and what actually gets drawn.
@MainActor
final class MenuBarPlayerTests: XCTestCase {
    private let track = Track(guid: "track", title: "夜曲", artists: [Artist(guid: "artist", name: "周杰伦")])
    private let column: CGFloat = MenuBarBarLayout.defaultColumnWidth

    private var timedLyrics: ParsedLyrics {
        ParsedLyrics(lines: [
            LyricLine(id: 0, time: 0, text: "第一行"),
            LyricLine(id: 1, time: 12.5, text: "第二行"),
            LyricLine(id: 2, time: 30, text: "第三行"),
        ])
    }

    // MARK: - Lyric text

    func testTimedLyricFollowsPlaybackPosition() {
        let parsed = timedLyrics
        XCTAssertEqual(MenuBarNowPlaying.lyricText(parsed: parsed, elapsed: 0), "第一行")
        XCTAssertEqual(MenuBarNowPlaying.lyricText(parsed: parsed, elapsed: 12.4), "第一行")
        XCTAssertEqual(MenuBarNowPlaying.lyricText(parsed: parsed, elapsed: 12.5), "第二行")
        XCTAssertEqual(MenuBarNowPlaying.lyricText(parsed: parsed, elapsed: 900), "第三行")
    }

    func testPositionBeforeFirstTimestampHasNoLyric() {
        let parsed = timedLyrics
        XCTAssertNil(MenuBarNowPlaying.lyricText(parsed: parsed, elapsed: -1))
        XCTAssertEqual(MenuBarNowPlaying.displayText(track: track, parsed: parsed, elapsed: -1), "夜曲")
    }

    func testBlankTimedLineFallsBackToTrackTitle() {
        let parsed = ParsedLyrics(lines: [
            LyricLine(id: 0, time: 0, text: "前奏"),
            LyricLine(id: 1, time: 4, text: "   "),
        ])
        XCTAssertNil(MenuBarNowPlaying.lyricText(parsed: parsed, elapsed: 6))
        XCTAssertEqual(MenuBarNowPlaying.displayText(track: track, parsed: parsed, elapsed: 6), "夜曲")
    }

    func testUntimedLyricsFallBackToTrackTitle() {
        let parsed = ParsedLyrics(lines: [LyricLine(id: 0, time: nil, text: "纯文本歌词")])
        XCTAssertNil(MenuBarNowPlaying.lyricText(parsed: parsed, elapsed: 5))
        XCTAssertEqual(MenuBarNowPlaying.displayText(track: track, parsed: parsed, elapsed: 5), "夜曲")
    }

    func testIdleTextWithoutTrack() {
        XCTAssertEqual(MenuBarNowPlaying.displayText(track: nil, parsed: timedLyrics, elapsed: 1),
                       MenuBarNowPlaying.idleText)
        XCTAssertEqual(MenuBarNowPlaying.tooltip(track: nil), "FnMusic")
    }

    func testTooltipAndAccessibilityCarryTrackIdentity() {
        XCTAssertEqual(MenuBarNowPlaying.tooltip(track: track), "夜曲 — 周杰伦")
        XCTAssertEqual(MenuBarNowPlaying.accessibilityLabel(track: track, text: "第二行"), "夜曲，第二行")
    }

    func testPlayPauseSymbolFollowsPlaybackState() {
        XCTAssertEqual(MenuBarNowPlaying.symbol(isPlaying: true), "pause.fill")
        XCTAssertEqual(MenuBarNowPlaying.symbol(isPlaying: false), "play.fill")
    }

    func testStatusItemVisibilityPolicy() {
        XCTAssertTrue(MenuBarPlayerController.shouldShow(enabled: true, hasTrack: true))
        XCTAssertFalse(MenuBarPlayerController.shouldShow(enabled: true, hasTrack: false))
        XCTAssertFalse(MenuBarPlayerController.shouldShow(enabled: false, hasTrack: true))
        XCTAssertFalse(MenuBarPlayerController.shouldShow(enabled: false, hasTrack: false))
    }

    // MARK: - Configurable width

    func testStoredWidthIsClampedAndDefaultsToTheStandardWidth() {
        XCTAssertEqual(MenuBarBarLayout.columnWidth(nil), MenuBarBarLayout.defaultColumnWidth)
        XCTAssertEqual(MenuBarBarLayout.columnWidth(10), MenuBarBarLayout.minColumnWidth)
        XCTAssertEqual(MenuBarBarLayout.columnWidth(10_000), MenuBarBarLayout.maxColumnWidth)
        XCTAssertEqual(MenuBarBarLayout.columnWidth(160), 160)
    }

    func testItemLengthTracksTheChosenWidth() {
        let narrow = MenuBarBarLayout.statusLength(columnWidth: MenuBarBarLayout.minColumnWidth)
        let wide = MenuBarBarLayout.statusLength(columnWidth: MenuBarBarLayout.maxColumnWidth)
        XCTAssertLessThan(narrow, wide)
        XCTAssertEqual(MenuBarBarLayout.statusLength(columnWidth: column),
                       MenuBarBarLayout.horizontalPadding + column + MenuBarBarLayout.spacing
                       + MenuBarBarLayout.controlsWidth + MenuBarBarLayout.horizontalPadding)
        XCTAssertEqual(MenuBarBarLayout.previousMinX(columnWidth: column), 5 + column + 2)
    }

    // MARK: - Scrolling decision

    func testLongLyricsScrollInsteadOfWideningTheItem() {
        let short = "踞江东志在九州"
        let long = String(repeating: "长风破浪", count: 12)
        XCTAssertFalse(MenuBarBarLayout.needsScroll(for: short, columnWidth: column))
        XCTAssertTrue(MenuBarBarLayout.needsScroll(for: long, columnWidth: column))
        XCTAssertEqual(MenuBarBarLayout.columnTextWidth(for: long, columnWidth: column), column)
        XCTAssertLessThan(MenuBarBarLayout.columnTextWidth(for: short, columnWidth: column), column)
        XCTAssertEqual(MenuBarBarLayout.textStartX(for: long, columnWidth: column),
                       MenuBarBarLayout.horizontalPadding,
                       "a scrolling line fills the column from its left edge")
    }

    func testShortLyricHugsTheControls() {
        let text = "踞江东志在九州"
        XCTAssertEqual(MenuBarBarLayout.textStartX(for: text, columnWidth: column),
                       MenuBarBarLayout.previousMinX(columnWidth: column) - MenuBarBarLayout.spacing
                       - MenuBarBarLayout.columnTextWidth(for: text, columnWidth: column))
    }

    func testNarrowerWidthMakesMoreLinesScroll() {
        let text = "长风破浪会有时直挂云帆济沧海"
        XCTAssertFalse(MenuBarBarLayout.needsScroll(for: text, columnWidth: MenuBarBarLayout.maxColumnWidth))
        XCTAssertTrue(MenuBarBarLayout.needsScroll(for: text, columnWidth: MenuBarBarLayout.minColumnWidth))
    }

    // MARK: - Click zones

    func testClickZonesCoverTheWholeBarWithoutOverlap() {
        let text = "踞江东志在九州"
        let textStart = MenuBarBarLayout.textStartX(for: text, columnWidth: column)

        XCTAssertEqual(MenuBarBarLayout.zone(atX: 0, text: text, columnWidth: column), .none,
                       "clicks left of a short lyric must not open the app")
        XCTAssertEqual(MenuBarBarLayout.zone(atX: textStart - 0.5, text: text, columnWidth: column), .none)
        XCTAssertEqual(MenuBarBarLayout.zone(atX: textStart, text: text, columnWidth: column), .text)
        XCTAssertEqual(MenuBarBarLayout.zone(
            atX: MenuBarBarLayout.previousMinX(columnWidth: column) - 0.5,
            text: text, columnWidth: column), .text)

        XCTAssertEqual(MenuBarBarLayout.zone(atX: MenuBarBarLayout.previousMinX(columnWidth: column),
                                             text: text, columnWidth: column), .previous)
        XCTAssertEqual(MenuBarBarLayout.zone(atX: MenuBarBarLayout.toggleMinX(columnWidth: column) - 0.5,
                                             text: text, columnWidth: column), .previous)
        XCTAssertEqual(MenuBarBarLayout.zone(atX: MenuBarBarLayout.toggleMinX(columnWidth: column),
                                             text: text, columnWidth: column), .toggle)
        XCTAssertEqual(MenuBarBarLayout.zone(atX: MenuBarBarLayout.nextMinX(columnWidth: column) - 0.5,
                                             text: text, columnWidth: column), .toggle)
        XCTAssertEqual(MenuBarBarLayout.zone(atX: MenuBarBarLayout.nextMinX(columnWidth: column),
                                             text: text, columnWidth: column), .next)
        XCTAssertEqual(MenuBarBarLayout.zone(atX: MenuBarBarLayout.statusLength(columnWidth: column),
                                             text: text, columnWidth: column), .next)
    }

    func testZonesHoldForEveryWidthAndLyricLength() {
        for column in [MenuBarBarLayout.minColumnWidth, 140, MenuBarBarLayout.defaultColumnWidth,
                       MenuBarBarLayout.maxColumnWidth] {
            for count in [1, 4, 8, 12, 16, 24, 40, 80] {
                let text = String(repeating: "长", count: count)
                for zone in [MenuBarBarLayout.Zone.text, .previous, .toggle, .next] {
                    XCTAssertEqual(MenuBarBarLayout.zone(
                        atX: MenuBarBarLayout.centerX(of: zone, text: text, columnWidth: column),
                        text: text, columnWidth: column), zone,
                        "zone mapping broke for \(count) characters at width \(column)")
                }
            }
        }
    }

    // MARK: - Marquee timing

    func testScrollingPausesThenSlidesAndWraps() {
        let width: CGFloat = 400
        let pause = MenuBarBarLayout.scrollPause

        XCTAssertEqual(MenuBarBarLayout.textOffset(after: 0, textWidth: width), 0)
        XCTAssertEqual(MenuBarBarLayout.textOffset(after: pause * 0.5, textWidth: width), 0,
                       "the line should rest at the start before sliding")
        XCTAssertEqual(MenuBarBarLayout.textOffset(after: pause + 1, textWidth: width),
                       MenuBarBarLayout.scrollSpeed, accuracy: 0.01)
        XCTAssertEqual(MenuBarBarLayout.textOffset(after: pause + 2, textWidth: width),
                       2 * MenuBarBarLayout.scrollSpeed, accuracy: 0.01)

        let duration = MenuBarBarLayout.cycleDuration(forTextWidth: width)
        XCTAssertEqual(MenuBarBarLayout.textOffset(after: duration, textWidth: width), 0, accuracy: 0.001,
                       "the marquee must wrap seamlessly after one pass plus the gap")
    }

    func testScrollOffsetStaysWithinOneCycle() {
        let width: CGFloat = 320
        let cycle = MenuBarBarLayout.cycleLength(forTextWidth: width)
        for seconds in stride(from: 0.0, through: 30.0, by: 0.37) {
            let offset = MenuBarBarLayout.textOffset(after: seconds, textWidth: width)
            XCTAssertGreaterThanOrEqual(offset, 0)
            XCTAssertLessThanOrEqual(offset, cycle + 0.001)
        }
    }

    // MARK: - Rendering

    private func content(text: String, isPlaying: Bool = true, hasTrack: Bool = true,
                         offset: CGFloat?, column: CGFloat? = nil) throws -> MenuBarCanvasView.Content {
        let lyric = try XCTUnwrap(MenuBarPlayerController.raster(MenuBarLyricStrip(text: text, tint: .black)))
        let controls = try XCTUnwrap(MenuBarPlayerController.raster(MenuBarControlsStrip(isPlaying: isPlaying,
                                                                                        tint: .black)))
        return MenuBarCanvasView.Content(
            text: lyric, controls: controls,
            textWidth: CGFloat(lyric.width) / MenuBarPlayerController.scale,
            columnWidth: column ?? self.column, hasTrack: hasTrack, offset: offset)
    }

    func testBarDrawsAtTheConfiguredItemSize() throws {
        for width in [MenuBarBarLayout.minColumnWidth, 160, MenuBarBarLayout.maxColumnWidth] {
            let cgImage = try XCTUnwrap(Self.render(try content(text: "踞江东志在九州", offset: nil, column: width),
                                                    column: width))
            XCTAssertEqual(cgImage.width, Int((MenuBarBarLayout.statusLength(columnWidth: width) * 2).rounded()))
            XCTAssertEqual(cgImage.height, Int((MenuBarBarLayout.height * 2).rounded()))
        }
    }

    func testScrollingMovesTheLyricButNotTheControls() throws {
        let text = String(repeating: "长风破浪会有时", count: 3)
        let start = try XCTUnwrap(Self.render(try content(text: text, offset: 0)))
        let moved = try XCTUnwrap(Self.render(try content(text: text, offset: 90)))

        let scale = MenuBarPlayerController.scale
        let controlsRect = CGRect(x: MenuBarBarLayout.previousMinX(columnWidth: column) * scale, y: 0,
                                  width: MenuBarBarLayout.controlsWidth * scale,
                                  height: MenuBarBarLayout.height * scale)
        let columnRect = CGRect(x: 0, y: 0,
                                width: column * scale,
                                height: MenuBarBarLayout.height * scale)

        XCTAssertEqual(Self.png(try XCTUnwrap(start.cropping(to: controlsRect))),
                       Self.png(try XCTUnwrap(moved.cropping(to: controlsRect))),
                       "the transport controls must not move while the lyric scrolls")
        XCTAssertNotEqual(Self.png(try XCTUnwrap(start.cropping(to: columnRect))),
                          Self.png(try XCTUnwrap(moved.cropping(to: columnRect))),
                          "the lyric itself has to move")
    }

    func testShortLyricLeavesTheLeftOfTheColumnEmpty() throws {
        let cgImage = try XCTUnwrap(Self.render(try content(text: "踞江东", offset: nil)))
        let scale = MenuBarPlayerController.scale
        let farLeft = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: 0, y: 0, width: MenuBarBarLayout.horizontalPadding * scale,
            height: CGFloat(cgImage.height))))
        XCTAssertEqual(Self.png(farLeft),
                       Self.png(try XCTUnwrap(Self.blank(width: MenuBarBarLayout.horizontalPadding * scale,
                                                         height: cgImage.height))),
                       "nothing may be drawn in the left padding")
    }

    func testScrollingLyricStartsAtTheColumnEdge() throws {
        let long = String(repeating: "长", count: 60)
        let cgImage = try XCTUnwrap(Self.render(try content(text: long, offset: 0)))
        let scale = MenuBarPlayerController.scale
        let leftSlice = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: MenuBarBarLayout.horizontalPadding * scale, y: 0,
            width: 20 * scale, height: CGFloat(cgImage.height))))
        XCTAssertNotEqual(Self.png(leftSlice),
                          Self.png(try XCTUnwrap(Self.blank(width: 20 * scale, height: cgImage.height))),
                          "a scrolling line starts at the column's left edge")
    }

    func testInkColorFollowsTheMenuBarAppearance() {
        XCTAssertEqual(MenuBarPlayerController.inkColor(for: NSAppearance(named: .darkAqua)!), .white)
        XCTAssertEqual(MenuBarPlayerController.inkColor(for: NSAppearance(named: .aqua)!), .black)
    }

    func testRenderSavesReviewPreviews() throws {
        for (name, text, offset, width) in [
            ("short", "踞江东志在九州", nil, MenuBarBarLayout.defaultColumnWidth),
            ("narrow", "踞江东志在九州", nil, MenuBarBarLayout.minColumnWidth),
            ("long-start", "君不见 军赤壁纵野火铁索连环 也不见 御北敌联西蜀长江上鏖战", 0,
             MenuBarBarLayout.defaultColumnWidth),
            ("long-mid", "君不见 军赤壁纵野火铁索连环 也不见 御北敌联西蜀长江上鏖战", 140,
             MenuBarBarLayout.defaultColumnWidth),
        ] as [(String, String, CGFloat?, CGFloat)] {
            let cgImage = try XCTUnwrap(Self.render(try content(text: text, offset: offset, column: width),
                                                    column: width))
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("fnmusic-menubar-\(name).png")
            try XCTUnwrap(Self.png(cgImage)).write(to: url)
            print("MenuBarPlayerBar preview (\(name)): \(url.path)")
        }
    }

    // MARK: Helpers

    private static func render(_ content: MenuBarCanvasView.Content,
                               column: CGFloat = MenuBarBarLayout.defaultColumnWidth) -> CGImage? {
        let scale = MenuBarPlayerController.scale
        let width = Int((MenuBarBarLayout.statusLength(columnWidth: column) * scale).rounded())
        let height = Int((MenuBarBarLayout.height * scale).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        MenuBarRenderer.draw(content, in: context, bounds: CGRect(
            x: 0, y: 0, width: MenuBarBarLayout.statusLength(columnWidth: column),
            height: MenuBarBarLayout.height))
        return context.makeImage()
    }

    private static func blank(width: CGFloat, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: Int(width), height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: CGFloat(height)))
        return context.makeImage()
    }

    private static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
