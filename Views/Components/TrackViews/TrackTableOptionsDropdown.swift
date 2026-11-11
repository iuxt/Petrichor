import SwiftUI

// MARK: - Sort Field Enum

enum TrackSortField: String, CaseIterable {
    case trackNumber
    case discNumber
    case title
    case artist
    case album
    case genre
    case year
    case composer
    case filename
    case duration
    case dateAdded
    case playCount
    case lastPlayedDate
    case custom

    var displayName: String {
        switch self {
        case .trackNumber: return String(appLocalized: "Track number (#)")
        case .discNumber: return String(appLocalized: "Disc number")
        case .title: return String(appLocalized: "Title")
        case .artist: return String(appLocalized: "Artist")
        case .album: return String(appLocalized: "Album")
        case .genre: return String(appLocalized: "Genre")
        case .year: return String(appLocalized: "Year")
        case .composer: return String(appLocalized: "Composer")
        case .filename: return String(appLocalized: "Filename")
        case .duration: return String(appLocalized: "Duration")
        case .dateAdded: return String(appLocalized: "Date added")
        case .playCount: return String(appLocalized: "Play count")
        case .lastPlayedDate: return String(appLocalized: "Last played")
        case .custom: return String(appLocalized: "Custom")
        }
    }

    func getComparator(ascending: Bool) -> KeyPathComparator<Track> {
        let sortComparators: [TrackSortField: KeyPathComparator<Track>] = [
            .trackNumber: KeyPathComparator(\Track.sortableTrackNumber, order: ascending ? .forward : .reverse),
            .discNumber: KeyPathComparator(\Track.sortableDiscNumber, order: ascending ? .forward : .reverse),
            .title: KeyPathComparator(\Track.title, order: ascending ? .forward : .reverse),
            .artist: KeyPathComparator(\Track.artist, order: ascending ? .forward : .reverse),
            .album: KeyPathComparator(\Track.album, order: ascending ? .forward : .reverse),
            .genre: KeyPathComparator(\Track.genre, order: ascending ? .forward : .reverse),
            .year: KeyPathComparator(\Track.year, order: ascending ? .forward : .reverse),
            .composer: KeyPathComparator(\Track.composer, order: ascending ? .forward : .reverse),
            .filename: KeyPathComparator(\Track.filename, order: ascending ? .forward : .reverse),
            .duration: KeyPathComparator(\Track.duration, order: ascending ? .forward : .reverse),
            .dateAdded: KeyPathComparator(\Track.dateAdded, order: ascending ? .forward : .reverse),
            .playCount: KeyPathComparator(\Track.playCount, order: ascending ? .forward : .reverse),
            .lastPlayedDate: KeyPathComparator(\Track.sortableLastPlayedDate, order: ascending ? .forward : .reverse),
            .custom: KeyPathComparator(\Track.sortableDateAdded, order: .forward)
        ]

        return sortComparators[self] ?? KeyPathComparator(\Track.title, order: ascending ? .forward : .reverse)
    }

    /// User-selectable sort fields. Hidden smart-playlist sort keys like play count and
    /// last played remain supported internally, but are omitted because the table has no
    /// matching visible columns for them.
    static var sortFields: [TrackSortField] {
        [
            .trackNumber, .discNumber, .title, .artist, .album, .genre,
            .year, .composer, .filename, .duration, .dateAdded
        ]
    }

    // MARK: - Comparator Parsing

    /// Map of KeyPathComparator description substrings to sort fields.
    private static let comparatorKeyMap: [(String, TrackSortField)] = [
        ("sortableTrackNumber", .trackNumber),
        ("sortableDiscNumber", .discNumber),
        ("sortableDateAdded", .dateAdded),
        ("sortableLastPlayedDate", .lastPlayedDate),
        ("dateAdded", .dateAdded),
        ("playCount", .playCount),
        ("lastPlayedDate", .lastPlayedDate),
        ("title", .title),
        ("artist", .artist),
        ("album", .album),
        ("genre", .genre),
        ("year", .year),
        ("composer", .composer),
        ("filename", .filename),
        ("duration", .duration),
    ]

    /// Detect the sort field from a KeyPathComparator array by parsing its description.
    static func detect(from sortOrder: [KeyPathComparator<Track>]) -> TrackSortField {
        guard let firstSort = sortOrder.first else { return .title }
        let sortString = String(describing: firstSort)
        for (key, field) in comparatorKeyMap where sortString.contains(key) {
            return field
        }
        return .title
    }

    /// Detect whether the sort order is ascending from a KeyPathComparator array.
    static func isAscending(from sortOrder: [KeyPathComparator<Track>]) -> Bool {
        guard let firstSort = sortOrder.first else { return true }
        return String(describing: firstSort).contains("forward")
    }

    /// The UserDefaults storage key (matches rawValue).
    var storageKey: String { rawValue }

    /// Look up a sort field from its storage key.
    static func from(storageKey: String) -> TrackSortField? {
        TrackSortField(rawValue: storageKey)
    }
}

/// Track/disc positions describe an album sequence, rather than an order across albums.
/// Folders and playlists keep these options for users arranging their own files/lists.
enum TrackSortContext: Equatable {
    case library
    case album
    case folder
    case playlist

    func allows(_ field: TrackSortField) -> Bool {
        self != .library || (field != .trackNumber && field != .discNumber)
    }

    var sortFields: [TrackSortField] {
        TrackSortField.sortFields.filter { allows($0) }
    }

    func normalized(_ order: [KeyPathComparator<Track>]) -> [KeyPathComparator<Track>] {
        guard !order.isEmpty, order.allSatisfy({ allows(TrackSortField.detect(from: [$0])) }) else {
            return [TrackSortField.title.getComparator(ascending: true)]
        }
        return order
    }
}

// MARK: - TrackTableOptionsDropdown

struct TrackTableOptionsDropdown: View {
    @Binding var sortOrder: [KeyPathComparator<Track>]
    @Binding var tableRowSize: TableRowSize
    private let playlistID: UUID?
    private let sortContext: TrackSortContext
    private let showCustomSort: Bool
    @State private var isCustomSort = false
    @AppStorage(NativeTrackTable.columnCustomizationKey)
    private var columnCustomizationData = Data()

    private var columnCustomization: TableColumnCustomization<Track> {
        NativeTrackTable.columnCustomization(from: columnCustomizationData)
    }

    init(
        sortOrder: Binding<[KeyPathComparator<Track>]>,
        tableRowSize: Binding<TableRowSize>,
        playlistID: UUID? = nil,
        showCustomSort: Bool = false,
        sortContext: TrackSortContext = .library
    ) {
        self._sortOrder = sortOrder
        self._tableRowSize = tableRowSize
        self.playlistID = playlistID
        self.showCustomSort = showCustomSort
        self.sortContext = sortContext
    }

    private var currentSortField: TrackSortField {
        if isCustomSort {
            return .custom
        }
        return TrackSortField.detect(from: sortOrder)
    }

    private var isAscending: Bool {
        TrackSortField.isAscending(from: sortOrder)
    }

    private var canChangeSortOrder: Bool {
        !isCustomSort && sortContext.sortFields.contains(currentSortField)
    }

    var body: some View {
        Menu {
            Section("Sort by") {
                ForEach(sortContext.sortFields, id: \.self) { field in
                    Toggle(field.displayName, isOn: Binding(
                        get: { currentSortField == field },
                        set: { _ in setSortField(field) }
                    ))
                }

                if showCustomSort {
                    Divider()

                    Toggle(TrackSortField.custom.displayName, isOn: Binding(
                        get: { isCustomSort },
                        set: { _ in setSortField(.custom) }
                    ))
                }
            }

            Divider()

            Section("Sort order") {
                Toggle("Ascending", isOn: Binding(
                    get: { isAscending },
                    set: { _ in setSortAscending(true) }
                ))

                Toggle("Descending", isOn: Binding(
                    get: { !isAscending },
                    set: { _ in setSortAscending(false) }
                ))
            }
            .disabled(!canChangeSortOrder)

            Divider()

            Menu(String(appLocalized: "Show Columns")) {
                let customization = columnCustomization
                let visibleCount = NativeTrackTable.columns.filter { $0.isVisible(in: customization) }.count
                ForEach(NativeTrackTable.columns, id: \.id) { column in
                    Toggle(column.displayName, isOn: Binding(
                        get: { column.isVisible(in: columnCustomization) },
                        set: { setColumnVisibility(column.id, visible: $0) }
                    ))
                    .disabled(column.isVisible(in: customization) && visibleCount <= 1)
                }

                Divider()

                Button(String(appLocalized: "Restore Default Columns")) {
                    columnCustomizationData = Data()
                }
            }

            Divider()

            Section("Row size") {
                ForEach([TableRowSize.expanded, TableRowSize.compact], id: \.self) { size in
                    Toggle(size.displayName, isOn: Binding(
                        get: { tableRowSize == size },
                        set: { _ in setRowSize(size) }
                    ))
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 14)
        .hoverEffect(activeBackgroundColor: Color(NSColor.controlColor))
        .help("Sort and display options")
        .onAppear {
            syncCustomSortState()
        }
        .onChange(of: sortOrder) {
            // When parent updates sortOrder (e.g. playlist switch), re-sync custom state
            syncCustomSortState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackTableSortChanged)) { notification in
            if let context = notification.userInfo?["sortContext"] as? TrackSortContext,
               context != sortContext { return }
            if let id = notification.userInfo?["sortPlaylistID"] as? String,
               id != (playlistID?.uuidString ?? "") { return }
            if notification.userInfo?["fromTable"] as? Bool == true,
               let newSortOrder = notification.userInfo?["sortOrder"] as? [KeyPathComparator<Track>] {
                sortOrder = newSortOrder
                // Table column header click overrides custom sort
                if isCustomSort {
                    isCustomSort = false
                }
            }
            if let customSort = notification.userInfo?["isCustomSort"] as? Bool {
                isCustomSort = customSort
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackTableRowSizeChanged)) { notification in
            if let context = notification.userInfo?["sortContext"] as? TrackSortContext,
               context != sortContext { return }
            if let id = notification.userInfo?["sortPlaylistID"] as? String,
               id != (playlistID?.uuidString ?? "") { return }
            if notification.userInfo?["fromTable"] as? Bool == true,
               let newRowSize = notification.userInfo?["rowSize"] as? TableRowSize {
                tableRowSize = newRowSize
            }
        }
    }

    // MARK: - Helper Methods

    private func setColumnVisibility(_ id: String, visible: Bool) {
        var customization = columnCustomization
        NativeTrackTable.setColumnVisibility(id, visible: visible, in: &customization)
        do {
            columnCustomizationData = try JSONEncoder().encode(customization)
        } catch {
            Logger.warning("Failed to encode TableColumnCustomization: \(error)")
        }
    }

    private func syncCustomSortState() {
        if let playlistID = playlistID {
            isCustomSort = PlaylistSortManager.shared.getSortField(for: playlistID) == .custom
        } else {
            isCustomSort = false
        }
    }

    private func setSortField(_ field: TrackSortField) {
        guard sortContext.allows(field) else { return }
        let isCustom = field == .custom
        isCustomSort = isCustom

        if let playlistID = playlistID {
            PlaylistSortManager.shared.setSortField(field, for: playlistID)
        }

        let newComparator = field.getComparator(ascending: isAscending)
        let userDefaultsKey = playlistID != nil ? "playlistTableSortOrder" : "trackTableSortOrder"

        NotificationCenter.default.post(
            name: .trackTableSortChanged,
            object: nil,
            userInfo: [
                "sortContext": sortContext,
                "sortPlaylistID": playlistID?.uuidString ?? "",
                "sortOrder": [newComparator],
                "userDefaultsKey": userDefaultsKey,
                "isCustomSort": isCustom
            ]
        )
    }

    private func setSortAscending(_ ascending: Bool) {
        let newComparator = currentSortField.getComparator(ascending: ascending)

        let userDefaultsKey = playlistID != nil ? "playlistTableSortOrder" : "trackTableSortOrder"

        if let playlistID = playlistID {
            PlaylistSortManager.shared.setSortAscending(ascending, for: playlistID)
        }

        NotificationCenter.default.post(
            name: .trackTableSortChanged,
            object: nil,
            userInfo: [
                "sortContext": sortContext,
                "sortPlaylistID": playlistID?.uuidString ?? "",
                "sortOrder": [newComparator],
                "userDefaultsKey": userDefaultsKey,
                "isCustomSort": false
            ]
        )
    }

    private func setRowSize(_ size: TableRowSize) {
        UserDefaults.standard.set(size.rawValue, forKey: "trackTableRowSize")

        NotificationCenter.default.post(
            name: .trackTableRowSizeChanged,
            object: nil,
            userInfo: ["rowSize": size]
        )
    }
}
