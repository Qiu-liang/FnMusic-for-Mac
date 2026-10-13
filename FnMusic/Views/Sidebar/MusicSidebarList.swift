import AppKit
import SwiftUI

/// Measured from the supplied Music sidebar, in logical points. Content remains
/// FnMusic's own destinations; these constants control only native presentation.
@MainActor
enum MusicSidebarMetrics {
    static let width: CGFloat = 206
    static let rowHeight: CGFloat = 32
    static let groupHeight: CGFloat = 36
    static let iconLeading: CGFloat = 26
    static let iconSize: CGFloat = 20
    static let textLeading: CGFloat = 53
    static let selectionLeading: CGFloat = 8
    static let selectionTrailing: CGFloat = 10
    static let accent = NSColor(srgbRed: 1, green: 0.02, blue: 0.30, alpha: 1)
}

struct MusicSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A real AppKit source list avoids SwiftUI List's version-dependent cell padding,
/// tint overrides and minimum row sizing. NSTableView owns focus, selection and
/// keyboard navigation; no screen coordinates or simulated web controls are used.
struct MusicSidebarList: NSViewRepresentable {
    @Binding var selection: SidebarDestination?
    let playlists: [Playlist]
    let images: ImageCache
    let isLoading: Bool
    let error: String?
    let onCreate: () -> Void
    let onAllPlaylists: () -> Void
    let onRetry: () -> Void

    enum Row: Equatable {
        case destination(SidebarDestination)
        case libraryHeader
        case playlistHeader
        case playlist(Playlist)
        case loading
        case empty
        case failure(String)

        var destination: SidebarDestination? {
            switch self {
            case .destination(let destination): destination
            case .playlist(let playlist): .playlist(playlist.guid)
            default: nil
            }
        }
        var isHeader: Bool { self == .libraryHeader || self == .playlistHeader }
    }

    static func rows(playlists: [Playlist], isLoading: Bool, error: String?) -> [Row] {
        var result = SidebarDestination.topItems.map(Row.destination)
        result.append(.libraryHeader)
        result += SidebarDestination.libraryItems.map(Row.destination)
        result.append(.playlistHeader)
        result += SidebarDestination.playlistItems.map(Row.destination)
        result += playlists.map(Row.playlist)
        if let error { result.append(.failure(error)) }
        else if isLoading && playlists.isEmpty { result.append(.loading) }
        else if playlists.isEmpty { result.append(.empty) }
        return result
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MusicSidebarScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = .init(top: 0, left: 0, bottom: 0, right: 0)
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none

        let table = MusicSidebarTableView(frame: NSRect(x: 0, y: 0, width: MusicSidebarMetrics.width, height: 1))
        let column = NSTableColumn(identifier: .init("navigation"))
        column.width = MusicSidebarMetrics.width
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.rowHeight = MusicSidebarMetrics.rowHeight
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.focusRingType = .none
        table.floatsGroupRows = false
        table.setAccessibilityLabel("侧边栏")
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.update(self)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(self) }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: MusicSidebarList
        weak var table: MusicSidebarTableView?
        private var items: [Row] = []
        private var updating = false

        init(parent: MusicSidebarList) { self.parent = parent }

        func update(_ parent: MusicSidebarList) {
            self.parent = parent
            guard let table else { return }
            updating = true
            defer { updating = false }
            let next = MusicSidebarList.rows(playlists: parent.playlists, isLoading: parent.isLoading, error: parent.error)
            if items != next {
                items = next
                table.reloadData()
            }
            if let selection = parent.selection, let index = items.firstIndex(where: { $0.destination == selection }) {
                if table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            } else { table.deselectAll(nil) }
            updateVisibleFonts()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            items[row].isHeader ? MusicSidebarMetrics.groupHeight : MusicSidebarMetrics.rowHeight
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items[row].destination != nil }
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { items[row].isHeader }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { MusicSidebarRowView() }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            switch items[row] {
            case .destination(let item):
                let cell = navigationCell(tableView)
                cell.configure(title: item.title, symbol: item.symbol, selected: parent.selection == item)
                return cell
            case .playlist(let playlist):
                let cell = navigationCell(tableView)
                cell.configure(playlist: playlist, cache: parent.images, selected: parent.selection == .playlist(playlist.guid))
                return cell
            case .libraryHeader:
                return header(title: "资料库", playlist: false)
            case .playlistHeader:
                return header(title: "播放列表", playlist: true)
            case .loading, .empty, .failure:
                return status(items[row])
            }
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            switch items[row] {
            case .destination(let item): item.title
            case .playlist(let playlist): playlist.displayName
            default: nil
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, items.indices.contains(table.selectedRow),
                  let destination = items[table.selectedRow].destination else { return }
            parent.selection = destination
            updateVisibleFonts()
        }

        private func updateVisibleFonts() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            for row in visible.location..<min(NSMaxRange(visible), items.count) {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MusicSidebarCellView)?
                    .setSelected(row == table.selectedRow)
            }
        }

        private func navigationCell(_ table: NSTableView) -> MusicSidebarCellView {
            let identifier = NSUserInterfaceItemIdentifier("music-navigation-row")
            let cell = table.makeView(withIdentifier: identifier, owner: nil) as? MusicSidebarCellView ?? MusicSidebarCellView()
            cell.identifier = identifier
            return cell
        }

        private func header(title: String, playlist: Bool) -> NSView {
            let view = NSView()
            let label = NSButton(title: title, target: playlist ? self : nil, action: playlist ? #selector(openPlaylists) : nil)
            label.isBordered = false
            label.bezelStyle = .inline
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.contentTintColor = .secondaryLabelColor
            label.alignment = .left
            label.isEnabled = playlist
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 15),
                label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
                label.heightAnchor.constraint(equalToConstant: 16)
            ])
            if playlist {
                label.toolTip = "查看和管理所有歌单"
                let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "新建歌单") ?? NSImage(),
                                   target: self, action: #selector(createPlaylist))
                add.isBordered = false
                add.contentTintColor = .secondaryLabelColor
                add.imageScaling = .scaleProportionallyDown
                add.toolTip = "新建歌单（实验性写接口）"
                add.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(add)
                NSLayoutConstraint.activate([
                    add.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                    add.centerYAnchor.constraint(equalTo: label.centerYAnchor),
                    add.widthAnchor.constraint(equalToConstant: 18),
                    add.heightAnchor.constraint(equalToConstant: 18),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: add.leadingAnchor, constant: -4)
                ])
            } else {
                label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12).isActive = true
            }
            return view
        }

        private func status(_ row: Row) -> NSView {
            let view = NSView()
            let title: String
            switch row {
            case .loading: title = "正在加载歌单…"
            case .failure: title = "加载失败，点击重试"
            default: title = "暂无歌单"
            }
            let button = NSButton(title: title, target: self, action: #selector(retry))
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.contentTintColor = .secondaryLabelColor
            button.alignment = .left
            if case .failure(let error) = row { button.toolTip = error }
            else { button.isEnabled = false }
            button.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 26),
                button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
                button.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            return view
        }

        @objc private func openPlaylists() { parent.onAllPlaylists() }
        @objc private func createPlaylist() { parent.onCreate() }
        @objc private func retry() { parent.onRetry() }
    }
}

final class MusicSidebarScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {}
}

final class MusicSidebarTableView: NSTableView {
    override func scrollWheel(with event: NSEvent) {}
}

final class MusicSidebarRowView: NSTableRowView {
    // The selection is neutral gray, so AppKit must not recolor its cells white.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = NSRect(x: MusicSidebarMetrics.selectionLeading, y: 0,
                          width: max(0, bounds.width - MusicSidebarMetrics.selectionLeading - MusicSidebarMetrics.selectionTrailing),
                          height: bounds.height)
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
    }
}

final class MusicSidebarCellView: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")
    let symbolView = NSImageView()
    private let coverView = NSView()
    private var artworkTask: Task<Void, Never>?
    private var identity = UUID()

    init() {
        super.init(frame: .zero)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.textColor = .labelColor
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = titleLabel
        coverView.wantsLayer = true
        coverView.layer?.cornerRadius = 3
        coverView.layer?.masksToBounds = true
        coverView.layer?.contentsGravity = .resizeAspectFill
        symbolView.imageScaling = .scaleProportionallyDown
        for icon in [coverView, symbolView] {
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MusicSidebarMetrics.iconLeading),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: MusicSidebarMetrics.iconSize),
                icon.heightAnchor.constraint(equalToConstant: MusicSidebarMetrics.iconSize)
            ])
        }
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MusicSidebarMetrics.textLeading),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { return nil }
    deinit { artworkTask?.cancel() }

    func configure(title: String, symbol: String, selected: Bool) {
        reset(title: title, selected: selected)
        coverView.isHidden = true
        symbolView.isHidden = false
        symbolView.contentTintColor = MusicSidebarMetrics.accent
        symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
    }

    func configure(playlist: Playlist, cache: ImageCache, selected: Bool) {
        reset(title: playlist.displayName, selected: selected)
        toolTip = playlist.trackCount.map { "\(playlist.displayName) · \($0) 首歌曲" } ?? playlist.displayName
        coverView.isHidden = false
        coverView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        symbolView.isHidden = false
        symbolView.contentTintColor = .secondaryLabelColor
        symbolView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        guard let coverId = playlist.coverId else { return }
        let request = identity
        artworkTask = Task { [weak self] in
            do {
                let image = try await cache.image(id: coverId, size: 160)
                try Task.checkCancellation()
                guard let self, self.identity == request else { return }
                self.coverView.layer?.contents = image
                self.symbolView.isHidden = true
            } catch { /* Keep the neutral placeholder; a list refresh retries. */ }
        }
    }

    func setSelected(_ selected: Bool) {
        titleLabel.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        titleLabel.textColor = .labelColor
    }

    private func reset(title: String, selected: Bool) {
        artworkTask?.cancel()
        artworkTask = nil
        identity = UUID()
        titleLabel.stringValue = title
        setAccessibilityLabel(title)
        toolTip = title
        coverView.layer?.contents = nil
        setSelected(selected)
    }
}
