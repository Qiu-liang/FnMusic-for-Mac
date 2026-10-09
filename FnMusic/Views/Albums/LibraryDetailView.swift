import SwiftUI
import Observation

@MainActor @Observable
final class DetailViewModel {
    var route: LibraryRoute
    var error: String?
    var loading = true
    private var generation = UUID()
    init(route: LibraryRoute) { self.route = route }

    func load(library: LibraryContext) async {
        let identity = UUID()
        generation = identity
        loading = true
        error = nil
        defer { if generation == identity { loading = false } }
        do {
            let updated: LibraryRoute
            switch route {
            case .album(let album): updated = .album(try await library.music.album(guid: album.guid))
            case .artist(let artist): updated = .artist(try await library.music.artist(guid: artist.guid))
            case .playlist(let playlist): updated = .playlist(try await library.playlists.detail(guid: playlist.guid))
            case .genre: updated = route
            }
            try Task.checkCancellation()
            guard generation == identity else { return }
            route = updated
        } catch is CancellationError { }
        catch { if generation == identity && !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct LibraryDetailView: View {
    @Environment(LibraryContext.self) private var library
    @State private var model: DetailViewModel
    @State private var controls: CatalogControls

    init(route: LibraryRoute) {
        _model = State(initialValue: DetailViewModel(route: route))
        _controls = State(initialValue: CatalogControls(sort: Self.trackSource(for: route).defaultSort))
    }

    var body: some View {
        if case .artist(let artist) = model.route {
            ArtistsView(model: library.artistBrowser, initialArtist: artist)
        } else {
            MusicPageChrome(title: headerInfo.title, placeholder: "在已加载歌曲中查找", query: $controls.query, inset: .padded) {
                TrackPageOptions(controls: controls, source: Self.trackSource(for: model.route))
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = model.error {
                        HStack {
                            Text(error).font(.callout).foregroundStyle(.red)
                            Button("重试") { controls.refresh() }
                        }.padding()
                    }
                    header.padding(28)
                    Divider()
                    TracksView(service: library.music, source: Self.trackSource(for: model.route),
                               showsToolbar: false, controls: controls)
                }
            }
            .task(id: controls.refreshRevision) { await model.load(library: library) }
        }
    }

    private static func trackSource(for route: LibraryRoute) -> TrackSource {
        switch route {
        case .album(let album): .album(album.guid)
        case .artist(let artist): .artist(artist.guid)
        case .playlist(let playlist): .playlist(playlist.guid)
        case .genre(let guid, _): .genre(guid)
        }
    }

    private var header: some View {
        let info = headerInfo
        return HStack(alignment: .bottom, spacing: 28) {
            ArtworkView(coverId: info.cover, cache: library.images).frame(width: 180, height: 180)
                .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 12) {
                Text(info.kind).font(.caption.weight(.semibold)).foregroundStyle(.pink)
                Text(info.title).font(.system(size: 28, weight: .bold)).lineLimit(2)
                Text(info.subtitle).font(.title3).foregroundStyle(.secondary)
                if model.loading { ProgressView().controlSize(.small) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerInfo: (cover: String?, kind: String, title: String, subtitle: String) {
        switch model.route {
        case .album(let album):
            (album.coverId, "专辑", album.displayName,
             [album.artistText, album.releaseDate, album.trackCount.map { "\($0) 首歌曲" }].compactMap { $0 }.joined(separator: " · "))
        case .artist(let artist):
            (artist.coverId, "艺人", artist.displayName, "")
        case .playlist(let playlist):
            (playlist.coverId, "歌单", playlist.displayName, playlist.trackCount.map { "\($0) 首歌曲" } ?? "")
        case .genre(_, let name):
            (nil, "风格", name, "关联歌曲 · 非空流派关系尚待服务器验证")
        }
    }
}
