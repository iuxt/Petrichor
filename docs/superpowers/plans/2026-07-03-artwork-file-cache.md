# Artwork File Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move album and track artwork bytes out of SQLite into a bounded file cache, and remove artist artwork as a runtime feature.

**Architecture:** Add a focused artwork layer under `Core/Artwork/` with source resolution, cache keying, cache storage, and async loading. UI components request artwork through that layer instead of expecting image BLOBs on `Track`, `FullTrack`, `AlbumEntity`, or `ArtistEntity`. Database migrations clear existing artwork BLOBs and runtime scan/update code stops writing them.

**Tech Stack:** Swift, SwiftUI, AppKit `NSImage`, Foundation `FileManager`, CryptoKit hashing, GRDB migrations, existing metadata readers, shell-script verification.

---

## File Structure

- Create `Core/Artwork/ArtworkRequest.swift`: value types for track, album, and playlist-derived artwork requests.
- Create `Core/Artwork/ArtworkFileCache.swift`: bounded cache directory, cache hit/write/touch/trim/clear behavior.
- Create `Core/Artwork/ArtworkResolver.swift`: source priority and async artwork resolution through the cache.
- Create `Views/Components/Artwork/AsyncArtworkImage.swift`: reusable SwiftUI image loader for track/album artwork.
- Modify `Core/Metadata/MetadataEngine.swift`: add an embedded-artwork-only helper used by the resolver.
- Modify `Core/Metadata/CrescendoMetadataReader.swift` and `Core/Metadata/SFBMetadataReader.swift`: expose embedded artwork extraction without mixing in external artwork.
- Modify `Managers/Database/DMSetup.swift`: keep legacy artwork columns for migration compatibility, but document them as unused and stop new code from depending on them.
- Modify `Managers/Database/DatabaseMigration.swift`: add `v16_clear_artwork_blobs`.
- Modify `Managers/Database/DMMetadata.swift`, `DMTrackProcessing.swift`, `DMNormalization.swift`, `DMBackgroundMigration.swift`, and `DMMerge.swift`: remove artwork writes/optimization/carry-over.
- Modify `Managers/Database/DMQueries.swift`, `DMCategoryQueries.swift`, `DMSearchQueries.swift`, `DMSmartPlaylistQueries.swift`, `DMPlaylists.swift`, and `DMPinnedItems.swift`: stop populating artwork BLOBs into tracks and entities.
- Modify `Models/Core/Track.swift`, `FullTrack.swift`, `Artist.swift`, `Album.swift`, `Entity.swift`, and `Playlist.swift`: remove or deprecate runtime artwork fields that read DB BLOBs; artist entities no longer expose artwork.
- Modify UI callers in `Views/Components/TrackViews/TrackTableView.swift`, `Views/Components/EntityGridView.swift`, `Views/Home/EntityDetailView.swift`, `Views/Main/PlayerView.swift`, `Views/Main/TrackDetailView.swift`, `Views/Components/NowPlaying/NowPlayingArtwork.swift`, `Views/MiniPlayer/MiniPlayerView.swift`, `Views/Immersive/ImmersiveView.swift`, and playlist views to use async artwork components.
- Modify `Managers/NowPlayingManager.swift` and `Managers/PlaybackManager.swift`: load artwork through resolver/cache for media-center and playback UI state.
- Modify `Managers/Library/LMLibrary.swift`: remove `updateArtistEntityArtwork`.
- Create `Managers/Library/LMArtworkCache.swift`: library-manager facade for clear, trim, and size operations.
- Modify `Views/Settings/LibraryTabView.swift`: add clear/trim artwork cache actions.
- Add scripts under `Scripts/` for static and behavioral verification.

## Task 1: Add Artwork Cache Core

**Files:**
- Create: `Core/Artwork/ArtworkRequest.swift`
- Create: `Core/Artwork/ArtworkFileCache.swift`
- Test: `Scripts/test-artwork-cache.sh`

- [ ] **Step 1: Write the failing cache behavior script**

Create `Scripts/test-artwork-cache.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if ! rg -n 'struct ArtworkCacheKey|enum ArtworkKind|struct ArtworkRequest' Core/Artwork/ArtworkRequest.swift >/dev/null; then
    printf 'Artwork request/key types are missing.\n' >&2
    exit 1
fi

if ! rg -n 'final class ArtworkFileCache|func data\\(for key: ArtworkCacheKey\\)|func store\\(_ data: Data, for key: ArtworkCacheKey\\)|func trimToLimit\\(\\)|func clear\\(\\)' Core/Artwork/ArtworkFileCache.swift >/dev/null; then
    printf 'ArtworkFileCache API is incomplete.\n' >&2
    exit 1
fi

if ! rg -n 'maxBytes: Int64 = 512 \\* 1024 \\* 1024' Core/Artwork/ArtworkFileCache.swift >/dev/null; then
    printf 'Artwork cache must default to 512 MB.\n' >&2
    exit 1
fi

if ! rg -n 'targetBytes = maxBytes \\* 9 / 10|sorted\\(by: \\{.*lastAccess' Core/Artwork/ArtworkFileCache.swift >/dev/null; then
    printf 'Artwork cache trim must delete least-recently-used files down to 90%% of limit.\n' >&2
    exit 1
fi

swift - <<'SWIFT'
import CryptoKit
import Foundation

enum ArtworkKind: String { case track, album, playlistDerived = "playlist-derived" }

struct ArtworkCacheKey: Hashable {
    let kind: ArtworkKind
    let identity: String
    let sourcePath: String
    let sourceSize: Int64
    let sourceModifiedAt: TimeInterval
    let version: Int

    var filename: String {
        let raw = [
            kind.rawValue,
            identity,
            sourcePath,
            String(sourceSize),
            String(sourceModifiedAt),
            String(version)
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".heic"
    }
}

let a = ArtworkCacheKey(kind: .track, identity: "/a/song.flac", sourcePath: "/a/song.flac", sourceSize: 10, sourceModifiedAt: 1, version: 1)
let b = ArtworkCacheKey(kind: .track, identity: "/a/song.flac", sourcePath: "/a/song.flac", sourceSize: 11, sourceModifiedAt: 1, version: 1)
if a.filename == b.filename {
    fatalError("cache key must change when source size changes")
}
if !a.filename.hasSuffix(".heic") {
    fatalError("cache key filename must use compressed artwork extension")
}
SWIFT
```

- [ ] **Step 2: Run the script and verify it fails**

Run: `bash Scripts/test-artwork-cache.sh`

Expected: FAIL with `Artwork request/key types are missing.`

- [ ] **Step 3: Implement artwork request and cache types**

Create `Core/Artwork/ArtworkRequest.swift` with:

```swift
import CryptoKit
import Foundation

enum ArtworkKind: String, Sendable {
    case track
    case album
    case playlistDerived = "playlist-derived"
}

struct ArtworkSourceIdentity: Hashable, Sendable {
    let path: String
    let size: Int64
    let modifiedAt: TimeInterval
}

struct ArtworkCacheKey: Hashable, Sendable {
    static let currentVersion = 1

    let kind: ArtworkKind
    let identity: String
    let source: ArtworkSourceIdentity
    let version: Int

    var filename: String {
        let raw = [
            kind.rawValue,
            identity,
            source.path,
            String(source.size),
            String(source.modifiedAt),
            String(version)
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".heic"
    }
}

struct ArtworkRequest: Hashable, Sendable {
    let kind: ArtworkKind
    let identity: String
    let audioURL: URL

    static func track(_ url: URL) -> ArtworkRequest {
        ArtworkRequest(kind: .track, identity: url.standardizedFileURL.path, audioURL: url)
    }

    static func album(albumId: Int64?, representativeTrackURL: URL) -> ArtworkRequest {
        let albumIdentity = albumId.map { "album:\($0)" } ?? "album:\(representativeTrackURL.standardizedFileURL.path)"
        return ArtworkRequest(kind: .album, identity: albumIdentity, audioURL: representativeTrackURL)
    }
}
```

Create `Core/Artwork/ArtworkFileCache.swift` with:

```swift
import Foundation

final class ArtworkFileCache {
    static let shared = ArtworkFileCache()

    private let fileManager: FileManager
    private let rootURL: URL
    private let imagesURL: URL
    private let maxBytes: Int64
    private let queue = DispatchQueue(label: "org.petrichor.artwork-file-cache", qos: .utility)

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        maxBytes: Int64 = 512 * 1024 * 1024
    ) {
        self.fileManager = fileManager
        self.maxBytes = maxBytes

        let baseURL: URL
        if let rootURL {
            baseURL = rootURL
        } else {
            let appSupport = (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? fileManager.temporaryDirectory
            let bundleID = Bundle.main.bundleIdentifier ?? About.bundleIdentifier
            baseURL = appSupport.appendingPathComponent(bundleID, isDirectory: true)
        }

        self.rootURL = baseURL.appendingPathComponent("ArtworkCache", isDirectory: true)
        self.imagesURL = self.rootURL.appendingPathComponent("images", isDirectory: true)
    }

    func data(for key: ArtworkCacheKey) -> Data? {
        queue.sync {
            let url = fileURL(for: key)
            guard let data = try? Data(contentsOf: url) else { return nil }
            touch(url)
            return data
        }
    }

    func store(_ data: Data, for key: ArtworkCacheKey) {
        queue.async {
            do {
                try self.ensureDirectories()
                try data.write(to: self.fileURL(for: key), options: .atomic)
                self.trimToLimit()
            } catch {
                Logger.error("Failed to write artwork cache file: \(error)")
            }
        }
    }

    func trimToLimit() {
        queue.async {
            self.trimToLimitLocked()
        }
    }

    func clear() {
        queue.async {
            do {
                if self.fileManager.fileExists(atPath: self.rootURL.path) {
                    try self.fileManager.removeItem(at: self.rootURL)
                }
            } catch {
                Logger.error("Failed to clear artwork cache: \(error)")
            }
        }
    }

    func cacheSize() -> Int64 {
        queue.sync {
            self.cacheFiles().reduce(Int64(0)) { $0 + $1.size }
        }
    }

    private func fileURL(for key: ArtworkCacheKey) -> URL {
        imagesURL.appendingPathComponent(key.filename, isDirectory: false)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: imagesURL, withIntermediateDirectories: true)
    }

    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func trimToLimitLocked() {
        let files = cacheFiles()
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxBytes else { return }

        let targetBytes = maxBytes * 9 / 10
        var remaining = total
        for file in files.sorted(by: { $0.lastAccess < $1.lastAccess }) {
            guard remaining > targetBytes else { break }
            do {
                try fileManager.removeItem(at: file.url)
                remaining -= file.size
            } catch {
                Logger.error("Failed to remove artwork cache file \(file.url.lastPathComponent): \(error)")
            }
        }
    }

    private struct CacheFile {
        let url: URL
        let size: Int64
        let lastAccess: Date
    }

    private func cacheFiles() -> [CacheFile] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: imagesURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "heic",
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return CacheFile(
                url: url,
                size: Int64(values.fileSize ?? 0),
                lastAccess: values.contentModificationDate ?? .distantPast
            )
        }
    }
}
```

- [ ] **Step 4: Add new files to the Xcode project**

Update `Petrichor.xcodeproj/project.pbxproj` so `Core/Artwork/ArtworkRequest.swift` and `Core/Artwork/ArtworkFileCache.swift` are included in the app target.

- [ ] **Step 5: Run the cache script**

Run: `bash Scripts/test-artwork-cache.sh`

Expected: PASS with no output.

- [ ] **Step 6: Build**

Run: `xcodebuild -scheme Petrichor -configuration Debug build`

Expected: build succeeds.

- [ ] **Step 7: Commit**

Run:

```bash
git add Core/Artwork/ArtworkRequest.swift Core/Artwork/ArtworkFileCache.swift Scripts/test-artwork-cache.sh Petrichor.xcodeproj/project.pbxproj
git commit -m "feat: add bounded artwork file cache"
```

## Task 2: Add Artwork Resolver and Source Priority

**Files:**
- Create: `Core/Artwork/ArtworkResolver.swift`
- Modify: `Core/Metadata/MetadataEngine.swift`
- Modify: `Core/Metadata/CrescendoMetadataReader.swift`
- Modify: `Core/Metadata/SFBMetadataReader.swift`
- Test: `Scripts/test-artwork-resolver-priority.sh`

- [ ] **Step 1: Write the failing resolver priority script**

Create `Scripts/test-artwork-resolver-priority.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if ! rg -n 'final class ArtworkResolver|static let shared = ArtworkResolver' Core/Artwork/ArtworkResolver.swift >/dev/null; then
    printf 'ArtworkResolver singleton is missing.\n' >&2
    exit 1
fi

if ! rg -n 'ExternalArtworkResolver\\.artworkURL\\(forAudioURL:candidates:\\)' Core/Artwork/ArtworkResolver.swift >/dev/null; then
    printf 'ArtworkResolver must reuse ExternalArtworkResolver priority.\n' >&2
    exit 1
fi

if ! rg -n 'MetadataEngine\\.extractEmbeddedArtwork\\(' Core/Artwork/ArtworkResolver.swift >/dev/null; then
    printf 'ArtworkResolver must fall back to embedded artwork.\n' >&2
    exit 1
fi

if ! rg -n 'func extractEmbeddedArtwork\\(from url: URL\\)' Core/Metadata/MetadataEngine.swift >/dev/null; then
    printf 'MetadataEngine embedded-artwork helper is missing.\n' >&2
    exit 1
fi

if ! rg -n 'func extractEmbeddedArtwork\\(from url: URL\\).*async -> Data\\?' Core/Metadata/MetadataEngine.swift Core/Metadata/CrescendoMetadataReader.swift Core/Metadata/SFBMetadataReader.swift >/dev/null; then
    printf 'Metadata readers must expose embedded-artwork extraction.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run the script and verify it fails**

Run: `bash Scripts/test-artwork-resolver-priority.sh`

Expected: FAIL with `ArtworkResolver singleton is missing.`

- [ ] **Step 3: Add embedded artwork reader contract**

Modify `Core/Metadata/MetadataEngine.swift`:

```swift
protocol MetadataReader {
    func extractMetadata(
        from url: URL,
        externalArtwork: Data?,
        artworkCache: ArtworkCompressionCache?
    ) async -> TrackMetadata

    func extractEmbeddedArtwork(from url: URL) async -> Data?
}

enum MetadataEngine {
    static func extractEmbeddedArtwork(from url: URL) async -> Data? {
        await reader().extractEmbeddedArtwork(from: url)
    }
}
```

Implement `extractEmbeddedArtwork(from:)` in `CrescendoMetadataReader` by reading `source.pictures.first?.data` and passing it through `MetadataMapping.compressedArtwork(from:source:cache:)` with `cache: nil`.

Implement `extractEmbeddedArtwork(from:)` in `SFBMetadataReader` by reusing its existing attached-picture extraction path, returning compressed image data without considering external artwork.

- [ ] **Step 4: Implement resolver**

Create `Core/Artwork/ArtworkResolver.swift`:

```swift
import Foundation

final class ArtworkResolver {
    static let shared = ArtworkResolver()

    private let cache: ArtworkFileCache
    private let fileManager: FileManager

    init(cache: ArtworkFileCache = .shared, fileManager: FileManager = .default) {
        self.cache = cache
        self.fileManager = fileManager
    }

    func artworkData(for request: ArtworkRequest) async -> Data? {
        guard let source = sourceIdentity(for: request.audioURL) else { return nil }
        let key = ArtworkCacheKey(kind: request.kind, identity: request.identity, source: source, version: ArtworkCacheKey.currentVersion)

        if let cached = cache.data(for: key) {
            return cached
        }

        guard let data = await resolveUncachedArtwork(for: request.audioURL) else { return nil }
        cache.store(data, for: key)
        return data
    }

    func clearCache() {
        cache.clear()
    }

    func trimCache() {
        cache.trimToLimit()
    }

    func cacheSize() -> Int64 {
        cache.cacheSize()
    }

    private func resolveUncachedArtwork(for audioURL: URL) async -> Data? {
        if let externalURL = externalArtworkURL(for: audioURL),
           let externalData = try? Data(contentsOf: externalURL),
           let compressed = ImageUtils.compressImage(from: externalData, source: externalURL.lastPathComponent) {
            return compressed
        }

        return await MetadataEngine.extractEmbeddedArtwork(from: audioURL)
    }

    private func externalArtworkURL(for audioURL: URL) -> URL? {
        let directory = audioURL.deletingLastPathComponent()
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return ExternalArtworkResolver.artworkURL(forAudioURL: audioURL, candidates: candidates)
    }

    private func sourceIdentity(for audioURL: URL) -> ArtworkSourceIdentity? {
        let sourceURL = externalArtworkURL(for: audioURL) ?? audioURL
        guard let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        return ArtworkSourceIdentity(
            path: sourceURL.standardizedFileURL.path,
            size: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
    }
}
```

- [ ] **Step 5: Add resolver file to Xcode project**

Update `Petrichor.xcodeproj/project.pbxproj` so `Core/Artwork/ArtworkResolver.swift` is included in the app target.

- [ ] **Step 6: Run resolver script**

Run: `bash Scripts/test-artwork-resolver-priority.sh`

Expected: PASS with no output.

- [ ] **Step 7: Build**

Run: `xcodebuild -scheme Petrichor -configuration Debug build`

Expected: build succeeds.

- [ ] **Step 8: Commit**

Run:

```bash
git add Core/Artwork/ArtworkResolver.swift Core/Metadata/MetadataEngine.swift Core/Metadata/CrescendoMetadataReader.swift Core/Metadata/SFBMetadataReader.swift Scripts/test-artwork-resolver-priority.sh Petrichor.xcodeproj/project.pbxproj
git commit -m "feat: resolve artwork from files"
```

## Task 3: Stop Writing Artwork BLOBs During Scans

**Files:**
- Modify: `Managers/Database/DMMetadata.swift`
- Modify: `Managers/Database/DMTrackProcessing.swift`
- Modify: `Managers/Database/DMNormalization.swift`
- Test: `Scripts/test-no-artwork-db-writes.sh`

- [ ] **Step 1: Write the failing DB-write removal script**

Create `Scripts/test-no-artwork-db-writes.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if rg -n 'track\\.trackArtworkData\\s*=\\s*metadata\\.artworkData|trackArtworkData\\]\\s*=\\s*trackArtworkData|updateArtistArtwork\\(|updateAlbumArtwork\\(' Managers/Database/DMMetadata.swift Managers/Database/DMTrackProcessing.swift Managers/Database/DMNormalization.swift >/dev/null; then
    printf 'Scan/update code still writes artwork into database-backed fields.\n' >&2
    rg -n 'track\\.trackArtworkData\\s*=\\s*metadata\\.artworkData|trackArtworkData\\]\\s*=\\s*trackArtworkData|updateArtistArtwork\\(|updateAlbumArtwork\\(' Managers/Database/DMMetadata.swift Managers/Database/DMTrackProcessing.swift Managers/Database/DMNormalization.swift >&2
    exit 1
fi

if rg -n 'Artist\\.Columns\\.artworkData\\.set|Album\\.Columns\\.artworkData\\.set|FullTrack\\.Columns\\.trackArtworkData\\.set' Managers/Database >/dev/null; then
    printf 'Database code still updates artwork blob columns.\n' >&2
    rg -n 'Artist\\.Columns\\.artworkData\\.set|Album\\.Columns\\.artworkData\\.set|FullTrack\\.Columns\\.trackArtworkData\\.set' Managers/Database >&2
    exit 1
fi
```

- [ ] **Step 2: Run the script and verify it fails**

Run: `bash Scripts/test-no-artwork-db-writes.sh`

Expected: FAIL with matches in `DMMetadata.swift`, `DMTrackProcessing.swift`, or `DMNormalization.swift`.

- [ ] **Step 3: Remove track artwork assignment**

In `Managers/Database/DMMetadata.swift`, change `applyMetadataToTrack(_:from:at:)` so it never assigns `track.trackArtworkData`.

Replace the existing artwork block with:

```swift
        // Artwork is resolved from source files through ArtworkResolver and is not stored in SQLite.
        track.trackArtworkData = nil
```

In `updateCoreMetadata(_:with:)`, replace the `if let newArtworkData = metadata.artworkData { ... }` block with:

```swift
        if track.trackArtworkData != nil {
            track.trackArtworkData = nil
            hasChanges = true
        }
```

- [ ] **Step 4: Remove artist/album artwork writes after scan**

In `Managers/Database/DMTrackProcessing.swift`, delete the post-insert and post-update blocks that call `updateArtistArtwork` and `updateAlbumArtwork`.

- [ ] **Step 5: Remove artwork update APIs**

In `Managers/Database/DMNormalization.swift`, delete:

```swift
func updateArtistArtwork(_ artistId: Int64, artworkData: Data?, in db: Database) throws
func updateAlbumArtwork(_ albumId: Int64, artworkData: Data?, in db: Database) throws
```

- [ ] **Step 6: Run the script**

Run: `bash Scripts/test-no-artwork-db-writes.sh`

Expected: PASS with no output.

- [ ] **Step 7: Build**

Run: `xcodebuild -scheme Petrichor -configuration Debug build`

Expected: build succeeds.

- [ ] **Step 8: Commit**

Run:

```bash
git add Managers/Database/DMMetadata.swift Managers/Database/DMTrackProcessing.swift Managers/Database/DMNormalization.swift Scripts/test-no-artwork-db-writes.sh
git commit -m "refactor: stop storing scanned artwork in sqlite"
```

## Task 4: Remove Artist Artwork Runtime Feature

**Files:**
- Modify: `Models/Core/Artist.swift`
- Modify: `Models/Core/Entity.swift`
- Modify: `Managers/Database/DMCategoryQueries.swift`
- Modify: `Managers/Database/DMQueries.swift`
- Modify: `Managers/Database/DMMerge.swift`
- Modify: `Managers/Library/LMLibrary.swift`
- Modify: `Views/Home/HomeView.swift`
- Test: `Scripts/test-artist-artwork-removed.sh`

- [ ] **Step 1: Write the failing artist-artwork removal script**

Create `Scripts/test-artist-artwork-removed.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if rg -n 'ArtistEntity\\([^\\n]*artworkData|updateArtistEntityArtwork|Artist\\.Columns\\.artworkData|artist\\.artworkData|carryOverArtistMetadata|winner\\.artworkData' Models Managers Views -g '*.swift' >/dev/null; then
    printf 'Artist artwork runtime feature is still referenced.\n' >&2
    rg -n 'ArtistEntity\\([^\\n]*artworkData|updateArtistEntityArtwork|Artist\\.Columns\\.artworkData|artist\\.artworkData|carryOverArtistMetadata|winner\\.artworkData' Models Managers Views -g '*.swift' >&2
    exit 1
fi
```

- [ ] **Step 2: Run the script and verify it fails**

Run: `bash Scripts/test-artist-artwork-removed.sh`

Expected: FAIL with artist artwork references.

- [ ] **Step 3: Remove `Artist.artworkData` as a runtime property**

In `Models/Core/Artist.swift`:

- Delete `var artworkData: Data?`.
- Delete `static let artworkData = Column("artwork_data")`.
- Delete `artworkData = row[Columns.artworkData]`.
- Delete `container[Columns.artworkData] = artworkData`.

- [ ] **Step 4: Make artist entities placeholder-only**

In `Models/Core/Entity.swift`, update `ArtistEntity`:

```swift
struct ArtistEntity: Entity {
    let id: UUID
    let name: String
    let tracks: [Track]
    let trackCount: Int
    let artworkData: Data?

    var displayName: String { LibraryFilterType.artists.localizedDisplay(name) }

    var subtitle: String? {
        String(localized: "\(trackCount) songs")
    }

    init(name: String, tracks: [Track]) {
        self.id = UUID(name: name.lowercased(), namespace: EntityNamespaces.artist)
        self.name = name
        self.tracks = tracks
        self.trackCount = tracks.count
        self.artworkData = ImageUtils.cachedCategoryArtwork(text: name.artistInitials, seed: "artist-\(name)")
    }

    init(name: String, trackCount: Int) {
        self.id = UUID(name: name.lowercased(), namespace: EntityNamespaces.artist)
        self.name = name
        self.tracks = []
        self.trackCount = trackCount
        self.artworkData = ImageUtils.cachedCategoryArtwork(text: name.artistInitials, seed: "artist-\(name)")
    }
}
```

- [ ] **Step 5: Remove artist artwork queries and merge carry-over**

In `Managers/Database/DMCategoryQueries.swift`, stop passing `artist.artworkData` into `ArtistEntity`. Use `ArtistEntity(name: artist.name, trackCount: artist.totalTracks)`.

In `Managers/Database/DMQueries.swift`, update `getArtistEntities()` and any artist entity construction to call `ArtistEntity(name: rowName, trackCount: count)`.

In `Managers/Database/DMMerge.swift`, delete the artist artwork carry-over logic inside `carryOverArtistMetadata`.

In `Managers/Library/LMLibrary.swift`, delete `updateArtistEntityArtwork(name:artworkData:)`.

In `Views/Home/HomeView.swift`, stop constructing `ArtistEntity` with `artworkData:`.

- [ ] **Step 6: Run the script**

Run: `bash Scripts/test-artist-artwork-removed.sh`

Expected: PASS with no output.

- [ ] **Step 7: Build**

Run: `xcodebuild -scheme Petrichor -configuration Debug build`

Expected: build succeeds.

- [ ] **Step 8: Commit**

Run:

```bash
git add Models/Core/Artist.swift Models/Core/Entity.swift Managers/Database/DMCategoryQueries.swift Managers/Database/DMQueries.swift Managers/Database/DMMerge.swift Managers/Library/LMLibrary.swift Views/Home/HomeView.swift Scripts/test-artist-artwork-removed.sh
git commit -m "refactor: remove artist artwork feature"
```

## Task 5: Stop DB Artwork Reads and Add Async Artwork Image

**Files:**
- Create: `Views/Components/Artwork/AsyncArtworkImage.swift`
- Modify: `Managers/Database/DMQueries.swift`
- Modify: `Managers/Database/DMSearchQueries.swift`
- Modify: `Managers/Database/DMSmartPlaylistQueries.swift`
- Modify: `Managers/Database/DMPlaylists.swift`
- Modify: `Managers/Database/DMPinnedItems.swift`
- Modify: `Managers/Library/LMDiscover.swift`
- Test: `Scripts/test-no-artwork-db-reads.sh`

- [ ] **Step 1: Write the failing DB-read removal script**

Create `Scripts/test-no-artwork-db-reads.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if rg -n 'populateAlbumArtworkForTracks|populateAlbumArtworkForFullTrack|populateAlbumArtwork\\(|populateTrackArtwork\\(|Album\\.Columns\\.artworkData|FullTrack\\.Columns\\.trackArtworkData' Managers/Database Managers/Library Views -g '*.swift' >/dev/null; then
    printf 'Runtime code still reads artwork from SQLite blob columns.\n' >&2
    rg -n 'populateAlbumArtworkForTracks|populateAlbumArtworkForFullTrack|populateAlbumArtwork\\(|populateTrackArtwork\\(|Album\\.Columns\\.artworkData|FullTrack\\.Columns\\.trackArtworkData' Managers/Database Managers/Library Views -g '*.swift' >&2
    exit 1
fi

if ! rg -n 'struct AsyncArtworkImage|ArtworkResolver\\.shared\\.artworkData' Views/Components/Artwork/AsyncArtworkImage.swift >/dev/null; then
    printf 'AsyncArtworkImage component is missing.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run the script and verify it fails**

Run: `bash Scripts/test-no-artwork-db-reads.sh`

Expected: FAIL with `populateAlbumArtworkForTracks` and artwork column references.

- [ ] **Step 3: Create async artwork component**

Create `Views/Components/Artwork/AsyncArtworkImage.swift`:

```swift
import SwiftUI

struct AsyncArtworkImage<Placeholder: View>: View {
    let request: ArtworkRequest?
    let contentMode: ContentMode
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: NSImage?
    @State private var loadedIdentity: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: request?.identity) {
            await load()
        }
    }

    private func load() async {
        guard let request else {
            await MainActor.run {
                image = nil
                loadedIdentity = nil
            }
            return
        }

        if loadedIdentity == request.identity { return }

        let data = await ArtworkResolver.shared.artworkData(for: request)
        let resolved = data.flatMap(NSImage.init(data:))
        await MainActor.run {
            loadedIdentity = request.identity
            image = resolved
        }
    }
}
```

- [ ] **Step 4: Add component to Xcode project**

Update `Petrichor.xcodeproj/project.pbxproj` so `Views/Components/Artwork/AsyncArtworkImage.swift` is included in the app target.

- [ ] **Step 5: Remove DB artwork population helpers**

In `Managers/Database/DMQueries.swift`, delete:

```swift
func populateAlbumArtworkForTracks(_ tracks: inout [Track], db: Database) throws
func populateAlbumArtworkForTracks(_ tracks: inout [Track])
func populateAlbumArtworkForFullTrack(_ track: inout FullTrack)
private func populateAlbumArtwork(for tracks: inout [Track], db: Database) throws
private func populateTrackArtwork(for tracks: inout [Track], db: Database) throws
```

Remove all calls to these helpers from database and library query files. Returned `Track` values should be lightweight metadata only.

- [ ] **Step 6: Run the script**

Run: `bash Scripts/test-no-artwork-db-reads.sh`

Expected: PASS with no output.

- [ ] **Step 7: Build**

Run: `xcodebuild -scheme Petrichor -configuration Debug build`

Expected: build succeeds. Any build failures should identify remaining view call sites that still expect pre-populated artwork data; update those call sites in Task 6.

- [ ] **Step 8: Commit**

Run:

```bash
git add Views/Components/Artwork/AsyncArtworkImage.swift Managers/Database/DMQueries.swift Managers/Database/DMSearchQueries.swift Managers/Database/DMSmartPlaylistQueries.swift Managers/Database/DMPlaylists.swift Managers/Database/DMPinnedItems.swift Managers/Library/LMDiscover.swift Scripts/test-no-artwork-db-reads.sh Petrichor.xcodeproj/project.pbxproj
git commit -m "refactor: remove sqlite artwork read paths"
```

## Task 6: Move UI Artwork Display to Resolver

**Files:**
- Modify: `Views/Components/TrackViews/TrackTableView.swift`
- Modify: `Views/Components/TrackView.swift`
- Modify: `Views/Components/EntityGridView.swift`
- Modify: `Views/Home/EntityDetailView.swift`
- Modify: `Views/Main/PlayerView.swift`
- Modify: `Views/Main/TrackDetailView.swift`
- Modify: `Views/Components/NowPlaying/NowPlayingArtwork.swift`
- Modify: `Views/MiniPlayer/MiniPlayerView.swift`
- Modify: `Views/Immersive/ImmersiveView.swift`
- Modify: `Views/Playlists/PlaylistDetailView.swift`
- Test: `Scripts/test-ui-uses-artwork-resolver.sh`

- [ ] **Step 1: Write the failing UI resolver script**

Create `Scripts/test-ui-uses-artwork-resolver.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if rg -n 'track\\.artworkData|track\\.albumArtworkData|fullTrack\\.artworkData|entity\\.artworkData|playlist\\.artworkData' Views Managers -g '*.swift' >/dev/null; then
    printf 'UI/runtime still depends on model artworkData fields instead of resolver-backed views.\n' >&2
    rg -n 'track\\.artworkData|track\\.albumArtworkData|fullTrack\\.artworkData|entity\\.artworkData|playlist\\.artworkData' Views Managers -g '*.swift' >&2
    exit 1
fi

if ! rg -n 'AsyncArtworkImage\\(' Views -g '*.swift' >/dev/null; then
    printf 'No UI call site uses AsyncArtworkImage.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run the script and verify it fails**

Run: `bash Scripts/test-ui-uses-artwork-resolver.sh`

Expected: FAIL with current `artworkData` call sites.

- [ ] **Step 3: Replace track row artwork**

In `Views/Components/TrackViews/TrackTableView.swift` and `Views/Components/TrackView.swift`, replace `track.albumArtworkData` image rendering with:

```swift
AsyncArtworkImage(
    request: .track(track.url),
    contentMode: .fill
) {
    Image(systemName: Icons.musicNote)
        .foregroundColor(.secondary)
}
```

Constrain the frame to the existing row artwork size and keep existing clipping/corner radius styling.

- [ ] **Step 4: Replace album entity artwork**

For album entities, use `AlbumEntity.albumId` and a representative track URL. When the entity already has tracks, choose the first track sorted by disc/track number. When it only has metadata, add a database helper in `DMQueries.swift`:

```swift
func representativeTrackURL(forAlbumId albumId: Int64) -> URL? {
    try? dbQueue.read { db in
        try Track
            .filter(Track.Columns.albumId == albumId)
            .filter(Track.Columns.isDuplicate == false)
            .order(Track.Columns.discNumber.ascNullsLast, Track.Columns.trackNumber.ascNullsLast, Track.Columns.filename)
            .select(Track.Columns.path, as: String.self)
            .fetchOne(db)
            .map { URL(fileURLWithPath: $0) }
    }
}
```

Use that URL to build:

```swift
ArtworkRequest.album(albumId: album.albumId, representativeTrackURL: representativeURL)
```

- [ ] **Step 5: Replace player and now-playing artwork**

In player, mini-player, immersive, and now-playing helper views, maintain a local `@State private var currentArtworkData: Data?` loaded with:

```swift
let data = await ArtworkResolver.shared.artworkData(for: .track(track.url))
```

Use `currentArtworkData` for `NSImage`, tint, gradient, and media-center artwork. Keep the fallback behavior when data is nil.

- [ ] **Step 6: Replace track detail artwork**

In `Views/Main/TrackDetailView.swift`, remove `populateAlbumArtworkForFullTrack(&loaded)`. Load artwork through `AsyncArtworkImage(request: .track(loaded.url), contentMode: .fill)`.

- [ ] **Step 7: Update playlist artwork**

In playlist detail views, generate collage images from resolver-loaded track artwork instead of `playlist.artworkData` or `track.artworkData`. Do not persist the generated collage in SQLite.

- [ ] **Step 8: Run the script**

Run: `bash Scripts/test-ui-uses-artwork-resolver.sh`

Expected: PASS with no output.

- [ ] **Step 9: Build**

Run: `xcodebuild -scheme Petrichor -configuration Debug build`

Expected: build succeeds.

- [ ] **Step 10: Commit**

Run:

```bash
git add Views/Components/TrackViews/TrackTableView.swift Views/Components/TrackView.swift Views/Components/EntityGridView.swift Views/Home/EntityDetailView.swift Views/Main/PlayerView.swift Views/Main/TrackDetailView.swift Views/Components/NowPlaying/NowPlayingArtwork.swift Views/MiniPlayer/MiniPlayerView.swift Views/Immersive/ImmersiveView.swift Views/Playlists/PlaylistDetailView.swift Managers/Database/DMQueries.swift Scripts/test-ui-uses-artwork-resolver.sh
git commit -m "refactor: load UI artwork through resolver"
```

## Task 7: Add Migration and Database Maintenance

**Files:**
- Modify: `Managers/Database/DatabaseMigration.swift`
- Modify: `Managers/Database/DMBackgroundMigration.swift`
- Modify: `Managers/Database/DMSetup.swift`
- Modify: `Models/Core/FullTrack.swift`
- Modify: `Models/Core/Album.swift`
- Modify: `Models/Core/Playlist.swift`
- Test: `Scripts/test-artwork-blob-migration.sh`

- [ ] **Step 1: Write the failing migration script**

Create `Scripts/test-artwork-blob-migration.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if ! rg -n 'v16_clear_artwork_blobs' Managers/Database/DatabaseMigration.swift >/dev/null; then
    printf 'v16 artwork blob cleanup migration is missing.\n' >&2
    exit 1
fi

for sql in \
    'UPDATE albums SET artwork_data = NULL' \
    'UPDATE artists SET artwork_data = NULL' \
    'UPDATE tracks SET track_artwork_data = NULL' \
    'UPDATE playlists SET cover_artwork_data = NULL'
do
    if ! rg -n "$sql" Managers/Database/DatabaseMigration.swift >/dev/null; then
        printf 'Migration missing SQL: %s\n' "$sql" >&2
        exit 1
    fi
done

if rg -n 'v8_background_convert_artwork_to_heic|artworkTableOps|convertArtworkToHEIC' Managers/Database/DMBackgroundMigration.swift >/dev/null; then
    printf 'Background artwork conversion should be removed after artwork blobs are cleared.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run the script and verify it fails**

Run: `bash Scripts/test-artwork-blob-migration.sh`

Expected: FAIL with `v16 artwork blob cleanup migration is missing.`

- [ ] **Step 3: Add v16 migration**

In `Managers/Database/DatabaseMigration.swift`, after `v15_remove_track_favorites`, add:

```swift
        migrator.registerMigration("v16_clear_artwork_blobs") { db in
            try db.execute(sql: "UPDATE albums SET artwork_data = NULL")
            try db.execute(sql: "UPDATE artists SET artwork_data = NULL")
            try db.execute(sql: "UPDATE tracks SET track_artwork_data = NULL")
            try db.execute(sql: "UPDATE playlists SET cover_artwork_data = NULL")
            Logger.info("v16_clear_artwork_blobs migration completed")
        }
```

- [ ] **Step 4: Remove background artwork optimization**

In `Managers/Database/DMBackgroundMigration.swift`, remove:

- `case "v8_background_convert_artwork_to_heic"`
- `ArtworkConversionProgress`
- `ArtworkTableOps`
- `artworkMigrationIdentifier`
- `artworkTableOps`
- `convertArtworkToHEIC(progress:)`

Leave other background migrations intact.

- [ ] **Step 5: Keep legacy columns but stop model persistence**

In `FullTrack.encode(to:)`, set `container[Columns.trackArtworkData] = nil` or remove the assignment if GRDB inserts tolerate omitted legacy columns.

In `Album.encode(to:)`, ensure `Columns.artworkData` is not encoded.

In `Playlist.encode(to:)`, ensure generated cover artwork is not encoded into `cover_artwork_data`.

- [ ] **Step 6: Run migration script**

Run: `bash Scripts/test-artwork-blob-migration.sh`

Expected: PASS with no output.

- [ ] **Step 7: Build**

Run: `xcodebuild -scheme Petrichor -configuration Debug build`

Expected: build succeeds.

- [ ] **Step 8: Commit**

Run:

```bash
git add Managers/Database/DatabaseMigration.swift Managers/Database/DMBackgroundMigration.swift Managers/Database/DMSetup.swift Models/Core/FullTrack.swift Models/Core/Album.swift Models/Core/Playlist.swift Scripts/test-artwork-blob-migration.sh
git commit -m "chore: clear legacy artwork blobs"
```

## Task 8: Add Cache Maintenance Controls

**Files:**
- Create: `Managers/Library/LMArtworkCache.swift`
- Modify: `Views/Settings/LibraryTabView.swift`
- Test: `Scripts/test-artwork-cache-maintenance.sh`

- [ ] **Step 1: Write the failing maintenance script**

Create `Scripts/test-artwork-cache-maintenance.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

if ! rg -n 'clearArtworkCache\\(|trimArtworkCache\\(|artworkCacheSize\\(' Managers/Library Views/Settings -g '*.swift' >/dev/null; then
    printf 'Library/settings artwork cache maintenance API is missing.\n' >&2
    exit 1
fi

if ! rg -n 'Clear Artwork Cache|Trim Artwork Cache|Artwork cache' Views/Settings/LibraryTabView.swift >/dev/null; then
    printf 'Library settings must expose artwork cache maintenance controls.\n' >&2
    exit 1
fi

if ! rg -n 'ArtworkResolver\\.shared\\.clearCache\\(|ArtworkResolver\\.shared\\.trimCache\\(' Managers/Library Views/Settings -g '*.swift' >/dev/null; then
    printf 'Maintenance controls must call ArtworkResolver cache methods.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run the script and verify it fails**

Run: `bash Scripts/test-artwork-cache-maintenance.sh`

Expected: FAIL with `Library/settings artwork cache maintenance API is missing.`

- [ ] **Step 3: Add library manager cache methods**

Create `Managers/Library/LMArtworkCache.swift`:

```swift
import Foundation

extension LibraryManager {
    func clearArtworkCache() {
        ArtworkResolver.shared.clearCache()
        NotificationManager.shared.addMessage(.info, String(localized: "Artwork cache cleared"))
    }

    func trimArtworkCache() {
        ArtworkResolver.shared.trimCache()
        NotificationManager.shared.addMessage(.info, String(localized: "Artwork cache optimized"))
    }

    func artworkCacheSize() -> Int64 {
        ArtworkResolver.shared.cacheSize()
    }
}
```

Add `Managers/Library/LMArtworkCache.swift` to `Petrichor.xcodeproj/project.pbxproj`.

- [ ] **Step 4: Add settings rows**

In `Views/Settings/LibraryTabView.swift`, add an `Artwork Cache` section below watched folders:

```swift
Section("Artwork Cache") {
    HStack {
        Text("Artwork cache")
        Spacer()
        Button {
            libraryManager.trimArtworkCache()
        } label: {
            Label("Trim Artwork Cache", systemImage: "sparkles")
        }
        Button(role: .destructive) {
            libraryManager.clearArtworkCache()
        } label: {
            Label("Clear Artwork Cache", systemImage: "trash")
        }
    }
}
```

Keep the buttons disabled while library updates are in progress if the existing settings style requires it.

- [ ] **Step 5: Run maintenance script**

Run: `bash Scripts/test-artwork-cache-maintenance.sh`

Expected: PASS with no output.

- [ ] **Step 6: Build**

Run: `xcodebuild -scheme Petrichor -configuration Debug build`

Expected: build succeeds.

- [ ] **Step 7: Commit**

Run:

```bash
git add Managers/Library/LMArtworkCache.swift Views/Settings/LibraryTabView.swift Scripts/test-artwork-cache-maintenance.sh Petrichor.xcodeproj/project.pbxproj
git commit -m "feat: add artwork cache maintenance"
```

## Task 9: Final Verification

**Files:**
- Modify only files required by failures found in verification.

- [ ] **Step 1: Run all artwork scripts**

Run:

```bash
bash Scripts/test-artwork-cache.sh
bash Scripts/test-artwork-resolver-priority.sh
bash Scripts/test-no-artwork-db-writes.sh
bash Scripts/test-artist-artwork-removed.sh
bash Scripts/test-no-artwork-db-reads.sh
bash Scripts/test-ui-uses-artwork-resolver.sh
bash Scripts/test-artwork-blob-migration.sh
bash Scripts/test-artwork-cache-maintenance.sh
```

Expected: all scripts exit 0.

- [ ] **Step 2: Run existing related scripts**

Run:

```bash
bash Scripts/test-external-artwork-priority.sh
bash Scripts/test-file-backed-playlists-integration.sh
bash Scripts/test-artist-info-download-removed.sh
```

Expected: all scripts exit 0.

- [ ] **Step 3: Build app**

Run: `xcodebuild -scheme Petrichor -configuration Debug build`

Expected: build succeeds.

- [ ] **Step 4: Manual smoke test**

Run the app and verify:

- Album grid displays album artwork from sidecar image or embedded artwork.
- Track table displays artwork without DB BLOB population.
- Now playing, mini player, and immersive player display current track artwork.
- Artist grid/detail shows generated placeholder treatment, not album-cover-as-artist-image.
- Settings can trim and clear artwork cache.
- After migration and database optimize, SQLite artwork BLOB columns are empty.

- [ ] **Step 5: Inspect database after migration**

Run:

```bash
DB="$HOME/Library/Application Support/org.Petrichor/petrichor.db"
sqlite3 -header -column "$DB" <<'SQL'
SELECT 'albums.artwork_data' AS column_name, COUNT(*) AS rows FROM albums WHERE artwork_data IS NOT NULL
UNION ALL SELECT 'artists.artwork_data', COUNT(*) FROM artists WHERE artwork_data IS NOT NULL
UNION ALL SELECT 'tracks.track_artwork_data', COUNT(*) FROM tracks WHERE track_artwork_data IS NOT NULL
UNION ALL SELECT 'playlists.cover_artwork_data', COUNT(*) FROM playlists WHERE cover_artwork_data IS NOT NULL;
SQL
```

Expected: all row counts are `0`.

- [ ] **Step 6: Inspect final git state**

Run: `git status --short`

Expected: no uncommitted changes from the artwork cache implementation remain. Existing unrelated user changes may still be present and should not be staged or reverted.
