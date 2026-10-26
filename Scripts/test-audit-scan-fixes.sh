#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

# Extract production methods; the fixtures only replace application dependencies.
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
def block(path, marker):
    text = Path(path).read_text()
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]
smart = 'Managers/Playlist/PMSmartPlaylists.swift'
(out / 'Smart.swift').write_text('''import Foundation
struct Track { let title: String }
struct SmartPlaylistCriteria: Equatable { var autoUpdate = true; var title: String }
struct Playlist {
 enum Kind { case smart }
 let id: UUID; var name: String; var type = Kind.smart
 var smartCriteria: SmartPlaylistCriteria?; var tracks: [Track] = []; var trackCount = 0
}
enum Logger { static func info(_ s: String) {}; static func error(_ s: String) {} }
@MainActor final class DatabaseManager {
 var pending: [Int: CheckedContinuation<[Track], Error>] = [:]
 var reads = 0
 var frozen: [Track] = []
 var savedRules: [String] = []
 var snapshotWrites: [[String]] = []
 func savePlaylistAsync(_ playlist: Playlist) async throws { savedRules.append(playlist.smartCriteria!.title) }
 func saveSmartPlaylistSnapshot(playlistId: UUID, tracks: [Track]) async throws {
  frozen = tracks; snapshotWrites.append(tracks.map(\\.title))
 }
 func getTracksForSmartPlaylist(_ playlist: Playlist) async throws -> [Track] {
  reads += 1
  let id = reads
  return try await withCheckedThrowingContinuation { pending[id] = $0 }
 }
 func loadTracksForPlaylist(_ id: UUID) -> [Track] { frozen }
 func finish(_ id: Int, _ title: String) { pending.removeValue(forKey: id)!.resume(returning: [Track(title: title)]) }
}
@MainActor final class LibraryManager { var databaseManager = DatabaseManager() }
@MainActor final class PlaylistManager {
 var playlists: [Playlist] = []
 var smartPlaylistLoads: [UUID: (criteria: SmartPlaylistCriteria?, token: UUID)] = [:]
 var smartPlaylistPersistenceTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
 var libraryManager: LibraryManager? = LibraryManager()
''' + block(smart, '    func loadSmartPlaylistTracks(') + '\n' + block(smart, '    private func isCurrentSmartPlaylist(') + '\n' + block(smart, '    private func scheduleSmartPlaylistPersistence(').replace('private ', '') + '\n' + block(smart, '    private func persistSmartPlaylist(') + '''
}
@main struct Main {
 @MainActor static func main() async {
  let manager = PlaylistManager()
  let database = manager.libraryManager!.databaseManager
  let old = Playlist(id: UUID(), name: "Test", smartCriteria: SmartPlaylistCriteria(title: "Old"))
  manager.playlists = [old]
  let first = Task { await manager.loadSmartPlaylistTracks(old) }
  while database.reads < 1 { await Task.yield() }
  await manager.loadSmartPlaylistTracks(old)
  precondition(database.reads == 1, "Duplicate loads should coalesce")
  var edited = old
  edited.smartCriteria = SmartPlaylistCriteria(title: "New")
  manager.playlists[0] = edited
  let second = Task { await manager.loadSmartPlaylistTracks(edited) }
  while database.reads < 2 { await Task.yield() }
  database.finish(2, "New result")
  await second.value
  database.finish(1, "Old result")
  await first.value
  precondition(manager.playlists[0].tracks.map(\\.title) == ["New result"])
  await manager.loadSmartPlaylistTracks(old)
  precondition(database.reads == 2, "An obsolete caller must not launch another load")

  // Even identical criteria can have newer results after a library refresh.
  let third = Task { await manager.loadSmartPlaylistTracks(edited) }
  while database.reads < 3 { await Task.yield() }
  let fourth = Task { await manager.loadSmartPlaylistTracks(edited, forceReload: true) }
  while database.reads < 4 { await Task.yield() }
  database.finish(3, "Before refresh")
  await third.value
  precondition(!manager.smartPlaylistLoads.isEmpty, "Old completion must not clear a newer load")
  database.finish(4, "After refresh")
  await fourth.value
  precondition(manager.playlists[0].tracks.map(\\.title) == ["After refresh"])

  let deleted = Task { await manager.loadSmartPlaylistTracks(edited) }
  while database.reads < 5 { await Task.yield() }
  manager.playlists = []
  database.finish(5, "Deleted")
  await deleted.value
  precondition(manager.playlists.isEmpty && manager.smartPlaylistLoads.isEmpty)

  manager.playlists = [edited]
  let failed = Task { await manager.loadSmartPlaylistTracks(edited) }
  while database.reads < 6 { await Task.yield() }
  database.pending.removeValue(forKey: 6)!.resume(throwing: CocoaError(.fileReadUnknown))
  await failed.value
  precondition(manager.smartPlaylistLoads.isEmpty)
  edited.smartCriteria!.autoUpdate = false
  manager.playlists = [edited]
  database.frozen = [Track(title: "Snapshot")]
  await manager.loadSmartPlaylistTracks(edited, forceReload: true)
  precondition(manager.playlists[0].tracks.map(\\.title) == ["Snapshot"])
  // Frozen edits also need ordered database writes, not only guarded UI updates.
  let writer = PlaylistManager(), storage = DatabaseManager()
  writer.libraryManager!.databaseManager = storage
  var frozenOld = old
  frozenOld.smartCriteria!.autoUpdate = false
  writer.playlists = [frozenOld]
  let saveOld = writer.scheduleSmartPlaylistPersistence(frozenOld, criteria: frozenOld.smartCriteria!)
  while storage.reads < 1 { await Task.yield() }
  var frozenNew = frozenOld
  frozenNew.smartCriteria!.title = "New frozen"
  writer.playlists = [frozenNew]
  let saveNew = writer.scheduleSmartPlaylistPersistence(frozenNew, criteria: frozenNew.smartCriteria!)
  storage.finish(1, "Obsolete snapshot")
  await saveOld.value
  while storage.reads < 2 { await Task.yield() }
  storage.finish(2, "New snapshot")
  await saveNew.value
  precondition(storage.snapshotWrites == [["New snapshot"]])
  precondition(writer.playlists[0].tracks.map(\\.title) == ["New snapshot"])
  precondition(writer.smartPlaylistPersistenceTasks.isEmpty)
  print("Smart playlist stale results, duplicate loads, failure, deletion and frozen snapshots passed")
 }
}
''')
now = Path('Managers/NowPlayingManager.swift').read_text()
cache = now[now.index('    private var cachedArtwork:'):now.index('    /// The remote commands')].replace('private ', '')
(out / 'Artwork.swift').write_text('''import Foundation
import AppKit
import MediaPlayer
struct Track { let url: URL; let artworkData: Data? }
@MainActor final class Cache {
''' + cache + '''
}
@main struct Main {
 @MainActor static func main() {
  func png(_ red: UInt8) -> Data {
   let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
   rep.bitmapData![0] = red; rep.bitmapData![1] = 0; rep.bitmapData![2] = 255 - red; rep.bitmapData![3] = 255
   return rep.representation(using: .png, properties: [:])!
  }
  let cache = Cache(), url = URL(fileURLWithPath: "/fixture/song.flac")
  let red = Track(url: url, artworkData: png(255)), blue = Track(url: url, artworkData: png(0))
  let first = cache.artwork(for: red)!
  precondition(cache.artwork(for: red) === first, "Unchanged artwork must reuse the cache")
  let second = cache.artwork(for: blue)!
  precondition(second !== first, "New image bytes at the same URL must replace artwork")
  precondition(cache.artwork(for: Track(url: url, artworkData: nil)) == nil)
  precondition(cache.artwork(for: blue) !== second, "Removing artwork must clear the cache")
  precondition(cache.artwork(for: Track(url: url, artworkData: Data())) == nil)
  print("Now Playing artwork replacement, removal, invalid data and cache reuse passed")
 }
}
''')
(out / 'Offline.swift').write_text('''import Foundation
final class DatabaseManager { func getDatabaseSize() -> Int64? { 42 } }
final class LibraryManager {
 let databaseManager = DatabaseManager()
 var optimizations = 0
 func performDatabaseOptimization(sizeBefore: Int64, context: String) { optimizations += 1 }
''' + block('Managers/Library/LMFolders.swift', '    func optimizeDatabase(') + '''
}
@main struct Main {
 static func main() {
  let library = LibraryManager()
  library.optimizeDatabase(notifyUser: true)
  precondition(library.optimizations == 1)
  print("Optimization is independent of filesystem availability")
 }
}
''')
# Run the real main-actor orchestration against a deliberately blocking filesystem
# stub. A main-queue callback must still execute before the move completes.
trash_path = 'Core/TrackTrashManager.swift'
(out / 'Trash.swift').write_text('''import Foundation
struct Track { let url = URL(fileURLWithPath: "/fixture/song.flac") }
struct Folder {}
enum Logger { static func error(_ message: String) {} }
@MainActor final class LibraryManager {
 var folders: [Folder] = []
 var removed = false
 func removeTrackFromLibrary(_ track: Track) async throws { removed = true }
}
@MainActor final class PlaybackManager {
 var prepared = false
 var advanced = false
 func prepareCurrentTrackForTrashMove(_ track: Track) -> Bool? { prepared = true; return true }
 func restoreCurrentTrackAfterFailedTrashMove(_ snapshot: Bool?) {}
 func handleTrackMovedToTrash(_ track: Track) { advanced = true }
}
@MainActor final class PlaylistManager { func removeTrashedTrackFromQueue(_ track: Track) {} }
@MainActor final class AppCoordinator {
 let libraryManager = LibraryManager()
 let playbackManager = PlaybackManager()
 let playlistManager = PlaylistManager()
}
enum TrackTrashManager {
 static let gate = DispatchSemaphore(value: 0)
''' + block(trash_path, '    private struct TrashMoveResult').replace('private ', '')
+ '\n' + block(trash_path, '    private struct TrashFileMoveResult').replace('private ', '')
+ '\n    @MainActor\n' + block(trash_path, '    private static func moveTrackCore(').replace('private ', '')
+ '''
 static func moveTrackFilesToTrash(audioURL: URL, folders: [Folder]) -> TrashFileMoveResult {
  precondition(!Thread.isMainThread, "Filesystem work must not run on the UI thread")
  precondition(gate.wait(timeout: .now() + 2) == .success, "Main queue was blocked by file I/O")
  return TrashFileMoveResult(audioMoved: true)
 }
}
@main struct Main {
 @MainActor static func main() async {
  let coordinator = AppCoordinator()
  DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { TrackTrashManager.gate.signal() }
  let result = await TrackTrashManager.moveTrackCore(Track(), coordinator: coordinator,
    captureSnapshot: true, advanceAfterMove: true)
  precondition(result.audioMoved && result.libraryRemoved)
  precondition(coordinator.playbackManager.prepared && coordinator.playbackManager.advanced)
  precondition(coordinator.libraryManager.removed)
  print("UI remains responsive during a blocking trash move; playback and library updates complete")
 }
}
''')
# Ensure all potentially blocking operations are in the detached phase, while
# playback release and state changes stay on the main actor.
trash = block('Core/TrackTrashManager.swift', '    private static func moveTrackCore(')
assert 'Task.detached' in trash
assert all(op not in trash for op in ['fileExists(', 'sidecarURLs(', 'moveItemToTrash(', 'libraryFolderAccessURL('])
assert trash.index('prepareCurrentTrackForTrashMove') < trash.index('moveTrackFilesToTrash') < trash.index('handleTrackMovedToTrash')
restore = block('Managers/PlaybackManager.swift', '    func restoreCurrentTrackAfterFailedTrashMove(')
assert restore.index('snapshot.suspensionGeneration == playbackRequestGeneration') < restore.index('currentTrack = snapshot.track')
PY
for name in Smart Artwork Offline Trash; do
    swiftc -parse-as-library "$test_dir/$name.swift" -o "$test_dir/$name"
    "$test_dir/$name"
done
