#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/QueueStubs.swift" <<'SWIFT'
import Foundation
struct Track { let id: UUID; let trackId: Int64?; let url: URL; var title: String; var artist = "Artist"; var album = "Album"; var duration = 180.0 }
struct Playlist { var tracks: [Track] }
class LibraryManager { var tracks: [Track] = [] }
class PlaybackManager { var currentTrack: Track?; var currentTime = 0.0; func playTrack(_ track: Track) { currentTrack = track }; func stop() {}; func seekTo(time: Double) {}; func updateNowPlayingInfo() {} }
enum RepeatMode { case off, all, one }
enum QueueSource { case library, folder, playlist }
class PlaylistManager { enum QueueSource { case library, folder, playlist }; var libraryManager: LibraryManager?; var audioPlayer: PlaybackManager?; var currentQueue: [Track] = []; var currentQueueIndex = -1; var currentPlaylist: Playlist?; var currentQueueSource: QueueSource = .library; var isShuffleEnabled = false; var repeatMode: RepeatMode = .off }
enum Logger { static func info(_ message: String) {} }

SWIFT
cat > "$test_dir/QueueMain.swift" <<'SWIFT'
import Foundation
@main struct Main {
 static func main() {
 let tracks = (0..<4).map { Track(id: UUID(), trackId: Int64($0), url: URL(fileURLWithPath: "/tmp/track-\($0)"), title: String($0)) }
 let m = PlaylistManager(); let a = PlaybackManager(); m.audioPlayer = a
 m.currentQueue = tracks; m.currentQueueIndex = 1; a.currentTrack = tracks[1]
 m.playNext(tracks[0])
 precondition(m.currentQueue.map(\.title) == ["1", "0", "2", "3"])
 precondition(m.currentQueueIndex == 0 && m.peekNextTrack()?.track.trackId == 0)
 m.playNext(tracks[1]); precondition(m.currentQueueIndex == 0 && m.currentQueue.count == 4)
 for mode: RepeatMode in [.one, .all, .off] {
 m.currentQueue = Array(tracks.prefix(2)); m.currentQueueIndex = 1; m.repeatMode = mode
 _ = m.playNextAfterRemovingCurrentTrack(tracks[1])
 precondition(m.peekNextTrack()?.index == 0)
 m.playNextTrack(); precondition(m.currentQueueIndex == 0)
 m.currentQueueIndex = -1; m.playPreviousTrack(); precondition(m.currentQueueIndex == 0)
 }
 m.repeatMode = .off; m.currentQueue = tracks; m.currentQueueIndex = 0
 m.removeTrashedTrackFromQueue(tracks[1])
 precondition(m.currentQueue.map(\.title) == ["0", "2", "3"])
 _ = m.playNextAfterRemovingCurrentTrack(tracks[0])
 precondition(a.currentTrack?.trackId == 2)
 m.currentQueue = tracks; m.currentQueueIndex = 2
 m.removeTrashedTrackFromQueue(tracks[0]); precondition(m.currentQueueIndex == 1)
 let state = PlaybackState(currentTrack: tracks[1], playbackPosition: 10, queue: tracks,
 currentQueueIndex: 1, queueSource: .library, sourceIdentifier: nil, volume: 1,
 isMuted: false, shuffleEnabled: false, repeatMode: .off)
 precondition(state.restoredQueueIndex(in: Array(tracks.dropFirst())) == 0)
 precondition(state.restoredQueueIndex(in: []) == -1)
 print("Queue and playback restoration regressions passed")
 }
}

SWIFT
cat > "$test_dir/FileStubs.swift" <<'SWIFT'
import Foundation
struct Track { var trackId: Int64?; var url: URL }
struct Folder { var url: URL }
struct PlaylistFileBacking: Hashable {
    let musicFolderURL: URL
    let fileURL: URL
    var unresolvedEntries: [String] = []
    var sourceContent: String? = nil
}


struct Playlist { var id = UUID(); var name: String; var tracks: [Track]; var fileBacking: PlaylistFileBacking? = nil; var trackCount = 0; var dateModified = Date() }
class DatabaseManager { var byPath: [String: Track] = [:]; func findTrackByPath(_ path: String) async -> Track? { byPath[path] ?? byPath.values.first { $0.url.lastPathComponent == URL(fileURLWithPath: path).lastPathComponent } } }
enum Logger { static func error(_ message: String) {}; static func warning(_ message: String) {}; static func info(_ message: String) {} }
extension String { init(appLocalized: String) { self = appLocalized } }
enum FilesystemUtils { static func sanitizeFilename(_ value: String) -> String { value } }
enum TrackTrashFallback { static let appTrashFolderName = "audit"; static func fallbackURL(for url: URL, trashDirectory: URL, fileManager: FileManager) -> URL { trashDirectory.appendingPathComponent(url.lastPathComponent) } }

SWIFT
cat > "$test_dir/FileMain.swift" <<'SWIFT'
import Foundation
@main struct Main {
 static func main() async throws {
 let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
 try FileManager.default.createDirectory(at: root.appendingPathComponent("playlists"), withIntermediateDirectories: true)
 let song = Track(trackId: 1, url: root.appendingPathComponent("known.mp3"))
 let other = Track(trackId: 2, url: root.appendingPathComponent("other.mp3"))
 let url = root.appendingPathComponent("playlists/Test.m3u")
 try "#EXTM3U\n../known.mp3\n../unresolved.mp3\n".write(to: url, atomically: true, encoding: .utf8)
 let db = DatabaseManager(); db.byPath[song.url.path] = song; db.byPath[other.url.path] = other
 let store = PlaylistFileStore()
 let loaded = await store.loadPlaylists(from: [Folder(url: root)], databaseManager: db)
 let playlist = loaded.playlists[0]
 precondition(playlist.tracks.count == 1 && playlist.fileBacking?.unresolvedEntries == ["../unresolved.mp3"])
 let renamed = try store.rename(playlist, to: "Renamed")
 precondition(renamed.id == playlist.id)
 let edited = try store.write(tracks: [song, other], for: renamed)
 let reloaded = await store.loadPlaylists(from: [Folder(url: root)], databaseManager: db)
 precondition(reloaded.playlists[0].id == playlist.id && reloaded.playlists[0].tracks.count == 2)
 let target = edited.fileBacking!.fileURL
 let entries = M3UPlaylistCodec.parseTrackEntries(from: try String(contentsOf: target, encoding: .utf8))
 precondition(entries.count == 3 && entries.contains("../unresolved.mp3"))
 let sameName = try store.rename(edited, to: "Renamed"); precondition(sameName.id == edited.id)
 let external = try String(contentsOf: target, encoding: .utf8) + "../externally-added.mp3\n"
 try external.write(to: target, atomically: true, encoding: .utf8)
 do { _ = try store.write(tracks: [], for: sameName); fatalError("Must reject stale writes") }
 catch PlaylistFileStoreError.fileChanged { }
 let unchanged = try String(contentsOf: target, encoding: .utf8); precondition(unchanged == external)
 print("M3U unresolved entries, stable rename, and stale-write regressions passed")
 }
}

SWIFT
swiftc "$test_dir/QueueStubs.swift" Managers/Playlist/PMQueue.swift Managers/Playlist/PMPlayback.swift Models/Core/PlaybackState.swift "$test_dir/QueueMain.swift" -o "$test_dir/queue-test"
"$test_dir/queue-test"
swiftc "$test_dir/FileStubs.swift" Core/M3UPlaylistCodec.swift Managers/Playlist/PlaylistFileStore.swift "$test_dir/FileMain.swift" -o "$test_dir/file-test"
"$test_dir/file-test" "$test_dir/music"
# Exercise production scan code, model equality, and relocation SQL.
python3 - "$test_dir" <<'PYTHON'
from pathlib import Path
import sys, re, sqlite3
out = Path(sys.argv[1])
source = Path('Managers/Database/DMFolders.swift').read_text()
method = source[source.index('    private func enumerateFolderContents('):source.index('    /// Remove tracks from database')].replace('private func', 'func', 1)
(out / 'Scan.swift').write_text('''import Foundation
struct FolderEnumerationResult { let musicFiles: [URL]; let modificationDates: [URL: Date]; let unsupportedFiles: [(url: URL, extension: String)] }
enum DatabaseError: Error { case scanFailed(String) }
enum AudioFormat { static func isNotSupported(_ ext: String) -> Bool { false } }
enum Logger { static func info(_ value: String) {} }
struct Scanner {
''' + method + '''}
let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("scan")
let blocked = root.appendingPathComponent("blocked")
try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
try Data().write(to: root.appendingPathComponent("visible.mp3"))
try Data().write(to: blocked.appendingPathComponent("inaccessible.mp3"))
defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
do {
    _ = try Scanner().enumerateFolderContents(from: root, supportedExtensions: ["mp3"])
    fatalError("An unreadable subtree must abort enumeration before pruning")
} catch { }
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
let complete = try Scanner().enumerateFolderContents(from: root, supportedExtensions: ["mp3"])
precondition(complete.musicFiles.count == 2)
print("Incomplete scan regression passed")
''')
track = Path('Models/Core/Track.swift').read_text()
fields = track[track.index('    let id = UUID()'):track.index('    // MARK: - Localized Display')]
equality = track[track.index('    static func =='):track.index('// MARK: - Audio Format')]
(out / 'TrackEquality.swift').write_text('import Foundation\nstruct Track: Equatable, Hashable {\n' + fields + equality + '''
let old = Track(trackId: 1, url: URL(fileURLWithPath: "/music/a.mp3"), title: "Before", artist: "Artist", album: "Album", duration: 30, format: "mp3", composer: "", genre: "", year: "")
var updated = old
updated.title = "After"
precondition(old.id == updated.id && old != updated && [old] != [updated])
precondition(old == old)
print("Metadata value equality regression passed")
''')
relocation = source[source.index('func relocateFolders('):source.index('    func addFolders(')]
statements = re.findall(r'db.execute\(sql: """(.*?)"""', relocation, re.S)
db = sqlite3.connect(':memory:')
db.executescript('CREATE TABLE tracks(id INTEGER, folder_id INTEGER, path TEXT, play_count INTEGER); CREATE TABLE pinned_items(item_type TEXT, filter_value TEXT);')
old, new = '/音乐/旧目录', '/音乐/新目录'
db.executemany('INSERT INTO tracks VALUES(?,?,?,?)', [(1, 5, old+'/a.mp3', 7),(2, 6, old+'2/b.mp3', 8),(3, 5, '/external/link.mp3', 9)])
db.executemany('INSERT INTO pinned_items VALUES(?,?)', [('folder',old),('folder',old+'/sub'),('folder',old+'2')])
prefix = old+'/'
db.execute(statements[0], (new,old,5,prefix,prefix))
db.execute(statements[1], (new,old,old,prefix,prefix))
assert db.execute('SELECT * FROM tracks ORDER BY id').fetchall() == [(1,5,new+'/a.mp3',7),(2,6,old+'2/b.mp3',8),(3,5,'/external/link.mp3',9)]
assert db.execute('SELECT filter_value FROM pinned_items').fetchall() == [(new,),(new+'/sub',),(old+'2',)]
print('Folder relocation preserves IDs, history, unrelated paths, and pins')
PYTHON
swift "$test_dir/Scan.swift" "$test_dir"
swift "$test_dir/TrackEquality.swift"
# Run the actual manager routing and ordering methods with storage spies.
python3 - "$test_dir" <<'PYTHON'
from pathlib import Path
import sys
out = Path(sys.argv[1])
def method(path, signature):
    source = Path(path).read_text()
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    return source[start:end]
routes = 'Managers/Playlist/PMRegularPlaylists.swift'
manager = 'Managers/Playlist/PlaylistManager.swift'
methods = '\n'.join(method(routes, name) for name in ['func deletePlaylist(', 'func renamePlaylist(', 'private func applyRenamedPlaylist('])
methods += '\n' + '\n'.join(method(manager, name) for name in ['func sortPlaylists(', 'func reorderPlaylists('])
methods = methods.replace('UserDefaults.standard', 'defaults')
(out / 'Routing.swift').write_text('''import Foundation
enum Kind { case regular, smart }
struct Playlist { var id = UUID(); var name: String; var type: Kind; var isUserEditable = true; var sortOrder = 0; var dateModified = Date() }
@MainActor final class DatabaseManager {
 var deleted: UUID?; var renamed: UUID?; var pinName: String?
 func deletePlaylist(_ id: UUID) async throws { deleted = id }
 func updatePlaylistMetadata(_ playlist: Playlist) async throws { renamed = playlist.id }
 func updatePinnedPlaylistName(_ playlist: Playlist) async throws { pinName = playlist.name }
}
@MainActor final class LibraryManager {
 let databaseManager = DatabaseManager()
 func loadPinnedItems() async { }
}
@MainActor final class FileStore {
 var deletions = 0; var renames = 0
 func delete(_ playlist: Playlist) throws { deletions += 1 }
 func rename(_ playlist: Playlist, to name: String) throws -> Playlist {
 renames += 1; var updated = playlist; updated.name = name; return updated
 }
}
@MainActor final class NotificationManager {
 static let shared = NotificationManager()
 enum Kind { case error }
 func addMessage(_ kind: Kind, _ message: String) { fatalError(message) }
}
enum Logger { static func error(_ value: String) { fatalError(value) }; static func warning(_ value: String) {} }
@MainActor final class PlaylistManager {
 var playlists: [Playlist] = []; var currentPlaylist: Playlist?
 var libraryManager: LibraryManager? = LibraryManager()
 let playlistFileStore = FileStore()
 let defaults: UserDefaults
 init(_ defaults: UserDefaults) { self.defaults = defaults }
 func handlePlaylistDeletionForPinnedItems(_ id: UUID) async { }
 func reloadFileBackedPlaylists() { }
 func invalidateFilePlaylistLoad() { }
''' + methods + '''
}
@main struct Main {
 @MainActor static func main() async throws {
 let suite = "petrichor-audit-" + UUID().uuidString
 let defaults = UserDefaults(suiteName: suite)!
 defer { defaults.removePersistentDomain(forName: suite) }
 let manager = PlaylistManager(defaults)
 let smart = Playlist(name: "Smart", type: .smart)
 let regular = Playlist(name: "Regular", type: .regular)
 let system = Playlist(name: "System", type: .smart, isUserEditable: false)
 manager.playlists = [system, smart, regular]
 manager.renamePlaylist(smart, newName: "Changed")
 for _ in 0..<100 where manager.libraryManager!.databaseManager.renamed == nil { try await Task.sleep(nanoseconds: 10_000_000) }
 precondition(manager.libraryManager!.databaseManager.renamed == smart.id)
 precondition(manager.playlists.first { $0.id == smart.id }?.name == "Changed")
 precondition(manager.playlistFileStore.renames == 0)
 manager.deletePlaylist(smart)
 for _ in 0..<100 where manager.playlists.contains(where: { $0.id == smart.id }) { try await Task.sleep(nanoseconds: 10_000_000) }
 precondition(manager.libraryManager!.databaseManager.deleted == smart.id && manager.playlistFileStore.deletions == 0)
 manager.currentPlaylist = regular
 manager.renamePlaylist(regular, newName: "Renamed regular")
 precondition(manager.currentPlaylist?.id == regular.id && manager.currentPlaylist?.name == "Renamed regular")
 manager.deletePlaylist(regular); precondition(manager.playlistFileStore.deletions == 1)
 manager.deletePlaylist(system); precondition(manager.playlistFileStore.deletions == 1)
 manager.reorderPlaylists([system, regular, smart])
 let relaunched = PlaylistManager(defaults)
 precondition(relaunched.sortPlaylists(smart: [smart, system], regular: [regular]).map(\\.id) == [system.id, regular.id, smart.id])
 print("Smart/regular storage routing and sidebar order regressions passed")
 }
}
''')
PYTHON
swiftc -parse-as-library "$test_dir/Routing.swift" -o "$test_dir/routing-test"
"$test_dir/routing-test"
