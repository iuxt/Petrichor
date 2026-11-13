import Foundation

struct LibraryFilterItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let count: Int
    let filterType: LibraryFilterType
    let isAllItem: Bool
    /// Album titles are not unique.
    let albumId: Int64?
    let albumArtist: String?

    init(name: String, count: Int, filterType: LibraryFilterType, isAllItem: Bool = false, albumId: Int64? = nil, albumArtist: String? = nil) {
        self.name = name.isEmpty ? "Unknown \(filterType.rawValue.dropLast())" : name
        self.count = count
        self.filterType = filterType
        self.isAllItem = isAllItem
        self.albumId = albumId
        self.albumArtist = albumArtist
    }

    func matches(_ track: Track) -> Bool {
        if filterType == .albums, track.albumId != nil || albumId != nil {
            return track.albumId == albumId
        }
        return filterType.trackMatches(track, filterValue: name)
    }

    static func allItem(for filterType: LibraryFilterType, totalCount: Int) -> LibraryFilterItem {
        LibraryFilterItem(
            name: "All \(filterType.rawValue)",
            count: totalCount,
            filterType: filterType,
            isAllItem: true
        )
    }

    // Equality and hashing deliberately exclude `id` so that two items with the same content
    // compare equal. This lets callers like `LibrarySidebarView.sortCache` actually hit.
    static func == (lhs: LibraryFilterItem, rhs: LibraryFilterItem) -> Bool {
        lhs.name == rhs.name
            && lhs.count == rhs.count
            && lhs.filterType == rhs.filterType
            && lhs.isAllItem == rhs.isAllItem
            && lhs.albumId == rhs.albumId
            && lhs.albumArtist == rhs.albumArtist
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(count)
        hasher.combine(filterType)
        hasher.combine(isAllItem)
        hasher.combine(albumId)
        hasher.combine(albumArtist)
    }
}
