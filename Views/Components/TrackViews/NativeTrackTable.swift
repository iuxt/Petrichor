import AppKit
import SwiftUI

/// Reuses native cells instead of retaining a SwiftUI graph for every visited row.
struct NativeTrackTable: NSViewRepresentable {
    let tracks: [Track]
    @Binding var selection: Set<Track.ID>
    @Binding var sortOrder: [KeyPathComparator<Track>]
    @Binding var customization: TableColumnCustomization<Track>
    let rowSize: TableRowSize
    let currentTrack: Track?
    let isPlaying: Bool
    let artworkRevision: Int
    let onPlay: (Track) -> Void
    let onDoubleClick: (Track) -> Void
    let menuItems: ([Track]) -> [ContextMenuItem]

    struct Column {
        let id: String
        let title: String
        let width: CGFloat
        let visible: Bool
    }
    static var columns: [Column] { [
        Column(id: "trackNumber", title: "#", width: 45, visible: false),
        Column(id: "discNumber", title: String(appLocalized: "Disc"), width: 45, visible: false),
        Column(id: "title", title: String(appLocalized: "Title"), width: 260, visible: true),
        Column(id: "artist", title: String(appLocalized: "Artist"), width: 150, visible: true),
        Column(id: "album", title: String(appLocalized: "Album"), width: 150, visible: true),
        Column(id: "genre", title: String(appLocalized: "Genre"), width: 100, visible: false),
        Column(id: "year", title: String(appLocalized: "Year"), width: 60, visible: true),
        Column(id: "composer", title: String(appLocalized: "Composer"), width: 150, visible: false),
        Column(id: "filename", title: String(appLocalized: "Filename"), width: 200, visible: false),
        Column(id: "dateAdded", title: String(appLocalized: "Date Added"), width: 110, visible: false),
        Column(id: "duration", title: String(appLocalized: "Duration"), width: 65, visible: true)
    ] }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = MenuTrackTable()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .reverseSequentialColumnAutoresizingStyle
        table.style = .inset
        table.backgroundColor = .clear
        table.rowHeight = rowSize.rowHeight
        table.intercellSpacing = NSSize(width: 12, height: 0)
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClick)
        for definition in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(definition.id))
            column.title = definition.title
            column.width = definition.width
            column.minWidth = definition.id == "title" ? 200 : 40
            // Keep short values compact while longer text columns fill the table.
            if ["title", "artist", "album", "genre", "composer", "filename", "dateAdded"].contains(definition.id) {
                column.resizingMask = [.userResizingMask, .autoresizingMask]
            } else {
                column.resizingMask = .userResizingMask
            }
            if definition.id == "duration" { column.maxWidth = 100 }
            column.sortDescriptorPrototype = NSSortDescriptor(key: definition.id, ascending: true)
            table.addTableColumn(column)
        }
        table.autosaveName = "NativeTrackTableColumns"
        table.autosaveTableColumns = true
        table.buildMenu = { [weak coordinator = context.coordinator] row in coordinator?.menu(for: row) }
        table.activateSelection = { [weak coordinator = context.coordinator] in coordinator?.activateSelection() }
        table.viewportChanged = { [weak coordinator = context.coordinator] in coordinator?.schedulePrefetch() }
        let headerMenu = NSMenu()
        for column in table.tableColumns {
            let item = NSMenuItem(title: column.title, action: #selector(Coordinator.toggleColumn(_:)), keyEquivalent: "")
            item.representedObject = column.identifier.rawValue
            item.target = context.coordinator
            headerMenu.addItem(item)
        }
        table.headerView?.menu = headerMenu
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        context.coordinator.table = table
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.viewportChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.update(self)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update(self) }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.cancelPrefetch()
        coordinator.table?.viewportChanged = nil
        coordinator.table?.enumerateAvailableRowViews { row, _ in
            for cell in row.subviews.compactMap({ $0 as? NativeTrackTitleCell }) { cell.artwork.stopLoading() }
        }
        coordinator.table?.delegate = nil
        coordinator.table?.dataSource = nil
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: NativeTrackTable
        weak var table: MenuTrackTable?
        private var initialized = false
        private var applying = false
        private var actions: [() -> Void] = []
        private var prefetchTasks: [ArtworkRequest: Task<Void, Never>] = [:]
        private var prefetchUpdate: Task<Void, Never>?
        private var previousVisibleRow = 0
        private static let dates: DateFormatter = {
            let value = DateFormatter(); value.dateStyle = .medium; value.timeStyle = .none; return value
        }()

        init(_ parent: NativeTrackTable) { self.parent = parent }

        deinit {
            prefetchUpdate?.cancel()
            for task in prefetchTasks.values { task.cancel() }
        }

        func update(_ next: NativeTrackTable) {
            guard let table else { return }
            let changedTracks = !initialized || next.tracks != parent.tracks
            if changedTracks || next.artworkRevision != parent.artworkRevision { cancelPrefetch() }
            let changedAppearance = !initialized || next.currentTrack != parent.currentTrack || next.isPlaying != parent.isPlaying
                || next.rowSize != parent.rowSize || next.artworkRevision != parent.artworkRevision
            parent = next
            applying = true
            defer { applying = false; initialized = true }
            for definition in NativeTrackTable.columns {
                guard let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(definition.id)) else { continue }
                let visibility = parent.customization[visibility: definition.id]
                column.isHidden = visibility == .hidden || (visibility == .automatic && !definition.visible)
            }
            for item in table.headerView?.menu?.items ?? [] {
                if let id = item.representedObject as? String, let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)) {
                    item.state = column.isHidden ? .off : .on
                }
            }
            let field = TrackSortField.detect(from: parent.sortOrder)
            let descriptor = NSSortDescriptor(key: field.rawValue, ascending: TrackSortField.isAscending(from: parent.sortOrder))
            if table.sortDescriptors != [descriptor] { table.sortDescriptors = [descriptor] }
            if table.rowHeight != parent.rowSize.rowHeight { table.rowHeight = parent.rowSize.rowHeight }
            if changedTracks { table.reloadData() }
            let indices = IndexSet(parent.tracks.indices.filter { parent.selection.contains(parent.tracks[$0].id) })
            let changedSelection = indices != table.selectedRowIndexes
            if changedSelection { table.selectRowIndexes(indices, byExtendingSelection: false) }
            if changedTracks || changedAppearance || changedSelection { refreshVisibleCells() }
            schedulePrefetch()
        }

        @objc func viewportChanged(_ notification: Notification) { schedulePrefetch() }

        func schedulePrefetch() {
            guard table?.window != nil, parent.rowSize == .expanded,
                  table?.tableColumn(withIdentifier: .init("title"))?.isHidden == false else {
                cancelPrefetch()
                return
            }
            guard prefetchUpdate == nil else { return }
            // Coalesce row creation and scroll notifications into one small update.
            prefetchUpdate = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.prefetchUpdate = nil
                self.prefetchNearbyRows()
            }
        }

        func cancelPrefetch() {
            prefetchUpdate?.cancel()
            prefetchUpdate = nil
            for task in prefetchTasks.values { task.cancel() }
            prefetchTasks.removeAll()
        }

        private func prefetchNearbyRows() {
            guard let table, table.window != nil else { cancelPrefetch(); return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound, visible.length > 0,
                  parent.tracks.indices.contains(visible.location) else { cancelPrefetch(); return }
            let end = min(NSMaxRange(visible), parent.tracks.count)
            let margin = min(32, max(12, visible.length * 2))
            let after = Array(end..<min(parent.tracks.count, end + margin))
            let before = Array(max(0, visible.location - margin)..<visible.location).reversed()
            let rows = visible.location >= previousVisibleRow ? after + before : before + after
            previousVisibleRow = visible.location
            let requests = rows.map { ArtworkRequest.thumbnail(parent.tracks[$0].url, albumTitle: parent.tracks[$0].album) }
            let wanted = Set(requests)
            // Preserve overlapping work on small scrolls; cancel only rows that
            // left the bounded window (at most 32 rows on either side).
            for request in Array(prefetchTasks.keys) where !wanted.contains(request) {
                prefetchTasks.removeValue(forKey: request)?.cancel()
            }
            for request in requests where prefetchTasks[request] == nil {
                guard TrackThumbnailCache.shared.cachedImage(for: request) == nil else { continue }
                prefetchTasks[request] = Task {
                    _ = await TrackThumbnailCache.shared.image(for: request, prefetch: true)
                }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.tracks.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.tracks.indices.contains(row), let column = tableColumn else { return nil }
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView {
                cell = reused
            } else if column.identifier.rawValue == "title" {
                cell = NativeTrackTitleCell()
            } else {
                cell = NSTableCellView()
                let label = NSTextField(labelWithString: "")
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 1
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            cell.identifier = column.identifier
            configure(cell, column: column.identifier.rawValue, row: row)
            return cell
        }

        private func configure(_ cell: NSTableCellView, column: String, row: Int) {
            let track = parent.tracks[row]
            let current = parent.currentTrack.map {
                if let id = $0.trackId, let other = track.trackId { return id == other }
                return $0.url == track.url
            } ?? false
            let selected = table?.selectedRowIndexes.contains(row) ?? false
            cell.textField?.font = .systemFont(ofSize: 13, weight: current ? (column == "title" ? .bold : .medium) : .regular)
            cell.textField?.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
            if let titleCell = cell as? NativeTrackTitleCell {
                titleCell.configure(track: track, expanded: parent.rowSize == .expanded,
                    current: current, playing: parent.isPlaying, selected: selected, revision: parent.artworkRevision)
                titleCell.play = { [weak self] track in self?.parent.onPlay(track) }
            } else {
                let value: String
                switch column {
                case "trackNumber": value = track.trackNumber.map(String.init) ?? ""
                case "discNumber": value = track.discNumber.map(String.init) ?? ""
                case "artist": value = track.displayArtist
                case "album": value = track.displayAlbum
                case "genre": value = track.displayGenre
                case "year": value = track.displayYear
                case "composer": value = track.displayComposer
                case "filename": value = track.filename
                case "dateAdded": value = track.dateAdded.map(Self.dates.string) ?? ""
                case "duration": value = HelperUtils.formattedDuration(track.duration)
                default: value = ""
                }
                cell.textField?.stringValue = value
            }
        }

        private func refreshVisibleCells() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            for row in visible.location..<min(NSMaxRange(visible), parent.tracks.count) {
                for (index, column) in table.tableColumns.enumerated() where !column.isHidden {
                    if let cell = table.view(atColumn: index, row: row, makeIfNecessary: false) as? NSTableCellView {
                        configure(cell, column: column.identifier.rawValue, row: row)
                    }
                }
            }
        }

        func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
            for cell in rowView.subviews.compactMap({ $0 as? NativeTrackTitleCell }) { cell.artwork.stopLoading() }
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            schedulePrefetch()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applying, let table else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap { parent.tracks.indices.contains($0) ? parent.tracks[$0].id : nil })
            refreshVisibleCells()
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applying, let sort = tableView.sortDescriptors.first,
                  let key = sort.key, let field = TrackSortField(rawValue: key) else { return }
            parent.sortOrder = [field == .dateAdded
                ? KeyPathComparator(\Track.sortableDateAdded, order: sort.ascending ? .forward : .reverse)
                : field.getComparator(ascending: sort.ascending)]
        }

        @objc func doubleClick() {
            guard let row = table?.clickedRow, parent.tracks.indices.contains(row) else { return }
            parent.onDoubleClick(parent.tracks[row])
        }

        func activateSelection() {
            guard let row = table?.selectedRow, parent.tracks.indices.contains(row) else { return }
            parent.onDoubleClick(parent.tracks[row])
        }

        @objc func toggleColumn(_ item: NSMenuItem) {
            guard let key = item.representedObject as? String,
                  let column = table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key)) else { return }
            // Keep at least one visible column, matching the native table contract.
            if !column.isHidden && table?.tableColumns.filter({ !$0.isHidden }).count == 1 { return }
            parent.customization[visibility: key] = column.isHidden ? .visible : .hidden
            update(parent)
        }

        func menu(for row: Int) -> NSMenu? {
            guard let table, parent.tracks.indices.contains(row) else { return nil }
            if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            let tracks = table.selectedRowIndexes.compactMap { parent.tracks.indices.contains($0) ? parent.tracks[$0] : nil }
            actions.removeAll()
            return makeMenu(parent.menuItems(tracks))
        }

        private func makeMenu(_ items: [ContextMenuItem]) -> NSMenu {
            let menu = NSMenu()
            for item in items {
                switch item {
                case .divider: menu.addItem(.separator())
                case .button(let title, _, _, let action):
                    let entry = NSMenuItem(title: title, action: #selector(invokeMenu(_:)), keyEquivalent: "")
                    entry.tag = actions.count; actions.append(action); entry.target = self
                    if let icon = item.icon { entry.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
                    menu.addItem(entry)
                case .menu(let title, _, let children):
                    let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    entry.submenu = makeMenu(children)
                    if let icon = item.icon { entry.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
                    menu.addItem(entry)
                }
            }
            return menu
        }

        @objc private func invokeMenu(_ item: NSMenuItem) {
            guard actions.indices.contains(item.tag) else { return }
            actions[item.tag]()
        }
    }
}

@MainActor final class MenuTrackTable: NSTableView {
    var buildMenu: ((Int) -> NSMenu?)?
    var activateSelection: (() -> Void)?
    var viewportChanged: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewportChanged?()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        buildMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            activateSelection?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor final class NativeTrackTitleCell: NSTableCellView {
    let artwork = ThumbnailImageView()
    private let button = NSButton()
    private var track: Track?
    private var expanded = true
    var play: ((Track) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        textField = label
        addSubview(artwork); addSubview(label); addSubview(button)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(playTrack)
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.setAccessibilityLabel(String(appLocalized: "Play"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(track: Track, expanded: Bool, current: Bool, playing: Bool, selected: Bool, revision: Int) {
        self.track = track
        self.expanded = expanded
        textField?.stringValue = track.title
        artwork.isHidden = !expanded
        if expanded { artwork.configure(request: .thumbnail(track.url, albumTitle: track.album), revision: revision) }
        else { artwork.stopLoading() }
        button.isHidden = !current && !selected
        button.image = NSImage(systemSymbolName: current && playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        button.contentTintColor = expanded ? .white : .labelColor
        button.layer?.backgroundColor = expanded ? NSColor.black.withAlphaComponent(0.5).cgColor : nil
        button.setAccessibilityLabel(current && playing ? String(appLocalized: "Pause") : String(appLocalized: "Play"))
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width: CGFloat = expanded ? ViewDefaults.listArtworkSize : 20
        artwork.frame = NSRect(x: 0, y: (bounds.height - width) / 2, width: width, height: width)
        button.frame = artwork.frame
        textField?.frame = NSRect(x: width + 8, y: (bounds.height - 17) / 2,
                                 width: max(0, bounds.width - width - 8), height: 17)
    }
    @objc private func playTrack() { if let track { play?(track) } }
}
