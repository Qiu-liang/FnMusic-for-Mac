import AppKit
import SwiftUI

private struct FullScreenTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct IsWindowFullScreenKey: EnvironmentKey {
    static let defaultValue = false
}

private struct WindowTitlebarChromeActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var fullScreenTopInset: CGFloat {
        get { self[FullScreenTopInsetKey.self] }
        set { self[FullScreenTopInsetKey.self] = newValue }
    }

    var isWindowFullScreen: Bool {
        get { self[IsWindowFullScreenKey.self] }
        set { self[IsWindowFullScreenKey.self] = newValue }
    }

    var windowTitlebarChromeActive: Bool {
        get { self[WindowTitlebarChromeActiveKey.self] }
        set { self[WindowTitlebarChromeActiveKey.self] = newValue }
    }
}

/// Applies `WindowTitlebarChrome` once at the window root (or falls back when a
/// child view like `RootView` or `NowPlayingView` is hosted standalone in tests)
/// and propagates `isWindowFullScreen` / `fullScreenTopInset` down the tree.
struct WindowTitlebarChromeModifier: ViewModifier {
    @Environment(\.windowTitlebarChromeActive) private var alreadyActive
    @State private var isFullScreen = false
    @State private var fullScreenTopInset: CGFloat = 0

    func body(content: Content) -> some View {
        if alreadyActive {
            content
        } else {
            content
                .environment(\.windowTitlebarChromeActive, true)
                .environment(\.isWindowFullScreen, isFullScreen)
                .environment(\.fullScreenTopInset, fullScreenTopInset)
                .background(
                    WindowTitlebarChrome { fullScreen, topInset in
                        if isFullScreen != fullScreen {
                            isFullScreen = fullScreen
                        }
                        if fullScreenTopInset != topInset {
                            fullScreenTopInset = topInset
                        }
                    }
                    .allowsHitTesting(false)
                )
        }
    }
}

/// Keeps the window toolbar enabled in windowed mode so AppKit keeps standard
/// window buttons (traffic lights) alive, while hiding the toolbar's *content
/// view* and the split-view titlebar background / decoration siblings inside
/// `NSTitlebarContainerView` (which in macOS full screen otherwise render an
/// opaque white / frosted bar across the top of the screen).
struct WindowTitlebarChrome: NSViewRepresentable {
    var onMetricsChange: ((Bool, CGFloat) -> Void)?

    init(onMetricsChange: ((Bool, CGFloat) -> Void)? = nil) {
        self.onMetricsChange = onMetricsChange
    }

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.onMetricsChange = onMetricsChange
        return view
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {
        nsView.onMetricsChange = onMetricsChange
        nsView.apply()
    }

    static func dismantleNSView(_ nsView: ChromeView, coordinator: ()) {
        nsView.restore()
    }

    final class ChromeView: NSView {
        var onMetricsChange: ((Bool, CGFloat) -> Void)?
        private weak var observedWindow: NSWindow?
        private var hiddenViews = NSHashTable<NSView>.weakObjects()
        private var pendingFullScreenTransition: Bool?
        private var lastReportedFullScreen: Bool?
        private var lastReportedTopInset: CGFloat?

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Never take clicks: the SwiftUI window owns hit testing.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if observedWindow !== window {
                restore()
                unregisterWindowObservers()
                pendingFullScreenTransition = nil
                observedWindow = window
                if let window {
                    registerWindowObservers(for: window)
                }
            }
            if window != nil {
                apply()
            } else {
                reportMetricsIfNeeded()
            }
        }

        override func layout() {
            super.layout()
            if window != nil {
                apply()
            }
        }

        /// Idempotent: called on every SwiftUI update, layout pass, and
        /// full-screen transition so AppKit cannot re-expose the toolbar or
        /// split-view titlebar strip.
        func apply() {
            reportMetricsIfNeeded()
            guard let window, let titlebar = window.standardWindowButton(.closeButton)?.superview else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            if let titlebarWindow = titlebar.window, titlebarWindow !== window {
                titlebarWindow.isOpaque = false
                titlebarWindow.backgroundColor = .clear
                titlebarWindow.appearance = window.effectiveAppearance
            }
            apply(toTitlebar: titlebar)
        }

        func apply(toTitlebar titlebar: NSView) {
            hideMatchingSubviews(in: titlebar, matching: Self.isToolbarContent)
            if let container = titlebar.superview {
                hideMatchingSubviews(in: container, matching: Self.isTitlebarBackdrop)
            }
        }

        func restore() {
            for view in hiddenViews.allObjects where view.isHidden {
                view.isHidden = false
            }
            hiddenViews.removeAllObjects()
        }

        static func fullScreenTopInset(for window: NSWindow?) -> CGFloat {
            guard let window, window.styleMask.contains(.fullScreen) else { return 0 }
            // When the window toolbar is visible in full screen, AppKit pins a
            // 52 pt NSToolbarFullScreenWindow over the top of the screen; when
            // hidden (the normal full-screen state), the menu bar auto-hides
            // offscreen (`safeAreaInsets.top == 0`) unless the user has disabled
            // menu-bar auto-hide in System Settings.
            return max(0, window.contentView?.safeAreaInsets.top ?? 0)
        }

        private func reportMetricsIfNeeded() {
            guard let onMetricsChange else { return }
            let isFullScreen = pendingFullScreenTransition ?? (window?.styleMask.contains(.fullScreen) ?? false)
            let topInset = Self.fullScreenTopInset(for: window)
            guard lastReportedFullScreen != isFullScreen || lastReportedTopInset != topInset else { return }
            lastReportedFullScreen = isFullScreen
            lastReportedTopInset = topInset
            Task { @MainActor [weak self] in
                guard self != nil else { return }
                onMetricsChange(isFullScreen, topInset)
            }
        }

        /// Assigned only on change: this runs for every page update and AppKit
        /// work belongs to actual changes.
        private func hideMatchingSubviews(in root: NSView, matching predicate: (NSView) -> Bool) {
            for subview in root.subviews where predicate(subview) {
                if !subview.isHidden {
                    subview.isHidden = true
                    hiddenViews.add(subview)
                }
            }
        }

        private func registerWindowObservers(for window: NSWindow) {
            let center = NotificationCenter.default
            for name in [
                NSWindow.willEnterFullScreenNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.willExitFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ] {
                center.addObserver(
                    self,
                    selector: #selector(handleFullScreenNotification(_:)),
                    name: name,
                    object: window
                )
            }
        }

        private func unregisterWindowObservers() {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func handleFullScreenNotification(_ notification: Notification) {
            switch notification.name {
            case NSWindow.willEnterFullScreenNotification:
                pendingFullScreenTransition = true
            case NSWindow.willExitFullScreenNotification:
                pendingFullScreenTransition = false
            case NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification:
                pendingFullScreenTransition = nil
            default:
                break
            }
            apply()
            Task { @MainActor [weak self] in
                self?.apply()
            }
        }

        static func isToolbarContent(_ view: NSView) -> Bool {
            String(describing: type(of: view)).hasSuffix("ToolbarView")
        }

        static func isTitlebarBackdrop(_ view: NSView) -> Bool {
            let name = String(describing: type(of: view))
            return name == "NSTitlebarBackgroundView"
                || name == "_NSTitlebarDecorationView"
                || name == "NSTitlebarContainerBlockingView"
        }
    }
}

typealias NowPlayingWindowChrome = WindowTitlebarChrome
