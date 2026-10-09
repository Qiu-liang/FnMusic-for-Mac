import SwiftUI

struct ArtistsView: View {
    @Environment(LibraryContext.self) private var library
    @State private var model: ArtistBrowserViewModel
    @State private var directoryAction: Task<Void, Never>?
    @State private var appliedInitialArtistGUID: String?
    private let initialArtist: Artist?

    init(model: ArtistBrowserViewModel, initialArtist: Artist? = nil) {
        _model = State(initialValue: model)
        self.initialArtist = initialArtist
    }

    var body: some View {
        MusicPageChrome(title: "艺人", placeholder: "在艺人中查找", query: $model.query) {
            pageOptions
        } content: {
            HStack(spacing: 0) {
                directory.frame(width: ArtistPageMetrics.directoryWidth)
                    .background {
                        GeometryReader { proxy in Color.clear.preference(key: ArtistPaneBoundsKey.self, value: ["directory": proxy.frame(in: .global)]) }
                    }
                Divider()
                ArtistDiscographyView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        GeometryReader { proxy in Color.clear.preference(key: ArtistPaneBoundsKey.self, value: ["detail": proxy.frame(in: .global)]) }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .onAppear { applyInitialArtist() }
        .onChange(of: initialArtist?.guid) { _, _ in applyInitialArtist() }
        .task(id: model.query + "|" + model.sort) { await model.ensureDirectory() }
        .onDisappear { directoryAction?.cancel() }
    }

    @ViewBuilder private var pageOptions: some View {
        Picker("艺人排序", selection: $model.sort) {
            Text("名称").tag("name,asc")
            Text("歌曲数量").tag("trackCount,desc")
            Text("专辑数量").tag("albumCount,desc")
        }.disabled(!model.query.isEmpty)
        if !model.query.isEmpty { Text("搜索结果按服务器相关度展示") }
        Divider()
        Button("所有艺人") { model.select(.all) }
        Button("合唱（按歌曲署名）") { model.select(.collaborations) }
        Button("返回上个艺人") { model.back() }.disabled(!model.canGoBack)
        Button("前往下个艺人") { model.forward() }.disabled(!model.canGoForward)
        Divider()
        Button("刷新艺人目录") { refreshDirectory() }
        Button("刷新当前作品") {
            directoryAction?.cancel()
            directoryAction = Task { await model.loadDetail() }
        }
        Button("添加已加载歌曲到队列") {
            model.loadedTracks.forEach { library.player.queue.append($0) }
            library.actions.notice = "已将 \(model.loadedTracks.count) 首歌曲加入队列"
        }.disabled(model.loadedTracks.isEmpty)
        if model.isPartialCollaborationFilter { Text("合唱只筛选已加载曲目") }
    }

    private var directory: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(model.artists) { artist in
                        ArtistDirectoryRow(scope: .artist(artist), selected: ArtistScope.artist(artist).id == model.selectedScope.id,
                                           cache: library.images) { model.selectArtist(artist) }
                            .id(ArtistScope.artist(artist).id)
                    }
                    if model.directoryLoading { ProgressView().controlSize(.small).padding(16) }
                    if let error = model.directoryError {
                        VStack(spacing: 8) {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("重试") { refreshDirectory() }
                        }.padding(16)
                    } else if !model.directoryLoading && model.artists.isEmpty {
                        Text(model.query.isEmpty ? "暂无艺人" : "未找到相关艺人")
                            .font(.callout).foregroundStyle(.secondary).padding(24)
                    }
                    if model.directoryHasMore && !model.artists.isEmpty {
                        Button("加载更多艺人") {
                            directoryAction?.cancel()
                            directoryAction = Task { await model.loadMoreArtists() }
                        }.disabled(model.directoryLoading).padding(14)
                    }
                    if !model.query.isEmpty {
                        Text("搜索展示服务器返回的结果，可能存在结果上限。")
                            .font(.caption2).foregroundStyle(.tertiary).padding(16)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, PlayerBarMetrics.contentClearance)
                .background(OverlayScrollIndicators())
            }
            .focusable()
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            .onAppear { proxy.scrollTo(model.selectedScope.id, anchor: .center) }
            .onChange(of: model.selectedScope.id) { _, id in
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("FnMusic.ArtistDirectory")
    }

    private func applyInitialArtist() {
        guard let initialArtist, appliedInitialArtistGUID != initialArtist.guid else { return }
        appliedInitialArtistGUID = initialArtist.guid
        model.selectArtist(initialArtist)
    }

    private func refreshDirectory() {
        directoryAction?.cancel()
        directoryAction = Task { await model.reloadDirectory() }
    }

    private func moveSelection(_ offset: Int) {
        let scopes = model.artists.map(ArtistScope.artist)
        guard !scopes.isEmpty else { return }
        let current = scopes.firstIndex(where: { $0.id == model.selectedScope.id }) ?? (offset > 0 ? -1 : scopes.count)
        model.select(scopes[min(max(0, current + offset), scopes.count - 1)])
    }
}

struct ArtistPaneBoundsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

enum ArtistPageMetrics {
    static let directoryWidth: CGFloat = 300
    static let artworkSize: CGFloat = 200
    static let albumWideMinimum: CGFloat = 530
}

private struct ArtistDirectoryRow: View {
    let scope: ArtistScope
    let selected: Bool
    let cache: ImageCache
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Group {
                        switch scope {
                        case .all: Image(systemName: "music.mic").font(.system(size: 23)).foregroundStyle(.secondary)
                        case .collaborations: Image(systemName: "person.2.fill").font(.system(size: 22)).foregroundStyle(.secondary)
                        case .artist(let artist): ArtworkView(coverId: artist.coverId, cache: cache, size: 160).clipShape(Circle())
                        }
                    }.frame(width: 36, height: 36)
                    Text(scope.title).font(.system(size: 13, weight: selected ? .medium : .regular))
                        .foregroundStyle(Color(nsColor: .labelColor)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(height: 54)
                .background(Color.primary.opacity(selected ? 0.10 : hovering ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(scope.title)
            Rectangle().fill(.primary.opacity(0.10)).frame(height: 0.5)
                .padding(.leading, 54).padding(.trailing, 10).opacity(selected ? 0 : 1)
        }
    }
}
