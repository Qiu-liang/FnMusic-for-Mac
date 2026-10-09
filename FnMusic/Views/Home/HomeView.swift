import SwiftUI

struct HomeView: View {
    @Environment(LibraryContext.self) private var library

    var body: some View {
        AlbumsView(service: library.music, recent: true, toolbarTitle: "主页")
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
