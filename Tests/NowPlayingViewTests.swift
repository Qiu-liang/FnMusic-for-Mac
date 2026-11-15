import AppKit
import AVKit
import SwiftUI
import XCTest
@testable import FnMusic

@MainActor
final class NowPlayingViewTests: XCTestCase {
    func testArtworkSizeFollowsReferenceWindowProportions() {
        XCTAssertEqual(NowPlayingMetrics.artworkSize(for: CGSize(width: 820, height: 600)), 228.206, accuracy: 0.01)
        XCTAssertEqual(NowPlayingMetrics.artworkSize(for: CGSize(width: 1024, height: 576)), 284.979, accuracy: 0.01)
        XCTAssertEqual(NowPlayingMetrics.artworkSize(for: CGSize(width: 1280, height: 880)), 356.224, accuracy: 0.01)
        XCTAssertEqual(NowPlayingMetrics.artworkSize(for: CGSize(width: 1379, height: 1047)), 383.776, accuracy: 0.01)
        XCTAssertEqual(NowPlayingMetrics.artworkSize(for: CGSize(width: 2560, height: 1440)), 712.448, accuracy: 0.01)
        XCTAssertEqual(NowPlayingMetrics.artworkSize(for: CGSize(width: 500, height: 400)), 139.15, accuracy: 0.01)
        XCTAssertEqual(NowPlayingMetrics.artworkSize(for: .zero), NowPlayingMetrics.defaultArtwork, accuracy: 0.01)
    }

    func testPaneWidthScalesProportionallyAcrossWindowSizes() {
        let sizes = [
            CGSize(width: 500, height: 400),
            CGSize(width: 820, height: 600),
            CGSize(width: 1024, height: 576),
            CGSize(width: 1280, height: 880),
            CGSize(width: 1379, height: 1047),
            CGSize(width: 2560, height: 1440),
            CGSize(width: 3840, height: 2160)
        ]
        for size in sizes {
            let artwork = NowPlayingMetrics.artworkSize(for: size)
            let pane = NowPlayingMetrics.paneWidth(for: size)
            XCTAssertEqual(pane, size.width * 0.448, accuracy: 0.01)
            XCTAssertEqual(pane / artwork, 0.448 / NowPlayingMetrics.artworkWidthRatio, accuracy: 0.01)
        }
        XCTAssertEqual(NowPlayingMetrics.paneWidth(for: .zero), NowPlayingMetrics.defaultPaneWidth, accuracy: 0.01)
    }

    func testLyricAndPlaybackMetricsScaleToReferenceProportions() {
        let ref1024 = CGSize(width: 1024, height: 576)
        let ref2560 = CGSize(width: 2560, height: 1440)

        XCTAssertEqual(NowPlayingMetrics.lyricFontSize(for: ref1024), 18.81, accuracy: 0.05)
        XCTAssertEqual(NowPlayingMetrics.lyricFontSize(for: ref2560), 47.02, accuracy: 0.05)
        XCTAssertEqual(NowPlayingMetrics.lyricLineSpacing(for: ref1024), 21.09, accuracy: 0.05)
        XCTAssertEqual(NowPlayingMetrics.lyricLineSpacing(for: ref2560), 52.72, accuracy: 0.05)
        XCTAssertEqual(NowPlayingMetrics.lyricHighlightAnchorY, 0.31, accuracy: 0.001)

        let artwork2560 = NowPlayingMetrics.artworkSize(for: ref2560)
        let spacing2560 = NowPlayingMetrics.playbackClusterSpacing(forArtwork: artwork2560)
        let centerPitch2560 = (NowPlayingMetrics.playbackPrevButtonWidth + NowPlayingMetrics.playbackPlayButtonWidth) / 2 + spacing2560
        XCTAssertEqual(centerPitch2560 / 2.5, 34.77, accuracy: 0.1)
    }

    func testTopBarDodgesFullScreenChromeStrip() {
        // Windowed: ignores the full-screen safe area and aligns the capsules'
        // vertical centerline with the window's traffic lights.
        XCTAssertEqual(NowPlayingMetrics.topBarTopPadding(isFullScreen: false, safeAreaTop: 52), 7)
        XCTAssertEqual(NowPlayingMetrics.topBarFrameHeight(isFullScreen: false, safeAreaTop: 52), 52)

        // Full screen: AppKit's input-taking NSToolbarFullScreenWindow owns the
        // top 52 pt, so the chrome must clear the whole reserved strip or its
        // buttons are visible but never clicked.
        let padding = NowPlayingMetrics.topBarTopPadding(isFullScreen: true, safeAreaTop: 52)
        let height = NowPlayingMetrics.topBarFrameHeight(isFullScreen: true, safeAreaTop: 52)
        XCTAssertEqual(padding, 60)
        XCTAssertEqual(height, 104)
        XCTAssertGreaterThanOrEqual(padding, 52, "the pill must start below the reserved strip")

        // An absent or nonsensical safe area never moves the chrome.
        XCTAssertEqual(NowPlayingMetrics.topBarTopPadding(isFullScreen: true, safeAreaTop: 0), 8)
        XCTAssertEqual(NowPlayingMetrics.topBarTopPadding(isFullScreen: true, safeAreaTop: -8), 8)
        XCTAssertEqual(NowPlayingMetrics.topBarTopPadding(isFullScreen: true, safeAreaTop: .infinity), 8)
        XCTAssertEqual(NowPlayingMetrics.topBarTopPadding(isFullScreen: true, safeAreaTop: .nan), 8)
    }

    func testTopBarAlignsVerticallyWithWindowTrafficLights() {
        let defaultTop = NowPlayingMetrics.topBarTopPadding(isFullScreen: false, safeAreaTop: 0)
        XCTAssertEqual(
            defaultTop + NowPlayingMetrics.topBarControlHeight / 2,
            NowPlayingMetrics.windowButtonCenterY,
            accuracy: 0.01
        )

        let customTop = NowPlayingMetrics.topBarTopPadding(
            isFullScreen: false,
            safeAreaTop: 0,
            trafficLightCenterY: 22
        )
        XCTAssertEqual(customTop, 3)
        XCTAssertEqual(customTop + NowPlayingMetrics.topBarControlHeight / 2, 22, accuracy: 0.01)

        // Invalid measurements fall back to the standard unified-toolbar center.
        XCTAssertEqual(NowPlayingMetrics.topBarTopPadding(isFullScreen: false, safeAreaTop: 0, trafficLightCenterY: .nan), defaultTop)
        XCTAssertEqual(NowPlayingMetrics.topBarTopPadding(isFullScreen: false, safeAreaTop: 0, trafficLightCenterY: -4), defaultTop)
    }

    func testHostedNowPlayingTopBarAlignsCapsulesWithTrafficLights() async throws {
        let client = APIClient(origin: try APIClient.serverURL("https://nowplaying-layout.invalid"), token: "test-only")
        let library = LibraryContext(client: client, user: User(guid: "nowplaying-layout-test"))
        defer { library.player.shutdown() }

        @MainActor final class BoundsBox { var rects: [String: CGRect] = [:] }
        let box = BoundsBox()

        let root = NowPlayingView()
            .environment(library)
            .onPreferenceChange(NowPlayingTopBarBoundsKey.self) { rects in
                Task { @MainActor in box.rects = rects }
            }
            .ignoresSafeArea(.container, edges: .top)
            .frame(width: 1280, height: 880)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "nowplaying-layout-test")
        window.setContentSize(NSSize(width: 1280, height: 880))
        window.orderFrontRegardless()
        defer { window.close() }

        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        window.layoutIfNeeded()

        let contentView = try XCTUnwrap(window.contentView)
        let closeWindowButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let routePicker = try XCTUnwrap(findSubview(ofType: AVRoutePickerView.self, in: contentView))

        let trafficFrame = closeWindowButton.convert(closeWindowButton.bounds, to: contentView)
        let routeFrame = routePicker.convert(routePicker.bounds, to: contentView)

        let trafficMidYFromTop = contentView.isFlipped ? trafficFrame.midY : contentView.bounds.height - trafficFrame.midY
        let routeMidYFromTop = contentView.isFlipped ? routeFrame.midY : contentView.bounds.height - routeFrame.midY

        XCTAssertEqual(routeMidYFromTop, trafficMidYFromTop, accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(routeFrame.minX, trafficFrame.maxX)

        let leftCapsule = try XCTUnwrap(box.rects["left"])
        let rightCapsule = try XCTUnwrap(box.rects["right"])
        XCTAssertEqual(leftCapsule.height, NowPlayingMetrics.topBarControlHeight, accuracy: 0.5)
        XCTAssertEqual(rightCapsule.height, NowPlayingMetrics.topBarControlHeight, accuracy: 0.5)
        XCTAssertEqual(leftCapsule.midY, trafficMidYFromTop, accuracy: 1.0)
        XCTAssertEqual(rightCapsule.midY, trafficMidYFromTop, accuracy: 1.0)
        XCTAssertEqual(leftCapsule.midY, rightCapsule.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(leftCapsule.minX, trafficFrame.maxX)

        await client.close()
    }

    private func findSubview<T: NSView>(ofType type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = findSubview(ofType: type, in: subview) { return found }
        }
        return nil
    }

    func testTopBarClearsTheWindowTrafficLights() {
        // Windowed pages keep the window's own close/minimise/zoom buttons, which
        // occupy 19...79 pt. The floating chrome must start after them, otherwise
        // the close button sits on top of the page's own close control.
        XCTAssertEqual(NowPlayingMetrics.topBarLeadingPadding(isFullScreen: false), 101)
        XCTAssertGreaterThanOrEqual(
            NowPlayingMetrics.topBarLeadingPadding(isFullScreen: false),
            NowPlayingMetrics.windowButtonTrailing,
            "the pill must start to the right of the traffic-light cluster"
        )
        XCTAssertEqual(NowPlayingMetrics.windowButtonReserve, 93)

        // Full screen hides the traffic lights, so the chrome returns to the page inset.
        XCTAssertEqual(NowPlayingMetrics.topBarLeadingPadding(isFullScreen: true), 8)
    }

    func testVolumeSliderMapsThumbTravelToVolume() {
        XCTAssertEqual(NowPlayingVolumeMetrics.value(forX: 0, width: 200, thumbWidth: 26), 0, accuracy: 0.001)
        XCTAssertEqual(NowPlayingVolumeMetrics.value(forX: 100, width: 200, thumbWidth: 26), 0.5, accuracy: 0.001)
        XCTAssertEqual(NowPlayingVolumeMetrics.value(forX: 200, width: 200, thumbWidth: 26), 1, accuracy: 0.001)
        XCTAssertEqual(NowPlayingVolumeMetrics.value(forX: 100, width: 0, thumbWidth: 26), 0, accuracy: 0.001)
        XCTAssertEqual(NowPlayingVolumeMetrics.thumbOffset(for: 0, width: 200, thumbWidth: 26), 0, accuracy: 0.001)
        XCTAssertEqual(NowPlayingVolumeMetrics.thumbOffset(for: 0.5, width: 200, thumbWidth: 26), 87, accuracy: 0.001)
        XCTAssertEqual(NowPlayingVolumeMetrics.thumbOffset(for: 1, width: 200, thumbWidth: 26), 174, accuracy: 0.001)
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

    func testWindowChromeHidesAndRestoresTitlebarBackdropAndToolbar() {
        final class NSTitlebarBackgroundView: NSView {}
        final class _NSTitlebarDecorationView: NSView {}
        final class NSTitlebarContainerBlockingView: NSView {}
        final class NSToolbarView: NSView {}

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 52))
        let sidebarBackdrop = NSTitlebarBackgroundView(frame: NSRect(x: 0, y: 0, width: 206, height: 52))
        let detailBackdrop = NSTitlebarBackgroundView(frame: NSRect(x: 206, y: 0, width: 994, height: 52))
        let decoration = _NSTitlebarDecorationView(frame: container.bounds)
        let blocker = NSTitlebarContainerBlockingView(frame: NSRect(x: 204, y: 0, width: 5, height: 52))
        let titlebar = NSView(frame: container.bounds)
        let toolbarView = NSToolbarView(frame: container.bounds)
        let closeButton = NSButton(frame: NSRect(x: 19, y: 19, width: 14, height: 14))
        let alreadyHidden = NSTitlebarBackgroundView(frame: .zero)
        alreadyHidden.isHidden = true

        titlebar.addSubview(toolbarView)
        titlebar.addSubview(closeButton)
        container.addSubview(sidebarBackdrop)
        container.addSubview(detailBackdrop)
        container.addSubview(alreadyHidden)
        container.addSubview(decoration)
        container.addSubview(blocker)
        container.addSubview(titlebar)

        let chrome = NowPlayingWindowChrome.ChromeView()
        chrome.apply(toTitlebar: titlebar)

        XCTAssertTrue(sidebarBackdrop.isHidden)
        XCTAssertTrue(detailBackdrop.isHidden)
        XCTAssertTrue(decoration.isHidden)
        XCTAssertTrue(blocker.isHidden)
        XCTAssertTrue(toolbarView.isHidden)
        XCTAssertFalse(titlebar.isHidden)
        XCTAssertFalse(closeButton.isHidden)

        chrome.restore()

        XCTAssertFalse(sidebarBackdrop.isHidden)
        XCTAssertFalse(detailBackdrop.isHidden)
        XCTAssertFalse(decoration.isHidden)
        XCTAssertFalse(blocker.isHidden)
        XCTAssertFalse(toolbarView.isHidden)
        XCTAssertTrue(alreadyHidden.isHidden, "restore must not unhide views that were already hidden")
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
