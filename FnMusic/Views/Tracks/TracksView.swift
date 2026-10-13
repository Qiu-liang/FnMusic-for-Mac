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
                                query: $controls.query,
                                toolbarStyle: isCollectionDetail ? .playlistDetail : .standard) {
                    TrackPageOptions(controls: controls, source: source)
                    if let sort = model.returnedSort { Text("服务器排序：\(sort)") }
                } content: {
                    if isCollectionDetail { collectionDetailContent }
                    else { scrollingContent }
                }
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

    private var collectionDetailContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    collectionHero.padding(.horizontal, 40)

                    HStack {
                        Text("歌曲")
                        Spacer()
                        Text("时长").padding(.trailing, 42)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 50)
                    .padding(.trailing, 22)
                    .padding(.top, 42)
                    .padding(.bottom, 12)

                    Rectangle().fill(.primary.opacity(0.06)).frame(height: 0.5)
                        .padding(.horizontal, 22)

                    LoadStateView(isLoading: model.isLoading, isEmpty: visibleTracks.isEmpty,
                                  error: model.items.isEmpty ? model.error : nil,
                                  emptyTitle: emptyCollectionTitle) {
                        controls.refresh()
                    }
                    .padding(.horizontal, 40)

                    TrackList(tracks: visibleTracks, scrollProxy: proxy, rowStyle: .collectionDetail)
                        .padding(.horizontal, 22)
                    PageFooter(model: model)
                }
                .padding(.bottom, PlayerBarMetrics.contentClearance + 18)
            }
            .scrollIndicators(.visible)
        }
    }

    private var collectionHero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 32) {
                collectionArtwork(size: 270)
                collectionInformation(height: 270)
            }
            HStack(alignment: .center, spacing: 24) {
                collectionArtwork(size: 190)
                collectionInformation(height: 190)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func collectionArtwork(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(collectionTint.opacity(0.11))
            Image(systemName: collectionSymbol)
                .font(.system(size: size * 0.34, weight: .medium))
                .foregroundStyle(collectionTint)
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.045), lineWidth: 0.5))
        .accessibilityLabel(collectionTitle)
    }

    private func collectionInformation(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            Text(collectionTitle)
                .font(.system(size: 29, weight: .bold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                collectionActionButton("shuffle", title: "随机播放") { playCollection(shuffle: true) }
                Button { playCollection(shuffle: false) } label: {
                    Label("播放", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 112, height: 34)
                        .background(Color.primary.opacity(0.065), in: Capsule())
                }
                .buttonStyle(.plain).foregroundStyle(.pink).disabled(visibleTracks.isEmpty)
                Menu {
                    ForEach(model.items) { track in
                        Button("下载：\(track.displayTitle)…") { library.downloads.download(track) }
                    }
                } label: {
                    Image(systemName: "arrow.down").font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 34).background(Color.primary.opacity(0.065), in: Circle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("下载已加载的\(collectionTitle)")
                .disabled(model.items.isEmpty || library.downloads.isPreparing || library.downloads.isDownloading)
            }
            .padding(.bottom, 1)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
    }

    private func collectionActionButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34).background(Color.primary.opacity(0.065), in: Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.pink).help(title).accessibilityLabel(title)
        .disabled(visibleTracks.isEmpty)
    }

    private func playCollection(shuffle: Bool) {
        let tracks = visibleTracks
        guard let track = shuffle ? tracks.randomElement() : tracks.first else { return }
        library.player.queue.shuffle = shuffle
        library.player.play(track, in: tracks)
    }

    private var isCollectionDetail: Bool { source == .favorites || source == .history }
    private var collectionTitle: String { source == .favorites ? "喜爱歌曲" : "最近播放" }
    private var collectionSymbol: String { source == .favorites ? "star.fill" : "clock.arrow.circlepath" }
    private var collectionTint: Color { source == .favorites ? .pink : .indigo }
    private var emptyCollectionTitle: String {
        let title = source == .favorites ? "还没有喜爱的歌曲" : "暂无最近播放记录"
        return controls.trimmedQuery.isEmpty ? title : "没有匹配的歌曲"
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
        case .history: "最近播放"
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

enum TrackListRowStyle: Equatable {
    case standard
    case collectionDetail
}

struct TrackList: View {
    @Environment(LibraryContext.self) private var library
    let tracks: [Track]
    var playlistGUID: String? = nil
    var scrollProxy: ScrollViewProxy? = nil
    var rowStyle: TrackListRowStyle = .standard
    @State private var removing: Track?
    @State private var selected: String?

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                rowContent(track)
                .padding(.horizontal, rowStyle == .collectionDetail ? 0 : 10)
                .padding(.vertical, rowStyle == .collectionDetail ? 7 : 8)
                .background {
                    if selected == track.guid {
                        RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.1))
                    } else if rowStyle == .standard && index.isMultiple(of: 2) {
                        RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.025))
                    }
                }
                .overlay(alignment: .bottom) {
                    if rowStyle == .collectionDetail {
                        Rectangle().fill(.primary.opacity(0.075)).frame(height: 0.5).padding(.leading, 58)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { library.player.play(track, in: tracks) }
                .onTapGesture { selected = track.guid }
                .contextMenu { trackActions(for: track) }
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

    @ViewBuilder private func rowContent(_ track: Track) -> some View {
        if rowStyle == .collectionDetail {
            HStack(spacing: 12) {
                Button {
                    if library.actions.experimentalWrites {
                        Task { await library.actions.toggleFavorite(track) }
                    } else {
                        library.actions.error = "请先在设置中启用实验性写操作。"
                    }
                } label: {
                    Group {
                        if library.actions.busyTracks.contains(track.guid) { ProgressView().controlSize(.mini) }
                        else { Image(systemName: library.actions.isFavorite(track) ? "star.fill" : "star") }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(library.actions.isFavorite(track) ? Color.pink : Color.secondary)
                    .frame(width: 16, height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(library.actions.isFavorite(track) ? 1 : 0.55)
                .help(library.actions.isFavorite(track) ? "取消收藏" : "收藏歌曲")
                .disabled(library.actions.busyTracks.contains(track.guid))

                ArtworkView(coverId: track.coverId, cache: library.images, size: 160)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text([track.album?.displayName, track.artistText].compactMap { $0 }.joined(separator: " – "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(track.durationSeconds.playbackTime).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
                Menu { trackActions(for: track) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 24, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityLabel("\(track.displayTitle)更多操作")
            }
        } else {
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
        }
    }

    @ViewBuilder private func trackActions(for track: Track) -> some View {
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

    private func moveSelection(_ offset: Int) {
        guard !tracks.isEmpty else { return }
        let current = tracks.firstIndex(where: { $0.guid == selected }) ?? (offset > 0 ? -1 : tracks.count)
        selected = tracks[min(max(0, current + offset), tracks.count - 1)].guid
    }
}
