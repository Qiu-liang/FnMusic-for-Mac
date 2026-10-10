import AppKit
import SwiftUI

/// Keeps a fixed-width column stable when macOS changes legacy scroller gutters
/// after a window/theme transition. This uses public NSScrollView behavior; it
/// does not hide scrolling or alter the user's global system preferences.
struct OverlayScrollIndicators: NSViewRepresentable {
    func makeNSView(context: Context) -> Bridge { Bridge(frame: .zero) }
    func updateNSView(_ view: Bridge, context: Context) { view.apply() }

    final class Bridge: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { return nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        override func layout() { super.layout(); apply() }

        func apply() {
            guard let scroll = enclosingScrollView else { return }
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
        }
    }
}

/// Disables the native horizontal scroller while leaving horizontal scrolling
/// gestures intact. SwiftUI's scrollIndicators modifier alone does not hide the
/// AppKit scroller in every macOS configuration.
struct HideHorizontalScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> Bridge { Bridge(frame: .zero) }
    func updateNSView(_ view: Bridge, context: Context) { view.apply() }

    final class Bridge: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { return nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        override func layout() { super.layout(); apply() }

        func apply() {
            guard let scroll = enclosingScrollView else { return }
            if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
            if let scroller = scroll.horizontalScroller, !scroller.isHidden { scroller.isHidden = true }
        }
    }
}
