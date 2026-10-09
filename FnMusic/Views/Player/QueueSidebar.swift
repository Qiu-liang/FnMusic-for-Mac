import SwiftUI

/// Leave enough room for the existing three-column artist browser and player.
/// Compact windows use an unmasked drawer above (not over) the mini player.
@MainActor
enum QueueSidebarMetrics {
    static let minimumMainWidth: CGFloat = 590
    static let minimumDockedWidth: CGFloat = 280

    static func isDocked(windowWidth: CGFloat, sidebarVisible: Bool) -> Bool {
        windowWidth >= minimumMainWidth + minimumDockedWidth + (sidebarVisible ? MusicSidebarMetrics.width : 0)
    }

    static func width(windowWidth: CGFloat, sidebarVisible: Bool) -> CGFloat {
        if isDocked(windowWidth: windowWidth, sidebarVisible: sidebarVisible) {
            return min(320, max(280, windowWidth * 0.21))
        }
        return min(280, max(240, windowWidth * 0.30))
    }
}

struct QueueSidebarBoundsKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 { value = next }
    }
}

/// A layout child of the main window, never a sheet or a separate NSWindow.
struct QueueSidebar: View {
    @Environment(LibraryContext.self) private var library
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            modeControls
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    historySection
                        .frame(height: max(120, geometry.size.height * 0.40))
                    Divider()
                    queueSection.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor) }
            else { Rectangle().fill(.regularMaterial) }
        }
        .overlay(alignment: .leading) { Divider() }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: QueueSidebarBoundsKey.self, value: geometry.frame(in: .global))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FnMusic.QueueSidebar")
        .onExitCommand { library.showQueue = false }
        .task { await library.queuePanel.loadHistoryIfNeeded() }
    }

    private var modeControls: some View {
        let queue = library.player.queue
        return HStack(spacing: 8) {
            Button { queue.cycleRepeatMode() } label: {
                Image(systemName: queue.repeatMode.symbol)
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .foregroundStyle(queue.repeatMode == .off ? Color.secondary : .pink)
                    .background(.primary.opacity(0.05), in: Capsule())
            }
            .help(queue.repeatMode.title).accessibilityLabel(queue.repeatMode.title)
            .accessibilityIdentifier("FnMusic.QueueRepeat")
            Button { queue.shuffle.toggle() } label: {
                Image(systemName: "shuffle")
                    .frame(maxWidth: .infinity).frame(height: 32)
                    .foregroundStyle(queue.shuffle ? Color.pink : .secondary)
                    .background(.primary.opacity(0.05), in: Capsule())
            }
            .help("随机播放（已加入队列的歌曲）").accessibilityLabel("随机播放")
            .accessibilityValue(queue.shuffle ? "开启" : "关闭")
            .accessibilityIdentifier("FnMusic.QueueShuffle")
            Button { library.showQueue = false } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 32)
            }
            .help("收起待播清单").accessibilityLabel("收起待播清单")
            .accessibilityIdentifier("FnMusic.QueueClose")
        }
        .buttonStyle(.plain)
        .font(.system(size: 16))
        .padding(.horizontal, 12)
        .frame(height: PageToolbarMetrics.height)
    }

    private var historySection: some View {
        let state = library.queuePanel
        let history = state.history
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("历史记录").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 4)
                Menu {
                    Button("刷新服务器历史") { Task { await state.loadHistory(refresh: true) } }
                        .disabled(history.isLoading)
                    Button("恢复显示已清除的记录") { state.restoreHistoryDisplay() }
                        .disabled(state.hiddenHistoryIDs.isEmpty)
                    Text("清除仅隐藏本面板已显示的记录，不删除服务器历史。")
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("历史记录选项")
                Button("清除") { state.clearDisplayedHistory() }
                    .font(.system(size: 11)).foregroundStyle(.pink)
                    .disabled(state.visibleHistory.isEmpty)
                    .help("仅清除本面板已显示的历史，不删除服务器记录")
                    .accessibilityLabel("清除本面板已显示的历史")
                    .accessibilityIdentifier("FnMusic.QueueClearHistory")
            }.buttonStyle(.plain).padding(.horizontal, 14).frame(height: 34)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.visibleHistory) { track in
                        QueueSidebarTrackRow(track: track, isCurrent: false, play: {
                            // An explicit history play uses the existing queue insertion
                            // and selection APIs; opening the panel never edits the queue.
                            let queue = library.player.queue
                            queue.insertNext(track)
                            let index = queue.index.map { min($0 + 1, queue.tracks.count - 1) } ?? 0
                            library.player.playQueueIndex(index)
                        }) {
                            Button("播放下一首") { library.player.queue.insertNext(track) }
                            Button("加入待播清单") { library.player.queue.append(track) }
                        }
                    }
                    if state.visibleHistory.isEmpty && !history.isLoading {
                        VStack(spacing: 8) {
                            Text(state.hiddenHistoryIDs.isEmpty ? "暂无服务器播放历史" : "已在本面板隐藏历史记录")
                                .font(.caption).foregroundStyle(.secondary)
                            if !state.hiddenHistoryIDs.isEmpty {
                                Button("恢复显示") { state.restoreHistoryDisplay() }.font(.caption)
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                    if history.isLoading { ProgressView().controlSize(.small).padding(12) }
                    if let error = history.error {
                        Text(error).font(.caption).foregroundStyle(.secondary).padding(8)
                        Button("重试") { Task { await state.loadHistory() } }.font(.caption)
                    } else if history.hasMore && !history.isLoading && !history.items.isEmpty {
                        Button("加载更多历史") { Task { await state.loadHistory() } }
                            .font(.caption).padding(10)
                    }
                }.padding(.horizontal, 12)
            }
            .accessibilityIdentifier("FnMusic.QueueHistoryScroll")
        }
    }

    private func perform(_ index: Int, snapshot: [Track], action: (Int) -> Void) {
        if !library.queuePanel.performQueueAction(at: index, snapshot: snapshot, queue: library.player.queue, action: action) {
            library.actions.notice = "队列已更新，请重新选择歌曲。"
        }
    }

    private var queueSection: some View {
        @Bindable var state = library.queuePanel
        let queue = library.player.queue
        let snapshot = queue.tracks
        let rows = Array(snapshot.enumerated()).filter { state.matchesQueueSearch($0.element) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("待播清单").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(queue.tracks.count) 首").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).frame(height: 36)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("在队列中查找", text: $state.query).textFieldStyle(.plain)
                    .accessibilityIdentifier("FnMusic.QueueSearch")
                if !state.query.isEmpty {
                    Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("清除队列查找")
                }
            }
            .font(.system(size: 11)).padding(.horizontal, 10).frame(height: 28)
            .background(.primary.opacity(0.04), in: Capsule()).padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if rows.isEmpty {
                        Text(queue.tracks.isEmpty ? "队列为空" : "没有匹配的队列歌曲")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    // Offset identity intentionally preserves duplicate Track GUIDs.
                    ForEach(rows, id: \.offset) { index, track in
                        QueueSidebarTrackRow(track: track, isCurrent: queue.index == index,
                                             play: { perform(index, snapshot: snapshot, action: library.player.playQueueIndex) }) {
                            Button("立即播放") { perform(index, snapshot: snapshot, action: library.player.playQueueIndex) }
                            Button("从待播清单移除", role: .destructive) {
                                perform(index, snapshot: snapshot, action: library.player.removeQueueEntry)
                            }
                        }
                        .accessibilityIdentifier("FnMusic.QueueEntry.\(index)")
                    }
                }.padding(.horizontal, 12)
            }
            .accessibilityIdentifier("FnMusic.QueueTracksScroll")
            Text("仅包含已加入队列的歌曲")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

private struct QueueSidebarTrackRow<Options: View>: View {
    @Environment(LibraryContext.self) private var library
    let track: Track
    let isCurrent: Bool
    let play: () -> Void
    @ViewBuilder let options: () -> Options

    var body: some View {
        HStack(spacing: 6) {
            Button(action: play) {
                HStack(spacing: 9) {
                    ArtworkView(coverId: track.coverId, cache: library.images, size: 160)
                        .frame(width: 34, height: 34)
                        .overlay {
                            if isCurrent {
                                RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.35))
                                Image(systemName: "waveform").font(.system(size: 15)).foregroundStyle(.white)
                            }
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.displayTitle).font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? Color.pink : .primary)
                        Text(track.artistText + (track.album.map { " — " + $0.displayName } ?? ""))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isCurrent ? "当前播放，" : "")\(track.displayTitle)，\(track.artistText)，播放")
            Menu { options() } label: {
                Image(systemName: "ellipsis").foregroundStyle(isCurrent ? Color.pink : .secondary)
                    .frame(width: 22, height: 30)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("\(track.displayTitle)更多操作")
        }
        .frame(height: 48)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 43) }
        .contextMenu { options() }
    }
}
