import SwiftUI

// MARK: - Artist Sort Field

enum ArtistSortField: String, CaseIterable {
    case name
    case trackCount

    func getComparator(ascending: Bool) -> KeyPathComparator<ArtistEntity> {
        switch self {
        case .name:
            return KeyPathComparator(\ArtistEntity.name, order: ascending ? .forward : .reverse)
        case .trackCount:
            return KeyPathComparator(\ArtistEntity.trackCount, order: ascending ? .forward : .reverse)
        }
    }

    /// Detect the sort field from a comparator array by parsing its description,
    /// matching the TrackSortField approach.
    static func detect(from sortOrder: [KeyPathComparator<ArtistEntity>]) -> ArtistSortField {
        guard let firstSort = sortOrder.first else { return .name }
        return String(describing: firstSort).contains("trackCount") ? .trackCount : .name
    }

    /// Detect whether the sort order is ascending from a comparator array.
    static func isAscending(from sortOrder: [KeyPathComparator<ArtistEntity>]) -> Bool {
        guard let firstSort = sortOrder.first else { return true }
        return String(describing: firstSort).contains("forward")
    }
}

// MARK: - Artist Table View

/// Multi-column artist list mirroring the tracks table presentation.
struct ArtistTableView: View {
    let artists: [ArtistEntity]
    let onSelectArtist: (ArtistEntity) -> Void
    let contextMenuItems: (ArtistEntity) -> [ContextMenuItem]
    @Binding var sortOrder: [KeyPathComparator<ArtistEntity>]

    @State private var selection: Set<ArtistEntity.ID> = []
    @State private var sortedArtists: [ArtistEntity] = []

    private static let artistFont = Font.system(size: 13, weight: .regular)
    private static let sortOrderStorageKey = "artistTableSortOrder"

    var body: some View {
        Table(sortedArtists, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Artist", value: \.name) { artist in
                Text(artist.displayName)
                    .font(Self.artistFont)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 200)

            TableColumn("Songs", value: \.trackCount) { artist in
                Text("\(artist.trackCount)")
                    .font(Self.artistFont)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 40)
        }
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 28)
        .contextMenu(forSelectionType: ArtistEntity.ID.self) { selectedIDs in
            let targetID = selectedIDs.first ?? selection.first
            if let artist = sortedArtists.first(where: { $0.id == targetID }) {
                ForEach(contextMenuItems(artist), id: \.id) { item in
                    ContextMenuItemView(item: item)
                }
            }
        } primaryAction: { selectedIDs in
            let targetID = selectedIDs.first ?? selection.first
            if let artist = sortedArtists.first(where: { $0.id == targetID }) {
                onSelectArtist(artist)
            }
        }
        .onAppear {
            restorePersistedSortOrder()
            performLocalizedSort()
        }
        .onChange(of: sortOrder) { _, newValue in
            persistSortOrder(newValue)
            performLocalizedSort()
        }
        .onChange(of: artists) { _, _ in
            performLocalizedSort()
        }
    }

    // MARK: - Sorting

    /// Re-sort with localized comparison so Chinese and other locale-aware ordering
    /// matches the previous grid presentation. Column-header comparators are
    /// non-localized, so ordering is rebuilt from the detected field and direction.
    private func performLocalizedSort() {
        let field = ArtistSortField.detect(from: sortOrder)
        let ascending = ArtistSortField.isAscending(from: sortOrder)

        sortedArtists = artists.sorted { a, b in
            switch field {
            case .name:
                let result = a.name.localizedCaseInsensitiveCompare(b.name)
                return ascending ? result == .orderedAscending : result == .orderedDescending
            case .trackCount:
                if a.trackCount != b.trackCount {
                    return ascending ? a.trackCount < b.trackCount : a.trackCount > b.trackCount
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    // MARK: - Sort Persistence

    private func restorePersistedSortOrder() {
        if let savedSort = UserDefaults.standard.dictionary(forKey: Self.sortOrderStorageKey),
           let key = savedSort["key"] as? String,
           let ascending = savedSort["ascending"] as? Bool,
           let field = ArtistSortField(rawValue: key) {
            sortOrder = [field.getComparator(ascending: ascending)]
            return
        }

        sortOrder = [ArtistSortField.name.getComparator(ascending: true)]
    }

    private func persistSortOrder(_ newValue: [KeyPathComparator<ArtistEntity>]) {
        let storage: [String: Any] = [
            "key": ArtistSortField.detect(from: newValue).rawValue,
            "ascending": ArtistSortField.isAscending(from: newValue)
        ]
        UserDefaults.standard.set(storage, forKey: Self.sortOrderStorageKey)
    }
}

// MARK: - Preview

#Preview("Artist Table") {
    let artists = [
        ArtistEntity(name: "Beatles", trackCount: 25),
        ArtistEntity(name: "Coldplay", trackCount: 42),
        ArtistEntity(name: "周杰伦", trackCount: 68)
    ]

    @Previewable @State var sortOrder = [KeyPathComparator(\ArtistEntity.name)]

    ArtistTableView(
        artists: artists,
        sortOrder: $sortOrder,
        onSelectArtist: { artist in
            Logger.debugPrint("Selected: \(artist.name)")
        },
        contextMenuItems: { _ in [] }
    )
    .frame(width: 500, height: 300)
}
