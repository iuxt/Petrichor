#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
derived="${PETRICHOR_DERIVED_DATA:-}"
if [[ -z "$derived" ]]; then
    for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/Petrichor-*; do
        if [[ -f "$candidate/Build/Products/Debug/GRDB.o" ]]; then derived="$candidate"; break; fi
    done
fi
products="$derived/Build/Products/Debug"
sqlite_module="$derived/SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite"
if [[ ! -f "$products/GRDB.o" ]]; then echo 'Build the Debug app first.' >&2; exit 1; fi
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
out=Path(sys.argv[1])
def method(path,signature):
 s=Path(path).read_text();a=s.index(signature);b=s.index('{',a)+1;depth=1
 while depth:
  if s[b]=='{':depth+=1
  elif s[b]=='}':depth-=1
  b+=1
 return s[a:b]+'\n'
full=Path('Models/Core/FullTrack.swift').read_text().split('    // MARK: - Associations')[0]+'}\n'
full=full.replace('Identifiable, Equatable, Hashable,','Identifiable,')
(out/'FullTrack.swift').write_text(full)
folder=Path('Models/Core/Folder.swift').read_text().split('    // MARK: - Associations')[0]+'}\n'
(out/'Folder.swift').write_text(folder)
meta=Path('Core/Metadata/MetadataEngine.swift').read_text();meta=meta[meta.index('struct TrackMetadata'):meta.index('// MARK: - Metadata Reader')]
s='''import Foundation
import GRDB
enum HelperUtils {
 static func sanitizedDuration(_ n:Double)->Double {n.isFinite ? max(0,n) : 0}
 static func needsMetadataHealing(_ n:Double?)->Bool {sanitizedDuration(n ?? 0)<=0}
}
extension String {
 var nilIfEmpty:String? {isEmpty ? nil : self}
 init(appLocalized value:String) {self=value}
}
enum Logger {static func info(_ s:String){};static func error(_ s:String){}}
enum DatabaseError:Error {case invalidTrackId;case scanFailed(String)}
@MainActor final class NotificationManager {
 static let shared=NotificationManager()
 enum Level {case warning}
 func addMessage(_ level:Level,_ message:String) {}
}
class ScanLookupCache {var affectedAlbumIDs = Set<Int64>()}
struct TrackArtist:Codable,FetchableRecord,PersistableRecord {static let databaseTableName="track_artists";var track_id:Int64;enum Columns {static let trackId=Column("track_id")}}
struct TrackGenre:Codable,FetchableRecord,PersistableRecord {static let databaseTableName="track_genres";var track_id:Int64;enum Columns {static let trackId=Column("track_id")}}
'''+meta+method('Managers/Database/DMFolders.swift','actor ScanState {')+method('Managers/Database/DatabaseManager.swift','enum TrackProcessResult {')+'''
enum MetadataEngine {
 static var result:TrackMetadata!
 static var reads=0
 static func extractMetadata(from url:URL) async -> TrackMetadata {reads+=1;return result}
}
class DatabaseManager {
 let dbQueue:DatabaseQueue
 var completedScans=0
 init(_ queue:DatabaseQueue) {dbQueue=queue}
 func updateFolderMetadata(_ id:Int64,precomputedHash:String?) async throws {completedScans+=1}
 func processTrackAlbum(_ track:inout FullTrack,in db:Database,cache:ScanLookupCache?) throws {
  if track.album != "Unknown Album" {track.albumId=1}
 }
 func processTrackArtists(_ track:FullTrack,in db:Database,cache:ScanLookupCache?) throws {}
 func processTrackGenres(_ track:FullTrack,in db:Database,cache:ScanLookupCache?) throws {}
'''
s+=method('Managers/Database/DMMetadata.swift','    func applyMetadataToTrack(')
s+=method('Managers/Database/DMMetadata.swift','    func updateTrackIfNeeded(')
s+=method('Managers/Database/DMTrackProcessing.swift','    func processUpdatedTrack(')
s+=method('Managers/Database/DMTrackProcessing.swift','    private func processFile(').replace('private ', '', 1)
s+=method('Managers/Database/DMFolders.swift','    private func finalizeScan(').replace('private ', '', 1)
s+=method('Managers/Database/DMFolders.swift','    private func invalidateFolderScanHash(')
(out/'Support.swift').write_text(s+'}\n')
PY
cat > "$test_dir/Main.swift" <<'SWIFT'
import Foundation
import GRDB
@main struct Main {
 static func main() async throws {
  let queue=try DatabaseQueue()
  let db=DatabaseManager(queue)
  let url=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("scan-test.flac")
  try Data().write(to:url)
  var old=FullTrack(url:url)
  old.trackId=1;old.title="Old";old.artist="Artist";old.album="Album";old.albumId=1
  old.albumArtist="Album Artist";old.trackNumber=8;old.year="2000";old.duration=180
  old.sortTitle="Sort";old.extendedMetadata=ExtendedMetadata();old.extendedMetadata?.lyrics="Lyrics"
  old.playCount=4;old.dateAdded=Date(timeIntervalSince1970:1000)
  old.dateModified=Date(timeIntervalSince1970:500)
  var failed=old
  precondition(!db.updateTrackIfNeeded(&failed,with:TrackMetadata(url:url),at:url))
  precondition(failed.title=="Old" && failed.extendedMetadata?.lyrics=="Lyrics" && failed.dateModified==old.dateModified)
  var fresh=TrackMetadata(url:url);fresh.readSucceeded=true;fresh.duration=181
  var cleared=old
  precondition(db.updateTrackIfNeeded(&cleared,with:fresh,at:url))
  precondition(cleared.title=="scan-test" && cleared.artist=="Unknown Artist" && cleared.album=="Unknown Album")
  precondition(cleared.albumArtist==nil && cleared.trackNumber==nil && cleared.year.isEmpty && cleared.sortTitle==nil)
  precondition(cleared.extendedMetadata?.lyrics==nil && cleared.duration==181)
  precondition(cleared.playCount==4 && cleared.dateAdded==old.dateAdded)
  try await queue.write { [old] sql in
   try sql.create(table:"tracks") {t in
    for name in try! old.databaseDictionary.keys.sorted() {
     if name=="id" {t.primaryKey("id",.integer)} else {t.column(name)}
    }
   }
   try sql.execute(sql:"CREATE TABLE track_artists(track_id INTEGER);CREATE TABLE track_genres(track_id INTEGER);")
   try sql.execute(sql:"CREATE TABLE folders(id INTEGER PRIMARY KEY,name TEXT,path TEXT,track_count INTEGER,date_added DATETIME,date_updated DATETIME,bookmark_data BLOB,shasum_hash TEXT)")
   try sql.execute(sql:"INSERT INTO folders VALUES (1,'Music','/Music',1,1000,1000,NULL,'previous-hash')")
   try old.insert(sql)
  }
  // Playback and duplicate detection write after the scan captured its record.
  try await queue.write { [cleared] sql in
   try sql.execute(sql:"UPDATE tracks SET play_count=5,last_played_date=?,date_added=?,is_duplicate=1,primary_track_id=9,duplicate_group_id='latest' WHERE id=1",arguments:[Date(timeIntervalSince1970:2000),Date(timeIntervalSince1970:900)])
   try db.processUpdatedTrack(cleared,in:sql)
  }
  let saved=try await queue.read {try FullTrack.fetchOne($0,key:1)!}
  precondition(saved.playCount==5 && saved.lastPlayedDate==Date(timeIntervalSince1970:2000))
  precondition(saved.dateAdded==Date(timeIntervalSince1970:900) && saved.isDuplicate && saved.primaryTrackId==9 && saved.duplicateGroupId=="latest")
  precondition(saved.albumId==nil && saved.album=="Unknown Album" && saved.trackNumber==nil)

  // Read failure must reach scan finalization and invalidate the folder hash;
  // otherwise an ordinary refresh would hide it indefinitely.
  MetadataEngine.result=TrackMetadata(url:url)
  let existing=[url.standardizedFileURL.path:old]
  let (_,failure)=await db.processFile(url,folderId:1,existingFullTracksByPath:existing)
  guard case .failed(let error)=failure else {preconditionFailure("Read failure was silently cached")}
  let state=ScanState()
  await state.addFailedFiles([(url:url,error:error)])
  let folder=try await queue.read {try Folder.fetchOne($0,key:1)!}
  try await db.finalizeScan(folderId:1,folder:folder,precomputedHash:"current-hash",scanState:state)
  let incomplete=try await queue.read {try Folder.fetchOne($0,key:1)!}
  precondition(incomplete.shasumHash==nil && incomplete.dateUpdated==folder.dateUpdated && db.completedScans==0)
  MetadataEngine.result=fresh
  let (_,retried)=await db.processFile(url,folderId:1,existingFullTracksByPath:existing)
  guard case .update(let retryTrack,_)=retried else {preconditionFailure("Unchanged failed file was not retried")}
  precondition(MetadataEngine.reads==2 && retryTrack.dateModified != old.dateModified)
  try await db.finalizeScan(folderId:1,folder:folder,precomputedHash:"current-hash",scanState:ScanState())
  precondition(db.completedScans==1)
  MetadataEngine.result=TrackMetadata(url:url)
  let (_,newFailure)=await db.processFile(url,folderId:1)
  guard case .failed=newFailure else {preconditionFailure("Unreadable new file must not be imported")}
  print("Scan metadata: removed tags, history preservation, failed-read protection and unchanged-file retry passed")
 }
}
SWIFT
swiftc -parse-as-library -I "$products" -I "$sqlite_module" \
 "$test_dir/FullTrack.swift" "$test_dir/Folder.swift" "$test_dir/Support.swift" "$test_dir/Main.swift" \
 Core/Cue/CueSheet.swift Models/Core/ExtendedMetadata.swift Core/FilenameStem.swift \
 "$products/GRDB.o" -lsqlite3 -o "$test_dir/test"
"$test_dir/test" "$test_dir"
