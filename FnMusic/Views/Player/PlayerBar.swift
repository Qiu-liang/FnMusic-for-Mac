import SwiftUI

struct PlayerBar: View {
    @Environment(LibraryContext.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var seeking = false
    @State private var seekValue: Double = 0
    @State private var showVolume = false
    @State private var showProgress = false

    var body: some View {
        let player = library.player
        HStack(spacing: 12) {
            playbackControls.frame(width: 156, alignment: .leading)
            nowPlaying.frame(maxWidth: .infinity)
            accessoryControls.frame(width: 156, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: PlayerBarMetrics.height)
        .frame(maxWidth: PlayerBarMetrics.maximumWidth)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: PlayerCapsuleBoundsKey.self, value: geometry.frame(in: .global))
            }.allowsHitTesting(false)
        }
        .buttonStyle(.plain)
        .modifier(PlayerGlassSurface())
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FnMusic.PlayerCapsule")
        .padding(.horizontal, PlayerBarMetrics.horizontalMargin)
        .padding(.top, 10)
        .padding(.bottom, PlayerBarMetrics.bottomMargin)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: player.currentTrack?.guid)
        .onChange(of: player.currentTrack?.guid) { _, _ in
            seeking = false
            showProgress = false
        }
        .alert("无法播放", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) {
            Button("重试") { player.resume() }
            Button("关闭", role: .cancel) { player.error = nil }
        } message: { Text(player.error ?? "") }
    }

    private var playbackControls: some View {
        let player = library.player
        let queue = player.queue
        return HStack(spacing: 2) {
            Button { queue.shuffle.toggle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(queue.shuffle ? Color.pink : .secondary)
                    .frame(width: 26, height: 32)
            }.help("随机播放（已加入队列的歌曲）").accessibilityLabel("随机播放")
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").frame(width: 28, height: 32)
            }.help("上一首").accessibilityLabel("上一首")
            Button { player.toggle() } label: {
                ZStack {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .opacity(player.isLoading ? 0 : 1)
                    if player.isLoading { ProgressView().controlSize(.small) }
                }.frame(width: 34, height: 34)
            }.help(player.isPlaying ? "暂停" : "播放")
                .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            Button { player.next() } label: {
                Image(systemName: "forward.fill").frame(width: 28, height: 32)
            }.help("下一首").accessibilityLabel("下一首")
            Button { queue.cycleRepeatMode() } label: {
                Image(systemName: queue.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(queue.repeatMode == .off ? Color.secondary : .pink)
                    .frame(width: 26, height: 32)
            }.help(queue.repeatMode.title).accessibilityLabel(queue.repeatMode.title)
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.primary.opacity(0.8))
        .disabled(player.currentTrack == nil)
    }

    @ViewBuilder private var nowPlaying: some View {
        let player = library.player
        if let track = player.currentTrack {
            VStack(spacing: 3) {
                Button { showProgress.toggle() } label: {
                    HStack(spacing: 8) {
                        ArtworkView(coverId: track.coverId, cache: library.images, size: 160)
                            .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(track.artistText).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .help("查看歌曲与播放进度")
                .accessibilityLabel("\(track.displayTitle)，\(track.artistText)，查看播放进度")
                .popover(isPresented: $showProgress) { progressPopover }
                CompactPlaybackProgress(elapsed: player.elapsed, duration: player.duration, onSeek: player.seek)
                    .frame(height: 8)
            }
            .id(track.guid)
        } else {
            // Use FnMusic's own neutral music glyph, never Apple's proprietary logo.
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.65))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .help("FnMusic · 未在播放")
                .accessibilityLabel("FnMusic，未在播放")
        }
    }

    private var accessoryControls: some View {
        HStack(spacing: 4) {
            Button { library.rightPanel = library.rightPanel == .lyrics ? nil : .lyrics } label: {
                Image(systemName: "quote.bubble").frame(width: 28, height: 32)
                    .foregroundStyle(library.rightPanel == .lyrics ? Color.pink : .primary.opacity(0.85))
            }
            .help(library.rightPanel == .lyrics ? "收起歌词" : "展开歌词")
            .accessibilityLabel("歌词")
            .accessibilityValue(library.rightPanel == .lyrics ? "已展开" : "已收起")
            .accessibilityIdentifier("FnMusic.LyricsToggle")
            .disabled(library.player.currentTrack == nil)
            Button { library.rightPanel = library.rightPanel == .queue ? nil : .queue } label: {
                Image(systemName: "list.bullet").frame(width: 28, height: 32)
                    .foregroundStyle(library.rightPanel == .queue ? Color.pink : .primary.opacity(0.85))
            }
            .help(library.rightPanel == .queue ? "收起待播清单" : "展开待播清单")
            .accessibilityLabel("播放队列")
            .accessibilityValue(library.rightPanel == .queue ? "已展开" : "已收起")
            .accessibilityIdentifier("FnMusic.QueueToggle")
            AudioRoutePicker(player: library.player).frame(width: 28, height: 28)
            Button { showVolume.toggle() } label: {
                Image(systemName: library.player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 28, height: 32)
            }
            .help("音量").accessibilityLabel("音量")
            .popover(isPresented: $showVolume) { volumePopover }
        }
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(.primary.opacity(0.85))
    }

    private var volumePopover: some View {
        @Bindable var player = library.player
        return VStack(alignment: .leading, spacing: 12) {
            Text("音量").font(.headline)
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1).frame(width: 140).accessibilityLabel("音量")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
        }.padding(18)
    }

    private var progressPopover: some View {
        let player = library.player
        return VStack(alignment: .leading, spacing: 12) {
            Text(player.currentTrack?.displayTitle ?? "播放进度").font(.headline).lineLimit(2)
            Slider(value: Binding(get: { seeking ? seekValue : min(player.elapsed, max(1, player.duration)) }, set: { seekValue = $0 }),
                   in: 0...max(1, player.duration), onEditingChanged: { editing in
                seeking = editing
                if !editing { player.seek(to: seekValue) }
            }).disabled(player.duration <= 0).accessibilityLabel("播放进度")
            HStack {
                Text((seeking ? seekValue : player.elapsed).playbackTime)
                Spacer()
                Text(player.duration.playbackTime)
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }.padding(18).frame(width: 310)
        .onAppear { seeking = false; seekValue = player.elapsed }
        .onChange(of: player.elapsed) { _, value in if !seeking { seekValue = value } }
    }

}

/// A thin but draggable progress line; the full native slider is also available
/// through the song popover for keyboard control and precise elapsed/total times.
struct CompactPlaybackProgress: View {
    let elapsed: Double
    let duration: Double
    let onSeek: (Double) -> Void
    @State private var dragFraction: Double?
    @State private var hovering = false

    static func fraction(at x: CGFloat, width: CGFloat) -> Double {
        guard width.isFinite, width > 0, x.isFinite else { return 0 }
        return min(1, max(0, Double(x / width)))
    }

    private var fraction: Double {
        guard duration.isFinite, duration > 0, elapsed.isFinite else { return 0 }
        return dragFraction ?? min(1, max(0, elapsed / duration))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.10)).frame(height: 2)
                Capsule().fill(.primary.opacity(0.4)).frame(width: geometry.size.width * fraction, height: 2)
                if hovering || dragFraction != nil {
                    Circle().fill(.primary.opacity(0.7)).frame(width: 6, height: 6)
                        .offset(x: max(0, (geometry.size.width - 6) * fraction))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { dragFraction = Self.fraction(at: $0.location.x, width: geometry.size.width) }
                .onEnded {
                    onSeek(Self.fraction(at: $0.location.x, width: geometry.size.width) * duration)
                    dragFraction = nil
                })
        }
        .allowsHitTesting(duration.isFinite && duration > 0)
        .onHover { hovering = $0 }
        .onDisappear { dragFraction = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(elapsed.playbackTime)，共 \(duration.playbackTime)")
        .accessibilityAdjustableAction { direction in
            guard duration.isFinite, duration > 0 else { return }
            switch direction {
            case .increment: onSeek(min(duration, elapsed + 5))
            case .decrement: onSeek(max(0, elapsed - 5))
            @unknown default: break
            }
        }
    }
}
