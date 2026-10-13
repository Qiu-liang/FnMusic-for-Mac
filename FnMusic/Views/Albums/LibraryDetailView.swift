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
            MusicPageChrome(title: headerInfo.title, placeholder: "在已加载歌曲中查找", query: $controls.query,
                            inset: isAlbum ? .scroll : .padded) {
                TrackPageOptions(controls: controls, source: Self.trackSource(for: model.route))
            } content: {
                if case .album(let album) = model.route {
                    AlbumDetailContent(album: album, service: library.music, controls: controls)
                        .id(album.guid)
                } else {
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
            }
            .task(id: controls.refreshRevision) { await model.load(library: library) }
        }
    }

    private var isAlbum: Bool {
        if case .album = model.route { return true }
        return false
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

/// Album details use the same track actions and artwork cards as the artist pages,
/// while keeping their track list and supporting sections in one native scroll view.
private struct AlbumDetailContent: View {
    @Environment(LibraryContext.self) private var library
    let album: Album
    let service: any MusicServiceProtocol
    let controls: CatalogControls
    @State private var model: PagedViewModel<Track>
    @State private var requestTask: Task<Void, Never>?
    @State private var activeRequest: CatalogRequestIdentity?

    init(album: Album, service: any MusicServiceProtocol, controls: CatalogControls) {
        self.album = album
        self.service = service
        self.controls = controls
        _model = State(initialValue: PagedViewModel(sort: controls.sort) { page, sort in
            try await service.tracks(page: page, sort: sort, source: .album(album.guid))
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                albumHero
                albumTracks
                albumMetadata
                if let artist = album.artists?.first {
                    RelatedArtistAlbums(artist: artist, currentAlbumGUID: album.guid, service: service)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, PlayerBarMetrics.contentClearance + 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .task(id: taskIdentity) { await updateRequest() }
        .onChange(of: model.items) { _, tracks in library.actions.reconcile(tracks) }
        .onDisappear {
            requestTask?.cancel()
            requestTask = nil
            activeRequest = nil
        }
        .accessibilityIdentifier("FnMusic.AlbumDetail")
    }

    private var albumHero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 32) {
                albumArtwork(size: 270)
                albumInformation
            }
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 24) {
                    albumArtwork(size: 190)
                    albumInformation
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func albumArtwork(size: CGFloat) -> some View {
        ArtworkView(coverId: album.coverId, cache: library.images)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.045), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
            .accessibilityLabel("专辑封面：\(album.displayName)")
    }

    private var albumInformation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("专辑").font(.caption.weight(.semibold)).foregroundStyle(.pink)
            Text(album.displayName)
                .font(.system(size: 29, weight: .bold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let artist = album.artists?.first {
                Button { library.navigation.append(.artist(artist)) } label: {
                    Text(album.artistText).font(.system(size: 20, weight: .semibold)).foregroundStyle(.pink)
                }.buttonStyle(.plain)
            } else {
                Text(album.artistText).font(.system(size: 20, weight: .semibold)).foregroundStyle(.pink)
            }
            if let releaseYear {
                Text(releaseYear).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if model.isLoading && model.items.isEmpty { ProgressView().controlSize(.small) }
            HStack(spacing: 10) {
                albumAction("shuffle", title: "随机播放") { play(shuffle: true) }
                Button { play(shuffle: false) } label: {
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
                .help("下载此专辑中已加载的歌曲")
                .disabled(model.items.isEmpty || library.downloads.isPreparing || library.downloads.isDownloading)
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func albumAction(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34).background(Color.primary.opacity(0.065), in: Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.pink).help(title).accessibilityLabel(title)
        .disabled(visibleTracks.isEmpty)
    }

    private var albumTracks: some View {
        VStack(spacing: 0) {
            if let error = model.error, model.items.isEmpty {
                LoadStateView(isLoading: model.isLoading, isEmpty: true, error: error,
                              emptyTitle: "专辑中没有歌曲") { controls.refresh() }
            } else if model.items.isEmpty && !model.isLoading {
                LoadStateView(isLoading: false, isEmpty: true, error: nil,
                              emptyTitle: controls.trimmedQuery.isEmpty ? "专辑中没有歌曲" : "没有匹配的歌曲") { controls.refresh() }
            }
            ForEach(Array(visibleTracks.enumerated()), id: \.element.guid) { index, track in
                ArtistTrackRow(track: track, index: index + 1, queue: model.items) { artist in
                    library.navigation.append(.artist(artist))
                }
                .padding(.horizontal, 4)
                Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5)
            }
            if model.isLoading && !model.items.isEmpty {
                ProgressView().controlSize(.small).padding(12)
            } else if model.hasMore && !model.items.isEmpty {
                Button(model.error == nil ? "加载更多歌曲" : "重试加载歌曲") {
                    Task { await model.loadMore() }
                }
                .disabled(model.isLoading)
                .font(.caption)
                .padding(10)
            }
            if let error = model.error, !model.items.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 10)
            }
        }
        .padding(.top, 2)
    }

    private var albumMetadata: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let releaseDate = album.releaseDate, !releaseDate.isEmpty {
                Label("发行日期  \(releaseDate)", systemImage: "calendar")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            let totalDuration = model.items.reduce(0) { $0 + $1.durationSeconds }
            let trackCount = model.total ?? album.trackCount ?? model.items.count
            if trackCount > 0 {
                Text("\(trackCount) 首歌曲" + (totalDuration > 0 ? "，已加载曲目时长 \(totalDuration.playbackTime)" : ""))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let barcode = album.barcode, !barcode.isEmpty {
                Text("条码  \(barcode)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.top, -10)
    }

    private var visibleTracks: [Track] {
        let query = controls.trimmedQuery
        guard !query.isEmpty else { return model.items }
        return model.items.filter {
            [$0.displayTitle, $0.artistText, $0.album?.displayName ?? ""]
                .contains { $0.localizedStandardContains(query) }
        }
    }

    private var releaseYear: String? {
        guard let releaseDate = album.releaseDate?.nilIfEmpty else { return nil }
        return releaseDate.split(separator: "-", maxSplits: 1).first.map(String.init)
    }

    private var taskIdentity: CatalogRequestIdentity {
        CatalogRequestIdentity(sort: controls.sort, query: "", refreshRevision: controls.refreshRevision,
                               actionsRevision: library.actions.revision)
    }

    private func updateRequest() async {
        guard !Task.isCancelled else { return }
        let identity = taskIdentity
        if activeRequest != identity || requestTask == nil {
            requestTask?.cancel()
            activeRequest = identity
            let model = model
            let sort = identity.sort
            requestTask = Task {
                model.sort = sort
                await model.refresh()
            }
        }
        await requestTask?.value
    }

    private func play(shuffle: Bool) {
        let tracks = visibleTracks
        guard let track = shuffle ? tracks.randomElement() : tracks.first else { return }
        library.player.queue.shuffle = shuffle
        library.player.play(track, in: model.items)
    }
}

private struct RelatedArtistAlbums: View {
    @Environment(LibraryContext.self) private var library
    let artist: Artist
    let currentAlbumGUID: String
    @State private var model: PagedViewModel<Album>

    init(artist: Artist, currentAlbumGUID: String, service: any MusicServiceProtocol) {
        self.artist = artist
        self.currentAlbumGUID = currentAlbumGUID
        _model = State(initialValue: PagedViewModel(sort: "newTrackAddedAt,desc") { page, sort in
            try await service.albums(page: page, sort: sort, artistGUID: artist.guid)
        })
    }

    var body: some View {
        Group {
            if !relatedAlbums.isEmpty || model.isLoading || model.error != nil {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("更多\(artist.displayName)的作品").font(.system(size: 17, weight: .semibold))
                        Spacer()
                        if model.isLoading && model.items.isEmpty { ProgressView().controlSize(.small) }
                    }
                    if let error = model.error, model.items.isEmpty {
                        HStack(spacing: 10) {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("重试") { Task { await model.refresh() } }
                        }
                    } else {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 18) {
                                ForEach(relatedAlbums) { album in
                                    Button { library.navigation.append(.album(album)) } label: {
                                        ArtworkCard(coverId: album.coverId, title: album.displayName,
                                                    subtitle: album.releaseDate ?? album.artistText, cache: library.images)
                                            .frame(width: 170)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("打开专辑：\(album.displayName)")
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .scrollIndicators(.hidden)
                        .background { HideHorizontalScroller() }
                    }
                }
            }
        }
        .task { await model.refresh() }
        .accessibilityIdentifier("FnMusic.RelatedArtistAlbums")
    }

    private var relatedAlbums: [Album] {
        model.items.filter { $0.guid != currentAlbumGUID }
    }
}
