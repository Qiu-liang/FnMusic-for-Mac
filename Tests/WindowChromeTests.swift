import AppKit
import SwiftUI
import XCTest
@testable import FnMusic

@MainActor
final class WindowChromeTests: XCTestCase {
    func testContentTopInsetAccountsForFullScreenSafeArea() {
        XCTAssertEqual(MusicPageChrome<EmptyView, EmptyView>.contentTopInset(toolbarStyle: .hidden, fullScreenTopInset: 0), 52)
        XCTAssertEqual(MusicPageChrome<EmptyView, EmptyView>.contentTopInset(toolbarStyle: .standard, fullScreenTopInset: 0), 52)
        XCTAssertEqual(MusicPageChrome<EmptyView, EmptyView>.contentTopInset(toolbarStyle: .artist, fullScreenTopInset: 0), 52)

        XCTAssertEqual(MusicPageChrome<EmptyView, EmptyView>.contentTopInset(toolbarStyle: .hidden, fullScreenTopInset: 52), 52)
        XCTAssertEqual(MusicPageChrome<EmptyView, EmptyView>.contentTopInset(toolbarStyle: .hidden, fullScreenTopInset: 64), 64)
        XCTAssertEqual(MusicPageChrome<EmptyView, EmptyView>.contentTopInset(toolbarStyle: .standard, fullScreenTopInset: 52), 104)
        XCTAssertEqual(MusicPageChrome<EmptyView, EmptyView>.contentTopInset(toolbarStyle: .artist, fullScreenTopInset: 52), 104)
        XCTAssertEqual(MusicPageChrome<EmptyView, EmptyView>.contentTopInset(toolbarStyle: .albumDetail, fullScreenTopInset: 52), 104)
        XCTAssertEqual(MusicPageChrome<EmptyView, EmptyView>.contentTopInset(toolbarStyle: .playlistDetail, fullScreenTopInset: 52), 104)
    }

    func testAppearanceMappingMapsLightDarkAndSystem() {
        XCTAssertEqual(FnMusicApp.nsAppearance(for: "light")?.name, .aqua)
        XCTAssertEqual(FnMusicApp.nsAppearance(for: "dark")?.name, .darkAqua)
        XCTAssertNil(FnMusicApp.nsAppearance(for: "system"))
        XCTAssertNil(FnMusicApp.nsAppearance(for: "unexpected"))
    }

    func testFullScreenTopInsetIsZeroOutsideFullScreen() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "WindowChromeTests")
        window.layoutIfNeeded()

        XCTAssertEqual(WindowTitlebarChrome.ChromeView.fullScreenTopInset(for: nil), 0)
        XCTAssertEqual(WindowTitlebarChrome.ChromeView.fullScreenTopInset(for: window), 0)
    }

    func testFullScreenNotificationsToggleIsFullScreenStateAndResetTopInset() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "FullScreenNotificationTest")

        var events: [(Bool, CGFloat)] = []
        let chrome = WindowTitlebarChrome.ChromeView()
        chrome.onMetricsChange = { fullScreen, inset in
            events.append((fullScreen, inset))
        }
        window.contentView = chrome
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(events.last?.0, false)
        XCTAssertEqual(events.last?.1, 0)
        XCTAssertTrue(window.delegate is FullScreenPresentationDelegateProxy)

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(events.last?.0, true)
        XCTAssertEqual(events.last?.1, 0)
        XCTAssertEqual(window.toolbar?.isVisible, true, "Full screen must keep native NSToolbar alive for native traffic lights")
        XCTAssertEqual(window.toolbarStyle, .unifiedCompact, "Full screen must switch to compact toolbar style")
        XCTAssertFalse(window.titlebarAppearsTransparent, "Full screen titlebar backing must be allowed for the hover bar")

        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(events.last?.0, false)
        XCTAssertEqual(events.last?.1, 0)
        XCTAssertEqual(window.toolbar?.isVisible, true)
        XCTAssertEqual(window.toolbarStyle, .unified, "Exiting full screen must restore the original toolbar style")
        XCTAssertTrue(window.titlebarAppearsTransparent, "Exiting full screen must restore transparent windowed titlebar")
    }

    func testSplitViewBackdropsAndTopScrollPocketsAreHiddenWhileBottomViewsRemainVisible() {
        final class NSTitlebarBackgroundView: NSView {}
        final class NSScrollPocket: NSView {}
        final class BackdropView: NSView {}

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let splitView = NSSplitView(frame: root.bounds)
        let sidebarStrip = NSTitlebarBackgroundView(frame: NSRect(x: 0, y: 568, width: 200, height: 32))
        let detailStrip = NSTitlebarBackgroundView(frame: NSRect(x: 200, y: 568, width: 600, height: 32))
        splitView.addSubview(sidebarStrip)
        splitView.addSubview(detailStrip)

        let scrollView = NSScrollView(frame: NSRect(x: 200, y: 0, width: 600, height: 600))
        // NSScrollView uses flipped coordinates, so y=0 sits at the top edge of root.
        let topPocket = NSScrollPocket(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        let topBackdrop = BackdropView(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        let bottomPocket = NSScrollPocket(frame: NSRect(x: 0, y: 568, width: 600, height: 32))
        scrollView.addSubview(topPocket)
        scrollView.addSubview(topBackdrop)
        scrollView.addSubview(bottomPocket)

        let chrome = WindowTitlebarChrome.ChromeView()
        root.addSubview(splitView)
        root.addSubview(scrollView)
        root.addSubview(chrome)

        window.contentView = root
        window.layoutIfNeeded()
        chrome.apply()

        XCTAssertTrue(sidebarStrip.isHidden, "Nested split-view sidebar titlebar strip must be hidden")
        XCTAssertTrue(detailStrip.isHidden, "Nested split-view detail titlebar strip must be hidden")
        XCTAssertTrue(topPocket.isHidden, "Top NSScrollPocket strip must be hidden")
        XCTAssertTrue(topBackdrop.isHidden, "Top NSScrollView BackdropView must be hidden")
        XCTAssertFalse(bottomPocket.isHidden, "Bottom scroll pockets must remain untouched")

        chrome.restore()
        XCTAssertFalse(sidebarStrip.isHidden)
        XCTAssertFalse(topPocket.isHidden)
    }

    func testDelegateProxyInjectsAutoHideToolbarAndForwardsCallbacks() {
        final class RecordingDelegate: NSObject, NSWindowDelegate {
            var didResizeCount = 0
            func windowDidResize(_ notification: Notification) {
                didResizeCount += 1
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let originalDelegate = RecordingDelegate()
        window.delegate = originalDelegate

        let chrome = WindowTitlebarChrome.ChromeView()
        window.contentView = chrome
        window.layoutIfNeeded()

        XCTAssertTrue(window.delegate is FullScreenPresentationDelegateProxy)
        let options = window.delegate?.window?(window, willUseFullScreenPresentationOptions: [.fullScreen])
        XCTAssertEqual(options?.contains(.fullScreen), true)
        XCTAssertEqual(options?.contains(.autoHideMenuBar), true)
        XCTAssertEqual(options?.contains(.autoHideToolbar), true)

        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        XCTAssertEqual(originalDelegate.didResizeCount, 1, "Proxy must forward unrelated NSWindowDelegate callbacks")

        chrome.restore()
        XCTAssertTrue(window.delegate === originalDelegate, "Restoring chrome must unwrap and restore the original delegate")
    }

    func testDetachedTitlebarWindowPreservesBackdropWhileWindowedChromeHidesIt() {
        final class NSTitlebarBackgroundView: NSView {}
        final class FakeToolbarView: NSView {}

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        let titlebar = NSView(frame: container.bounds)
        let backdrop = NSTitlebarBackgroundView(frame: container.bounds)
        let toolbarView = FakeToolbarView(frame: container.bounds)
        titlebar.addSubview(toolbarView)
        container.addSubview(backdrop)
        container.addSubview(titlebar)

        let chrome = WindowTitlebarChrome.ChromeView()
        chrome.apply(toTitlebar: titlebar, isDetachedTitlebarWindow: false)
        XCTAssertTrue(toolbarView.isHidden)
        XCTAssertTrue(backdrop.isHidden, "Windowed titlebar must hide backdrop")

        chrome.apply(toTitlebar: titlebar, isDetachedTitlebarWindow: true)
        XCTAssertTrue(toolbarView.isHidden, "Detached full-screen bar still hides toolbar content view")
        XCTAssertFalse(backdrop.isHidden, "Detached full-screen NSToolbarFullScreenWindow must keep its backdrop visible")
    }

    func testNestedChromeModifierDoesNotRestoreParentWindowChromeOnDismiss() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "NestedChromeTest")

        final class ChromeHostContainer: ObservableObject {
            @Published var showInner = true
        }

        struct OuterChromeHost: View {
            @ObservedObject var state: ChromeHostContainer
            var body: some View {
                ZStack {
                    Color.clear
                    if state.showInner {
                        Color.clear
                            .modifier(WindowTitlebarChromeModifier())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(WindowTitlebarChromeModifier())
            }
        }

        let state = ChromeHostContainer()
        let hosting = NSHostingView(rootView: OuterChromeHost(state: state))
        window.contentView = hosting
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let titlebar = window.standardWindowButton(.closeButton)?.superview,
              let container = titlebar.superview
        else {
            return XCTFail("Expected AppKit titlebar hierarchy")
        }

        func anyVisibleBackdropOrToolbar() -> Bool {
            let hiddenToolbar = titlebar.subviews.contains {
                WindowTitlebarChrome.ChromeView.isToolbarContent($0) && !$0.isHidden
            }
            let hiddenBackdrop = container.subviews.contains {
                WindowTitlebarChrome.ChromeView.isTitlebarBackdrop($0) && !$0.isHidden
            }
            return hiddenToolbar || hiddenBackdrop
        }

        XCTAssertFalse(anyVisibleBackdropOrToolbar(), "Window chrome must hide titlebar backdrops across non-lyrics pages")

        state.showInner = false
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertFalse(anyVisibleBackdropOrToolbar(), "Dismissing an inner view must not unhide outer window titlebar backdrops")
    }
}
