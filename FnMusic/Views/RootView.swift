import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(LibraryContext.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var unavailableQuery = ""
    @State private var pageToolbarHost = WindowPageToolbarHost()

    var body: some View {
        @Bindable var library = library
        @Bindable var actions = library.actions
        GeometryReader { geometry in
            let sidebarVisible = library.columnVisibility != .detailOnly
            let docked = QueueSidebarMetrics.isDocked(windowWidth: geometry.size.width, sidebarVisible: sidebarVisible)
            let panelWidth = QueueSidebarMetrics.width(windowWidth: geometry.size.width, sidebarVisible: sidebarVisible)
            let panelOpen = library.rightPanel != nil
            let reservedWidth = panelOpen && docked ? panelWidth : 0
            ZStack(alignment: .bottom) {
                HStack(spacing: 0) {
                    catalogPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if panelOpen && docked {
                        RightSidebar().frame(width: panelWidth)
                            .transition(.move(edge: .trailing))
                    }
                }
                // At minimum window sizes preserve the existing page/player
                // width. This unmasked drawer is the ONLY compact fallback;
                // normal desktop sizes above use real, space-consuming columns.
                .overlay(alignment: .trailing) {
                    if panelOpen && !docked {
                        RightSidebar().frame(width: panelWidth)
                            .padding(.bottom, PlayerBarMetrics.contentClearance)
                            .transition(.move(edge: .trailing))
                    }
                }

                // A single stable player stays outside navigation and panel
                // lifetimes. No branches, .id changes or new AudioPlayer instances.
                PlayerBar()
                    .padding(.leading, sidebarVisible ? MusicSidebarMetrics.width : 0)
                    .padding(.trailing, reservedWidth)
                    .zIndex(20)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: panelOpen)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: library.rightPanel)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar(.visible, for: .windowToolbar)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: app.selection) { _, _ in library.resetNavigation() }
        .onChange(of: actions.revision) { _, _ in Task { await library.search.clear() } }
        .onChange(of: library.downloads.message) { _, message in
            if let message { actions.notice = message }
        }
        .onChange(of: library.downloads.error) { _, error in
            if let error { actions.error = error }
        }
        .task(id: actions.revision) { await library.sidebarPlaylists.refresh() }
        .onChange(of: library.sidebarPlaylists.items) { _, playlists in
            if case .playlist(let guid) = app.selection,
               !playlists.contains(where: { $0.guid == guid }) {
                app.selection = .playlists
            }
        }
        .sheet(item: $actions.pendingPlaylistTrack) { track in
            AddToPlaylistView(track: track, service: library.playlists).environment(library)
        }
        .alert("操作未完成", isPresented: Binding(get: { actions.error != nil }, set: { if !$0 { actions.error = nil } })) {
            Button("好", role: .cancel) { actions.error = nil }
        } message: { Text(actions.error ?? "") }
        .overlay(alignment: .top) {
            if !app.network.hasNetworkPath {
                Label("网络不可用，请检查连接后重试", systemImage: "wifi.slash")
                    .font(.callout).padding(12).background(.regularMaterial, in: Capsule())
                    .padding(.top, PageToolbarMetrics.height + 8)
            } else if let notice = actions.notice {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(notice).font(.callout)
                    Button { actions.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(12).background(.regularMaterial, in: Capsule())
                .padding(.top, PageToolbarMetrics.height + 8)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { actions.notice = nil }
                }
            }
        }
    }

    private var catalogPane: some View {
        @Bindable var app = app
        @Bindable var library = library
        return ZStack(alignment: .top) {
            NavigationSplitView(columnVisibility: $library.columnVisibility) {
                SidebarView(selection: $app.selection, userName: app.user?.name ?? "当前用户",
                            serverName: app.configuration?.serverName ?? "飞牛音乐")
                    .padding(.top, PageToolbarMetrics.height)
                    .ignoresSafeArea(.container, edges: .top)
            } detail: {
                NavigationStack(path: $library.navigation) {
                    destination
                        .contentMargins(.bottom, PlayerBarMetrics.contentClearance, for: .scrollContent)
                        .id(app.selection)
                        .navigationTitle("")
                        .navigationBarBackButtonHidden()
                        .navigationDestination(for: LibraryRoute.self) { route in
                            Group {
                                if case .artist(let artist) = route {
                                    ArtistsView(model: library.artistBrowser, initialArtist: artist)
                                } else {
                                    LibraryDetailView(route: route)
                                        .contentMargins(.bottom, PlayerBarMetrics.contentClearance, for: .scrollContent)
                                }
                            }
                            .navigationBarBackButtonHidden()
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
            }
            .toolbar(removing: .sidebarToggle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.windowPageToolbarHost, pageToolbarHost)
            .onPreferenceChange(WindowPageToolbarDescriptorKey.self) { pages in
                Task { @MainActor in pageToolbarHost.updateVisible(pages) }
            }
            WindowPageToolbar(host: pageToolbarHost)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.leading, library.columnVisibility == .detailOnly ? 0 : MusicSidebarMetrics.width)
                .zIndex(30)
            if pageToolbarHost.current?.style == .artist && library.columnVisibility != .detailOnly {
                HStack(spacing: 0) {
                    Color.clear.frame(width: MusicSidebarMetrics.width)
                    Rectangle().fill(.primary.opacity(0.12)).frame(width: 0.5)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(31)
            }
        }
    }

    @ViewBuilder private var destination: some View {
        switch app.selection ?? .home {
        case .home: HomeView(service: library.music)
        case .albums: AlbumsView(service: library.music)
        case .artists: ArtistsView(model: library.artistBrowser)
        case .recentlyAdded: AlbumsView(service: library.music, recent: true)
        case .tracks: TracksView(service: library.music)
        case .favorites: TracksView(service: library.music, source: .favorites)
        case .recent: TracksView(service: library.music, source: .history)
        case .genres: GenresView(service: library.browse)
        case .library: MusicLibraryView()
        case .playlists: PlaylistsView(model: library.sidebarPlaylists)
        case .search: SearchView(service: library.search)
        case .playlist(let guid):
            if let playlist = library.sidebarPlaylists.items.first(where: { $0.guid == guid }) {
                LibraryDetailView(route: .playlist(playlist)).id(playlist)
            } else {
                MusicPageChrome(title: "歌单", placeholder: "在歌单中查找", query: $unavailableQuery, inset: .padded) {
                    Button("查看所有播放列表") { app.selection = .playlists }
                } content: {
                    ContentUnavailableView("歌单不可用", systemImage: "music.note.list",
                                           description: Text("歌单可能已删除，请重新加载歌单列表。"))
                }
            }
        }
    }
}
