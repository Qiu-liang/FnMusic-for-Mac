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

extension Notification.Name {
    static let windowTitlebarChromeNeedsApply = Notification.Name("FnMusic.WindowTitlebarChromeNeedsApply")
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

/// Forwards all `NSWindowDelegate` calls to SwiftUI's existing delegate while
/// adding `.autoHideMenuBar` and `.autoHideToolbar` so AppKit auto-hides the
/// native full-screen titlebar & traffic lights at rest and slides them down
/// over the app on pointer hover without pushing layout down.
final class FullScreenPresentationDelegateProxy: NSObject, NSWindowDelegate {
    nonisolated(unsafe) weak var wrappedDelegate: (any NSWindowDelegate)?

    init(wrappedDelegate: (any NSWindowDelegate)?) {
        self.wrappedDelegate = wrappedDelegate
        super.init()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (wrappedDelegate?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        wrappedDelegate
    }

    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []
    ) -> NSApplication.PresentationOptions {
        let base = wrappedDelegate?.window?(
            window,
            willUseFullScreenPresentationOptions: proposedOptions
        ) ?? proposedOptions
        return [base, .fullScreen, .autoHideMenuBar, .autoHideToolbar]
    }
}

/// Keeps the native AppKit toolbar and traffic lights alive in both windowed
/// and full-screen modes:
/// - Windowed: keeps a transparent `52 pt` titlebar and hides split-view /
///   scroll-edge backdrop strips inside `window.contentView` and `titlebar`.
/// - Full screen: injects `.autoHideToolbar` so macOS hides the native
///   `NSToolbarFullScreenWindow` offscreen (`fullScreenTopInset == 0`) while
///   keeping `titlebarWindow !== window` backed by a compact `.unifiedCompact`
///   native white/adaptive strip + real traffic lights on hover.
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
        nsView.scheduleDeferredApply()
    }

    static func dismantleNSView(_ nsView: ChromeView, coordinator: ()) {
        nsView.restore()
    }

    final class ChromeView: NSView {
        var onMetricsChange: ((Bool, CGFloat) -> Void)?
        private weak var observedWindow: NSWindow?
        private var hiddenViews = NSHashTable<NSView>.weakObjects()
        private var pendingFullScreenTransition: Bool?
        private var savedWindowedToolbarStyle: NSWindow.ToolbarStyle?
        private var delegateProxy: FullScreenPresentationDelegateProxy?
        private var lastReportedFullScreen: Bool?
        private var lastReportedTopInset: CGFloat?
        private var deferredApplyScheduled = false

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
                scheduleDeferredApply()
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

        /// Idempotent: called on every SwiftUI update, layout pass, navigation
        /// change, and full-screen transition.
        func apply() {
            let isFullScreen = effectiveFullScreen
            if let window {
                installDelegateProxyIfNeeded(on: window)
                syncFullScreenToolbarAppearance(in: window, isFullScreen: isFullScreen)
            }
            reportMetricsIfNeeded()

            guard let window else { return }
            window.titleVisibility = .hidden

            if let contentView = window.contentView {
                hideContentBackdrops(in: contentView, rootContentView: contentView)
            }

            guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return }
            let isDetachedTitlebarWindow = (titlebar.window != nil && titlebar.window !== window)
            if isDetachedTitlebarWindow, let titlebarWindow = titlebar.window {
                titlebarWindow.appearance = window.effectiveAppearance
            }
            apply(toTitlebar: titlebar, isDetachedTitlebarWindow: isDetachedTitlebarWindow)
        }

        func scheduleDeferredApply() {
            guard !deferredApplyScheduled, window != nil else { return }
            deferredApplyScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.deferredApplyScheduled = false
                if self.window != nil {
                    self.apply()
                }
            }
        }

        func apply(toTitlebar titlebar: NSView) {
            apply(toTitlebar: titlebar, isDetachedTitlebarWindow: false)
        }

        func apply(toTitlebar titlebar: NSView, isDetachedTitlebarWindow: Bool) {
            hideMatchingSubviews(in: titlebar, matching: Self.isToolbarContent)
            if let container = titlebar.superview {
                if isDetachedTitlebarWindow {
                    unhideTrackedBackdrops(in: container)
                } else {
                    hideMatchingSubviews(in: container, matching: Self.isTitlebarBackdrop)
                }
            }
        }

        func restore() {
            for view in hiddenViews.allObjects where view.isHidden {
                view.isHidden = false
            }
            hiddenViews.removeAllObjects()

            if let window = observedWindow {
                if let saved = savedWindowedToolbarStyle, window.toolbarStyle != saved {
                    window.toolbarStyle = saved
                }
                savedWindowedToolbarStyle = nil
                if !window.titlebarAppearsTransparent {
                    window.titlebarAppearsTransparent = true
                }
                if let proxy = delegateProxy, window.delegate === proxy {
                    window.delegate = proxy.wrappedDelegate
                }
            } else {
                savedWindowedToolbarStyle = nil
            }
            delegateProxy = nil
        }

        static func fullScreenTopInset(for window: NSWindow?) -> CGFloat {
            guard let window, window.styleMask.contains(.fullScreen) else { return 0 }
            // When our auto-hide proxy governs full-screen presentation, AppKit
            // hides NSToolbarFullScreenWindow offscreen at rest and slides it
            // over the top on hover without pushing down app layout.
            if window.delegate is FullScreenPresentationDelegateProxy {
                return 0
            }
            if window.toolbar?.isVisible == true {
                return max(0, window.contentView?.safeAreaInsets.top ?? 0)
            }
            return 0
        }

        private var effectiveFullScreen: Bool {
            pendingFullScreenTransition ?? (window?.styleMask.contains(.fullScreen) ?? false)
        }

        private func installDelegateProxyIfNeeded(on window: NSWindow) {
            if let existingProxy = delegateProxy, window.delegate === existingProxy {
                return
            }
            let currentDelegate = window.delegate
            if let alreadyProxy = currentDelegate as? FullScreenPresentationDelegateProxy {
                delegateProxy = alreadyProxy
                return
            }
            let proxy = FullScreenPresentationDelegateProxy(wrappedDelegate: currentDelegate)
            delegateProxy = proxy
            window.delegate = proxy
        }

        private func syncFullScreenToolbarAppearance(in window: NSWindow, isFullScreen: Bool) {
            if isFullScreen {
                if savedWindowedToolbarStyle == nil {
                    savedWindowedToolbarStyle = window.toolbarStyle
                }
                if window.toolbarStyle != .unifiedCompact {
                    window.toolbarStyle = .unifiedCompact
                }
                if window.titlebarAppearsTransparent {
                    window.titlebarAppearsTransparent = false
                }
            } else {
                if let saved = savedWindowedToolbarStyle {
                    if window.toolbarStyle != saved {
                        window.toolbarStyle = saved
                    }
                    savedWindowedToolbarStyle = nil
                }
                if !window.titlebarAppearsTransparent {
                    window.titlebarAppearsTransparent = true
                }
            }
        }

        private func reportMetricsIfNeeded() {
            guard let onMetricsChange else { return }
            let isFullScreen = effectiveFullScreen
            let topInset = Self.fullScreenTopInset(for: window)
            guard lastReportedFullScreen != isFullScreen || lastReportedTopInset != topInset else { return }
            lastReportedFullScreen = isFullScreen
            lastReportedTopInset = topInset
            Task { @MainActor [weak self] in
                guard self != nil else { return }
                onMetricsChange(isFullScreen, topInset)
            }
        }

        private func hideContentBackdrops(in view: NSView, rootContentView: NSView) {
            for subview in view.subviews {
                if Self.isTitlebarBackdrop(subview) || Self.isTopScrollPocket(subview, in: rootContentView) {
                    if !subview.isHidden {
                        subview.isHidden = true
                        hiddenViews.add(subview)
                    }
                }
                hideContentBackdrops(in: subview, rootContentView: rootContentView)
            }
        }

        private func unhideTrackedBackdrops(in root: NSView) {
            for subview in root.subviews where Self.isTitlebarBackdrop(subview) {
                if hiddenViews.contains(subview) {
                    if subview.isHidden {
                        subview.isHidden = false
                    }
                    hiddenViews.remove(subview)
                }
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
            center.addObserver(
                self,
                selector: #selector(handleChromeNeedsApply(_:)),
                name: .windowTitlebarChromeNeedsApply,
                object: nil
            )
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
            scheduleDeferredApply()
        }

        @objc private func handleChromeNeedsApply(_ notification: Notification) {
            apply()
            scheduleDeferredApply()
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

        static func isTopScrollPocket(_ view: NSView, in contentView: NSView) -> Bool {
            let name = String(describing: type(of: view))
            guard name == "NSScrollPocket" || (name == "BackdropView" && view.superview is NSScrollView) else {
                return false
            }
            guard view.bounds.height > 0, view.bounds.height <= 96, contentView.bounds.height > 0 else {
                return false
            }
            let frameInContent = view.convert(view.bounds, to: contentView)
            if contentView.isFlipped {
                return frameInContent.minY <= 2 && frameInContent.height <= 96
            }
            return frameInContent.maxY >= contentView.bounds.height - 2 && frameInContent.height <= 96
        }
    }
}

typealias NowPlayingWindowChrome = WindowTitlebarChrome
