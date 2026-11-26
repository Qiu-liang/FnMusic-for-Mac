import SwiftUI

struct PlaylistDetailContent: View {
    @Environment(LibraryContext.self) private var library
    let playlist: Playlist
    let service: any MusicServiceProtocol
    let controls: CatalogControls
    @State private var model: PagedViewModel<Track>
    @State private var requestTask: Task<Void, Never>?
    @State private var activeRequest: CatalogRequestIdentity?
    @State private var isPreparingPlayback = false
    @State private var playTask: Task<Void, Never>?

    init(playlist: Playlist, service: any MusicServiceProtocol, controls: CatalogControls) {
        self.playlist = playlist
        self.service = service
        self.controls = controls
        _model = State(initialValue: PagedViewModel(sort: controls.sort) { page, sort in
            try await service.tracks(page: page, sort: sort, source: .playlist(playlist.guid))
        })
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    playlistHero.padding(.horizontal, 40)

                    HStack {
                        Text("歌曲")
                        Spacer()
                        Text("时长").padding(.trailing, 42)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 50)
                    .padding(.trailing, 22)
                    .padding(.top, 42)
                    .padding(.bottom, 12)

                    Rectangle().fill(.primary.opacity(0.06)).frame(height: 0.5)
                        .padding(.horizontal, 22)

                    LoadStateView(isLoading: model.isLoading, isEmpty: visibleTracks.isEmpty,
                                  error: model.items.isEmpty ? model.error : nil,
                                  emptyTitle: controls.trimmedQuery.isEmpty ? "歌单中没有歌曲" : "没有匹配的歌曲") {
                        controls.refresh()
                    }
                    .padding(.horizontal, 40)

                    TrackList(tracks: visibleTracks, playlistGUID: playlist.guid, scrollProxy: proxy,
                              rowStyle: .collectionDetail, onPlayTrack: { playTrack($0) })
                        .padding(.horizontal, 22)
                    PageFooter(model: model)
                }
                .padding(.bottom, PlayerBarMetrics.contentClearance + 18)
            }
            .scrollIndicators(.visible)
        }
        .task(id: taskIdentity) { await updateRequest() }
        .onChange(of: model.items) { _, tracks in library.actions.reconcile(tracks) }
        .onDisappear {
            requestTask?.cancel()
            requestTask = nil
            activeRequest = nil
            playTask?.cancel()
            playTask = nil
            isPreparingPlayback = false
        }
        .accessibilityIdentifier("FnMusic.PlaylistDetail")
    }

    private var playlistHero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 32) {
                artwork(size: 270)
                playlistInformation(height: 270)
            }
            HStack(alignment: .center, spacing: 24) {
                artwork(size: 190)
                playlistInformation(height: 190)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func artwork(size: CGFloat) -> some View {
        ArtworkView(coverId: playlist.coverId, cache: library.images)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.045), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
            .accessibilityLabel("歌单封面：\(playlist.displayName)")
    }

    private func playlistInformation(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            Text(playlist.displayName)
                .font(.system(size: 29, weight: .bold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                actionButton("shuffle", title: "随机播放", isLoading: isPreparingPlayback) { play(shuffle: true) }
                Button { play(shuffle: false) } label: {
                    Label("播放", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 112, height: 34)
                        .background(Color.primary.opacity(0.065), in: Capsule())
                }
                .buttonStyle(.plain).foregroundStyle(.pink).disabled(visibleTracks.isEmpty)
            }
            .padding(.bottom, 1)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
    }

    private func actionButton(_ symbol: String, title: String, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isLoading { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
            }
            .frame(width: 34, height: 34).background(Color.primary.opacity(0.065), in: Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.pink).help(title).accessibilityLabel(title)
        .disabled(visibleTracks.isEmpty || isLoading)
    }

    private var visibleTracks: [Track] {
        let query = controls.trimmedQuery
        guard !query.isEmpty else { return model.items }
        return model.items.filter {
            [$0.displayTitle, $0.artistText, $0.album?.displayName ?? ""]
                .contains { $0.localizedStandardContains(query) }
        }
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
            playTask?.cancel()
            playTask = nil
            isPreparingPlayback = false
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
        if shuffle && model.hasMore {
            playTask?.cancel()
            let token = library.player.beginPendingPlay()
            isPreparingPlayback = true
            playTask = Task {
                defer {
                    isPreparingPlayback = false
                    playTask = nil
                }
                let completed = await model.loadAll()
                guard !Task.isCancelled, library.player.isCurrentPendingPlay(token) else { return }
                guard completed else {
                    if let error = model.error {
                        library.actions.error = "读取完整歌单失败：\(error)"
                    }
                    return
                }
                let tracks = visibleTracks
                guard let track = tracks.randomElement() else {
                    library.actions.error = "歌单中没有可播放的歌曲。"
                    return
                }
                library.player.queue.shuffle = true
                library.player.play(track, in: tracks)
            }
            return
        }

        playTask?.cancel()
        playTask = nil
        isPreparingPlayback = false
        let tracks = visibleTracks
        guard let track = shuffle ? tracks.randomElement() : tracks.first else { return }
        library.player.queue.shuffle = shuffle
        playTrack(track)
    }

    private func playTrack(_ track: Track) {
        playTask?.cancel()
        playTask = nil
        isPreparingPlayback = false
        let tracks = visibleTracks
        let continuation = model.playbackContinuation(matching: controls.trimmedQuery)
        library.player.play(track, in: tracks, continuation: continuation) { error in
            library.actions.notice = "后续歌单歌曲加载未完成：\(error.localizedDescription)"
        }
    }
}
