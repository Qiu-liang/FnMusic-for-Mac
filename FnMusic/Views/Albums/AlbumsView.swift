import SwiftUI

struct AlbumsView: View {
    @Environment(LibraryContext.self) private var library
    @State private var model: PagedViewModel<Album>
    @State private var controls: CatalogControls
    @State private var requestTask: Task<Void, Never>?
    @State private var activeRequest: CatalogRequestIdentity?
    @State private var visibleDateGroup: AlbumDateGroup?
    @Namespace private var scrollSpace
    private let service: any MusicServiceProtocol
    let recent: Bool
    let artistGUID: String?
    let showsToolbar: Bool
    let toolbarTitle: String?
    private let columns = [GridItem(.adaptive(minimum: 165, maximum: 240), spacing: 20, alignment: .top)]

    init(service: any MusicServiceProtocol, recent: Bool = false, artistGUID: String? = nil,
         showsToolbar: Bool = true, controls: CatalogControls? = nil, toolbarTitle: String? = nil) {
        self.service = service
        self.recent = recent
        self.artistGUID = artistGUID
        self.showsToolbar = showsToolbar
        self.toolbarTitle = toolbarTitle
        let shared = controls ?? CatalogControls(sort: "newTrackAddedAt,desc")
        _controls = State(initialValue: shared)
        _model = State(initialValue: PagedViewModel(sort: shared.sort) { page, sort in
            try await service.albums(page: page, sort: sort, artistGUID: artistGUID)
        })
    }

    var body: some View {
        Group {
            if showsToolbar {
                MusicPageChrome(title: toolbarTitle ?? (recent ? "最近添加" : "专辑"),
                                placeholder: artistGUID == nil ? (recent ? "在最近添加中查找" : "在专辑中查找") : "在已加载专辑中查找", query: $controls.query,
                                displayTitle: recent ? (visibleDateGroup ?? firstDateGroup)?.rawValue : nil) {
                    AlbumPageOptions(controls: controls, recent: recent, searchesLoadedItemsOnly: artistGUID != nil)
                    if let sort = model.returnedSort { Text("服务器排序：\(sort)") }
                } content: { scrollingContent }
            } else { scrollingContent }
        }
        .task(id: taskIdentity) { await updateRequest() }
        .onDisappear {
            requestTask?.cancel()
            requestTask = nil
            activeRequest = nil
        }
    }

    private var scrollingContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if visibleAlbums.isEmpty {
                    LoadStateView(isLoading: model.isLoading, isEmpty: true,
                                  error: model.items.isEmpty ? model.error : nil,
                                  emptyTitle: controls.trimmedQuery.isEmpty ? "这里还没有专辑" : "没有匹配的专辑") { controls.refresh() }
                }
                if recent {
                    ForEach(AlbumDateGroup.allCases) { group in
                        let albums = visibleAlbums.filter { AlbumDateGroup.group(for: $0.createdAt) == group }
                        if !albums.isEmpty {
                            Text(group.rawValue).font(.title3.weight(.semibold))
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: AlbumSectionOffsetsKey.self,
                                            value: [group: geometry.frame(in: .named(scrollSpace)).minY])
                                    }
                                }
                            grid(albums)
                        }
                    }
                } else { grid(visibleAlbums) }
                PageFooter(model: model)
            }.padding(30)
        }
        .coordinateSpace(name: scrollSpace)
        .onPreferenceChange(AlbumSectionOffsetsKey.self) { offsets in
            // Keep the current date section in the titlebar as its heading
            // scrolls underneath the frosted surface.
            visibleDateGroup = AlbumDateGroup.allCases.last(where: {
                if let y = offsets[$0] { return y <= PageToolbarMetrics.height + 1 }
                return false
            }) ?? AlbumDateGroup.allCases.first(where: { offsets[$0] != nil })
        }
    }

    private var firstDateGroup: AlbumDateGroup? {
        AlbumDateGroup.allCases.first { group in
            visibleAlbums.contains { AlbumDateGroup.group(for: $0.createdAt) == group }
        }
    }

    private var visibleAlbums: [Album] {
        let query = controls.trimmedQuery
        guard artistGUID != nil, !query.isEmpty else { return model.items }
        return model.items.filter {
            $0.displayName.localizedStandardContains(query) || $0.artistText.localizedStandardContains(query)
        }
    }

    private var taskIdentity: CatalogRequestIdentity {
        CatalogRequestIdentity(sort: controls.sort, query: controls.query, refreshRevision: controls.refreshRevision)
    }

    private func updateRequest() async {
        guard !Task.isCancelled else { return }
        let identity = CatalogRequestIdentity(sort: controls.sort,
            query: artistGUID == nil ? controls.trimmedQuery : "", refreshRevision: controls.refreshRevision)
        // Typing within an artist scope must not restart the current list or discard loaded pages.
        if activeRequest != identity || requestTask == nil {
            requestTask?.cancel()
            activeRequest = identity
            let service = service
            let model = model
            requestTask = Task {
                model.sort = identity.sort
                if !identity.query.isEmpty {
                    await model.loadSnapshot(query: identity.query) { try await service.searchAlbums(query: $0) }
                } else { await model.refresh() }
            }
        }
        await requestTask?.value
    }

    private func grid(_ albums: [Album]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
            ForEach(albums) { album in
                NavigationLink(value: LibraryRoute.album(album)) {
                    ArtworkCard(coverId: album.coverId, title: album.displayName, subtitle: album.artistText, cache: library.images)
                }.buttonStyle(.plain)
            }
        }
    }
}

struct AlbumPageOptions: View {
    @Bindable var controls: CatalogControls
    var recent: Bool = false
    var searchesLoadedItemsOnly: Bool = false

    var body: some View {
        if !recent {
            Picker("排序", selection: $controls.sort) {
                Text("最近加入曲目").tag("newTrackAddedAt,desc")
                Text("专辑名称").tag("name,asc")
                Text("发行年份").tag("releaseYear,desc")
            }.disabled(!searchesLoadedItemsOnly && !controls.trimmedQuery.isEmpty)
        }
        if searchesLoadedItemsOnly {
            Text("搜索仅筛选已加载的专辑和艺人；可继续加载更多。")
        } else if !controls.trimmedQuery.isEmpty {
            Text("搜索按服务器相关度排列，不支持排序或分页；结果可能有上限。")
        }
        if recent { Text("按专辑创建时间分组，不代表曲目加入时间。") }
        Button("刷新", systemImage: "arrow.clockwise") { controls.refresh() }
    }
}

private struct AlbumSectionOffsetsKey: PreferenceKey {
    static let defaultValue: [AlbumDateGroup: CGFloat] = [:]
    static func reduce(value: inout [AlbumDateGroup: CGFloat], nextValue: () -> [AlbumDateGroup: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum AlbumDateGroup: String, CaseIterable, Identifiable {
    case threeMonths = "最近 3 个月"
    case sixMonths = "最近 6 个月"
    case older = "更早添加"
    case unknown = "添加时间未知"
    var id: String { rawValue }

    static func group(for timestamp: Double?, now: Date = Date()) -> Self {
        guard let timestamp, timestamp > 0 else { return .unknown }
        let date = Date(timeIntervalSince1970: timestamp)
        if let cutoff = Calendar.current.date(byAdding: .month, value: -3, to: now), date >= cutoff { return .threeMonths }
        if let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: now), date >= cutoff { return .sixMonths }
        return .older
    }
}
