#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

# Exercise the actual sidebar row, tap handler and album filters without opening a library.
sed -n '/^enum Icons {/,/^}/p' Utilities/Constants.swift > "$test_dir/Icons.swift"
{
    echo 'import Foundation'
    sed -n '/^protocol SidebarItem:/,/^}/p; /^struct LibrarySidebarItem:/,/^}/p' Views/Components/Sidebar/SidebarProtocol.swift
    echo 'extension Selection {'
    sed -n '/    private func handleItemSelection(/,/^    }/p' Views/Library/LibrarySidebarView.swift | sed 's/private func/func/'
    echo '}'
} > "$test_dir/Sidebar.swift"

cat > "$test_dir/main.swift" <<'SWIFT'
import Foundation

extension String { init(appLocalized value: String) { self = value } }
enum ArtistParser {
    static func parse(_ value: String, unknownPlaceholder: String) -> [String] { [value] }
    static func normalizeArtistName(_ value: String) -> String { value }
}
struct Track: Hashable {
    let id: Int
    var albumId: Int64?
    var album: String
    var artist = ""
    var albumArtist: String?
    var year = "", genre = "", composer = ""
}
final class Selection {
    var selectedFilterItem: LibraryFilterItem?
    func selectAllSearchResults() { selectedFilterItem = .allItem(for: .albums, totalCount: 6) }
}

// The supplied order represents FTS rank. The two releases have equal counts.
let tracks = [
    Track(id: 4, albumId: 20, album: "同名专辑", artist: "乙"),
    Track(id: 3, albumId: 10, album: "同名专辑", albumArtist: "甲"),
    Track(id: 2, albumId: 20, album: "同名专辑", artist: "乙"),
    Track(id: 1, albumId: 10, album: "同名專輯", albumArtist: "甲"),
    Track(id: 5, album: "同名专辑"),
    Track(id: 6, album: "")
]
let items = LibraryFilterType.albums.getFilterItems(from: tracks)
precondition(items.count == 4)
let selection = Selection()
for (id, artist, trackIDs) in [(Int64(10), "甲", [3, 1]), (20, "乙", [4, 2])] {
    let row = LibrarySidebarItem(filterItem: items.first { $0.albumId == id }!)
    precondition(row.title == "同名专辑" && row.subtitle?.contains(artist) == true)
    selection.handleItemSelection(row)
    let selected = selection.selectedFilterItem!
    precondition(selected.albumId == id && selected.count == 2)
    precondition(tracks.filter(selected.matches).map(\.id) == trackIDs)
}
for item in items where item.albumId == nil {
    precondition(tracks.filter(item.matches).map(\.id) == [item.name == "同名专辑" ? 5 : 6])
}
selection.handleItemSelection(LibrarySidebarItem(allItemFor: .albums, count: tracks.count))
precondition(selection.selectedFilterItem?.isAllItem == true)
print("Same-title album selection and ranked track membership passed")
SWIFT
swiftc Models/Core/LibraryFilterItem.swift Models/Enums/LibraryFilterType.swift "$test_dir"/*.swift -o "$test_dir/test"
"$test_dir/test"

# The unsearched sidebar must also return only albums with visible tracks, even
# when an old album row still carries a positive cached count.
python3 - <<'PY'
from pathlib import Path
import sqlite3

source = Path("Managers/Database/DMCategoryQueries.swift").read_text()
method = source.split("func getAlbumFilterItems()", 1)[1]
query = method.split('let sql = """', 1)[1].split('"""', 1)[0]
db = sqlite3.connect(":memory:")
db.executescript("""
    CREATE TABLE albums(id INTEGER PRIMARY KEY, title TEXT, sort_title TEXT, total_tracks INTEGER);
    CREATE TABLE tracks(id INTEGER PRIMARY KEY, album_id INTEGER, album TEXT, is_duplicate INTEGER);
    CREATE TABLE artists(id INTEGER PRIMARY KEY, name TEXT);
    CREATE TABLE album_artists(album_id INTEGER, artist_id INTEGER, role TEXT, position INTEGER);
    INSERT INTO albums VALUES (1,'同名专辑','同名专辑',2),(2,'同名专辑','同名专辑',2),(3,'同名专辑','同名专辑',2);
    INSERT INTO tracks VALUES (1,1,'同名专辑',0),(2,1,'同名专辑',1),(3,2,'同名专辑',0),(4,2,'同名专辑',0),
                             (5,NULL,'Unknown Album',0);
    INSERT INTO artists VALUES (1,'甲'),(2,'乙');
    INSERT INTO album_artists VALUES (1,2,'featured',0),(1,1,'primary',0),(2,2,'primary',0);
""")
for hide_duplicates in (False, True):
    clause = "AND t.is_duplicate = 0" if hide_duplicates else ""
    rows = db.execute(query.replace(r'\(duplicateClause)', clause)).fetchall()
    assert [(name, count, album_id, artist) for name, _, count, album_id, artist in rows] == [
        ("Unknown Album", 1, None, None), ("同名专辑", 1 if hide_duplicates else 2, 1, "甲"),
        ("同名专辑", 2, 2, "乙")
    ]
print("Album sidebar membership, artists and visible counts passed")
PY
