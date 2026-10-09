import SwiftUI

struct ArtistDiscographyView: View {
    @Environment(LibraryContext.self) private var library
    let model: ArtistBrowserViewModel
    @State private var action: Task<Void, Never>?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 32) {
                header.padding(.leading, 10)
                if let warning = model.warning {
                    Text(warning).font(.caption).foregroundStyle(.secondary)
                }
                if model.isPartialCollaborationFilter {
                    Label("依据已加载歌曲的多艺人署名筛选；尚未加载的曲目不计入结果。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.loading && model.sections.isEmpty {
                    ProgressView("正在加载作品…").frame(maxWidth: .infinity).padding(.vertical, 60)
                } else if let error = model.error, model.sections.isEmpty {
                    ContentUnavailableView {
                        Label("无法加载作品", systemImage: "wifi.exclamationmark")
                    } description: { Text(error) } actions: { Button("重试") { reload() } }
                } else if model.sections.isEmpty {
                    ContentUnavailableView("暂无可显示的歌曲", systemImage: "music.note",
                                           description: Text(model.isPartialCollaborationFilter && model.hasMoreTracks
                                                             ? "当前已加载曲目没有多艺人署名，可继续加载。" : "选择其他艺人，或刷新服务器资料库。"))
                }
                LazyVStack(alignment: .leading, spacing: 80) {
                    ForEach(model.sections) { section in
                        ArtistAlbumBlock(section: section, queue: model.loadedTracks) { artist in model.selectArtist(artist) }
                    }
                }
                if let error = model.error, !model.sections.isEmpty {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                VStack(spacing: 12) {
                    if model.loading && !model.sections.isEmpty { ProgressView().controlSize(.small) }
                    if model.hasMoreTracks {
                        Button(model.error == nil ? "加载更多歌曲" : "重试加载") {
                            action?.cancel()
                            action = Task { await model.loadMoreTracks() }
                        }.disabled(model.loading)
                    }
                    if model.scannedTracks > 0 {
                        Text(model.isPartialCollaborationFilter
                             ? "已检查 \(model.scannedTracks) 首，显示 \(model.loadedTracks.count) 首合唱歌曲"
                             : "已加载 \(model.loadedTracks.count) / \(model.totalTracks ?? model.loadedTracks.count) 首歌曲")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }.frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 32).padding(.top, 28)
            .padding(.bottom, PlayerBarMetrics.contentClearance + 16)
        }
        .task(id: model.selectedScope.id) { await model.loadDetail() }
        .onChange(of: model.loadedTracks) { _, tracks in library.actions.reconcile(tracks) }
        .onDisappear { action?.cancel() }
        .accessibilityIdentifier("FnMusic.ArtistDiscography")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text(model.detailArtist?.displayName ?? model.selectedScope.title)
                    .font(.system(size: 25, weight: .bold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    roundButton("play.fill", help: "播放已加载歌曲") { play(shuffle: false) }
                    roundButton("shuffle", help: "随机播放已加载歌曲") { play(shuffle: true) }
                }.foregroundStyle(.pink)
            }
            Divider()
            Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        if let artist = model.detailArtist {
            let albums = artist.albumCount.map { "\($0) 张专辑" } ?? "已加载 \(model.sections.count) 张专辑"
            let tracks = model.totalTracks ?? artist.trackCount ?? model.loadedTracks.count
            return "\(albums)，\(tracks) 首歌曲"
        }
        return "已加载 \(model.sections.count) 张专辑，\(model.loadedTracks.count) 首歌曲"
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28).background(.primary.opacity(0.035), in: Circle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help).disabled(model.loadedTracks.isEmpty)
    }

    private func play(shuffle: Bool) {
        let tracks = model.loadedTracks
        guard let track = shuffle ? tracks.randomElement() : tracks.first else { return }
        library.player.queue.shuffle = shuffle
        library.player.play(track, in: tracks)
    }

    private func reload() {
        action?.cancel()
        action = Task { await model.loadDetail() }
    }
}

private struct ArtistAlbumBlock: View {
    @Environment(LibraryContext.self) private var library
    let section: ArtistAlbumSection
    let queue: [Track]
    let selectArtist: (Artist) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 64) {
                cover.frame(width: ArtistPageMetrics.artworkSize, height: ArtistPageMetrics.artworkSize)
                VStack(alignment: .leading, spacing: 20) {
                    albumHeading
                    songRows
                }.frame(minWidth: 250, maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: ArtistPageMetrics.albumWideMinimum, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    cover.frame(width: 72, height: 72)
                    albumHeading
                }
                songRows
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FnMusic.ArtistAlbumBlock.\(section.id)")
    }

    private var cover: some View {
        ArtworkView(coverId: section.coverId, cache: library.images)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.055), lineWidth: 0.5))
    }

    private var albumHeading: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(section.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).help(section.title)
                Menu {
                    ForEach(section.tracks) { track in
                        Button("下载：\(track.displayTitle)…") { library.downloads.download(track) }
                    }
                } label: {
                    Image(systemName: "arrow.down").foregroundStyle(.pink)
                        .frame(width: 26, height: 26).background(.primary.opacity(0.035), in: Circle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("选择已加载的曲目并下载原文件")
                .disabled(library.downloads.isPreparing || library.downloads.isDownloading)
                Menu {
                    Button("播放此专辑中已加载的歌曲") {
                        guard let first = section.tracks.first else { return }
                        library.player.play(first, in: section.tracks)
                    }
                    Button("添加到队列") { section.tracks.forEach { library.player.queue.append($0) } }
                    if let album = section.album {
                        Divider()
                        Button("查看完整专辑") { library.navigation.append(.album(album)) }
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.pink)
                        .frame(width: 26, height: 26).background(.primary.opacity(0.035), in: Circle())
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            Text(section.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var songRows: some View {
        VStack(spacing: 0) {
            Divider()
            ForEach(Array(section.tracks.enumerated()), id: \.element.guid) { index, track in
                ArtistTrackRow(track: track, index: index + 1, queue: queue, selectArtist: selectArtist)
                Rectangle().fill(.primary.opacity(0.055)).frame(height: 0.5)
            }
        }
    }
}
