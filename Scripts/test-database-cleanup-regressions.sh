#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Reuse the app's built GRDB module; no package downloads or user database access.
derived="${PETRICHOR_DERIVED_DATA:-}"
if [[ -z "$derived" ]]; then
    for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/Petrichor-*; do
        if [[ -f "$candidate/Build/Products/Debug/GRDB.o" ]]; then
            derived="$candidate"
            break
        fi
    done
fi
products="$derived/Build/Products/Debug"
sqlite_module="$derived/SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite"
if [[ ! -f "$products/GRDB.o" || ! -d "$sqlite_module" ]]; then
    echo 'Build the Debug app first, or set PETRICHOR_DERIVED_DATA to its DerivedData directory.' >&2
    exit 1
fi
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
out=Path(sys.argv[1])
def method(path, signature):
    source=Path(path).read_text()
    start=source.index(signature); opening=source.index('{',start); end=opening+1; depth=1
    while depth:
        if source[end]=='{': depth+=1
        elif source[end]=='}': depth-=1
        end+=1
    return source[start:end].replace('private func','func',1) + '\n'
models='''import Foundation
import GRDB
struct Track: Codable, FetchableRecord, PersistableRecord {
 static let databaseTableName = "tracks"
 var trackId: Int64?; var folderId: Int64?; var albumId: Int64?
 var path: String; var duplicateKey: String; var qualityScore: Int
 var isDuplicate: Bool; var primaryTrackId: Int64?; var duplicateGroupId: String?
 var url: URL { URL(fileURLWithPath: path) }
 enum CodingKeys: String, CodingKey {
  case trackId = "id", folderId = "folder_id", albumId = "album_id", path
  case duplicateKey = "duplicate_key", qualityScore = "quality_score"
  case isDuplicate = "is_duplicate", primaryTrackId = "primary_track_id", duplicateGroupId = "duplicate_group_id"
 }
 enum Columns {
  static let trackId = Column("id"), folderId = Column("folder_id"), albumId = Column("album_id")
  static let isDuplicate = Column("is_duplicate"), primaryTrackId = Column("primary_track_id"), duplicateGroupId = Column("duplicate_group_id")
 }
 static let lightweightSelection: [any SQLSelectable] = [AllColumns()]
}
typealias FullTrack = Track
'''
for name,table,fields in [('Artist','artists',{'id':'id'}),('Album','albums',{'id':'id'}),('Genre','genres',{'id':'id'}),('Playlist','playlists',{'id':'id'}),('PinnedItem','pinned_items',{'id':'id','playlistId':'playlist_id'}),('TrackArtist','track_artists',{'trackId':'track_id','artistId':'artist_id'}),('AlbumArtist','album_artists',{'albumId':'album_id','artistId':'artist_id'}),('TrackGenre','track_genres',{'trackId':'track_id','genreId':'genre_id'})]:
    models+=f'struct {name}: Codable, FetchableRecord, PersistableRecord {{\n static let databaseTableName = "{table}"\n'
    models+=' var id: '+('String' if name=='Playlist' else 'Int64')+'\n enum Columns {\n'
    models+='\n'.join(f' static let {key} = Column("{value}")' for key,value in fields.items())+'\n }\n}\n'
models+='''enum DatabaseError: Error { case invalidTrackId }
enum Logger { static func info(_ message: String) {} }
extension String { init(appLocalized value: String) { self = value } }
actor GlobalScanState {
 func incrementTracksRemoved(by count: Int) {}
 func getProgress() -> Progress { Progress() }
 struct Progress { var processed = 0; var total = 0 }
}
@MainActor final class NotificationManager {
 static let shared = NotificationManager()
 enum Kind { case info }
 func addMessage(_ kind: Kind, _ message: String) {}
 func updateActivityProgress(current: Int, total: Int, detail: String) {}
}
final class DatabaseManager {
 let dbQueue: DatabaseQueue
 init() throws { dbQueue = try DatabaseQueue() }
 func scanProgressDetail(_ progress: GlobalScanState.Progress) -> String { "" }
 // This is intentionally UI-filtered, to expose accidental reuse by reconciliation.
 func getTracksForFolder(_ id: Int64) -> [Track] {
  try! dbQueue.read { db in try Track.filter(Track.Columns.folderId == id).filter(Track.Columns.isDuplicate == false).fetchAll(db) }
 }
'''
models+=method('Managers/Database/DMTrackMetadataEditing.swift','func refreshDuplicateGroups(')
models+=method('Managers/Database/DMFolders.swift','private func removeDeletedTracks(')
models+=method('Managers/Database/DMPlaylists.swift','func deletePlaylist(')
models+='\n}\n'
(out/'Support.swift').write_text(models)
PY
cat > "$test_dir/Main.swift" <<'SWIFT'
import Foundation
import GRDB
func expect(_ condition: @autoclosure () throws -> Bool) rethrows {
 let result = try condition()
 precondition(result)
}
@main struct Main {
 static func main() async throws {
  let manager = try DatabaseManager()
  try await manager.dbQueue.write { db in
   try db.execute(sql: """
    CREATE TABLE artists(id INTEGER PRIMARY KEY);
    CREATE TABLE albums(id INTEGER PRIMARY KEY);
    CREATE TABLE genres(id INTEGER PRIMARY KEY);
    CREATE TABLE playlists(id TEXT PRIMARY KEY);
    CREATE TABLE tracks(id INTEGER PRIMARY KEY, folder_id INTEGER, album_id INTEGER REFERENCES albums(id),
     path TEXT, duplicate_key TEXT, quality_score INTEGER, is_duplicate BOOLEAN,
     primary_track_id INTEGER REFERENCES tracks(id) ON DELETE SET NULL, duplicate_group_id TEXT);
    CREATE TABLE track_artists(track_id INTEGER REFERENCES tracks(id) ON DELETE CASCADE, artist_id INTEGER REFERENCES artists(id) ON DELETE CASCADE);
    CREATE TABLE album_artists(album_id INTEGER REFERENCES albums(id) ON DELETE CASCADE, artist_id INTEGER REFERENCES artists(id) ON DELETE CASCADE);
    CREATE TABLE track_genres(track_id INTEGER REFERENCES tracks(id) ON DELETE CASCADE, genre_id INTEGER REFERENCES genres(id) ON DELETE CASCADE);
    CREATE TABLE playlist_tracks(track_id INTEGER REFERENCES tracks(id) ON DELETE CASCADE);
    CREATE TABLE pinned_items(id INTEGER PRIMARY KEY, artist_id INTEGER, album_id INTEGER, playlist_id TEXT);
    INSERT INTO pinned_items VALUES(1,NULL,NULL,'file-backed'),(2,999,NULL,NULL);
    INSERT INTO artists VALUES(1),(2),(3);
    INSERT INTO albums VALUES(10),(20),(30);
    INSERT INTO tracks VALUES(1,1,10,'/music/primary.flac','song',100,0,NULL,'group'),
     (2,1,20,'/music/copy.mp3','song',80,1,1,'group'),
     (3,1,20,'/music/third.mp3','song',50,1,1,'group'),
     (4,1,30,'/music/gone.mp3','gone',10,1,NULL,'gone');
    INSERT INTO track_artists VALUES(1,1),(2,2),(3,2),(4,3);
    INSERT INTO album_artists VALUES(10,1),(20,1),(30,3);
    """)
  }
  // Complete cleanup must preserve file-backed pins but still remove orphan library pins.
  try await manager.cleanupOrphanedData()
  try await manager.dbQueue.read { db in
   try expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pinned_items WHERE id=1") == 1)
   try expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pinned_items WHERE id=2") == 0)
  }
  // Simulate an otherwise successful scan with the hidden file absent on disk.
  try await manager.removeDeletedTracks(folderId: 1,
   foundPaths: Set(["primary.flac", "copy.mp3", "third.mp3"].map { URL(fileURLWithPath: "/music/" + $0) }),
   folderName: "Music", hasRemainingFiles: true)
  try await manager.dbQueue.read { db in
   try expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE id=4") == 0)
   try expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artists WHERE id=3") == 0)
  }
  // Removing the best version promotes the highest-quality survivor and keeps album-only artists.
  let primary = try await manager.dbQueue.read { try Track.fetchOne($0, key: 1)! }
  try await manager.removeTrackFromLibrary(primary)
  try await manager.dbQueue.read { db in
   let survivor = try Track.fetchOne(db, key: 2)!
   let duplicate = try Track.fetchOne(db, key: 3)!
   precondition(!survivor.isDuplicate && survivor.primaryTrackId == nil)
   precondition(duplicate.isDuplicate && duplicate.primaryTrackId == 2)
   precondition(survivor.duplicateGroupId == duplicate.duplicateGroupId)
   try expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_artists WHERE album_id=20 AND artist_id=1") == 1)
  }
  try await manager.cleanupAfterTrackRemoval([2])
  try await manager.dbQueue.read { db in
   let last = try Track.fetchOne(db, key: 3)!
   precondition(!last.isDuplicate && last.primaryTrackId == nil && last.duplicateGroupId == nil)
  }
  // A rollback must restore both the deleted row and duplicate state.
  try manager.dbQueue.inTransaction { db in
   try manager.deleteTracksAndCleanupLocked([3], in: db)
   return .rollback
  }
  try await manager.dbQueue.read { db in try expect(Track.fetchCount(db) == 1) }
  let smartID = UUID()
  try await manager.dbQueue.write { db in
   try db.execute(sql: "INSERT INTO playlists VALUES(?); INSERT INTO pinned_items VALUES(3,NULL,NULL,?);", arguments: [smartID.uuidString,smartID.uuidString])
  }
  try await manager.deletePlaylist(smartID)
  try await manager.dbQueue.read { db in
   try expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pinned_items WHERE id=3") == 0)
   try expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pinned_items WHERE id=1") == 1)
  }
  print("Database cleanup: file-backed pins, hidden missing tracks, duplicate promotion, album artists and rollback passed")
 }
}
SWIFT
swiftc -parse-as-library -I "$products" -I "$sqlite_module" \
    "$test_dir/Support.swift" Managers/Database/DMCleanup.swift "$test_dir/Main.swift" \
    "$products/GRDB.o" -lsqlite3 -o "$test_dir/regression"
"$test_dir/regression"
