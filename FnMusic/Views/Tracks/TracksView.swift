import SwiftUI

struct TracksView: View {
    @Environment(LibraryContext.self) private var library
    @State private var model: PagedViewModel<Track>
    @State private var controls: CatalogControls
    @State private var requestTask: Task<Void, Never>?
    @State private var activeRequest: CatalogRequestIdentity?
    private let service: any MusicServiceProtocol
    let source: TrackSource
    let showsToolbar: Bool

    init(service: any MusicServiceProtocol, source: TrackSource = .library,
         showsToolbar: Bool = true, controls: CatalogControls? = nil) {
        self.service = service
        self.source = source
        self.showsToolbar = showsToolbar
        let shared = controls ?? CatalogControls(sort: source.defaultSort)
        _controls = State(initialValue: shared)
        _model = State(initialValue: PagedViewModel(sort: shared.sort) { page, sort in
            try await service.tracks(page: page, sort: sort, source: source)
        })
    }

    var body: some View {
        Group {
            if showsToolbar {
                MusicPageChrome(title: title, placeholder: source == .library ? "在歌曲中查找" : "在已加载歌曲中查找",
                                query: $controls.query) {
                    TrackPageOptions(controls: controls, source: source)
                    if let sort = model.returnedSort { Text("服务器排序：\(sort)") }
                } content: { scrollingContent }
            } else { scrollingContent }
        }
        .task(id: taskIdentity) { await updateRequest() }
        .onChange(of: model.items) { _, tracks in library.actions.reconcile(tracks) }
        .onDisappear {
            requestTask?.cancel()
            requestTask = nil
            activeRequest = nil
        }
    }

    private var scrollingContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LoadStateView(isLoading: model.isLoading, isEmpty: visibleTracks.isEmpty,
                                  error: model.items.isEmpty ? model.error : nil,
                                  emptyTitle: controls.trimmedQuery.isEmpty ? "这里还没有音乐" : "没有匹配的歌曲") { controls.refresh() }
                    TrackList(tracks: visibleTracks, playlistGUID: playlistGUID, scrollProxy: proxy)
                    PageFooter(model: model)
                }.padding(28)
            }
        }
    }

    private var visibleTracks: [Track] {
        let query = controls.trimmedQuery
        guard source != .library, !query.isEmpty else { return model.items }
        return model.items.filter {
            [$0.displayTitle, $0.artistText, $0.album?.displayName ?? ""]
                .contains { $0.localizedStandardContains(query) }
        }
    }

    private var taskIdentity: CatalogRequestIdentity {
        CatalogRequestIdentity(sort: controls.sort, query: controls.query,
                               refreshRevision: controls.refreshRevision, actionsRevision: library.actions.revision)
    }

    private func updateRequest() async {
        guard !Task.isCancelled else { return }
        let identity = CatalogRequestIdentity(sort: controls.sort,
            query: source == .library ? controls.trimmedQuery : "",
            refreshRevision: controls.refreshRevision, actionsRevision: library.actions.revision)
        // Local query changes update only the projection, not pagination or an in-flight page.
        if activeRequest != identity || requestTask == nil {
            requestTask?.cancel()
            activeRequest = identity
            let service = service
            let model = model
            requestTask = Task {
                model.sort = identity.sort
                if !identity.query.isEmpty {
                    await model.loadSnapshot(query: identity.query) { try await service.searchTracks(query: $0) }
                } else { await model.refresh() }
            }
        }
        await requestTask?.value
    }

    private var title: String {
        switch source {
        case .library: "歌曲"
        case .favorites: "喜爱歌曲"
        case .history: "播放历史"
        case .album: "专辑歌曲"
        case .artist: "艺人歌曲"
        case .playlist: "播放列表"
        case .genre: "风格歌曲"
        }
    }

    private var playlistGUID: String? {
        if case .playlist(let guid) = source { return guid }
        return nil
    }
}

struct TrackPageOptions: View {
    @Bindable var controls: CatalogControls
    let source: TrackSource

    var body: some View {
        if source.allowsTitleSort {
            Picker("排序", selection: $controls.sort) {
                Text("默认顺序").tag(source.defaultSort)
                Text("歌曲名称").tag("title,asc")
            }.disabled(source == .library && !controls.trimmedQuery.isEmpty)
        }
        if source == .library {
            if !controls.trimmedQuery.isEmpty {
                Text("搜索按服务器相关度排列，不支持排序或分页；结果可能有上限。")
            }
        } else { Text("搜索仅筛选已加载的歌曲、艺人和专辑；可继续加载更多。") }
        Button("刷新", systemImage: "arrow.clockwise") { controls.refresh() }
    }
}

struct TrackList: View {
    @Environment(LibraryContext.self) private var library
    let tracks: [Track]
    var playlistGUID: String? = nil
    var scrollProxy: ScrollViewProxy? = nil
    @State private var removing: Track?
    @State private var selected: String?

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                HStack(spacing: 12) {
                    Button { library.player.play(track, in: tracks) } label: {
                        Image(systemName: library.player.currentTrack?.guid == track.guid && library.player.isPlaying ? "waveform" : "play.fill")
                            .font(.caption).frame(width: 28)
                    }.buttonStyle(.plain).foregroundStyle(.pink).help("播放")
                    ArtworkView(coverId: track.coverId, cache: library.images, size: 160)
                        .frame(width: 42, height: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(track.artistText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(track.album?.displayName ?? "").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                    if library.actions.busyTracks.contains(track.guid) {
                        ProgressView().controlSize(.mini)
                    } else if library.actions.isFavorite(track) {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.pink)
                    }
                    Text(track.durationSeconds.playbackTime).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                        .frame(width: 45, alignment: .trailing)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(selected == track.guid ? Color.accentColor.opacity(0.1) : (index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { library.player.play(track, in: tracks) }
                .onTapGesture { selected = track.guid }
                .contextMenu {
                    Button("播放") { library.player.play(track, in: tracks) }
                    Button("下一首播放") { library.player.queue.insertNext(track) }
                    Button("添加到队列") { library.player.queue.append(track) }
                    Divider()
                    Button(library.actions.isFavorite(track) ? "取消收藏（实验性）" : "收藏（实验性）") {
                        Task { await library.actions.toggleFavorite(track) }
                    }.disabled(library.actions.busyTracks.contains(track.guid))
                    Button("添加到歌单（实验性）") {
                        if library.actions.experimentalWrites { library.actions.pendingPlaylistTrack = track }
                        else { library.actions.error = "请先在设置中启用实验性写操作。" }
                    }
                    if playlistGUID != nil {
                        Button("从此歌单移除（实验性）", role: .destructive) { removing = track }
                    }
                    Divider()
                    if let album = track.album { Button("查看专辑") { library.navigation.append(.album(album)) } }
                    if let artist = track.artists?.first { Button("查看艺人") { library.navigation.append(.artist(artist)) } }
                }
                .accessibilityElement(children: .combine)
                .id(track.guid)
            }
        }
        .onChange(of: selected) { _, guid in
            if let guid { withAnimation(.easeInOut(duration: 0.15)) { scrollProxy?.scrollTo(guid, anchor: .center) } }
        }
        .confirmationDialog("从当前歌单移除“\(removing?.displayTitle ?? "")”？不会删除原音乐文件。",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                guard let track = removing, let playlistGUID else { return }
                removing = nil
                Task { await library.actions.remove(track, playlistGUID: playlistGUID, service: library.playlistMutations) }
            }
            Button("取消", role: .cancel) { removing = nil }
        }
        .focusable()
        .onKeyPress(.return) {
            guard let track = tracks.first(where: { $0.guid == selected }) else { return .ignored }
            library.player.play(track, in: tracks)
            return .handled
        }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.space) { library.player.toggle(); return .handled }
    }

    private func moveSelection(_ offset: Int) {
        guard !tracks.isEmpty else { return }
        let current = tracks.firstIndex(where: { $0.guid == selected }) ?? (offset > 0 ? -1 : tracks.count)
        selected = tracks[min(max(0, current + offset), tracks.count - 1)].guid
    }
}
