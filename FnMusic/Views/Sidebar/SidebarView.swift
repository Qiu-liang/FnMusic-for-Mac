import SwiftUI

enum SidebarDestination: Hashable, Identifiable {
    case home, favorites, recent, albums, artists, genres, library
    case search, tracks, playlists, recentlyAdded
    case playlist(String)

    static let topItems: [Self] = [.search, .home]
    static let libraryItems: [Self] = [.recentlyAdded, .artists, .albums, .tracks]
    static let playlistItems: [Self] = [.playlists, .favorites]
    static let mainItems: [Self] = topItems + libraryItems + playlistItems
    var id: Self { self }
    var title: String {
        switch self {
        case .home: "主页"
        case .favorites: "喜爱歌曲"
        case .recent: "播放历史"
        case .recentlyAdded: "最近添加"
        case .albums: "专辑"
        case .artists: "艺人"
        case .genres: "风格"
        case .library: "音乐库"
        case .search: "搜索"
        case .tracks: "歌曲"
        case .playlists: "所有播放列表"
        case .playlist: "歌单"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .favorites: "star.square"
        case .recent: "clock.arrow.circlepath"
        case .recentlyAdded: "clock"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .genres: "atom"
        case .library: "music.note.house"
        case .search: "magnifyingglass"
        case .tracks: "music.note"
        case .playlists: "square.grid.3x3"
        case .playlist: "music.note.list"
        }
    }
}

struct SidebarView: View {
    @Environment(LibraryContext.self) private var library
    @Binding var selection: SidebarDestination?
    var userName = "未连接"
    var serverName = "连接你的音乐资料库"
    @State private var creating = false
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            MusicSidebarList(selection: $selection,
                             playlists: library.sidebarPlaylists.items,
                             images: library.images,
                             isLoading: library.sidebarPlaylists.isLoading,
                             error: library.sidebarPlaylists.error,
                             onCreate: { creating = true },
                             onAllPlaylists: { selection = .playlists },
                             onRetry: refresh)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Text(String(userName.prefix(1)))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        LinearGradient(colors: [Color(red: 0.72, green: 0.80, blue: 0.91),
                                                 Color(red: 0.51, green: 0.59, blue: 0.73)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Circle())
                Text(userName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundStyle(Color(nsColor: .labelColor))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 60)
            .help(serverName)
            .accessibilityElement(children: .combine)
            .accessibilityHint(serverName)
        }
        .background(MusicSidebarMaterial().ignoresSafeArea())
        .navigationSplitViewColumnWidth(MusicSidebarMetrics.width)
        .sheet(isPresented: $creating) { PlaylistNameSheet().environment(library) }
        .onDisappear { refreshTask?.cancel() }
    }

    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { await library.sidebarPlaylists.refresh() }
    }
}
