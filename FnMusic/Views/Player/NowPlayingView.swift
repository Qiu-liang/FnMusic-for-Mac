import AppKit
import CoreGraphics
import SwiftUI

/// Layout math for the immersive page. Kept pure so window-size behavior can
/// be checked without hosting SwiftUI.
enum NowPlayingMetrics {
    static let minimumArtwork: CGFloat = 200
    static let maximumArtwork: CGFloat = 372
    static let maximumPaneWidth: CGFloat = 560
    static let minimumPaneWidth: CGFloat = 300
    static let outerSpacing: CGFloat = 24
    static let columnGap: CGFloat = 48

    static func artworkSize(for size: CGSize) -> CGFloat {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return 300 }
        return min(maximumArtwork, max(minimumArtwork, min(size.width * 0.30, size.height * 0.42)))
    }

    static func paneWidth(for size: CGSize) -> CGFloat {
        guard size.width.isFinite, size.width > 0 else { return maximumPaneWidth }
        let remaining = size.width - artworkSize(for: size) - columnGap - outerSpacing * 2
        return min(maximumPaneWidth, max(minimumPaneWidth, remaining))
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

/// Full-window now-playing page opened from the mini player's artwork.
struct NowPlayingView: View {
    @Environment(LibraryContext.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var side: Side = .lyrics

    private enum Side {
        case lyrics, queue
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                NowPlayingBackground(coverId: library.player.currentTrack?.coverId)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    content(size: geometry.size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 6)
                        .padding(.bottom, 18)
                }

                sideSwitch
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.colorScheme, .dark)
        .onExitCommand { close() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("FnMusic.NowPlayingPage")
    }

    private func close() {
        library.nowPlayingExpanded = false
    }

    // MARK: Top bar

    private var topBar: some View {
        @Bindable var player = library.player
        return HStack(spacing: 12) {
            HStack(spacing: 0) {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help("关闭歌词页")
                .accessibilityLabel("关闭歌词页")
                .accessibilityIdentifier("FnMusic.NowPlayingClose")
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(2)
            .modifier(NowPlayingGlass())
            .padding(.leading, 84)

            Spacer(minLength: 0)

            HStack(spacing: 9) {
                AudioRoutePicker(player: player, buttonColor: .white)
                    .frame(width: 22, height: 22)
                Slider(value: $player.volume, in: 0...1)
                    .controlSize(.mini)
                    .frame(width: 92)
                    .tint(.white)
                    .accessibilityLabel("音量")
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 11)
            .frame(height: 30)
            .modifier(NowPlayingGlass())
        }
        .padding(.trailing, 18)
        .padding(.top, 13)
        .frame(height: 56)
    }

    // MARK: Main columns

    private func content(size: CGSize) -> some View {
        let artwork = NowPlayingMetrics.artworkSize(for: size)
        return HStack(alignment: .center, spacing: 0) {
            Spacer(minLength: NowPlayingMetrics.outerSpacing)
            leftColumn
                .frame(width: artwork, alignment: .leading)
            Spacer(minLength: NowPlayingMetrics.columnGap)
            Group {
                switch side {
                case .lyrics:
                    NowPlayingLyrics(trackGUID: library.player.currentTrack?.guid)
                case .queue:
                    NowPlayingQueue()
                }
            }
            .frame(maxWidth: NowPlayingMetrics.paneWidth(for: size), maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
            Spacer(minLength: NowPlayingMetrics.outerSpacing)
        }
    }

    private var leftColumn: some View {
        let player = library.player
        return VStack(alignment: .leading, spacing: 0) {
            if let track = player.currentTrack {
                ArtworkView(coverId: track.coverId, cache: library.images, size: 600)
                    .shadow(color: .black.opacity(0.42), radius: 30, y: 18)
                    .accessibilityLabel("\(track.displayTitle) 封面")

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.displayTitle)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(trackSubtitle(track))
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        favoriteButton(track)
                        trackMenu(track)
                    }
                    .padding(.top, 22)

                    NowPlayingProgress(player: player)
                        .padding(.top, 16)

                    playbackControls
                        .padding(.top, 12)
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
        HStack(spacing: 2) {
            sideButton(.lyrics, symbol: "quote.bubble", label: "歌词")
            sideButton(.queue, symbol: "list.bullet", label: "待播清单")
        }
        .padding(3)
        .modifier(NowPlayingGlass())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FnMusic.NowPlayingSideSwitch")
    }

    private func sideButton(_ target: Side, symbol: String, label: String) -> some View {
        Button { side = target } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(side == target ? .white : .white.opacity(0.35))
                .frame(width: 30, height: 26)
                .background(side == target ? .white.opacity(0.16) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(side == target ? "已选中" : "未选中")
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
                    .overlay(Color.black.opacity(0.34))
                    .id(coverId)
                    .transition(.opacity)
            }

            LinearGradient(
                colors: [.black.opacity(0.04), .black.opacity(0.16), .black.opacity(0.48)],
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
            HStack(alignment: .firstTextBaseline) {
                Text("待播清单")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text("\(snapshot.count) 首")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
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
                .scrollIndicators(.hidden)
                .padding(.top, 2)

                Text("仅包含已加入队列的歌曲")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("FnMusic.NowPlayingQueue")
    }

    private func row(_ track: Track, index: Int, isCurrent: Bool, snapshot: [Track]) -> some View {
        HStack(spacing: 8) {
            Button {
                perform(index, snapshot: snapshot) { library.player.playQueueIndex($0) }
            } label: {
                HStack(spacing: 11) {
                    ArtworkView(coverId: track.coverId, cache: library.images, size: 160)
                        .frame(width: 40, height: 40)
                        .overlay {
                            if isCurrent {
                                RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.35))
                                Image(systemName: "waveform")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white)
                            }
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.displayTitle)
                            .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? Color.pink : .white.opacity(0.92))
                        Text(queueSubtitle(track))
                            .font(.system(size: 11))
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
        .frame(height: 54)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
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
