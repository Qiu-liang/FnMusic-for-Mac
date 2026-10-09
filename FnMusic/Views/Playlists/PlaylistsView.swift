import SwiftUI

struct PlaylistsView: View {
    @Environment(LibraryContext.self) private var library
    @State private var model: PlaylistListViewModel
    @State private var query = ""
    @State private var creating = false
    @State private var renaming: Playlist?
    @State private var deleting: Playlist?
    @State private var busy = false
    @State private var refreshTask: Task<Void, Never>?

    init(model: PlaylistListViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        MusicPageChrome(title: "所有播放列表", placeholder: "搜索播放列表", query: $query) {
            Button("新建歌单（实验性）", systemImage: "plus") {
                guard library.actions.experimentalWrites else {
                    library.actions.error = "请先在设置中启用实验性写操作。"
                    return
                }
                creating = true
            }
            Button("刷新", systemImage: "arrow.clockwise") {
                refreshTask?.cancel()
                refreshTask = Task { await model.refresh() }
            }
        } content: {
            ScrollView {
                VStack(spacing: 24) {
                    LoadStateView(isLoading: model.isLoading, isEmpty: model.items.isEmpty, error: model.error, emptyTitle: "还没有播放列表") { await model.refresh() }
                    if !model.items.isEmpty && filteredPlaylists.isEmpty {
                        Text("没有匹配的播放列表").font(.callout).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 165, maximum: 240), spacing: 20)], spacing: 26) {
                        ForEach(filteredPlaylists) { playlist in
                            NavigationLink(value: LibraryRoute.playlist(playlist)) {
                                ArtworkCard(coverId: playlist.coverId, title: playlist.displayName,
                                            subtitle: playlist.trackCount.map { "\($0) 首歌曲" } ?? "播放列表", cache: library.images)
                            }.buttonStyle(.plain)
                            .contextMenu {
                                Button("重命名（实验性）") { renaming = playlist }
                                Button("删除歌单（实验性）", role: .destructive) { deleting = playlist }
                            }
                        }
                    }
                }.padding(30)
            }
        }
        // RootView owns loading this shared model, keeping sidebar and grid in sync.
        .sheet(isPresented: $creating) { PlaylistNameSheet().environment(library) }
        .sheet(item: $renaming) { playlist in PlaylistNameSheet(playlist: playlist).environment(library) }
        .confirmationDialog("确定删除“\(deleting?.displayName ?? "")”吗？此操作无法撤销。",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let target = deleting else { return }
                deleting = nil
                guard library.actions.experimentalWrites else {
                    library.actions.error = "请先在设置中启用实验性写操作。"
                    return
                }
                busy = true
                Task {
                    do {
                        try await library.playlistMutations.delete(target)
                        library.actions.revision += 1
                        library.actions.notice = "歌单已删除并读回确认"
                    } catch { library.actions.error = error.localizedDescription }
                    busy = false
                }
            }
            Button("取消", role: .cancel) { deleting = nil }
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
        .disabled(busy)
        .overlay { if busy { ProgressView("正在删除并验证…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
    }

    private var filteredPlaylists: [Playlist] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return model.items }
        return model.items.filter { $0.name?.localizedStandardContains(term) == true }
    }
}
