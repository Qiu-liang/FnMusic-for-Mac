import SwiftUI

/// Compact lyric presentation hosted by RightSidebar in the main window.
struct LyricsView: View {
    @Environment(LibraryContext.self) private var library
    @State private var follow = true

    private struct Entry: Identifiable {
        let id: Int
        let text: String
        var translations: [String] = []
    }

    var body: some View {
        @Bindable var model = library.lyricsPanel
        let track = library.player.currentTrack
        let current = model.parsed.currentIndex(at: library.player.elapsed)

        VStack(spacing: 0) {
            panelHeader(model: model)
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    ScrollView {
                        let entries = displayEntries(model.parsed.lines)
                        if model.loading {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 50)
                        } else if let error = model.error {
                            ContentUnavailableView {
                                Label("歌词加载失败", systemImage: "quote.bubble")
                            } description: {
                                Text(error).lineLimit(4)
                            } actions: {
                                Button("重试") { Task { await model.load(trackGUID: track?.guid) } }
                            }
                            .padding(.top, 26)
                        } else if entries.isEmpty {
                            ContentUnavailableView("暂无歌词", systemImage: "quote.bubble")
                                .padding(.top, 26)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 23) {
                                ForEach(entries) { entry in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.text)
                                            .font(.system(size: current == entry.id ? 21 : 17,
                                                          weight: current == entry.id ? .bold : .semibold,
                                                          design: .rounded))
                                            .foregroundStyle(.primary.opacity(current == entry.id || !model.parsed.isTimed ? 0.96 : 0.42))
                                            .fixedSize(horizontal: false, vertical: true)
                                        ForEach(Array(entry.translations.enumerated()), id: \.offset) { _, translation in
                                            Text(translation)
                                                .font(.system(size: 12, weight: current == entry.id ? .medium : .regular))
                                                .foregroundStyle(.secondary.opacity(current == entry.id ? 0.82 : 0.58))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if let time = model.parsed.lines.first(where: { $0.id == entry.id })?.time {
                                            library.player.seek(to: max(0, time))
                                        }
                                    }
                                    .id(entry.id)
                                    .animation(.easeInOut(duration: 0.24), value: current)
                                }
                            }
                            .padding(.horizontal, 22)
                            .padding(.top, geometry.size.height * 0.2)
                            .padding(.bottom, geometry.size.height * 0.8)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: current) { _, index in
                        guard follow, model.parsed.isTimed, let index else { return }
                        withAnimation(.easeInOut(duration: 0.38)) {
                            proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.2))
                        }
                    }
                    .onChange(of: model.parsed.lines) { _, _ in
                        guard let current else { return }
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: 0.2))
                        }
                    }
                    .onAppear {
                        if let current { proxy.scrollTo(current, anchor: UnitPoint(x: 0.5, y: 0.2)) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: track?.guid) { await model.load(trackGUID: track?.guid) }
        .onChange(of: model.selectedGUID) { _, _ in model.select() }
        .accessibilityIdentifier("FnMusic.LyricsPanel")
    }

    private func panelHeader(model: LyricsViewModel) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if model.variants.count > 1 {
                Menu {
                    ForEach(model.variants) { lyric in
                        Button {
                            model.selectedGUID = lyric.guid
                        } label: {
                            Text("来源 \(lyric.source.map(String.init) ?? "未知") · \(lyric.guid.suffix(4))")
                        }
                    }
                    Divider()
                    Toggle("跟随播放", isOn: $follow)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("歌词选项")
            }
            Button { library.rightPanel = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("收起歌词")
            .accessibilityLabel("收起歌词")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: PageToolbarMetrics.height)
    }

    private func displayEntries(_ lines: [LyricLine]) -> [Entry] {
        var entries: [Entry] = []
        var precedingTimedEntry: Int?
        for line in lines {
            if line.time == nil, let precedingTimedEntry {
                entries[precedingTimedEntry].translations.append(line.text)
            } else {
                entries.append(Entry(id: line.id, text: line.text))
                precedingTimedEntry = line.time == nil ? nil : entries.count - 1
            }
        }
        return entries
    }
}
