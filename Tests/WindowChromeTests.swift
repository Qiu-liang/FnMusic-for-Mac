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

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(events.last?.0, true)
        XCTAssertEqual(events.last?.1, 0)
        XCTAssertEqual(window.toolbar?.isVisible, false, "Full screen chrome must hide AppKit NSToolbar directly")

        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(events.last?.0, false)
        XCTAssertEqual(events.last?.1, 0)
        XCTAssertEqual(window.toolbar?.isVisible, true, "Exiting full screen must restore AppKit NSToolbar visibility")
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
