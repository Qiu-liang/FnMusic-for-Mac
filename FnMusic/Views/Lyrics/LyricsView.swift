import SwiftUI

struct LyricsView: View {
    @Environment(LibraryContext.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var model: LyricsViewModel
    @State private var follow = true
    @State private var query = ""

    init(service: any LyricsServiceProtocol) { _model = State(initialValue: LyricsViewModel(service: service)) }

    var body: some View {
        MusicPageChrome(title: "歌词", placeholder: "在歌词中查找", query: $query, inset: .padded, showsCommonOptions: false) {
            Toggle("跟随播放", isOn: $follow)
            if model.variants.count > 1 {
                Picker("歌词版本", selection: $model.selectedGUID) {
                    ForEach(model.variants) { lyric in
                        Text("来源 \(lyric.source.map(String.init) ?? "未知") · \(lyric.guid.suffix(4))")
                            .tag(Optional(lyric.guid))
                    }
                }
            }
            Text("查找期间暂不自动滚动，不修改服务器歌词偏好。")
            Divider()
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
        } content: {
            HStack(spacing: 38) {
                VStack(alignment: .leading, spacing: 18) {
                    ArtworkView(coverId: library.player.currentTrack?.coverId, cache: library.images)
                        .frame(width: 270, height: 270)
                        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
                    Text(library.player.currentTrack?.displayTitle ?? "未在播放").font(.title2.weight(.semibold))
                    Text(library.player.currentTrack?.artistText ?? "").foregroundStyle(.secondary)
                    Text("仅调整本地展示，不向服务器写入偏移或歌词偏好。")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }.frame(width: 270)
                lyricContent
            }.padding(.horizontal, 32).padding(.vertical, 16)
        }
        .frame(minWidth: 820, idealWidth: 920, minHeight: 560, idealHeight: 650)
        .background(.regularMaterial)
        .onExitCommand { dismiss() }
        .task(id: library.player.currentTrack?.guid) { await model.load(trackGUID: library.player.currentTrack?.guid) }
        .onChange(of: model.selectedGUID) { _, _ in model.select() }
    }

    private var lyricContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let current = model.parsed.currentIndex(at: library.player.elapsed)
                let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let visible = Array(model.parsed.lines.enumerated()).filter { term.isEmpty || $0.element.text.localizedStandardContains(term) }
                VStack(alignment: .leading, spacing: 24) {
                    LoadStateView(isLoading: model.loading, isEmpty: model.parsed.lines.isEmpty, error: model.error,
                                  emptyTitle: "暂无歌词") { await model.load(trackGUID: library.player.currentTrack?.guid) }
                    if !model.parsed.lines.isEmpty && visible.isEmpty {
                        ContentUnavailableView("没有匹配歌词", systemImage: "magnifyingglass")
                    }
                    LazyVStack(alignment: .leading, spacing: 26) {
                        ForEach(visible, id: \.element.id) { index, line in
                            Text(line.text)
                                .font(.system(size: current == index ? 29 : 24, weight: .semibold, design: .rounded))
                                .foregroundStyle(current == index || !model.parsed.isTimed ? .primary : .secondary)
                                .opacity(current == index || !model.parsed.isTimed ? 1 : 0.55)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { if let time = line.time { library.player.seek(to: max(0, time)) } }
                                .id(line.id)
                        }
                    }.padding(.vertical, 100)
                }
                .padding(.horizontal, 8)
                .animation(.easeInOut(duration: 0.25), value: current)
                .onChange(of: current) { _, index in
                    guard follow, term.isEmpty, let index else { return }
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(model.parsed.lines[index].id, anchor: .center) }
                }
            }
        }
    }
}
