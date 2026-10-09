import SwiftUI

struct AddToPlaylistView: View {
    @Environment(LibraryContext.self) private var library
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var model: PlaylistListViewModel
    @State private var busy = false
    @State private var error: String?

    init(track: Track, service: any PlaylistServiceProtocol) {
        self.track = track
        _model = State(initialValue: PlaylistListViewModel(service: service))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加到播放列表").font(.title2.weight(.bold))
            Text(track.displayTitle).foregroundStyle(.secondary)
            Text("实验性操作 · H 级接口，操作后会读回确认。")
                .font(.caption).foregroundStyle(.orange)
            LoadStateView(isLoading: model.isLoading, isEmpty: model.items.isEmpty, error: model.error,
                          emptyTitle: "请先创建播放列表") { await model.refresh() }
            List(model.items) { playlist in
                Button {
                    guard library.actions.experimentalWrites else { error = "实验性写操作未启用。"; return }
                    busy = true
                    Task {
                        do {
                            try await library.playlistMutations.add(track: track, to: playlist)
                            library.actions.revision += 1
                            library.actions.notice = "已添加到“\(playlist.displayName)”并读回确认"
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                } label: {
                    HStack {
                        Image(systemName: "music.note.list").foregroundStyle(.pink)
                        Text(playlist.displayName)
                        Spacer()
                        if let count = playlist.trackCount { Text("\(count) 首").foregroundStyle(.secondary) }
                    }.padding(.vertical, 6)
                }.buttonStyle(.plain).disabled(busy)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.disabled(busy)
            }
        }.padding(24).frame(width: 430, height: 480)
        .task { await model.refresh() }
        .interactiveDismissDisabled(busy)
    }
}

struct PlaylistNameSheet: View {
    @Environment(LibraryContext.self) private var library
    @Environment(\.dismiss) private var dismiss
    var playlist: Playlist?
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(playlist == nil ? "新建播放列表" : "重命名播放列表").font(.title2.weight(.bold))
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            Text("实验性 H 级写入。保留原有封面，不调用上传或清理接口。")
                .font(.caption).foregroundStyle(.orange)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.disabled(busy)
                Button("保存") { save() }.buttonStyle(.borderedProminent)
                    .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 420)
        .onAppear { name = playlist?.name ?? "" }
        .interactiveDismissDisabled(busy)
    }

    private func save() {
        guard library.actions.experimentalWrites else { error = "请在设置中启用实验性写操作。"; return }
        busy = true
        Task {
            do {
                let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let playlist { try await library.playlistMutations.rename(playlist, name: normalized) }
                else { _ = try await library.playlistMutations.create(name: normalized) }
                library.actions.revision += 1
                library.actions.notice = "歌单已保存并读回确认"
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
