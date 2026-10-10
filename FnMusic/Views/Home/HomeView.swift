import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(LibraryContext.self) private var library
    @State private var query = ""
    @State private var refreshRevision = 0
    @State private var history: PagedViewModel<Track>
    @State private var albums: PagedViewModel<Album>
    @State private var tracks: PagedViewModel<Track>

    init(service: any MusicServiceProtocol) {
        _history = State(initialValue: PagedViewModel(sort: TrackSource.history.defaultSort) { page, sort in
            try await service.tracks(page: page, sort: sort, source: .history)
        })
        _albums = State(initialValue: PagedViewModel(sort: "newTrackAddedAt,desc") { page, sort in
            try await service.albums(page: page, sort: sort, artistGUID: nil)
        })
        _tracks = State(initialValue: PagedViewModel(sort: TrackSource.library.defaultSort) { page, sort in
            try await service.tracks(page: page, sort: sort, source: .library)
        })
    }

    var body: some View {
        MusicPageChrome(title: "主页", placeholder: "在首页内容中查找", query: $query) {
            Button("刷新首页", systemImage: "arrow.clockwise") { refreshRevision &+= 1 }
            Text("搜索仅筛选当前已加载的首页内容。")
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HomeCarouselSection(title: "最近播放", itemIDs: filteredHistory.prefix(12).map(\.guid),
                                        onSeeAll: { app.selection = .recent }) {
                        if !filteredHistory.isEmpty {
                            ForEach(filteredHistory.prefix(12)) { track in
                                Button { library.player.play(track, in: history.items) } label: {
                                    HomeArtworkCard(coverId: track.album?.coverId ?? track.coverId,
                                                    title: track.displayTitle,
                                                    subtitle: track.album?.displayName ?? track.artistText,
                                                    cache: library.images)
                                }
                                .id(track.guid)
                                .buttonStyle(.plain)
                                .help("播放：\(track.displayTitle)")
                            }
                        } else {
                            HomeSectionStatus(isLoading: history.isLoading, error: history.error,
                                             emptyTitle: "暂无最近播放记录") { Task { await history.refresh() } }
                        }
                    }

                    HomeCarouselSection(title: "最近添加专辑", itemIDs: filteredAlbums.prefix(12).map(\.guid),
                                        onSeeAll: { app.selection = .recentlyAdded }) {
                        if !filteredAlbums.isEmpty {
                            ForEach(filteredAlbums.prefix(12)) { album in
                                NavigationLink(value: LibraryRoute.album(album)) {
                                    HomeArtworkCard(coverId: album.coverId, title: album.displayName,
                                                    subtitle: album.artistText, cache: library.images)
                                }
                                .id(album.guid)
                                .buttonStyle(.plain)
                            }
                        } else {
                            HomeSectionStatus(isLoading: albums.isLoading, error: albums.error,
                                             emptyTitle: "暂无最近添加的专辑") { Task { await albums.refresh() } }
                        }
                    }

                    HomeCarouselSection(title: "最近添加歌曲", itemIDs: filteredTracks.prefix(12).map(\.guid),
                                        onSeeAll: { app.selection = .tracks }) {
                        if !filteredTracks.isEmpty {
                            ForEach(filteredTracks.prefix(12)) { track in
                                Button { library.player.play(track, in: tracks.items) } label: {
                                    HomeArtworkCard(coverId: track.album?.coverId ?? track.coverId,
                                                    title: track.displayTitle,
                                                    subtitle: track.artistText,
                                                    cache: library.images)
                                }
                                .id(track.guid)
                                .buttonStyle(.plain)
                                .help("播放：\(track.displayTitle)")
                            }
                        } else {
                            HomeSectionStatus(isLoading: tracks.isLoading, error: tracks.error,
                                             emptyTitle: "暂无最近添加的歌曲") { Task { await tracks.refresh() } }
                        }
                    }

                    HomeCarouselSection(title: "歌单", itemIDs: filteredPlaylists.prefix(12).map(\.guid),
                                        onSeeAll: { app.selection = .playlists }) {
                        if !filteredPlaylists.isEmpty {
                            ForEach(filteredPlaylists.prefix(12)) { playlist in
                                NavigationLink(value: LibraryRoute.playlist(playlist)) {
                                    HomeArtworkCard(coverId: playlist.coverId, title: playlist.displayName,
                                                    subtitle: playlist.trackCount.map { "\($0) 首歌曲" } ?? "播放列表",
                                                    cache: library.images)
                                }
                                .id(playlist.guid)
                                .buttonStyle(.plain)
                            }
                        } else {
                            HomeSectionStatus(isLoading: library.sidebarPlaylists.isLoading,
                                             error: library.sidebarPlaylists.error,
                                             emptyTitle: "暂无歌单") {
                                Task { await library.sidebarPlaylists.refresh() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 26)
            }
        }
        .task(id: refreshRevision) { await refreshHome() }
    }

    private var filteredHistory: [Track] { filter(tracks: history.items) }
    private var filteredTracks: [Track] { filter(tracks: tracks.items) }

    private var filteredAlbums: [Album] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return albums.items }
        return albums.items.filter {
            $0.displayName.localizedStandardContains(term) || $0.artistText.localizedStandardContains(term)
        }
    }

    private var filteredPlaylists: [Playlist] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return library.sidebarPlaylists.items }
        return library.sidebarPlaylists.items.filter { $0.displayName.localizedStandardContains(term) }
    }

    private func filter(tracks: [Track]) -> [Track] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return tracks }
        return tracks.filter {
            $0.displayTitle.localizedStandardContains(term) ||
            $0.artistText.localizedStandardContains(term) ||
            ($0.album?.displayName.localizedStandardContains(term) ?? false)
        }
    }

    private func refreshHome() async {
        async let historyRefresh: Void = history.refresh()
        async let albumRefresh: Void = albums.refresh()
        async let trackRefresh: Void = tracks.refresh()
        _ = await (historyRefresh, albumRefresh, trackRefresh)
    }
}

private struct HomeCarouselSection<Content: View>: View {
    let title: String
    let itemIDs: [String]
    let onSeeAll: () -> Void
    @ViewBuilder let content: Content
    @State private var firstVisibleIndex = 0
    @State private var viewportWidth: CGFloat = 0

    private let sideInset: CGFloat = 46
    private let spacing: CGFloat = 16
    private var spaceName: String { "HomeCarousel.\(title)" }

    private var visibleItemCount: Int {
        guard viewportWidth > 0 else { return 1 }
        let usableWidth = max(HomeArtworkCard.size, viewportWidth - sideInset * 2)
        return max(1, Int((usableWidth + spacing) / (HomeArtworkCard.size + spacing)))
    }

    private var lastFirstVisibleIndex: Int { max(0, itemIDs.count - visibleItemCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                Button(action: onSeeAll) {
                    HStack(spacing: 4) {
                        Text("全部")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看全部\(title)")
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: spacing) { content }
                        .padding(.horizontal, sideInset)
                        .padding(.bottom, 3)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: HomeCarouselOffsetKey.self,
                                                       value: max(0, -geometry.frame(in: .named(spaceName)).minX))
                            }
                        }
                        .background(HideHorizontalScroller())
                }
                .coordinateSpace(name: spaceName)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: HomeCarouselViewportWidthKey.self, value: geometry.size.width)
                    }
                }
                .scrollIndicators(.hidden, axes: .horizontal)
                .overlay(alignment: .leading) {
                    carouselButton(direction: -1, disabled: firstVisibleIndex == 0) {
                        move(by: -max(1, visibleItemCount - 1), using: proxy)
                    }
                    .padding(.leading, 5)
                }
                .overlay(alignment: .trailing) {
                    carouselButton(direction: 1,
                                   disabled: itemIDs.count <= visibleItemCount || firstVisibleIndex >= lastFirstVisibleIndex) {
                        move(by: max(1, visibleItemCount - 1), using: proxy)
                    }
                    .padding(.trailing, 5)
                }
                .onPreferenceChange(HomeCarouselOffsetKey.self) { offset in
                    let inferred = Int((offset / (HomeArtworkCard.size + spacing)).rounded())
                    let clamped = min(max(0, inferred), lastFirstVisibleIndex)
                    if firstVisibleIndex != clamped { firstVisibleIndex = clamped }
                }
                .onPreferenceChange(HomeCarouselViewportWidthKey.self) { width in
                    if viewportWidth != width { viewportWidth = width }
                }
                .onChange(of: itemIDs) { _, ids in
                    firstVisibleIndex = 0
                    if let first = ids.first {
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(first, anchor: .leading) }
                    }
                }
            }
        }
    }

    private func move(by offset: Int, using proxy: ScrollViewProxy) {
        guard !itemIDs.isEmpty else { return }
        let target = min(max(0, firstVisibleIndex + offset), lastFirstVisibleIndex)
        guard itemIDs.indices.contains(target) else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            proxy.scrollTo(itemIDs[target], anchor: .leading)
        }
    }

    private func carouselButton(direction: Int, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .modifier(HomeCarouselArrowGlass())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .help(direction < 0 ? "向左滚动\(title)" : "向右滚动\(title)")
        .accessibilityLabel(direction < 0 ? "向左滚动\(title)" : "向右滚动\(title)")
        .zIndex(2)
    }
}

private struct HomeCarouselOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct HomeCarouselViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct HomeCarouselArrowGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.14), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(!reduceMotion), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
        }
    }
}

private struct HomeArtworkCard: View {
    static let size: CGFloat = 180

    let coverId: String?
    let title: String
    let subtitle: String
    let cache: ImageCache

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(coverId: coverId, cache: cache, size: 160)
                .frame(width: Self.size, height: Self.size)
                .shadow(color: .black.opacity(0.05), radius: 3, y: 2)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: Self.size, alignment: .topLeading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct HomeSectionStatus: View {
    let isLoading: Bool
    let error: String?
    let emptyTitle: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("正在加载…")
            } else if let error {
                Text(error).lineLimit(2)
                Button("重试", action: retry).buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Image(systemName: "music.note.list").foregroundStyle(.tertiary)
                Text(emptyTitle)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(height: 178, alignment: .center)
        .frame(minWidth: 260, alignment: .leading)
    }
}

struct MusicLibraryView: View {
    @Environment(LibraryContext.self) private var library
    @State private var tab = 0
    @State private var trackControls = CatalogControls(sort: TrackSource.library.defaultSort)
    @State private var libraryQuery = ""
    @State private var libraryRefreshRevision = 0

    var body: some View {
        MusicPageChrome(title: "音乐库", placeholder: tab == 0 ? "搜索歌曲" : "搜索共享库名称或路径", query: searchQuery) {
            Picker("视图", selection: $tab) {
                Text("所有歌曲").tag(0)
                Text("共享音乐库").tag(1)
            }
            Divider()
            if tab == 0 {
                TrackPageOptions(controls: trackControls, source: .library)
            } else {
                Button("刷新", systemImage: "arrow.clockwise") { libraryRefreshRevision += 1 }
            }
        } content: {
            if tab == 0 {
                TracksView(service: library.music, source: .library, showsToolbar: false, controls: trackControls)
            } else {
                SharedLibrariesView(service: library.browse, showsToolbar: false,
                                    query: $libraryQuery, refreshRevision: libraryRefreshRevision)
            }
        }
    }

    private var searchQuery: Binding<String> {
        Binding(
            get: { tab == 0 ? trackControls.query : libraryQuery },
            set: { value in
                if tab == 0 { trackControls.query = value }
                else { libraryQuery = value }
            }
        )
    }
}
