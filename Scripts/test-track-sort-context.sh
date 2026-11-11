#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/Sort.swift" <<'SWIFT'
import Foundation
struct Track {
    var title: String
    var trackNumber: Int
    var discNumber: Int
    var album = "Album"
    var artist = "Artist"
    var genre = "Genre"
    var year = "2026"
    var composer = "Composer"
    var filename = "song.flac"
    var duration = 180.0
    var dateAdded: Date? = nil
    var playCount = 0
    var sortableLastPlayedDate: Date { .distantPast }
    var sortableTrackNumber: Int { trackNumber }
    var sortableDiscNumber: Int { discNumber }
    var sortableDateAdded: Date { dateAdded ?? .distantPast }
}
extension String { init(appLocalized: String) { self = appLocalized } }
SWIFT
sed '/\/\/ MARK: - TrackTableOptionsDropdown/,$d' Views/Components/TrackViews/TrackTableOptionsDropdown.swift >> "$test_dir/Sort.swift"
cat >> "$test_dir/Sort.swift" <<'SWIFT'
let tracks = [
    Track(title: "A", trackNumber: 2, discNumber: 1),
    Track(title: "B", trackNumber: 1, discNumber: 2),
    Track(title: "C", trackNumber: 1, discNumber: 1)
]
let albumOrder = [
    TrackSortField.discNumber.getComparator(ascending: true),
    TrackSortField.trackNumber.getComparator(ascending: true)
]
// Old global position preferences must fall back to titles in cross-album lists.
for field: TrackSortField in [.trackNumber, .discNumber] {
    precondition(!TrackSortContext.library.sortFields.contains(field))
    let restored = TrackSortContext.library.normalized([field.getComparator(ascending: false)])
    precondition(tracks.sorted(using: restored).map(\.title) == ["A", "B", "C"])
}
precondition(tracks.sorted(using: TrackSortContext.library.normalized(albumOrder)).map(\.title) == ["A", "B", "C"])
// Check all comparators, including a position field used only as a secondary key.
let mixedOrder = [TrackSortField.album.getComparator(ascending: true)] + albumOrder
precondition(TrackSortContext.library.normalized(mixedOrder) == [TrackSortField.title.getComparator(ascending: true)])
// Albums, folders and playlists retain multi-disc album order.
for context: TrackSortContext in [.album, .folder, .playlist] {
    precondition(context.sortFields.contains(.trackNumber) && context.sortFields.contains(.discNumber))
    precondition(tracks.sorted(using: context.normalized(albumOrder)).map(\.title) == ["C", "A", "B"])
}
// Ordinary choices and internal smart-playlist keys keep their direction and identity.
for field: TrackSortField in [.title, .artist, .album, .year, .duration, .dateAdded, .playCount, .lastPlayedDate, .custom] {
    let order = [field.getComparator(ascending: false)]
    precondition(TrackSortContext.library.normalized(order) == order)
}
print("Track sort contexts: mixed lists reject positions; album/folder/playlist ordering preserved")
SWIFT
swiftc "$test_dir/Sort.swift" -o "$test_dir/sort-test"
"$test_dir/sort-test"
