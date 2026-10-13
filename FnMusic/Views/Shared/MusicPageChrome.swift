import SwiftUI
import Observation

enum PageContentInset { case scroll, padded }
enum PageToolbarStyle: Equatable, Sendable { case standard, artist, albumDetail, playlistDetail, hidden }

enum PageToolbarMetrics {
    static let height: CGFloat = 52
    static let searchWidth: CGFloat = 210
    static let controlHeight: CGFloat = 36
}

struct PageToolbarBoundsKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// The active page supplies bindings/actions, but the window owns header placement.
/// Owner checks prevent a departing navigation destination clearing a newer header.
@MainActor @Observable
final class WindowPageToolbarHost {
    var current: PageToolbarDescriptor?

    func show(_ descriptor: PageToolbarDescriptor) {
        if current != descriptor { current = descriptor }
    }
    func updateVisible(_ pages: [PageToolbarDescriptor]) {
        // Navigation transitions may emit an empty preference temporarily.
        // Retain the last header until the visible page (including a popped root)
        // publishes its descriptor, instead of relying on onAppear rehosting.
        if let page = pages.last { show(page) }
    }
    func clear(owner: UUID) {
        if current?.owner == owner { current = nil }
    }
}

@MainActor
struct PageToolbarDescriptor: Equatable {
    nonisolated let owner: UUID
    nonisolated let title: String
    nonisolated let placeholder: String
    nonisolated var displayTitle: String? = nil
    nonisolated var style: PageToolbarStyle = .standard
    let query: Binding<String>
    let options: @MainActor () -> AnyView

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner == rhs.owner && lhs.title == rhs.title && lhs.placeholder == rhs.placeholder &&
            lhs.displayTitle == rhs.displayTitle && lhs.style == rhs.style
    }
}

struct WindowPageToolbarDescriptorKey: PreferenceKey {
    static let defaultValue: [PageToolbarDescriptor] = []
    static func reduce(value: inout [PageToolbarDescriptor], nextValue: () -> [PageToolbarDescriptor]) {
        value += nextValue()
    }
}

private struct WindowPageToolbarHostKey: EnvironmentKey {
    static let defaultValue: WindowPageToolbarHost? = nil
}

extension EnvironmentValues {
    var windowPageToolbarHost: WindowPageToolbarHost? {
        get { self[WindowPageToolbarHostKey.self] }
        set { self[WindowPageToolbarHostKey.self] = newValue }
    }
}

struct WindowPageToolbar: View {
    let host: WindowPageToolbarHost

    var body: some View {
        if let page = host.current, page.style != .hidden {
            UnifiedPageToolbar(title: page.title, placeholder: page.placeholder,
                               query: page.query, displayTitle: page.displayTitle, style: page.style,
                               showsCommonOptions: true) { page.options() }
                .id(page.owner)
        }
    }
}

/// One shared page chrome. Each navigation destination owns its own query/actions,
/// so a hidden page cannot overwrite the active toolbar's bindings or menus.
struct MusicPageChrome<Options: View, Content: View>: View {
    @Environment(\.windowPageToolbarHost) private var windowHost
    @State private var headerOwner = UUID()
    let title: String
    let placeholder: String
    @Binding var query: String
    let inset: PageContentInset
    let displayTitle: String?
    let toolbarStyle: PageToolbarStyle
    let showsCommonOptions: Bool
    private let options: @MainActor () -> Options
    private let content: Content

    init(title: String, placeholder: String, query: Binding<String>, inset: PageContentInset = .scroll,
         showsCommonOptions: Bool = true, displayTitle: String? = nil,
         toolbarStyle: PageToolbarStyle = .standard,
         @ViewBuilder options: @escaping @MainActor () -> Options, @ViewBuilder content: () -> Content) {
        self.title = title
        self.placeholder = placeholder
        _query = query
        self.inset = inset
        self.showsCommonOptions = showsCommonOptions
        self.displayTitle = displayTitle
        self.toolbarStyle = toolbarStyle
        self.options = options
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                switch inset {
                case .scroll: content.contentMargins(.top, PageToolbarMetrics.height, for: .scrollContent)
                case .padded: content.padding(.top, PageToolbarMetrics.height)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if (windowHost == nil || !showsCommonOptions) && toolbarStyle != .hidden {
                UnifiedPageToolbar(title: title, placeholder: placeholder, query: $query,
                                   displayTitle: displayTitle, style: toolbarStyle,
                                   showsCommonOptions: showsCommonOptions) { options() }
                    .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preference(key: WindowPageToolbarDescriptorKey.self,
                    value: windowHost != nil && showsCommonOptions ? [headerDescriptor] : [])
    }

    private var headerDescriptor: PageToolbarDescriptor {
        let buildOptions = options
        return PageToolbarDescriptor(owner: headerOwner, title: title, placeholder: placeholder,
                                     displayTitle: displayTitle, style: toolbarStyle,
                                     query: $query, options: { AnyView(buildOptions()) })
    }
}

private struct UnifiedPageToolbar<Options: View>: View {
    @Environment(LibraryContext.self) private var library
    @Environment(\.controlActiveState) private var controlActiveState
    let title: String
    let placeholder: String
    @Binding var query: String
    let displayTitle: String?
    let style: PageToolbarStyle
    let showsCommonOptions: Bool
    @ViewBuilder let options: () -> Options
    @FocusState private var focused: Bool
    @State private var active = false

    var body: some View {
        HStack(spacing: 8) {
            if style == .albumDetail {
                LibraryBackButton()
                Spacer(minLength: 12)
                pageOptionsMenu
                    .frame(width: PageToolbarMetrics.controlHeight, height: PageToolbarMetrics.controlHeight)
                    .modifier(FloatingTopControlGlass(shape: Circle()))
                searchField
            } else if style == .playlistDetail {
                Spacer(minLength: 12)
                pageOptionsMenu
                    .frame(width: PageToolbarMetrics.controlHeight, height: PageToolbarMetrics.controlHeight)
                    .modifier(FloatingTopControlGlass(shape: Circle()))
                searchField
            } else {
                Text(displayTitle ?? title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("FnMusic.PageTitle")
                Spacer(minLength: 12)
                pageOptionsMenu
                    .frame(width: PageToolbarMetrics.controlHeight, height: PageToolbarMetrics.controlHeight)
                    .modifier(FloatingTopControlGlass(shape: Circle()))
                searchField
            }
        }
        .padding(.leading, showsCommonOptions && library.columnVisibility == .detailOnly ? 90 : 20).padding(.trailing, 10)
        .frame(height: PageToolbarMetrics.height)
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: PageToolbarBoundsKey.self, value: [title: geometry.frame(in: .global)])
            }.allowsHitTesting(false)
        }
        .background(alignment: .leading) {
            if style == .standard || style == .artist {
                FloatingTopBackdrop(width: style == .artist ? ArtistPageMetrics.directoryWidth : nil)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FnMusic.UnifiedPageToolbar")
        .onAppear { active = true; if title == "搜索" { focused = true } }
        .onDisappear { active = false; focused = false }
        .onChange(of: library.toolbarSearchFocus) { _, _ in
            if active && controlActiveState == .key { focused = true }
        }
    }

    private var pageOptionsMenu: some View {
        Menu {
            options()
            if showsCommonOptions {
                Divider()
                CommonPageOptions()
            }
        } label: {
            Image(systemName: style == .standard || style == .artist ? "line.3.horizontal.decrease" : "ellipsis")
                .font(.system(size: style == .standard || style == .artist ? 16 : 15, weight: .regular))
                .foregroundStyle(Color(nsColor: .labelColor))
                .frame(width: PageToolbarMetrics.controlHeight, height: PageToolbarMetrics.controlHeight)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .tint(Color(nsColor: .labelColor))
        .help(style == .standard || style == .artist ? "页面选项：排序、筛选及更多操作" : "更多操作")
        .accessibilityLabel(style == .standard || style == .artist ? "\(title)页面选项" : "更多操作")
        .accessibilityIdentifier("FnMusic.PageOptions")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                .accessibilityLabel(placeholder)
                .accessibilityIdentifier("FnMusic.PageSearch")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel("清除查找")
            }
        }
        .padding(.horizontal, 11)
        .frame(width: PageToolbarMetrics.searchWidth, height: PageToolbarMetrics.controlHeight)
        .modifier(FloatingTopControlGlass(shape: Capsule()))
    }
}

/// A frosted titlebar. Standard pages fill the toolbar; artist pages constrain
/// the material to the directory pane while keeping controls on the same row.
private struct FloatingTopBackdrop: View {
    let width: CGFloat?
    @Environment(\.accessibilityReduceTransparency) private var opaque

    var body: some View {
        Group {
            if opaque {
                Color(nsColor: .windowBackgroundColor)
            } else if #available(macOS 26.0, *) {
                Rectangle()
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: 0)) // 全宽矩形，圆角为0
            } else {
                Rectangle().fill(.ultraThinMaterial) // 旧系统回退
            }
        }
        .overlay(alignment: .bottomLeading) {
            Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5)
        }
        .frame(width: width)
    }
}

/// Clear interactive glass distinguishes the two controls from the quieter
/// full-width titlebar material without adding a second opaque plate.
struct FloatingTopControlGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        if opaque {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            content
                .background { shape.fill(.ultraThinMaterial).opacity(0.45) }
                .glassEffect(.clear.interactive(!reduceMotion), in: shape)
        } else {
            content
                .background { shape.fill(.ultraThinMaterial).opacity(0.65) }
                .overlay(shape.strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
        }
    }
}

private struct CommonPageOptions: View {
    @Environment(AppState.self) private var app
    @Environment(LibraryContext.self) private var library

    var body: some View {
        Menu("导航") {
            Button("返回上一级") { LibraryNavigationActions.goBack(in: library) }
                .disabled(library.navigation.isEmpty)
            Button("前进") { library.goForward() }.disabled(!library.canGoForward)
            Divider()
            Button("搜索整个资料库") { navigate(to: .search) }
            Button("主页") { navigate(to: .home) }
            Button("所有歌曲") { navigate(to: .tracks) }
            Button("所有播放列表") { navigate(to: .playlists) }
            Menu("其他资料库") {
                Button("风格") { navigate(to: .genres) }
                Button("音乐库") { navigate(to: .library) }
                Button("播放历史") { navigate(to: .recent) }
            }
        }
        if library.downloads.isPreparing || library.downloads.isDownloading {
            Divider()
            Text(library.downloads.isPreparing ? "正在准备下载…" : "下载进度 \(Int(library.downloads.progress * 100))%")
            Button("取消下载", role: .destructive) { library.downloads.cancel() }
        }
        Divider()
        SettingsLink { Label("设置", systemImage: "gearshape") }
        Button("退出登录") { Task { await app.logout() } }
    }

    private func navigate(to destination: SidebarDestination) {
        library.resetNavigation()
        app.selection = destination
    }
}
