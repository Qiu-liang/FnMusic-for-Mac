import AppKit
import CoreGraphics
import SwiftUI

/// Layout math for the immersive page. Kept pure so window-size behavior can
/// be checked without hosting SwiftUI.
enum NowPlayingMetrics {
    static let minimumArtwork: CGFloat = 200
    static let maximumArtwork: CGFloat = 720
    static let maximumPaneWidth: CGFloat = 780
    static let leadingRatio: CGFloat = 0.11
    static let paneLeadingRatio: CGFloat = 0.508
    static let trailingRatio: CGFloat = 0.05
    static let pausedArtworkScale: CGFloat = 0.73
    static let topBarEdgeInset: CGFloat = 18
    /// Height of the floating top-bar glass capsules (32 pt buttons + 3 pt padding).
    static let topBarControlHeight: CGFloat = 38
    /// Standard gap between the full-screen reserved strip and the floating chrome.
    static let topBarTopInset: CGFloat = 13
    /// Height of the floating chrome row itself, matching `PageToolbarMetrics.height`.
    static let topBarHeight: CGFloat = 52
    /// Vertical center of the standard macOS traffic-light cluster (`y = 19...33`).
    static let windowButtonCenterY: CGFloat = 26

    /// In full screen AppKit reserves the top of the window for the auto-hiding
    /// title/toolbar strip and installs an input-taking `NSToolbarFullScreenWindow`
    /// over it. The immersive page ignores the safe area for its full-bleed
    /// background, so anything it draws at the very top is visible but never
    /// receives a click. The reserved strip is published as the window's top
    /// safe-area inset (52 pt on current macOS with a hidden toolbar), so the
    /// floating chrome dodges it whenever the window is full screen.
    static func reservedTop(isFullScreen: Bool, safeAreaTop: CGFloat) -> CGFloat {
        guard isFullScreen, safeAreaTop.isFinite else { return 0 }
        return max(0, safeAreaTop)
    }

    static func topBarTopPadding(
        isFullScreen: Bool,
        safeAreaTop: CGFloat,
        trafficLightCenterY: CGFloat? = nil
    ) -> CGFloat {
        if isFullScreen {
            return topBarTopInset + reservedTop(isFullScreen: true, safeAreaTop: safeAreaTop)
        }
        let centerY: CGFloat
        if let measured = trafficLightCenterY, measured.isFinite, measured > 0 {
            centerY = measured
        } else {
            centerY = windowButtonCenterY
        }
        return max(0, centerY - topBarControlHeight / 2)
    }

    static func topBarFrameHeight(isFullScreen: Bool, safeAreaTop: CGFloat) -> CGFloat {
        topBarHeight + reservedTop(isFullScreen: isFullScreen, safeAreaTop: safeAreaTop)
    }

    /// Standard macOS traffic-light cluster: three 14 pt buttons that end at 79 pt.
    static let windowButtonTrailing: CGFloat = 79
    /// Gap between the traffic lights and the floating chrome in the reference.
    static let windowButtonGap: CGFloat = 22
    /// Extra leading room the floating chrome needs so the traffic lights stay
    /// clickable while the immersive page covers the window.
    static let windowButtonReserve: CGFloat = windowButtonTrailing + windowButtonGap - topBarEdgeInset

    /// Full screen hides the traffic lights, so the chrome returns to the plain
    /// page-inset and only the reserved top strip is added there.
    static func topBarLeadingPadding(isFullScreen: Bool) -> CGFloat {
        isFullScreen ? topBarEdgeInset : topBarEdgeInset + windowButtonReserve
    }

    static func artworkSize(for size: CGSize) -> CGFloat {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return 300 }
        return min(maximumArtwork, max(minimumArtwork, min(size.width * 0.28, size.height * 0.52)))
    }

    static func paneWidth(for size: CGSize) -> CGFloat {
        guard size.width.isFinite, size.width > 0 else { return maximumPaneWidth }
        return min(maximumPaneWidth, size.width * (1 - paneLeadingRatio - trailingRatio))
    }
}

enum NowPlayingVolumeMetrics {
    static let thumbWidth: CGFloat = 26

    static func value(forX x: CGFloat, width: CGFloat, thumbWidth: CGFloat) -> Double {
        guard width.isFinite, x.isFinite, width > thumbWidth else { return 0 }
        let travel = width - thumbWidth
        let position = min(max(x - thumbWidth / 2, 0), travel)
        return Double(position / travel)
    }

    static func thumbOffset(for value: Double, width: CGFloat, thumbWidth: CGFloat) -> CGFloat {
        guard width.isFinite, width > thumbWidth else { return 0 }
        return min(max(0, value), 1) * (width - thumbWidth)
    }
}

/// Distance-based lyric focus: the current line stays crisp and opaque while
/// farther lines fade and blur, mirroring the reference player.
enum NowPlayingLyricFocus {
    struct Style: Equatable {
        let blur: CGFloat
        let opacity: Double
    }

    static let maximumBlur: CGFloat = 5

    static func style(distance: Int) -> Style {
        let distance = max(0, distance)
        guard distance > 0 else { return Style(blur: 0, opacity: 1) }
        let opacity = max(0.18, 0.70 - Double(distance - 1) * 0.06)
        let blur = min(maximumBlur, CGFloat(distance - 1) * 0.9)
        return Style(blur: blur, opacity: opacity)
    }
}

/// Publishes actual top-bar capsule bounds for native layout regression checks.
/// SwiftUI does not evaluate this preference when no ancestor consumes it.
struct NowPlayingTopBarBoundsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Full-window now-playing page opened from the mini player's artwork.
struct NowPlayingView: View {
    var body: some View {
        NowPlayingContentView().modifier(WindowTitlebarChromeModifier())
    }
}

private struct NowPlayingContentView: View {
    @Environment(LibraryContext.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isWindowFullScreen) private var isFullScreen
    @Environment(\.fullScreenTopInset) private var fullScreenTopInset
    @State private var side: Side = .lyrics
    @State private var trafficLightCenterY: CGFloat?
    @State private var hostingWindow: NSWindow?

    private enum Side {
        case lyrics, queue
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                NowPlayingBackground(coverId: library.player.currentTrack?.coverId)
                    .ignoresSafeArea()

                content(size: geometry.size)

                topBar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                sideSwitch
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(NowPlayingWindowAccessor(window: $hostingWindow))
        .environment(\.colorScheme, .dark)
        .onAppear { updateTrafficLightCenterY() }
        .onChange(of: hostingWindow) { _, _ in updateTrafficLightCenterY() }
        .onChange(of: isFullScreen) { _, _ in updateTrafficLightCenterY() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            if let notifiedWindow = notification.object as? NSWindow,
               let hostingWindow, notifiedWindow !== hostingWindow { return }
            updateTrafficLightCenterY()
        }
        .onExitCommand { close() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("FnMusic.NowPlayingPage")
    }

    private func close() {
        library.nowPlayingExpanded = false
    }

    private func updateTrafficLightCenterY() {
        let window = hostingWindow ?? NSApp.mainWindow ?? NSApp.keyWindow
        let fullScreen = isFullScreen || (window?.styleMask.contains(.fullScreen) ?? false)
        trafficLightCenterY = fullScreen ? nil : Self.measuredTrafficLightCenterY(in: window)
    }

    private static func measuredTrafficLightCenterY(in window: NSWindow?) -> CGFloat? {
        guard let window,
              let contentView = window.contentView,
              let closeButton = window.standardWindowButton(.closeButton),
              closeButton.bounds.height > 0,
              contentView.bounds.height > 0
        else { return nil }
        let frameInContent = closeButton.convert(closeButton.bounds, to: contentView)
        let centerFromTop = contentView.isFlipped
            ? frameInContent.midY
            : contentView.bounds.height - frameInContent.midY
        return centerFromTop.isFinite && centerFromTop > 0 && centerFromTop < contentView.bounds.height / 2
            ? centerFromTop
            : nil
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .help("关闭歌词页")
                .accessibilityLabel("关闭歌词页")
                .accessibilityIdentifier("FnMusic.NowPlayingClose")

                Button {
                    hostingWindow?.toggleFullScreen(nil)
                } label: {
                    Image(systemName: isFullScreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 34, height: 32)
                }
                .buttonStyle(.plain)
                .help(isFullScreen ? "退出全屏" : "进入全屏")
                .accessibilityLabel(isFullScreen ? "退出全屏" : "进入全屏")
            }
            .foregroundStyle(.white.opacity(0.96))
            .padding(3)
            .frame(height: NowPlayingMetrics.topBarControlHeight)
            .modifier(NowPlayingGlass())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.24), lineWidth: 0.8)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: NowPlayingTopBarBoundsKey.self, value: ["left": geometry.frame(in: .global)])
                }
                .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .padding(.leading, NowPlayingMetrics.topBarLeadingPadding(isFullScreen: isFullScreen))

            Spacer(minLength: 0)

            volumeControl
        }
        .padding(.trailing, NowPlayingMetrics.topBarEdgeInset)
        .padding(.top, NowPlayingMetrics.topBarTopPadding(
            isFullScreen: isFullScreen,
            safeAreaTop: fullScreenTopInset,
            trafficLightCenterY: trafficLightCenterY
        ))
        .frame(height: NowPlayingMetrics.topBarFrameHeight(
            isFullScreen: isFullScreen,
            safeAreaTop: fullScreenTopInset
        ), alignment: .top)
    }

    private var volumeControl: some View {
        @Bindable var player = library.player
        return HStack(spacing: 10) {
            AudioRoutePicker(player: player, buttonColor: .white)
                .frame(width: 24, height: 24)
                .padding(.trailing, 6)

            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: 20)

            NowPlayingVolumeSlider(value: $player.volume)
                .frame(width: 112, height: 22)

            Image(systemName: speakerSymbol(for: player.volume))
                .font(.system(size: 14, weight: .medium))
                .frame(width: 18)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 13)
        .frame(height: NowPlayingMetrics.topBarControlHeight)
        .modifier(NowPlayingGlass())
        .overlay {
            Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: NowPlayingTopBarBoundsKey.self, value: ["right": geometry.frame(in: .global)])
            }
            .allowsHitTesting(false)
        }
        .accessibilityIdentifier("FnMusic.NowPlayingVolume")
    }

    private func speakerSymbol(for volume: Double) -> String {
        if volume == 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: Main columns

    private func content(size: CGSize) -> some View {
        let artwork = NowPlayingMetrics.artworkSize(for: size)
        let leading = size.width * NowPlayingMetrics.leadingRatio
        let paneLeading = size.width * NowPlayingMetrics.paneLeadingRatio
        let gap = max(24, paneLeading - leading - artwork)
        return HStack(alignment: .center, spacing: 0) {
            Spacer().frame(width: leading)
            leftColumn(artwork: artwork)
                .frame(width: artwork, alignment: .leading)
            Spacer().frame(width: gap)
            Group {
                switch side {
                case .lyrics:
                    NowPlayingLyrics(trackGUID: library.player.currentTrack?.guid)
                case .queue:
                    NowPlayingQueue()
                }
            }
            .frame(width: NowPlayingMetrics.paneWidth(for: size))
            .frame(maxHeight: .infinity, alignment: .top)
            Spacer(minLength: 0)
        }
    }

    private func leftColumn(artwork: CGFloat) -> some View {
        let player = library.player
        let displayedArtwork = artwork * (player.isPlaying ? 1 : NowPlayingMetrics.pausedArtworkScale)
        return VStack(alignment: .leading, spacing: 0) {
            if let track = player.currentTrack {
                ArtworkView(coverId: track.coverId, cache: library.images, size: 600)
                    .frame(width: displayedArtwork, height: displayedArtwork)
                    .shadow(color: .black.opacity(0.42), radius: 30, y: 18)
                    .accessibilityLabel("\(track.displayTitle) 封面")
                    .frame(width: artwork, height: artwork)
                    .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: player.isPlaying)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.displayTitle)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(trackSubtitle(track))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        favoriteButton(track)
                        trackMenu(track)
                    }
                    .padding(.top, 16)

                    NowPlayingProgress(player: player)
                        .padding(.top, 12)

                    playbackControls
                        .padding(.top, 10)
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func trackSubtitle(_ track: Track) -> String {
        [track.artistText, track.album?.displayName]
            .compactMap { $0 }
            .joined(separator: " — ")
    }

    private func favoriteButton(_ track: Track) -> some View {
        let favorite = library.actions.isFavorite(track)
        return Button {
            Task { await library.actions.toggleFavorite(track) }
        } label: {
            Group {
                if library.actions.busyTracks.contains(track.guid) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: favorite ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(favorite ? Color.pink : .white.opacity(0.8))
                }
            }
            .frame(width: 28, height: 28)
            .background(.white.opacity(0.12), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(favorite ? "取消收藏" : "收藏歌曲")
        .accessibilityLabel(favorite ? "取消收藏" : "收藏歌曲")
        .disabled(library.actions.busyTracks.contains(track.guid))
    }

    private func trackMenu(_ track: Track) -> some View {
        Menu {
            Button("下一首播放") { library.player.queue.insertNext(track) }
            Button("添加到队列") { library.player.queue.append(track) }
            Divider()
            Button(library.actions.isFavorite(track) ? "取消收藏（实验性）" : "收藏（实验性）") {
                Task { await library.actions.toggleFavorite(track) }
            }
            .disabled(library.actions.busyTracks.contains(track.guid))
            Button("添加到歌单（实验性）") {
                if library.actions.experimentalWrites { library.actions.pendingPlaylistTrack = track }
                else { library.actions.error = "请先在设置中启用实验性写操作。" }
            }
            Divider()
            Button("下载原始音频…") { library.downloads.download(track) }
            if track.album != nil || track.artists?.first != nil {
                Divider()
            }
            if let album = track.album {
                Button("查看专辑") { open(.album(album)) }
            }
            if let artist = track.artists?.first {
                Button("查看艺人") { open(.artist(artist)) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
        .accessibilityLabel("\(track.displayTitle)更多操作")
    }

    private func open(_ route: LibraryRoute) {
        library.nowPlayingExpanded = false
        library.navigation.append(route)
    }

    private var playbackControls: some View {
        let player = library.player
        let queue = player.queue
        return HStack(spacing: 0) {
            Button { queue.shuffle.toggle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(queue.shuffle ? Color.pink : .white.opacity(0.82))
                    .frame(width: 34, height: 34)
            }
            .help("随机播放（一轮内每首只播一次，播完继续）")
            .accessibilityLabel("随机播放")
            .accessibilityValue(queue.shuffle ? "开启" : "关闭")

            Spacer(minLength: 0)

            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 36, height: 36)
            }
            .help("上一首")
            .accessibilityLabel("上一首")

            Spacer(minLength: 0)

            Button { player.toggle() } label: {
                ZStack {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .opacity(player.isLoading ? 0 : 1)
                    if player.isLoading {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .frame(width: 46, height: 40)
                .contentShape(Rectangle())
            }
            .help(player.isPlaying ? "暂停" : "播放")
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Spacer(minLength: 0)

            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 36, height: 36)
            }
            .help("下一首")
            .accessibilityLabel("下一首")

            Spacer(minLength: 0)

            Button { queue.cycleRepeatMode() } label: {
                Image(systemName: queue.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(queue.repeatMode == .off ? .white.opacity(0.82) : Color.pink)
                    .frame(width: 34, height: 34)
            }
            .help(queue.repeatMode.title)
            .accessibilityLabel(queue.repeatMode.title)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .disabled(player.currentTrack == nil)
    }

    // MARK: Lyrics / queue switch

    private var sideSwitch: some View {
        HStack(spacing: 0) {
            sideButton(.lyrics, symbol: "quote.bubble", selectedSymbol: "quote.bubble.fill", label: "歌词")
            sideButton(.queue, symbol: "list.bullet", selectedSymbol: "list.bullet", label: "待播清单")
        }
        .padding(4)
        .modifier(NowPlayingGlass())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FnMusic.NowPlayingSideSwitch")
    }

    private func sideButton(_ target: Side, symbol: String, selectedSymbol: String, label: String) -> some View {
        let selected = side == target
        return Button { side = target } label: {
            Image(systemName: selected ? selectedSymbol : symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.black.opacity(0.72) : .white.opacity(0.68))
                .frame(width: 38, height: 36)
                .background(selected ? .white.opacity(0.9) : .clear, in: Circle())
                .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(selected ? "已选中" : "未选中")
    }
}

private struct NowPlayingWindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    final class ObserverView: NSView {
        var windowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowChanged?(window)
        }
    }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.windowChanged = { window = $0 }
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {}
}

private struct NowPlayingVolumeSlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let thumbWidth = NowPlayingVolumeMetrics.thumbWidth
            let offset = NowPlayingVolumeMetrics.thumbOffset(for: value, width: width, thumbWidth: thumbWidth)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(height: 4)
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: min(width, offset + thumbWidth / 2), height: 4)
                Capsule()
                    .fill(.white)
                    .frame(width: thumbWidth, height: 14)
                    .offset(x: offset)
                    .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        value = NowPlayingVolumeMetrics.value(
                            forX: gesture.location.x,
                            width: width,
                            thumbWidth: thumbWidth
                        )
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("音量")
        .accessibilityValue("\(Int((value * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(1, value + 0.05)
            case .decrement: value = max(0, value - 0.05)
            @unknown default: break
            }
        }
    }
}

// MARK: - Background

private struct NowPlayingBackground: View {
    let coverId: String?
    @Environment(LibraryContext.self) private var library
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.06, blue: 0.065)

            if !reduceTransparency, let image {
                Rectangle()
                    .fill(.clear)
                    .overlay {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .blur(radius: 72, opaque: true)
                    .saturation(1.35)
                    .overlay(Color.black.opacity(0.48))
                    .id(coverId)
                    .transition(.opacity)
            }

            LinearGradient(
                colors: [.black.opacity(0.08), .black.opacity(0.20), .black.opacity(0.52)],
                startPoint: .top,
                endPoint: .bottom
            )

            if reduceTransparency {
                Color.black.opacity(0.55)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeInOut(duration: 0.55), value: coverId)
        .task(id: coverId) { await load() }
    }

    private func load() async {
        guard let coverId, !coverId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            image = nil
            return
        }
        let loaded = try? await library.images.image(id: coverId, size: 600)
        guard !Task.isCancelled else { return }
        image = loaded
    }
}

// MARK: - Progress

private struct NowPlayingProgress: View {
    let player: AudioPlayer
    @State private var seeking = false
    @State private var seekValue: Double = 0

    var body: some View {
        let elapsed = seeking ? seekValue : min(player.elapsed, max(1, player.duration))
        let remaining = max(0, player.duration - elapsed)
        return VStack(spacing: 4) {
            Slider(
                value: Binding(get: { elapsed }, set: { seekValue = $0 }),
                in: 0...max(1, player.duration),
                onEditingChanged: { editing in
                    if editing {
                        seekValue = player.elapsed
                        seeking = true
                    } else {
                        player.seek(to: seekValue)
                        seeking = false
                    }
                }
            )
            .controlSize(.small)
            .tint(.white.opacity(0.92))
            .disabled(player.duration <= 0)
            .accessibilityLabel("播放进度")

            HStack {
                Text(elapsed.playbackTime)
                Spacer(minLength: 8)
                Text("-\(remaining.playbackTime)")
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.52))
            .monospacedDigit()
        }
        .onChange(of: player.elapsed) { _, value in
            if !seeking { seekValue = value }
        }
    }
}

// MARK: - Lyrics

private struct NowPlayingLyrics: View {
    let trackGUID: String?
    @Environment(LibraryContext.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let highlightAnchorY: CGFloat = 0.42

    var body: some View {
        let model = library.lyricsPanel
        let current = model.parsed.currentIndex(at: library.player.elapsed)
        let entries = model.displayEntries
        let currentEntry = entries.firstIndex { $0.id == current }

        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    if model.loading {
                        statusView {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("正在加载歌词")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .frame(minHeight: geometry.size.height)
                    } else if let error = model.error {
                        statusView {
                            Image(systemName: "quote.bubble")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                            Text("歌词加载失败")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.5))
                                .multilineTextAlignment(.center)
                                .lineLimit(4)
                            Button("重试") {
                                Task { await model.load(trackGUID: trackGUID) }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(.white.opacity(0.14), in: Capsule())
                        }
                        .frame(minHeight: geometry.size.height)
                    } else if entries.isEmpty {
                        statusView {
                            Image(systemName: "quote.bubble")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                            Text("暂无歌词")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .frame(minHeight: geometry.size.height)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                lyricLine(entry, distance: currentEntry.map { abs(index - $0) }, model: model)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, geometry.size.height * highlightAnchorY)
                        .padding(.bottom, geometry.size.height * (1 - highlightAnchorY))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: current)
                        .background(HideVerticalScroller())
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: current) { _, index in
                    guard let index, model.parsed.isTimed else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.42)) {
                        proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: highlightAnchorY))
                    }
                }
                .onChange(of: model.parsed.lines) { _, _ in
                    guard let current else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.42)) {
                        proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: highlightAnchorY))
                    }
                }
                .onAppear {
                    if let current {
                        proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: highlightAnchorY))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: trackGUID) { await library.lyricsPanel.load(trackGUID: trackGUID) }
        .accessibilityIdentifier("FnMusic.NowPlayingLyrics")
    }

    private func lyricLine(_ entry: LyricDisplayEntry, distance: Int?, model: LyricsViewModel) -> some View {
        let timed = model.parsed.isTimed
        let active = timed && distance == 0
        let style = timed
            ? NowPlayingLyricFocus.style(distance: distance ?? 0)
            : NowPlayingLyricFocus.Style(blur: 0, opacity: 0.9)
        return VStack(alignment: .leading, spacing: 5) {
            Text(entry.text)
                .font(.system(size: active ? 30 : 27, weight: active ? .bold : .semibold))
                .foregroundStyle(.white.opacity(style.opacity))
                .blur(radius: active ? 0 : style.blur)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(entry.translations.enumerated()), id: \.offset) { _, translation in
                Text(translation)
                    .font(.system(size: 13, weight: active ? .medium : .regular))
                    .foregroundStyle(.white.opacity(active ? 0.62 : 0.32))
                    .blur(radius: active ? 0 : min(style.blur, 2.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let time = model.parsed.lines.first(where: { $0.id == entry.id })?.time else { return }
            library.player.seek(to: max(0, time))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(active ? "当前歌词，\(entry.text)" : entry.text)
        .accessibilityAddTraits(.isButton)
    }

    private func statusView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) { content() }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }
}

// MARK: - Queue

private struct NowPlayingQueue: View {
    @Environment(LibraryContext.self) private var library

    var body: some View {
        let queue = library.player.queue
        let snapshot = queue.tracks
        return VStack(alignment: .leading, spacing: 0) {
            modeControls(queue: queue)

            HStack(alignment: .firstTextBaseline) {
                Text("继续播放")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text("\(snapshot.count) 首")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Text("来自：当前播放队列")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.42))
                .padding(.top, 3)
                .padding(.bottom, 10)

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 0.5)

            if snapshot.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 26, weight: .medium))
                    Text("队列为空").font(.system(size: 13))
                }
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(snapshot.enumerated()), id: \.offset) { index, track in
                            row(track, index: index, isCurrent: queue.index == index, snapshot: snapshot)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .contentMargins(.bottom, 16, for: .scrollContent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 64)
        .padding(.bottom, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("FnMusic.NowPlayingQueue")
    }

    private func modeControls(queue: QueueManager) -> some View {
        HStack(spacing: 8) {
            modeButton(symbol: "infinity", label: "列表循环", active: queue.repeatMode == .all) {
                queue.repeatMode = queue.repeatMode == .all ? .off : .all
            }
            modeButton(symbol: "shuffle", label: "随机播放", active: queue.shuffle) {
                queue.shuffle.toggle()
            }
        }
        .padding(.vertical, 14)
    }

    private func modeButton(symbol: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(label).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(active ? Color.black.opacity(0.82) : .white.opacity(0.8))
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(active ? .white.opacity(0.78) : .white.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(active ? "开启" : "关闭")
    }

    private func row(_ track: Track, index: Int, isCurrent: Bool, snapshot: [Track]) -> some View {
        HStack(spacing: 8) {
            Button {
                perform(index, snapshot: snapshot) { library.player.playQueueIndex($0) }
            } label: {
                HStack(spacing: 10) {
                    ArtworkView(coverId: track.coverId, cache: library.images, size: 160)
                        .frame(width: 34, height: 34)
                        .overlay {
                            if isCurrent {
                                RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.35))
                                Image(systemName: "waveform")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white)
                            }
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.displayTitle)
                            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? Color.pink : .white.opacity(0.92))
                        Text(queueSubtitle(track))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isCurrent ? "当前播放，" : "")\(track.displayTitle)，\(track.artistText)，播放")

            Menu {
                Button("立即播放") {
                    perform(index, snapshot: snapshot) { library.player.playQueueIndex($0) }
                }
                Button("从待播清单移除", role: .destructive) {
                    perform(index, snapshot: snapshot) { library.player.removeQueueEntry(at: $0) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCurrent ? Color.pink : .white.opacity(0.5))
                    .frame(width: 24, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("\(track.displayTitle)更多操作")
        }
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5).padding(.leading, 44)
        }
        .contextMenu {
            Button("立即播放") {
                perform(index, snapshot: snapshot) { library.player.playQueueIndex($0) }
            }
            Button("从待播清单移除", role: .destructive) {
                perform(index, snapshot: snapshot) { library.player.removeQueueEntry(at: $0) }
            }
        }
    }

    private func queueSubtitle(_ track: Track) -> String {
        [track.artistText, track.album?.displayName]
            .compactMap { $0 }
            .joined(separator: " — ")
    }

    private func perform(_ index: Int, snapshot: [Track], action: (Int) -> Void) {
        if !library.queuePanel.performQueueAction(at: index, snapshot: snapshot, queue: library.player.queue, action: action) {
            library.actions.notice = "队列已更新，请重新选择歌曲。"
        }
    }
}

// MARK: - Glass chrome

private struct NowPlayingGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color.black.opacity(0.55), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(!reduceMotion), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        }
    }
}
