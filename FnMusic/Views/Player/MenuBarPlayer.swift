import AppKit
import SwiftUI

/// Presentation rules for the menu bar player. Kept free of AppKit so the
/// lyric/title/state decisions are unit testable without a status bar.
enum MenuBarNowPlaying {
    static let idleText = "未在播放"

    /// The lyric line that owns the given playback position, if the lyric set
    /// is time stamped. Blank lines count as "no lyric" so the bar keeps
    /// showing something useful between verses.
    static func lyricText(parsed: ParsedLyrics, elapsed: Double) -> String? {
        guard parsed.isTimed,
              let index = parsed.currentIndex(at: elapsed),
              parsed.lines.indices.contains(index) else { return nil }
        let text = parsed.lines[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Menu bar text: the current lyric line when available, otherwise the
    /// track title. Plain (untimed) lyrics deliberately fall back to the title
    /// because they have no position to follow.
    static func displayText(track: Track?, parsed: ParsedLyrics, elapsed: Double) -> String {
        guard let track else { return idleText }
        return lyricText(parsed: parsed, elapsed: elapsed) ?? track.displayTitle
    }

    static func symbol(isPlaying: Bool) -> String {
        isPlaying ? "pause.fill" : "play.fill"
    }

    static func tooltip(track: Track?) -> String {
        guard let track else { return "FnMusic" }
        return "\(track.displayTitle) — \(track.artistText)"
    }

    static func accessibilityLabel(track: Track?, text: String) -> String {
        guard let track else { return "FnMusic 菜单栏播放器" }
        return "\(track.displayTitle)，\(text)"
    }
}

/// Fixed geometry for the status item. The item never changes length while a
/// lyric plays (a length change makes the whole item jump); the visible width is
/// a user setting, and lyrics wider than it scroll inside the column.
enum MenuBarBarLayout {
    static let defaultColumnWidth: CGFloat = 200
    static let minColumnWidth: CGFloat = 80
    static let maxColumnWidth: CGFloat = 360
    static let controlWidth: CGFloat = 20
    static let controlHeight: CGFloat = 18
    static let spacing: CGFloat = 2
    static let horizontalPadding: CGFloat = 5
    static let height: CGFloat = 22
    /// Slack so SwiftUI never clips a string measured with AppKit metrics.
    static let textSlack: CGFloat = 3

    /// Marquee behaviour for lyrics wider than the column.
    static let scrollGap: CGFloat = 40
    static let scrollSpeed: CGFloat = 24
    static let scrollPause: TimeInterval = 0.8
    static let frameInterval: TimeInterval = 1.0 / 15.0

    static func columnWidth(_ stored: Double?) -> CGFloat {
        guard let stored, stored.isFinite, stored > 0 else { return defaultColumnWidth }
        return min(maxColumnWidth, max(minColumnWidth, CGFloat(stored)))
    }

    static var controlsWidth: CGFloat { 3 * controlWidth + 2 * spacing }
    static func previousMinX(columnWidth: CGFloat) -> CGFloat {
        horizontalPadding + columnWidth + spacing
    }
    static func toggleMinX(columnWidth: CGFloat) -> CGFloat {
        previousMinX(columnWidth: columnWidth) + controlWidth + spacing
    }
    static func nextMinX(columnWidth: CGFloat) -> CGFloat {
        toggleMinX(columnWidth: columnWidth) + controlWidth + spacing
    }
    static func statusLength(columnWidth: CGFloat) -> CGFloat {
        nextMinX(columnWidth: columnWidth) + controlWidth + horizontalPadding
    }

    enum Zone: Equatable {
        /// Inside the item but left of the drawn lyric text: no action.
        case none, text, previous, toggle, next
    }

    static func naturalTextWidth(for text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + textSlack
    }

    static func columnTextWidth(for text: String, columnWidth: CGFloat) -> CGFloat {
        min(columnWidth, naturalTextWidth(for: text))
    }

    static func needsScroll(for text: String, columnWidth: CGFloat) -> Bool {
        naturalTextWidth(for: text) > columnWidth + 0.5
    }

    /// Left edge of the drawn text when it fits the column; a scrolling line
    /// fills the column from its left padding.
    static func textStartX(for text: String, columnWidth: CGFloat) -> CGFloat {
        max(horizontalPadding,
            previousMinX(columnWidth: columnWidth) - spacing
            - columnTextWidth(for: text, columnWidth: columnWidth))
    }

    /// Right-most control wins on shared boundaries so every control keeps a
    /// full-width target.
    static func zone(atX x: CGFloat, text: String, columnWidth: CGFloat) -> Zone {
        if x >= nextMinX(columnWidth: columnWidth) { return .next }
        if x >= toggleMinX(columnWidth: columnWidth) { return .toggle }
        if x >= previousMinX(columnWidth: columnWidth) { return .previous }
        if x >= textStartX(for: text, columnWidth: columnWidth) { return .text }
        return .none
    }

    static func centerX(of zone: Zone, text: String, columnWidth: CGFloat) -> CGFloat {
        switch zone {
        case .none: textStartX(for: text, columnWidth: columnWidth) / 2
        case .text: (textStartX(for: text, columnWidth: columnWidth)
                     + previousMinX(columnWidth: columnWidth)) / 2
        case .previous: previousMinX(columnWidth: columnWidth) + controlWidth / 2
        case .toggle: toggleMinX(columnWidth: columnWidth) + controlWidth / 2
        case .next: nextMinX(columnWidth: columnWidth) + controlWidth / 2
        }
    }

    // MARK: Marquee timing

    /// One pass plus the gap, in points.
    static func cycleLength(forTextWidth width: CGFloat) -> CGFloat { width + scrollGap }

    /// Seconds for one pass plus the gap, including the leading pause.
    static func cycleDuration(forTextWidth width: CGFloat) -> TimeInterval {
        scrollPause + TimeInterval(cycleLength(forTextWidth: width) / scrollSpeed)
    }

    /// Horizontal offset for a scrolling line: it rests at the start for
    /// `scrollPause`, then slides left and wraps seamlessly after one cycle.
    static func textOffset(after elapsed: TimeInterval, textWidth: CGFloat) -> CGFloat {
        guard textWidth > 0 else { return 0 }
        let cycle = TimeInterval(cycleLength(forTextWidth: textWidth) / scrollSpeed)
        guard cycle > 0 else { return 0 }
        let position = elapsed.truncatingRemainder(dividingBy: scrollPause + cycle)
        guard position > scrollPause else { return 0 }
        return scrollSpeed * CGFloat(position - scrollPause)
    }
}

/// The lyric text rasterised at its natural width, in the menu bar's ink color.
struct MenuBarLyricStrip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(tint)
            .frame(height: MenuBarBarLayout.height)
    }
}

/// The three transport glyphs as a fixed strip.
struct MenuBarControlsStrip: View {
    let isPlaying: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: MenuBarBarLayout.spacing) {
            symbol("backward.fill")
            symbol(MenuBarNowPlaying.symbol(isPlaying: isPlaying))
            symbol("forward.fill")
        }
        .foregroundStyle(tint)
        .frame(width: MenuBarBarLayout.controlsWidth, height: MenuBarBarLayout.height)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 10.5, weight: .semibold))
            .frame(width: MenuBarBarLayout.controlWidth, height: MenuBarBarLayout.controlHeight)
    }
}

/// Draws the bar into the status item. A drawing-only view keeps clicks going
/// to the status button (see `hitTest`), so it never has to handle events.
final class MenuBarCanvasView: NSView {
    struct Content {
        var text: CGImage?
        var controls: CGImage?
        var textWidth: CGFloat = 0
        var columnWidth: CGFloat = MenuBarBarLayout.defaultColumnWidth
        var hasTrack: Bool = true
        var offset: CGFloat?
    }

    var content = Content()
    var onAppearanceChange: (@MainActor () -> Void)?

    override var isOpaque: Bool { false }

    /// Clicks must fall through to `NSStatusBarButton`, whose action routes
    /// them to the transport controls by x position.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        MenuBarRenderer.draw(content, in: context, bounds: bounds)
    }
}

enum MenuBarRenderer {
    static func draw(_ content: MenuBarCanvasView.Content, in context: CGContext, bounds: CGRect) {
        context.setAlpha(content.hasTrack ? 1 : 0.55)

        if let text = content.text, content.textWidth > 0 {
            let column = CGRect(x: MenuBarBarLayout.horizontalPadding, y: 0,
                                width: content.columnWidth, height: bounds.height)
            context.saveGState()
            context.clip(to: column)
            if let offset = content.offset {
                let cycle = content.textWidth + MenuBarBarLayout.scrollGap
                var x = column.minX - offset
                while x < column.maxX {
                    context.draw(text, in: CGRect(x: x, y: 0, width: content.textWidth, height: bounds.height))
                    x += cycle
                }
            } else {
                context.draw(text, in: CGRect(x: column.maxX - content.textWidth, y: 0,
                                              width: content.textWidth, height: bounds.height))
            }
            context.restoreGState()
        }

        if let controls = content.controls {
            context.draw(controls, in: CGRect(x: MenuBarBarLayout.previousMinX(columnWidth: content.columnWidth),
                                              y: 0, width: MenuBarBarLayout.controlsWidth,
                                              height: bounds.height))
        }
    }
}

/// Owns the status item that shows lyrics and transport controls in the menu
/// bar. The item is created once; its canvas redraws in place, so scrolling
/// lyrics never resize the item or re-lay out the menu bar.
@MainActor
final class MenuBarPlayerController: NSObject {
    static let enabledKey = "menuBarPlayer"
    static let widthKey = "menuBarLyricWidth"
    static let scale: CGFloat = 2

    private var statusItem: NSStatusItem?
    private var canvas: MenuBarCanvasView?
    private var app: AppState?
    private var defaultsObserver: NSObjectProtocol?

    private var textImage: CGImage?
    private var controlsImage: CGImage?
    private var textWidth: CGFloat = 0
    private var columnWidth = MenuBarBarLayout.defaultColumnWidth
    private var isScrolling = false
    private var scrollStart: TimeInterval = 0
    private var scrollTimer: Timer?

    // Last rendered inputs: avoids re-rasterising at playback's 4 Hz cadence.
    private var displayedText: String?
    private var displayedPlaying: Bool?
    private var displayedHasTrack: Bool?
    /// What the canvas currently shows. AppKit calls
    /// `viewDidChangeEffectiveAppearance` on every display pass and the status
    /// bar even alternates between vibrant and plain dark appearances, so the
    /// key uses the resolved ink color: equal keys never reset the marquee.
    private var renderedKey: RenderKey?

    struct RenderKey: Equatable {
        let text: String
        let isPlaying: Bool
        let hasTrack: Bool
        let isDarkInk: Bool
        let columnWidth: CGFloat
    }

    private var loadedLyricsGUID: String?
    private var lyricsLoad: Task<Void, Never>?

    var isInstalled: Bool { statusItem != nil }

    /// Whether the item should be visible at all. Pure so the policy stays
    /// testable: an explicit opt-out always wins over a playing track.
    static func shouldShow(enabled: Bool, hasTrack: Bool) -> Bool { enabled && hasTrack }

    func start(app: AppState) {
        self.app = app
        guard statusItem == nil else {
            update()
            return
        }
        guard !Self.isRunningTests else { return }

        columnWidth = Self.storedColumnWidth()
        let item = NSStatusBar.system.statusItem(withLength: MenuBarBarLayout.statusLength(columnWidth: columnWidth))
        let canvas = MenuBarCanvasView(frame: NSRect(x: 0, y: 0,
                                                     width: MenuBarBarLayout.statusLength(columnWidth: columnWidth),
                                                     height: NSStatusBar.system.thickness))
        canvas.autoresizingMask = [.width, .height]
        canvas.onAppearanceChange = { [weak self] in self?.appearanceChanged() }
        item.button?.addSubview(canvas)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: .leftMouseUp)
        statusItem = item
        self.canvas = canvas

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update() }
        }
        update()
        observePlayback()
    }

    func stop() {
        stopScrolling()
        lyricsLoad?.cancel()
        lyricsLoad = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        canvas = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        app = nil
    }

    static func storedColumnWidth() -> CGFloat {
        MenuBarBarLayout.columnWidth(UserDefaults.standard.object(forKey: widthKey) as? Double)
    }

    /// A status item click is one button; the x position selects the control.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let point = sender.convert(event.locationInWindow, from: nil)
        switch MenuBarBarLayout.zone(atX: point.x, text: displayedText ?? "", columnWidth: columnWidth) {
        case .previous: app?.library?.player.previous()
        case .toggle: app?.library?.player.toggle()
        case .next: app?.library?.player.next()
        case .text: Self.revealMainWindow()
        case .none: break
        }
    }

    private static func revealMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Observation drives the canvas; elapsed time is tracked so the lyric line
    /// advances without a timer, but identical text skips redraws.
    private func observePlayback() {
        guard let app else { return }
        withObservationTracking {
            _ = app.library?.player.currentTrack?.guid
            _ = app.library?.player.isPlaying
            _ = app.library?.player.elapsed
            _ = app.library?.menuBarLyrics.parsed.lines
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.update()
                self.observePlayback()
            }
        }
    }

    private func update() {
        guard let app, let statusItem else { return }
        let player = app.library?.player
        let track = player?.currentTrack
        let lyrics = app.library?.menuBarLyrics

        let storedWidth = Self.storedColumnWidth()
        if storedWidth != columnWidth {
            columnWidth = storedWidth
            let length = MenuBarBarLayout.statusLength(columnWidth: columnWidth)
            if statusItem.length != length { statusItem.length = length }
            renderedKey = nil   // force a rebuild at the new width
        }

        let enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        let visible = Self.shouldShow(enabled: enabled, hasTrack: track != nil)
        if statusItem.isVisible != visible { statusItem.isVisible = visible }

        if loadedLyricsGUID != track?.guid {
            loadedLyricsGUID = track?.guid
            lyricsLoad?.cancel()
            // Never return early here: logging out must still clear tooltips,
            // stale lyric text and the scroll timer.
            if let lyrics {
                lyricsLoad = Task { await lyrics.load(trackGUID: track?.guid) }
            }
        }

        let text = MenuBarNowPlaying.displayText(
            track: track,
            parsed: lyrics?.parsed ?? ParsedLyrics(lines: []),
            elapsed: player?.elapsed ?? 0)
        let isPlaying = player?.isPlaying ?? false
        let hasTrack = track != nil
        if let button = statusItem.button {
            button.toolTip = MenuBarNowPlaying.tooltip(track: track)
            button.setAccessibilityLabel(MenuBarNowPlaying.accessibilityLabel(track: track, text: text))
        }

        // No early return on "nothing changed": a column-width change keeps
        // text/playback equal but must still repaint and re-aim the hit zones.
        displayedText = text
        displayedPlaying = isPlaying
        displayedHasTrack = hasTrack
        rebuildContent(text: text, isPlaying: isPlaying, hasTrack: hasTrack, visible: visible)
    }

    private func appearanceChanged() {
        guard let text = displayedText, let isPlaying = displayedPlaying,
              let hasTrack = displayedHasTrack else { return }
        rebuildContent(text: text, isPlaying: isPlaying, hasTrack: hasTrack,
                       visible: statusItem?.isVisible ?? false)
    }

    private func rebuildContent(text: String, isPlaying: Bool, hasTrack: Bool, visible: Bool) {
        guard let canvas else { return }
        let isDarkInk = Self.isDarkInk(canvas.effectiveAppearance)
        let key = RenderKey(text: text, isPlaying: isPlaying, hasTrack: hasTrack,
                            isDarkInk: isDarkInk, columnWidth: columnWidth)
        guard key != renderedKey else {
            updateScrolling(visible: visible)
            return
        }
        // A new line or width restarts the marquee from its resting offset;
        // a play-state or appearance change keeps the line where it is.
        let restart = Self.restartsScroll(previous: renderedKey, text: text, columnWidth: columnWidth)
        let preservedOffset = canvas.content.offset
        renderedKey = key
        let tint: Color = isDarkInk ? .white : .black
        guard let lyric = Self.raster(MenuBarLyricStrip(text: text, tint: tint)),
              let controls = Self.raster(MenuBarControlsStrip(isPlaying: isPlaying, tint: tint)) else { return }
        textImage = lyric
        controlsImage = controls
        textWidth = CGFloat(lyric.width) / Self.scale
        isScrolling = textWidth > columnWidth + 0.5
        if restart { scrollStart = ProcessInfo.processInfo.systemUptime }
        canvas.content = MenuBarCanvasView.Content(
            text: lyric, controls: controls, textWidth: textWidth,
            columnWidth: columnWidth, hasTrack: hasTrack,
            offset: isScrolling ? (restart ? 0 : preservedOffset) : nil)
        canvas.needsDisplay = true
        updateScrolling(visible: visible)
    }

    /// A new lyric line (or a new column width) starts the marquee over; only
    /// then does the rest-pause apply again. Other redraws resume in place.
    static func restartsScroll(previous: RenderKey?, text: String, columnWidth: CGFloat) -> Bool {
        guard let previous else { return true }
        return previous.text != text || previous.columnWidth != columnWidth
    }

    private func updateScrolling(visible: Bool) {
        if isScrolling, visible { startScrolling() } else { stopScrolling() }
    }

    private func startScrolling() {
        guard scrollTimer == nil else { return }
        // Resuming after a hidden item must continue where the line stopped,
        // not restart the pass or skip the head of the line.
        let now = ProcessInfo.processInfo.systemUptime
        let offset = canvas?.content.offset ?? 0
        scrollStart = offset > 0
            ? now - (MenuBarBarLayout.scrollPause + TimeInterval(offset / MenuBarBarLayout.scrollSpeed))
            : now
        let timer = Timer(timeInterval: MenuBarBarLayout.frameInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advanceScroll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
    }

    private func stopScrolling() {
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    private func advanceScroll() {
        guard isScrolling, statusItem?.isVisible == true, let canvas else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - scrollStart
        canvas.content.offset = MenuBarBarLayout.textOffset(after: elapsed, textWidth: textWidth)
        canvas.needsDisplay = true
    }

    // MARK: Rendering helpers

    /// Menu bar ink: dark text on a light bar, light text on a dark bar.
    /// Resolved through `bestMatch` so vibrant variants map to the same ink.
    static func isDarkInk(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func inkColor(for appearance: NSAppearance) -> Color {
        isDarkInk(appearance) ? .white : .black
    }

    static func raster<V: View>(_ view: V) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }

    private static var isRunningTests: Bool {
        #if DEBUG
        // Hosted tests would otherwise leave a real status item behind and
        // touch the developer's live menu bar.
        return NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        return false
        #endif
    }
}
