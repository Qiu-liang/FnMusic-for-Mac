import SwiftUI

struct ArtistTrackRow: View {
    @Environment(LibraryContext.self) private var library
    let track: Track
    let index: Int
    let queue: [Track]
    let selectArtist: (Artist) -> Void
    @State private var hovering = false

    private var isCurrent: Bool { library.player.currentTrack?.guid == track.guid }
    private var isFavorite: Bool { library.actions.isFavorite(track) }
    private var downloading: Bool { library.downloads.activeTrackGUID == track.guid && library.downloads.isDownloading }

    var body: some View {
        HStack(spacing: 6) {
            Button { Task { await library.actions.toggleFavorite(track) } } label: {
                Group {
                    if library.actions.busyTracks.contains(track.guid) { ProgressView().controlSize(.mini) }
                    else { Image(systemName: isFavorite ? "star.fill" : "star").font(.system(size: 10)) }
                }.frame(width: 16, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isFavorite ? Color.pink : .secondary)
            .opacity(isFavorite || hovering ? 1 : 0.25)
            .help(isFavorite ? "取消收藏" : "收藏歌曲")
            .accessibilityLabel(isFavorite ? "取消收藏 \(track.displayTitle)" : "收藏 \(track.displayTitle)")
            .disabled(library.actions.busyTracks.contains(track.guid))

            Button { library.player.play(track, in: queue) } label: {
                HStack(spacing: 12) {
                    Group {
                        if isCurrent && library.player.isPlaying {
                            Image(systemName: "waveform").foregroundStyle(.pink)
                        } else {
                            Text(String(track.trackNo ?? index)).foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 12)).frame(width: 18)
                    Text(track.displayTitle).font(.system(size: 13))
                        .foregroundStyle(isCurrent ? Color.pink : .primary)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("播放 \(track.displayTitle)")

            Text(track.durationSeconds.playbackTime).font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            Button {
                if downloading { library.downloads.cancel() }
                else { library.downloads.download(track) }
            } label: {
                if downloading {
                    ProgressView(value: library.downloads.progress).progressViewStyle(.circular)
                        .controlSize(.mini).frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.down").font(.system(size: 12)).frame(width: 22, height: 26)
                }
            }.buttonStyle(.plain).foregroundStyle(.pink)
                .help(downloading ? "取消下载" : "下载原始音频…")
                .accessibilityLabel(downloading ? "取消下载" : "下载 \(track.displayTitle)")
            Menu { moreMenu } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.pink)
                    .frame(width: 22, height: 26)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.vertical, 7)
        .background(Color.primary.opacity(isCurrent ? 0.025 : 0))
        .onHover { hovering = $0 }
        .contextMenu { moreMenu }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FnMusic.ArtistTrack.\(track.guid)")
    }

    @ViewBuilder private var moreMenu: some View {
        Button("播放") { library.player.play(track, in: queue) }
        Button("下一首播放") { library.player.queue.insertNext(track) }
        Button("添加到队列") { library.player.queue.append(track) }
        Divider()
        Button(isFavorite ? "取消收藏" : "收藏") { Task { await library.actions.toggleFavorite(track) } }
            .disabled(library.actions.busyTracks.contains(track.guid))
        Button("添加到播放列表…") {
            if library.actions.experimentalWrites { library.actions.pendingPlaylistTrack = track }
            else { library.actions.error = "请先在设置中启用实验性写操作。" }
        }
        Button("下载原始音频…") { library.downloads.download(track) }
        Divider()
        if let album = track.album {
            Button("查看专辑") { library.navigation.append(.album(album)) }
        }
        if let artists = track.artists {
            ForEach(artists) { artist in
                Button("查看艺人：\(artist.displayName)") { selectArtist(artist) }
            }
        }
    }
}
