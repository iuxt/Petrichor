# File-Backed Playlists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make user regular playlists live directly in each music folder's `playlists/*.m3u` files while keeping only the two Top 25 smart playlists database-driven.

**Architecture:** Add a pure Foundation M3U codec for discovery, parsing, path resolution, and rendering. Add a file-backed playlist store used by `PlaylistManager` for regular playlist discovery and mutations, while database playlist code remains for smart playlists only. Existing UI methods continue calling `PlaylistManager` so most view code only loses import/export entry points.

**Tech Stack:** Swift, SwiftUI, Foundation `FileManager`, `FileManager.trashItem`, GRDB for smart playlist and track lookup, shell script checks, `xcodebuild`.

---

## File Map

- Create `Core/M3UPlaylistCodec.swift`: pure Foundation helpers for finding M3U files, parsing entries, resolving relative paths, and rendering M3U content.
- Create `Managers/Playlist/PlaylistFileStore.swift`: file-backed regular playlist load/write/delete operations that bridge M3U files to `Playlist` and `Track`.
- Modify `Models/Core/Playlist.swift`: add transient file-backing metadata, deterministic IDs for file-backed playlists, and remove the built-in Favorites smart playlist from defaults.
- Modify `Managers/Playlist/PlaylistManager.swift`: keep smart playlist DB loading, then merge in discovered file-backed regular playlists.
- Modify `Managers/Playlist/PMRegularPlaylists.swift`: make regular playlist create/rename/delete/add/remove/reorder write M3U files instead of database rows.
- Modify `Managers/Playlist/PMTrackUpdate.swift`: remove built-in Favorites playlist membership handling while keeping favorite track toggles.
- Modify `Managers/Database/DMSetup.swift` and `Managers/Database/DatabaseMigration.swift`: seed and migrate only the two retained built-in smart playlists.
- Modify `Managers/Database/DMPlaylists.swift`: keep smart playlist DB paths; stop regular playlist DB assumptions from affecting runtime.
- Modify `Managers/Library/LMLibrary.swift` and `Managers/Library/LMFolders.swift`: reload file-backed playlists after folder load and refresh.
- Modify `Views/Main/ContentView.swift`, `PetrichorApp.swift`, `Views/Playlists/PlaylistSidebarView.swift`, and remove or orphan `Views/Playlists/Sheets/ExportPlaylistsSheet.swift`: remove import/export entry points.
- Create `Scripts/test-file-backed-playlists-codec.sh`: test M3U codec behavior without the app runtime.
- Create `Scripts/test-file-backed-playlists-integration.sh`: static/runtime checks for menu removal, default playlist seeding, and file-backed method wiring.

---

### Task 1: Add M3U Codec Tests

**Files:**
- Create: `Scripts/test-file-backed-playlists-codec.sh`
- Create after red: `Core/M3UPlaylistCodec.swift`

- [ ] **Step 1: Write the failing codec test**

Create `Scripts/test-file-backed-playlists-codec.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/test.swift" <<'SWIFT'
import Foundation

let root = URL(fileURLWithPath: "/Music")
let playlistFile = root.appendingPathComponent("playlists/Rock.m3u")

let content = """
#EXTM3U
#EXTINF:123,Artist - Title
Artist/Album/Song.flac

./Other/Track.mp3
file:///Music/Encoded%20Name.m4a
"""

let entries = M3UPlaylistCodec.parseTrackEntries(from: content)
precondition(entries == [
    "Artist/Album/Song.flac",
    "./Other/Track.mp3",
    "file:///Music/Encoded%20Name.m4a"
], "Unexpected entries: \\(entries)")

let rootRelative = M3UPlaylistCodec.pathVariations(
    for: "Artist/Album/Song.flac",
    musicFolder: root,
    playlistFileURL: playlistFile
)
precondition(rootRelative[0] == "/Music/Artist/Album/Song.flac", rootRelative.joined(separator: "|"))
precondition(rootRelative.contains("/Music/playlists/Artist/Album/Song.flac"), rootRelative.joined(separator: "|"))

let encoded = M3UPlaylistCodec.pathVariations(
    for: "file:///Music/Encoded%20Name.m4a",
    musicFolder: root,
    playlistFileURL: playlistFile
)
precondition(encoded.first == "/Music/Encoded Name.m4a", encoded.joined(separator: "|"))

let rendered = M3UPlaylistCodec.render(
    trackURLs: [
        root.appendingPathComponent("Artist/Album/Song.flac"),
        URL(fileURLWithPath: "/External/Loose.mp3")
    ],
    musicFolder: root
)
precondition(rendered.contains("Artist/Album/Song.flac"), rendered)
precondition(rendered.contains("/External/Loose.mp3"), rendered)
precondition(rendered.hasPrefix("#EXTM3U\\r\\n"), rendered)

print("M3U codec checks passed")
SWIFT

swift Core/M3UPlaylistCodec.swift "$tmpdir/test.swift"
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
chmod +x Scripts/test-file-backed-playlists-codec.sh
Scripts/test-file-backed-playlists-codec.sh
```

Expected: FAIL because `Core/M3UPlaylistCodec.swift` does not exist or `M3UPlaylistCodec` is not in scope.

- [ ] **Step 3: Commit the failing test**

```bash
git add Scripts/test-file-backed-playlists-codec.sh
git commit -m "test: add file-backed playlist codec coverage"
```

---

### Task 2: Implement Pure M3U Codec

**Files:**
- Create: `Core/M3UPlaylistCodec.swift`
- Test: `Scripts/test-file-backed-playlists-codec.sh`

- [ ] **Step 1: Implement the codec**

Create `Core/M3UPlaylistCodec.swift`:

```swift
import Foundation

enum M3UPlaylistCodec {
    static let supportedExtensions: Set<String> = ["m3u", "m3u8"]
    private static let header = "#EXTM3U"
    private static let commentPrefix = "#"
    private static let lineEnding = "\r\n"

    static func playlistDirectory(in musicFolder: URL) -> URL {
        musicFolder.appendingPathComponent("playlists", isDirectory: true)
    }

    static func playlistFiles(in musicFolder: URL, fileManager: FileManager = .default) -> [URL] {
        let directory = playlistDirectory(in: musicFolder)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func parseTrackEntries(from content: String) -> [String] {
        content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix(commentPrefix) }
    }

    static func readText(from url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }

    static func pathVariations(for entry: String, musicFolder: URL, playlistFileURL: URL) -> [String] {
        var normalized = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["file://", "smb://", "afp://", "nfs://"] where normalized.lowercased().hasPrefix(scheme) {
            normalized = String(normalized.dropFirst(scheme.count))
            break
        }
        if normalized.hasPrefix("//") {
            normalized = "/Volumes" + String(normalized.dropFirst(1))
        }
        normalized = normalized.replacingOccurrences(of: "\\", with: "/")
        normalized = normalized.removingPercentEncoding ?? normalized

        var result: [String] = []
        func appendUnique(_ path: String) {
            if !result.contains(path) {
                result.append(path)
            }
        }

        if normalized.hasPrefix("/") {
            appendUnique(URL(fileURLWithPath: normalized).standardizedFileURL.path)
            if normalized.hasPrefix("/Volumes/") {
                appendUnique(String(normalized.dropFirst(8)))
            } else if !normalized.hasPrefix("/Users/") {
                appendUnique("/Volumes" + normalized)
            }
        } else {
            var relativePath = normalized
            while relativePath.hasPrefix("./") {
                relativePath = String(relativePath.dropFirst(2))
            }
            appendUnique(musicFolder.appendingPathComponent(relativePath).standardizedFileURL.path)
            appendUnique(playlistFileURL.deletingLastPathComponent().appendingPathComponent(relativePath).standardizedFileURL.path)
            appendUnique(relativePath)
        }

        return result
    }

    static func relativeOrAbsolutePath(for trackURL: URL, musicFolder: URL) -> String {
        let root = musicFolder.standardizedFileURL.path
        let path = trackURL.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    static func render(trackURLs: [URL], musicFolder: URL) -> String {
        var lines = [header]
        for url in trackURLs {
            lines.append(relativeOrAbsolutePath(for: url, musicFolder: musicFolder))
        }
        return lines.joined(separator: lineEnding) + lineEnding
    }
}
```

- [ ] **Step 2: Run the codec test**

Run:

```bash
Scripts/test-file-backed-playlists-codec.sh
```

Expected: PASS with `M3U codec checks passed`.

- [ ] **Step 3: Commit**

```bash
git add Core/M3UPlaylistCodec.swift
git commit -m "feat: add m3u playlist codec"
```

---

### Task 3: Add File-Backing Metadata to Playlist

**Files:**
- Modify: `Models/Core/Playlist.swift`
- Modify: `Utilities/Constants.swift`
- Test: `Scripts/test-file-backed-playlists-integration.sh`

- [ ] **Step 1: Write a failing integration check**

Create `Scripts/test-file-backed-playlists-integration.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if ! rg -n "struct PlaylistFileBacking" Models/Core/Playlist.swift >/dev/null; then
    printf 'PlaylistFileBacking is missing from Playlist model.\n' >&2
    exit 1
fi

if ! rg -n "fileBacking: PlaylistFileBacking\\?" Models/Core/Playlist.swift >/dev/null; then
    printf 'Playlist.fileBacking is missing.\n' >&2
    exit 1
fi

if rg -n "DefaultPlaylists\\.favorites" Models/Core/Playlist.swift Managers/Database/DMSetup.swift >/dev/null; then
    printf 'Built-in Favorites playlist is still seeded by defaults or setup.\n' >&2
    exit 1
fi

printf 'File-backed playlist integration checks passed\n'
```

- [ ] **Step 2: Run the integration check to verify it fails**

Run:

```bash
chmod +x Scripts/test-file-backed-playlists-integration.sh
Scripts/test-file-backed-playlists-integration.sh
```

Expected: FAIL with `PlaylistFileBacking is missing from Playlist model.`

- [ ] **Step 3: Add transient file backing and remove Favorites from default playlist creation**

In `Models/Core/Playlist.swift`, add after `SmartPlaylistCriteria`:

```swift
struct PlaylistFileBacking: Hashable {
    let musicFolderURL: URL
    let fileURL: URL
}
```

Add this property to `Playlist`:

```swift
var fileBacking: PlaylistFileBacking?
```

Update the regular initializer:

```swift
init(name: String, tracks: [Track] = [], coverArtworkData: Data? = nil, fileBacking: PlaylistFileBacking? = nil) {
    self.id = UUID()
    self.name = name
    self.tracks = tracks
    self.dateCreated = Date()
    self.dateModified = Date()
    self.coverArtworkData = coverArtworkData
    self.type = .regular
    self.isUserEditable = true
    self.isContentEditable = true
    self.smartCriteria = nil
    self.fileBacking = fileBacking
}
```

Update the database restoration initializer and `init(row:)` to set `fileBacking = nil`. Update any initializer call sites that use the database restoration initializer by adding `fileBacking = nil` inside the body, not as a persisted field.

Replace `createDefaultSmartPlaylists()` with:

```swift
static func createDefaultSmartPlaylists() -> [Playlist] {
    [
        Playlist(
            name: DefaultPlaylists.mostPlayed,
            criteria: SmartPlaylistCriteria(
                rules: [
                    SmartPlaylistCriteria.Rule(
                        field: "playCount",
                        condition: .greaterThanOrEqual,
                        value: "5"
                    )
                ],
                limit: 25,
                sortBy: "playCount",
                sortAscending: false
            ),
            isUserEditable: false
        ),
        Playlist(
            name: DefaultPlaylists.recentlyPlayed,
            criteria: SmartPlaylistCriteria(
                rules: [
                    SmartPlaylistCriteria.Rule(
                        field: "lastPlayedDate",
                        condition: .greaterThan,
                        value: "7days"
                    )
                ],
                limit: 25,
                sortBy: "lastPlayedDate",
                sortAscending: false
            ),
            isUserEditable: false
        )
    ]
}
```

In `Utilities/Constants.swift`, keep `DefaultPlaylists.favorites` only if favorite button localization still needs it. Remove the `case DefaultPlaylists.favorites` branches from `displayName`, `noSongsText`, `emptyStateText`, and icon helpers so built-in smart playlist display logic only handles the two retained smart playlists.

- [ ] **Step 4: Run the integration check**

Run:

```bash
Scripts/test-file-backed-playlists-integration.sh
```

Expected: PASS with `File-backed playlist integration checks passed`.

- [ ] **Step 5: Commit**

```bash
git add Models/Core/Playlist.swift Utilities/Constants.swift Scripts/test-file-backed-playlists-integration.sh
git commit -m "feat: mark playlists as file-backed"
```

---

### Task 4: Implement Playlist File Store

**Files:**
- Create: `Managers/Playlist/PlaylistFileStore.swift`
- Modify: `Scripts/test-file-backed-playlists-integration.sh`
- Test: `Scripts/test-file-backed-playlists-codec.sh`

- [ ] **Step 1: Extend the integration check for store wiring**

Append to `Scripts/test-file-backed-playlists-integration.sh` before the final `printf`:

```bash
if ! rg -n "final class PlaylistFileStore" Managers/Playlist/PlaylistFileStore.swift >/dev/null; then
    printf 'PlaylistFileStore is missing.\n' >&2
    exit 1
fi

if ! rg -n "loadPlaylists\\(from folders: \\[Folder\\], databaseManager: DatabaseManager\\)" Managers/Playlist/PlaylistFileStore.swift >/dev/null; then
    printf 'PlaylistFileStore.loadPlaylists signature is missing.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run the integration check to verify it fails**

Run:

```bash
Scripts/test-file-backed-playlists-integration.sh
```

Expected: FAIL with `PlaylistFileStore is missing.`

- [ ] **Step 3: Add the file store**

Create `Managers/Playlist/PlaylistFileStore.swift`:

```swift
import CryptoKit
import Foundation

final class PlaylistFileStore {
    struct LoadResult {
        let playlists: [Playlist]
        let missingEntries: [URL: [String]]
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func loadPlaylists(from folders: [Folder], databaseManager: DatabaseManager) async -> LoadResult {
        var playlists: [Playlist] = []
        var missingEntries: [URL: [String]] = [:]
        var usedNames = Set<String>()

        for folder in folders {
            for fileURL in M3UPlaylistCodec.playlistFiles(in: folder.url, fileManager: fileManager) {
                do {
                    let content = try M3UPlaylistCodec.readText(from: fileURL)
                    let entries = M3UPlaylistCodec.parseTrackEntries(from: content)
                    let matched = await match(entries: entries, musicFolder: folder.url, fileURL: fileURL, databaseManager: databaseManager)
                    let baseName = fileURL.deletingPathExtension().lastPathComponent
                    let displayName = uniqueName(baseName, usedNames: &usedNames)
                    var playlist = Playlist(
                        name: displayName,
                        tracks: matched.tracks,
                        fileBacking: PlaylistFileBacking(musicFolderURL: folder.url, fileURL: fileURL)
                    )
                    playlist.trackCount = matched.tracks.count
                    playlist.dateModified = modificationDate(for: fileURL) ?? Date()
                    playlist = playlist.withStableFileBackedID(for: fileURL)
                    playlists.append(playlist)
                    if !matched.missing.isEmpty {
                        missingEntries[fileURL] = matched.missing
                    }
                } catch {
                    Logger.error("Failed to read playlist file \(fileURL.path): \(error)")
                }
            }
        }

        return LoadResult(playlists: playlists, missingEntries: missingEntries)
    }

    func createPlaylist(named name: String, tracks: [Track], in defaultFolder: Folder) throws -> Playlist {
        let directory = M3UPlaylistCodec.playlistDirectory(in: defaultFolder.url)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = uniqueFileURL(for: name, in: directory)
        try write(tracks: tracks, to: fileURL, musicFolder: defaultFolder.url)
        var playlist = Playlist(
            name: fileURL.deletingPathExtension().lastPathComponent,
            tracks: tracks,
            fileBacking: PlaylistFileBacking(musicFolderURL: defaultFolder.url, fileURL: fileURL)
        )
        playlist.trackCount = tracks.count
        return playlist.withStableFileBackedID(for: fileURL)
    }

    func rename(_ playlist: Playlist, to newName: String) throws -> Playlist {
        guard let backing = playlist.fileBacking else { throw PlaylistFileStoreError.missingBackingFile }
        let target = uniqueFileURL(for: newName, in: backing.fileURL.deletingLastPathComponent(), excluding: backing.fileURL)
        try fileManager.moveItem(at: backing.fileURL, to: target)
        var updated = playlist
        updated.name = target.deletingPathExtension().lastPathComponent
        updated.dateModified = Date()
        updated.fileBacking = PlaylistFileBacking(musicFolderURL: backing.musicFolderURL, fileURL: target)
        return updated.withStableFileBackedID(for: target)
    }

    func delete(_ playlist: Playlist) throws {
        guard let backing = playlist.fileBacking else { throw PlaylistFileStoreError.missingBackingFile }
        var resultingURL: NSURL?
        try fileManager.trashItem(at: backing.fileURL, resultingItemURL: &resultingURL)
        _ = resultingURL
    }

    func write(tracks: [Track], for playlist: Playlist) throws -> Playlist {
        guard let backing = playlist.fileBacking else { throw PlaylistFileStoreError.missingBackingFile }
        try write(tracks: tracks, to: backing.fileURL, musicFolder: backing.musicFolderURL)
        var updated = playlist
        updated.tracks = tracks
        updated.trackCount = tracks.count
        updated.dateModified = Date()
        return updated
    }

    private func write(tracks: [Track], to fileURL: URL, musicFolder: URL) throws {
        let content = M3UPlaylistCodec.render(trackURLs: tracks.map(\.url), musicFolder: musicFolder)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func match(entries: [String], musicFolder: URL, fileURL: URL, databaseManager: DatabaseManager) async -> (tracks: [Track], missing: [String]) {
        var tracks: [Track] = []
        var missing: [String] = []
        var seen = Set<Int64>()

        for entry in entries {
            var matched: Track?
            for path in M3UPlaylistCodec.pathVariations(for: entry, musicFolder: musicFolder, playlistFileURL: fileURL) {
                if let track = await databaseManager.findTrackByPath(path) {
                    matched = track
                    break
                }
            }
            if let matched, let trackId = matched.trackId, seen.insert(trackId).inserted {
                tracks.append(matched)
            } else if matched == nil {
                missing.append(entry)
            }
        }

        return (tracks, missing)
    }

    private func modificationDate(for url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private func uniqueName(_ name: String, usedNames: inout Set<String>) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : name
        var candidate = base
        var suffix = 2
        while usedNames.contains(candidate.lowercased()) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        usedNames.insert(candidate.lowercased())
        return candidate
    }

    private func uniqueFileURL(for name: String, in directory: URL, excluding currentURL: URL? = nil) -> URL {
        let base = FilesystemUtils.sanitizeFilename(name)
        var candidate = directory.appendingPathComponent(base).appendingPathExtension("m3u")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) && candidate != currentURL {
            candidate = directory.appendingPathComponent("\(base) \(suffix)").appendingPathExtension("m3u")
            suffix += 1
        }
        return candidate
    }
}

enum PlaylistFileStoreError: LocalizedError {
    case missingBackingFile
    case missingDefaultMusicFolder

    var errorDescription: String? {
        switch self {
        case .missingBackingFile:
            return String(localized: "The playlist file could not be found.")
        case .missingDefaultMusicFolder:
            return String(localized: "Add a music folder before creating playlists.")
        }
    }
}
```

Add a helper at the bottom of `Managers/Playlist/PlaylistFileStore.swift`:

```swift
extension Playlist {
    func withStableFileBackedID(for fileURL: URL) -> Playlist {
        var copy = self
        copy.id = UUID.stablePlaylistID(for: fileURL.standardizedFileURL.path)
        return copy
    }
}

extension UUID {
    fileprivate static func stablePlaylistID(for value: String) -> UUID {
        let digest = SHA256.hash(data: Data(value.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
```

Change `Playlist.id` from `let id: UUID` to `var id: UUID`.

- [ ] **Step 4: Run checks**

Run:

```bash
Scripts/test-file-backed-playlists-codec.sh
Scripts/test-file-backed-playlists-integration.sh
```

Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add Managers/Playlist/PlaylistFileStore.swift Models/Core/Playlist.swift Scripts/test-file-backed-playlists-integration.sh
git commit -m "feat: add playlist file store"
```

---

### Task 5: Load File-Backed Playlists Instead of DB Regular Playlists

**Files:**
- Modify: `Managers/Playlist/PlaylistManager.swift`
- Modify: `Managers/Library/LMLibrary.swift`
- Modify: `Managers/Library/LMFolders.swift`
- Modify: `Managers/Database/DMPlaylists.swift`
- Test: `Scripts/test-file-backed-playlists-integration.sh`

- [ ] **Step 1: Extend integration check for runtime wiring**

Append before the final `printf`:

```bash
if ! rg -n "PlaylistFileStore" Managers/Playlist/PlaylistManager.swift >/dev/null; then
    printf 'PlaylistManager does not use PlaylistFileStore.\n' >&2
    exit 1
fi

if rg -n "let savedRegularPlaylists = savedPlaylists\\.filter" Managers/Playlist/PlaylistManager.swift >/dev/null; then
    printf 'PlaylistManager still loads regular playlists from the database.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run integration check to verify it fails**

Run:

```bash
Scripts/test-file-backed-playlists-integration.sh
```

Expected: FAIL with `PlaylistManager does not use PlaylistFileStore.`

- [ ] **Step 3: Add file store to PlaylistManager**

In `Managers/Playlist/PlaylistManager.swift`, add:

```swift
internal let playlistFileStore = PlaylistFileStore()
```

Replace `loadPlaylists()` with:

```swift
func loadPlaylists() {
    guard let dbManager = libraryManager?.databaseManager else { return }

    let savedSmartPlaylists = dbManager.loadAllPlaylists()
        .filter { $0.type == .smart && $0.name != DefaultPlaylists.favorites }

    playlists = sortPlaylists(smart: savedSmartPlaylists, regular: [])
    updateSmartPlaylistCounts()
    reloadFileBackedPlaylists()
}

func reloadFileBackedPlaylists() {
    guard let libraryManager else { return }
    let folders = libraryManager.folders
    let dbManager = libraryManager.databaseManager

    Task {
        let result = await playlistFileStore.loadPlaylists(from: folders, databaseManager: dbManager)
        await MainActor.run {
            let smart = self.playlists.filter { $0.type == .smart }
            self.playlists = self.sortPlaylists(smart: smart, regular: result.playlists)
            for (fileURL, missing) in result.missingEntries where !missing.isEmpty {
                Logger.warning("Playlist \(fileURL.lastPathComponent) has \(missing.count) missing tracks")
            }
        }
    }
}
```

Update `getPlaylistTracks(_:)`:

```swift
func getPlaylistTracks(_ playlist: Playlist) -> [Track] {
    if playlist.type == .smart {
        return playlist.tracks
    }
    return playlist.tracks
}
```

Update `loadPlaylistTracks(for:)` so regular file-backed playlists do not hit `databaseManager.loadTracksForPlaylist`:

```swift
func loadPlaylistTracks(for playlistId: UUID) {
    guard let playlist = playlists.first(where: { $0.id == playlistId }) else { return }
    if playlist.type == .smart {
        Task { await loadSmartPlaylistTracks(playlist) }
    }
}
```

- [ ] **Step 4: Trigger playlist reloads when library folders reload**

In `Managers/Library/LMLibrary.swift`, after `coordinator.playlistManager.updateSmartPlaylists()` add:

```swift
coordinator.playlistManager.reloadFileBackedPlaylists()
```

In `Managers/Library/LMFolders.swift`, after successful folder refresh paths that call `loadMusicLibrary()`, do not add duplicate calls if `loadMusicLibrary()` already handles it.

- [ ] **Step 5: Run integration check**

Run:

```bash
Scripts/test-file-backed-playlists-integration.sh
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Managers/Playlist/PlaylistManager.swift Managers/Library/LMLibrary.swift Managers/Library/LMFolders.swift Scripts/test-file-backed-playlists-integration.sh
git commit -m "feat: load playlists from m3u files"
```

---

### Task 6: Route Regular Playlist Mutations to M3U Files

**Files:**
- Modify: `Managers/Playlist/PMRegularPlaylists.swift`
- Modify: `Views/Playlists/Sheets/RegularPlaylistEditorSheet.swift`
- Test: `Scripts/test-file-backed-playlists-integration.sh`

- [ ] **Step 1: Add mutation checks**

Append before final `printf`:

```bash
if rg -n "savePlaylistAsync\\(newPlaylist\\)|appendTracksToPlaylist|removeTracksFromPlaylist\\(playlistId:|setPlaylistTrackOrder" Managers/Playlist/PMRegularPlaylists.swift >/dev/null; then
    printf 'Regular playlist mutations still call database playlist-track APIs.\n' >&2
    exit 1
fi

if ! rg -n "playlistFileStore\\.write|playlistFileStore\\.createPlaylist|playlistFileStore\\.rename|playlistFileStore\\.delete" Managers/Playlist/PMRegularPlaylists.swift >/dev/null; then
    printf 'Regular playlist mutations are not wired to PlaylistFileStore.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run check to verify it fails**

Run:

```bash
Scripts/test-file-backed-playlists-integration.sh
```

Expected: FAIL with `Regular playlist mutations still call database playlist-track APIs.`

- [ ] **Step 3: Replace regular playlist creation**

Replace `createPlaylist(name:tracks:)` in `PMRegularPlaylists.swift` with:

```swift
func createPlaylist(name: String, tracks: [Track] = []) -> Playlist {
    guard let defaultFolder = libraryManager?.folders.first else {
        NotificationManager.shared.addMessage(.error, PlaylistFileStoreError.missingDefaultMusicFolder.localizedDescription)
        return Playlist(name: name, tracks: tracks)
    }

    do {
        let newPlaylist = try playlistFileStore.createPlaylist(named: name, tracks: tracks, in: defaultFolder)
        playlists.append(newPlaylist)
        playlists = sortPlaylists(
            smart: playlists.filter { $0.type == .smart },
            regular: playlists.filter { $0.type == .regular }
        )
        return newPlaylist
    } catch {
        Logger.error("Failed to create playlist file: \(error)")
        NotificationManager.shared.addMessage(.error, error.localizedDescription)
        return Playlist(name: name, tracks: tracks)
    }
}
```

- [ ] **Step 4: Replace delete and rename**

Use this delete implementation:

```swift
func deletePlaylist(_ playlist: Playlist) {
    guard playlist.isUserEditable else {
        Logger.warning("Cannot delete system playlist: \(playlist.name)")
        return
    }

    do {
        try playlistFileStore.delete(playlist)
        playlists.removeAll { $0.id == playlist.id }
        Task { await handlePlaylistDeletionForPinnedItems(playlist.id) }
    } catch {
        Logger.error("Failed to delete playlist file: \(error)")
        NotificationManager.shared.addMessage(.error, error.localizedDescription)
        reloadFileBackedPlaylists()
    }
}
```

Use this rename implementation:

```swift
func renamePlaylist(_ playlist: Playlist, newName: String) {
    guard playlist.isUserEditable else {
        Logger.warning("Cannot rename system playlist: \(playlist.name)")
        return
    }

    do {
        let updatedPlaylist = try playlistFileStore.rename(playlist, to: newName)
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index] = updatedPlaylist
        }
    } catch {
        Logger.error("Failed to rename playlist file: \(error)")
        NotificationManager.shared.addMessage(.error, error.localizedDescription)
        reloadFileBackedPlaylists()
    }
}
```

- [ ] **Step 5: Replace add/remove/reorder methods**

Add this helper:

```swift
private func persistRegularPlaylistTracks(playlistID: UUID, tracks: [Track]) async {
    guard let index = await MainActor.run(body: { playlists.firstIndex(where: { $0.id == playlistID }) }) else { return }
    let playlist = await MainActor.run { playlists[index] }
    do {
        let updated = try playlistFileStore.write(tracks: tracks, for: playlist)
        await MainActor.run {
            if let currentIndex = self.playlists.firstIndex(where: { $0.id == playlistID }) {
                self.playlists[currentIndex] = updated
            }
        }
    } catch {
        Logger.error("Failed to write playlist file: \(error)")
        await MainActor.run {
            NotificationManager.shared.addMessage(.error, error.localizedDescription)
            self.reloadFileBackedPlaylists()
        }
    }
}
```

Replace `addTracksToPlaylist` with:

```swift
func addTracksToPlaylist(tracks: [Track], playlistID: UUID) async {
    guard let playlist = await MainActor.run(body: { playlists.first(where: { $0.id == playlistID && $0.type == .regular && $0.isContentEditable }) }) else {
        Logger.warning("Cannot add tracks to this playlist")
        return
    }
    let existingIDs = Set(playlist.tracks.compactMap { $0.trackId })
    let newTracks = tracks.filter { track in track.trackId.map { !existingIDs.contains($0) } ?? false }
    guard !newTracks.isEmpty else { return }
    await persistRegularPlaylistTracks(playlistID: playlistID, tracks: playlist.tracks + newTracks)
}
```

Replace `removeTracksFromPlaylist` with:

```swift
func removeTracksFromPlaylist(tracks: [Track], playlistID: UUID) async {
    guard let playlist = await MainActor.run(body: { playlists.first(where: { $0.id == playlistID && $0.type == .regular && $0.isContentEditable }) }) else {
        Logger.warning("Cannot remove tracks from this playlist")
        return
    }
    let idsToRemove = Set(tracks.compactMap { $0.trackId })
    let remaining = playlist.tracks.filter { track in track.trackId.map { !idsToRemove.contains($0) } ?? true }
    await persistRegularPlaylistTracks(playlistID: playlistID, tracks: remaining)
}
```

Replace `applyPlaylistTrackOrder` with:

```swift
func applyPlaylistTrackOrder(playlistID: UUID, orderedTrackIds: [Int64]) async {
    guard let playlist = await MainActor.run(body: { playlists.first(where: { $0.id == playlistID && $0.type == .regular && $0.isContentEditable }) }) else {
        return
    }
    let byId = Dictionary(playlist.tracks.compactMap { track in track.trackId.map { ($0, track) } }) { first, _ in first }
    let reordered = orderedTrackIds.compactMap { byId[$0] }
    guard reordered.count == playlist.tracks.count else { return }
    await persistRegularPlaylistTracks(playlistID: playlistID, tracks: reordered)
}
```

Make `addTrackToRegularPlaylist` call `await addTracksToPlaylist(tracks: [track], playlistID: playlistID)`. Make `removeTrackFromRegularPlaylist` call `await removeTracksFromPlaylist(tracks: [track], playlistID: playlistID)`.

- [ ] **Step 6: Update the editor to load file-backed tracks from memory**

In `RegularPlaylistEditorSheet.loadExistingTracks()`, replace the database load with:

```swift
private func loadExistingTracks() {
    guard let playlistID = editingPlaylistID, !didLoad else { return }
    didLoad = true
    let tracks = playlistManager.playlists.first { $0.id == playlistID }?.tracks ?? []
    playlistTracks = tracks
    originalTrackIDs = Set(tracks.compactMap { $0.trackId })
}
```

- [ ] **Step 7: Run checks**

Run:

```bash
Scripts/test-file-backed-playlists-integration.sh
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Managers/Playlist/PMRegularPlaylists.swift Views/Playlists/Sheets/RegularPlaylistEditorSheet.swift Scripts/test-file-backed-playlists-integration.sh
git commit -m "feat: write regular playlists to m3u files"
```

---

### Task 7: Remove Import/Export UI and Built-In Favorites Playlist Runtime Hooks

**Files:**
- Modify: `PetrichorApp.swift`
- Modify: `Views/Main/ContentView.swift`
- Modify: `Views/Playlists/PlaylistSidebarView.swift`
- Modify: `Managers/Playlist/PMTrackUpdate.swift`
- Test: `Scripts/test-file-backed-playlists-integration.sh`

- [ ] **Step 1: Add UI removal checks**

Append before final `printf`:

```bash
if rg -n "Import Playlists|Export Playlists|importPlaylistsMenuItem|exportPlaylistsMenuItem|showingExportPlaylistSheet|ExportPlaylistsSheet|\\.importPlaylists|\\.exportPlaylists" PetrichorApp.swift Views Managers/Playlist >/dev/null; then
    printf 'Import/export playlist UI or notifications are still present.\n' >&2
    exit 1
fi

if rg -n "DefaultPlaylists\\.favorites" Managers/Playlist/PMTrackUpdate.swift >/dev/null; then
    printf 'Favorites smart playlist runtime hook still exists.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run check to verify it fails**

Run:

```bash
Scripts/test-file-backed-playlists-integration.sh
```

Expected: FAIL with `Import/export playlist UI or notifications are still present.`

- [ ] **Step 3: Remove macOS menu import/export commands**

In `PetrichorApp.swift`, remove the Playlists submenu that only contains `importPlaylistsMenuItem()` and `exportPlaylistsMenuItem()`. Delete the `importPlaylistsMenuItem()` and `exportPlaylistsMenuItem()` helper methods.

- [ ] **Step 4: Remove ContentView import/export state and handlers**

In `Views/Main/ContentView.swift`, remove:

```swift
@State private var showingExportPlaylistSheet = false
```

Remove the `.sheet(isPresented: $showingExportPlaylistSheet)` block for `ExportPlaylistsSheet`. Remove `.onReceive` handlers for `.importPlaylists` and `.exportPlaylists`. Delete `importPlaylists()` and `showImportNotifications(result:)`.

- [ ] **Step 5: Remove playlist sidebar options menu**

In `Views/Playlists/PlaylistSidebarView.swift`, delete the kebab `Menu` containing `Import Playlists...` and `Export Playlists...`. Keep the plus menu for new regular and smart playlists.

- [ ] **Step 6: Remove Favorites smart playlist hooks**

In `Managers/Playlist/PMTrackUpdate.swift`, remove the block that searches for the Favorites playlist after `trackFavoriteStatusChanged`. In `updateTrackInPlaylist`, replace the smart playlist branch with:

```swift
if playlist.type == .smart {
    return
}
```

Keep `updateTrackFavoriteStatus` itself so track favorite buttons continue working.

- [ ] **Step 7: Run integration check**

Run:

```bash
Scripts/test-file-backed-playlists-integration.sh
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add PetrichorApp.swift Views/Main/ContentView.swift Views/Playlists/PlaylistSidebarView.swift Managers/Playlist/PMTrackUpdate.swift Scripts/test-file-backed-playlists-integration.sh
git commit -m "feat: remove playlist import export workflow"
```

---

### Task 8: Migrate and Seed Only Retained Smart Playlists

**Files:**
- Modify: `Managers/Database/DMSetup.swift`
- Modify: `Managers/Database/DatabaseMigration.swift`
- Test: `Scripts/test-file-backed-playlists-integration.sh`

- [ ] **Step 1: Extend integration check for migration**

Append before final `printf`:

```bash
if ! rg -n "remove_builtin_favorites_playlist" Managers/Database/DatabaseMigration.swift >/dev/null; then
    printf 'Migration to remove built-in Favorites playlist is missing.\n' >&2
    exit 1
fi

if ! rg -n "DefaultPlaylists\\.recentlyPlayed" Managers/Database/DMSetup.swift >/dev/null; then
    printf 'Recently played default playlist is not pinned or seeded in setup.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run check to verify it fails**

Run:

```bash
Scripts/test-file-backed-playlists-integration.sh
```

Expected: FAIL with `Migration to remove built-in Favorites playlist is missing.`

- [ ] **Step 3: Update pinned default setup**

In `Managers/Database/DMSetup.swift`, change `seedDefaultPinnedItems(in:)` to fetch `DefaultPlaylists.mostPlayed` and `DefaultPlaylists.recentlyPlayed`, then pin those two with sort orders `0` and `1`. Remove the fetch and pin block for `DefaultPlaylists.favorites`.

- [ ] **Step 4: Add database migration**

In `Managers/Database/DatabaseMigration.swift`, after the latest registered migration, add:

```swift
migrator.registerMigration("v14_remove_builtin_favorites_playlist") { db in
    let favoriteIds = try String.fetchAll(
        db,
        sql: "SELECT id FROM playlists WHERE name = ? AND type = 'smart' AND is_user_editable = 0",
        arguments: [DefaultPlaylists.favorites]
    )

    for playlistId in favoriteIds {
        try db.execute(sql: "DELETE FROM pinned_items WHERE playlist_id = ?", arguments: [playlistId])
        try db.execute(sql: "DELETE FROM playlist_tracks WHERE playlist_id = ?", arguments: [playlistId])
        try db.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [playlistId])
    }

    Logger.info("v14_remove_builtin_favorites_playlist migration completed")
}
```

Use the next migration number if the latest migration in the file is not `v13`.

- [ ] **Step 5: Run integration check**

Run:

```bash
Scripts/test-file-backed-playlists-integration.sh
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Managers/Database/DMSetup.swift Managers/Database/DatabaseMigration.swift Scripts/test-file-backed-playlists-integration.sh
git commit -m "feat: keep only top smart playlists"
```

---

### Task 9: Build Verification and Cleanup

**Files:**
- Modify if compile errors require it: files changed in Tasks 1-8
- Test: `Scripts/test-file-backed-playlists-codec.sh`
- Test: `Scripts/test-file-backed-playlists-integration.sh`

- [ ] **Step 1: Run script checks**

Run:

```bash
Scripts/test-file-backed-playlists-codec.sh
Scripts/test-file-backed-playlists-integration.sh
```

Expected: both PASS.

- [ ] **Step 2: Build the app**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Fix compile errors with the smallest scoped edits**

If the build reports main-thread warnings around file writes, keep the `PlaylistFileStore` API synchronous and call write-heavy methods from the existing `Task` blocks in `PMRegularPlaylists.swift`. Keep all UI mutations on `MainActor`.

If the build reports `id` mutability issues, verify `Playlist.id` is `var id: UUID` and that database encode/decode still writes the UUID string.

If the build reports stale import/export references, remove the referenced sheet, state, notification, or menu method. Do not remove unrelated playlist editor or smart playlist editor code.

- [ ] **Step 4: Re-run verification after fixes**

Run:

```bash
Scripts/test-file-backed-playlists-codec.sh
Scripts/test-file-backed-playlists-integration.sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: scripts PASS and build succeeds.

- [ ] **Step 5: Inspect git diff**

Run:

```bash
git diff --stat
git diff -- Core/M3UPlaylistCodec.swift Managers/Playlist/PlaylistFileStore.swift Managers/Playlist/PMRegularPlaylists.swift Managers/Playlist/PlaylistManager.swift
```

Expected: changes are limited to file-backed playlist behavior, import/export removal, and retained smart playlist defaults.

- [ ] **Step 6: Commit final fixes**

```bash
git add Core/M3UPlaylistCodec.swift Managers/Playlist/PlaylistFileStore.swift Models/Core/Playlist.swift Managers/Playlist/PlaylistManager.swift Managers/Playlist/PMRegularPlaylists.swift Managers/Playlist/PMTrackUpdate.swift Managers/Library/LMLibrary.swift Managers/Library/LMFolders.swift Managers/Database/DMSetup.swift Managers/Database/DatabaseMigration.swift Views/Main/ContentView.swift Views/Playlists/PlaylistSidebarView.swift PetrichorApp.swift Scripts/test-file-backed-playlists-codec.sh Scripts/test-file-backed-playlists-integration.sh
git commit -m "fix: finalize file-backed playlist behavior"
```

Skip this commit if Task 9 made no changes after previous task commits.
