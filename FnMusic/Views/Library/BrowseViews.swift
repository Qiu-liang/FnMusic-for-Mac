import SwiftUI

struct GenresView: View {
    @State private var model: PagedViewModel<GenreRecord>
    @State private var query = ""
    @State private var refreshID = UUID()

    init(service: any BrowseServiceProtocol) {
        _model = State(initialValue: PagedViewModel(sort: "trackCount,desc") { page, sort in
            try await service.genres(page: page, sort: sort)
        })
    }

    var body: some View {
        MusicPageChrome(title: "风格", placeholder: "搜索已加载风格", query: $query) {
            Picker("排序", selection: $model.sort) {
                Text("风格名称").tag("name,asc")
                Text("歌曲数量").tag("trackCount,desc")
            }
            Button("刷新", systemImage: "arrow.clockwise") { refreshID = UUID() }
            Divider()
            Text("非空流派模型尚未完整验证")
            Text("仅搜索已加载记录的原始名称；无有效 guid 的记录不能导航。")
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LoadStateView(isLoading: model.isLoading, isEmpty: model.items.isEmpty,
                                  error: model.items.isEmpty ? model.error : nil,
                                  emptyTitle: "暂无风格") { await model.refresh() }
                    if !model.items.isEmpty && filteredGenres.isEmpty {
                        Text(model.hasMore ? "已加载风格中没有匹配项，可继续加载更多。" : "已加载风格中没有匹配项。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(filteredGenres) { record in
                            if let guid = record.guid {
                                NavigationLink(value: LibraryRoute.genre(guid: guid, name: record.displayName)) {
                                    HStack {
                                        Label(record.displayName, systemImage: "guitars")
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                    }.padding(12).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("未知记录", systemImage: "questionmark.folder")
                                    Text(record.displayName).font(.callout)
                                    Text("服务器未返回可用的字符串 guid，无法打开关联歌曲。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(12)
                            }
                            Divider()
                        }
                    }
                    PageFooter(model: model)
                }.padding(30)
            }
        }
        .task(id: [model.sort, refreshID.uuidString]) { await model.refresh() }
    }

    private var filteredGenres: [GenreRecord] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return model.items }
        return model.items.filter { record in
            guard case .string(let name) = record.fields?["name"] else { return false }
            return name.localizedStandardContains(term)
        }
    }
}

struct SharedLibrariesView: View {
    private let service: any BrowseServiceProtocol
    private let showsToolbar: Bool
    private let externalQuery: Binding<String>?
    private let refreshRevision: Int
    @State private var model: SharedLibrariesViewModel
    @State private var selectedLibrary: SharedLibrary?
    @State private var localQuery = ""
    @State private var refreshID = UUID()

    init(service: any BrowseServiceProtocol, showsToolbar: Bool = true,
         query: Binding<String>? = nil, refreshRevision: Int = 0) {
        self.service = service
        self.showsToolbar = showsToolbar
        self.externalQuery = query
        self.refreshRevision = refreshRevision
        _model = State(initialValue: SharedLibrariesViewModel(service: service))
    }

    var body: some View {
        Group {
            if showsToolbar {
                MusicPageChrome(title: "共享音乐库", placeholder: "搜索名称或服务器路径", query: searchQuery) {
                    Button("刷新", systemImage: "arrow.clockwise") { refreshID = UUID() }
                } content: {
                    libraryContent
                }
            } else {
                libraryContent
            }
        }
        .task(id: [String(refreshRevision), refreshID.uuidString]) { await model.refresh() }
        .onDisappear { model.invalidate() }
        .sheet(item: $selectedLibrary) { library in
            SharedLibraryDetailView(guid: library.guid, service: service)
        }
    }

    private var searchQuery: Binding<String> { externalQuery ?? $localQuery }

    private var filteredLibraries: [SharedLibrary] {
        let term = searchQuery.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return model.items }
        // A server-local path is text only, never an address to open or request.
        return model.items.filter {
            $0.name?.localizedStandardContains(term) == true || $0.path?.localizedStandardContains(term) == true
        }
    }

    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SharedLibraryReadOnlyNotice()
                LoadStateView(isLoading: model.isLoading, isEmpty: model.items.isEmpty,
                              error: model.error, emptyTitle: "暂无共享音乐库") { await model.refresh() }
                if !model.items.isEmpty && filteredLibraries.isEmpty {
                    Text("没有匹配的共享音乐库").font(.callout).foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(filteredLibraries) { library in
                        Button { selectedLibrary = library } label: {
                            HStack(alignment: .top) {
                                Image(systemName: "externaldrive.connected.to.line.below")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(library.displayName).font(.headline)
                                    if let path = library.path {
                                        Text(verbatim: path).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text("访问状态（原始值）：\(library.accessStatus?.display ?? "—")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }.padding(30)
        }
    }
}

private struct SharedLibraryReadOnlyNotice: View {
    var body: some View {
        Text("仅显示共享音乐库的只读信息。文档未确认按库筛选歌曲，不支持按共享库筛歌；服务器路径不是可打开的 URL。")
            .font(.callout).foregroundStyle(.secondary)
    }
}

private struct SharedLibraryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: SharedLibraryDetailViewModel
    @State private var query = ""

    init(guid: String, service: any BrowseServiceProtocol) {
        _model = State(initialValue: SharedLibraryDetailViewModel(guid: guid, service: service))
    }

    var body: some View {
        MusicPageChrome(title: "共享音乐库详情", placeholder: "搜索详情字段", query: $query, showsCommonOptions: false) {
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LoadStateView(isLoading: model.isLoading, isEmpty: model.library == nil,
                                  error: model.error, emptyTitle: "暂无共享音乐库详情") { await model.refresh() }
                    if model.library != nil {
                        if filteredFields.isEmpty {
                            Text("没有匹配的详情字段").font(.callout).foregroundStyle(.secondary)
                        } else {
                            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
                                ForEach(filteredFields) { field in
                                    detailRow(field.label, field.value)
                                }
                            }
                        }
                    }
                    SharedLibraryReadOnlyNotice()
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 380)
        .onExitCommand { dismiss() }
        .task(id: model.guid) { await model.refresh() }
        .onDisappear { model.invalidate() }
    }

    private struct DetailField: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private var filteredFields: [DetailField] {
        guard let library = model.library else { return [] }
        let fields = [
            DetailField(label: "名称", value: library.displayName),
            DetailField(label: "GUID", value: library.guid),
            DetailField(label: "服务器路径（只读）", value: library.path ?? "—"),
            DetailField(label: "访问状态（原始值）", value: library.accessStatus?.display ?? "—"),
            DetailField(label: "元数据偏好", value: library.metadataPreference ?? "—"),
            DetailField(label: "自动下载歌词", value: library.autoDownloadLyric.map { $0 ? "是" : "否" } ?? "—"),
            DetailField(label: "内容最后变更（原始值）", value: library.contentLastChangedAt?.display ?? "—")
        ]
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return fields }
        return fields.filter { $0.label.localizedStandardContains(term) || $0.value.localizedStandardContains(term) }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Text(verbatim: value).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
