import SwiftUI

struct SearchView: View {
    @Environment(LibraryContext.self) private var library
    @State private var model: SearchViewModel
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 20)]

    init(service: any SearchServiceProtocol) { _model = State(initialValue: SearchViewModel(service: service)) }

    var body: some View {
        MusicPageChrome(title: "搜索", placeholder: "搜索歌曲、专辑、艺人和歌单", query: $model.query) {
            Button("清除搜索", systemImage: "xmark.circle") { model.query = "" }
                .disabled(model.query.isEmpty)
            Text("搜索结果可能有服务器上限；显示更多仅展开已收到的结果。")
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView("发现你的音乐", systemImage: "magnifyingglass", description: Text("输入关键词，在你的资料库中查找。"))
                    } else {
                        LoadStateView(isLoading: model.isLoading, isEmpty: model.result.isEmpty, error: model.error,
                                      emptyTitle: "没有找到相关音乐") { await model.search() }
                    }
                    if !model.result.tracks.isEmpty {
                        sectionTitle("歌曲", count: model.result.tracks.count)
                        TrackList(tracks: Array(model.result.tracks.prefix(model.displayLimit)))
                    }
                    if !model.result.albums.isEmpty {
                        sectionTitle("专辑", count: model.result.albums.count)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                            ForEach(Array(model.result.albums.prefix(model.displayLimit))) { album in
                                NavigationLink(value: LibraryRoute.album(album)) {
                                    ArtworkCard(coverId: album.coverId, title: album.displayName, subtitle: album.artistText, cache: library.images)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if !model.result.artists.isEmpty {
                        sectionTitle("艺人", count: model.result.artists.count)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                            ForEach(Array(model.result.artists.prefix(model.displayLimit))) { artist in
                                NavigationLink(value: LibraryRoute.artist(artist)) {
                                    ArtworkCard(coverId: artist.coverId, title: artist.displayName, subtitle: "艺人", cache: library.images)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if !model.result.playlists.isEmpty {
                        sectionTitle("播放列表", count: model.result.playlists.count)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                            ForEach(Array(model.result.playlists.prefix(model.displayLimit))) { playlist in
                                NavigationLink(value: LibraryRoute.playlist(playlist)) {
                                    ArtworkCard(coverId: playlist.coverId, title: playlist.displayName, subtitle: "播放列表", cache: library.images)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if [model.result.tracks.count, model.result.albums.count, model.result.artists.count, model.result.playlists.count].contains(where: { $0 > model.displayLimit }) {
                        Button("显示更多已收到的结果") { model.displayLimit += 60 }
                    }
                    if !model.result.isEmpty {
                        Text("显示服务器实际返回的结果。搜索接口尚无可靠分页契约，可能存在服务器结果上限。")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }.padding(.horizontal, 28).padding(.bottom, 28)
            }
        }
        .task(id: model.query + String(library.actions.revision)) { await model.search() }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.title2.weight(.semibold))
            Text("\(count)").foregroundStyle(.secondary)
        }
    }
}
