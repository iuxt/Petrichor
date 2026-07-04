# Artist Image Folder Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store downloaded artist images under each music folder's `artist images` directory and display those images anywhere an `ArtistEntity` is shown.

**Architecture:** Add a file-backed `ArtistImageStore` that owns artist image path rules, filename sanitization, per-root grouping, reads, and writes. Update the downloader to use the store instead of song directories, then update the Home artist grid and detail header to asynchronously read file-backed artist images while keeping generated initials as fallback.

**Tech Stack:** Swift, SwiftUI, Foundation file IO, AppKit `NSImage`, existing `ArtistParser`, existing `AlbumArtFormat`, bash guard scripts, `Localizable.xcstrings`, `xcodebuild`.

---

## File Structure

- Create `Core/ArtistImageStore.swift`
  - Owns `artist images` directory naming, sanitized artist filenames, root matching, artist grouping by root, existing-image lookup, image reads, and image writes.
  - Has no networking and no database dependency.
- Modify `Managers/ArtistImageDownloadManager.swift`
  - Remove song-directory grouping and private filename/path helpers.
  - Fetch tracks and folders, group artists by music root through `ArtistImageStore`, skip existing root-level images, and write through `ArtistImageStore`.
- Modify `Utilities/Constants.swift`
  - Add `Notification.Name.artistImagesDidChange` so UI can reload after background downloads finish.
- Modify `Views/Components/EntityGridView.swift`
  - Give grid items access to `LibraryManager`.
  - Prefer file-backed artist images for `ArtistEntity`; keep current generated entity artwork fallback.
- Modify `Views/Home/EntityDetailView.swift`
  - Add `artistImageData` state and load file-backed images for `ArtistEntity` after entity tracks are loaded.
  - Use the loaded file-backed image in the header and gradient calculation.
- Modify `Views/Settings/IntegrationsTabView.swift`
  - Replace the artist-image toggle label/help text with localized strings that mention music folders.
- Modify `Resources/Localizable.xcstrings`
  - Add Simplified Chinese translations for the new artist-image setting label and help text.
- Modify `Scripts/test-artist-image-sidecar-download.sh`
  - Turn the current sidecar guard into the regression guard for `artist images` folder storage, UI reads, localization, and no database artwork writes.

No Xcode project file edits are expected because `Core`, `Managers`, `Views`, `Resources`, and `Scripts` are already visible to the project or test runner through existing structure.

## Task 1: Update the Guard Script First

**Files:**
- Modify: `Scripts/test-artist-image-sidecar-download.sh`

- [ ] **Step 1: Replace the guard script with the new failing checks**

Replace the entire file with:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

store="Core/ArtistImageStore.swift"
manager="Managers/ArtistImageDownloadManager.swift"
settings="Views/Settings/IntegrationsTabView.swift"
grid="Views/Components/EntityGridView.swift"
detail="Views/Home/EntityDetailView.swift"
strings="Resources/Localizable.xcstrings"

if [[ ! -f "$store" ]]; then
  echo "Missing ArtistImageStore." >&2
  exit 1
fi

for pattern in \
  "enum ArtistImageStore" \
  "artistImagesDirectoryName = \"artist images\"" \
  "imageDirectory\\(forMusicRoot" \
  "preferredImageURL\\(artistName:musicRoot:" \
  "existingImageURL\\(artistName:musicRoot:" \
  "imageData\\(for artistName:" \
  "groupedArtistsByMusicRoot\\(from tracks:" \
  "musicRoot\\(containing url:" \
  "writeImage\\(_ data:" \
  "AlbumArtFormat\\.supportedExtensions"; do
  if ! rg -n "$pattern" "$store" >/dev/null; then
    echo "ArtistImageStore missing expected pattern: $pattern" >&2
    exit 1
  fi
done

if rg -n "DatabaseManager|updateArtist|artwork_data|artistArtwork|artist\\.artworkData" "$store" >/dev/null; then
  echo "ArtistImageStore must not read or write artist artwork through the database." >&2
  exit 1
fi

for pattern in \
  "final class ArtistImageDownloadManager" \
  "static let shared = ArtistImageDownloadManager" \
  "artistImageDownloadEnabled" \
  "https://musicbrainz.org/ws/2/artist/" \
  "https://www.wikidata.org/w/api.php" \
  "commonsThumbUrl" \
  "libraryManager\\.databaseManager\\.getAllFolders\\(\\)" \
  "ArtistImageStore\\.groupedArtistsByMusicRoot" \
  "ArtistImageStore\\.existingImageURL" \
  "ArtistImageStore\\.writeImage" \
  "NotificationCenter\\.default\\.post\\(name: \\.artistImagesDidChange" \
  "UserDefaults\\.standard\\.bool\\(forKey: Self\\.artistImageDownloadEnabledKey\\)"; do
  if ! rg -n "$pattern" "$manager" >/dev/null; then
    echo "ArtistImageDownloadManager missing expected pattern: $pattern" >&2
    exit 1
  fi
done

if rg -n "deletingLastPathComponent\\(\\)|appendingPathComponent\\(filename\\)\\.appendingPathExtension\\(\"jpg\"\\)|sanitizedArtistFilename\\(" "$manager" >/dev/null; then
  echo "Artist image downloader still writes images beside individual songs." >&2
  exit 1
fi

if rg -n "updateArtist|artwork_data|artistArtwork|artist\\.artworkData" "$manager" >/dev/null; then
  echo "Artist image downloader must not write artist artwork to the database." >&2
  exit 1
fi

if ! rg -n "@AppStorage\\(\"artistImageDownloadEnabled\"\\)" "$settings" >/dev/null; then
  echo "Missing artist image download setting." >&2
  exit 1
fi

if ! rg -n "Download artist images to music folders|ArtistImageDownloadManager\\.shared\\.downloadMissingArtistImages" "$settings" >/dev/null; then
  echo "Settings UI does not expose or trigger artist image downloads." >&2
  exit 1
fi

if rg -n "Download artist images to song folders|next to songs" "$settings" >/dev/null; then
  echo "Settings UI still describes song-folder artist image storage." >&2
  exit 1
fi

if ! rg -n "ArtistImageStore\\.imageData\\(for: artist(Name|\\.name)" "$grid" >/dev/null; then
  echo "Artist grid does not read file-backed artist images." >&2
  exit 1
fi

if ! rg -n "artistImageRefreshID|publisher\\(for: \\.artistImagesDidChange\\)" "$grid" >/dev/null; then
  echo "Artist grid does not refresh after artist image downloads change files." >&2
  exit 1
fi

if ! rg -n "artistImageData|loadArtistImage|ArtistImageStore\\.imageData\\(for: entity\\.name" "$detail" >/dev/null; then
  echo "Artist detail does not read file-backed artist images." >&2
  exit 1
fi

if ! rg -n "publisher\\(for: \\.artistImagesDidChange\\)" "$detail" >/dev/null; then
  echo "Artist detail does not refresh after artist image downloads change files." >&2
  exit 1
fi

if ! rg -n "artistImagesDidChange" Utilities/Constants.swift >/dev/null; then
  echo "Missing artist image change notification." >&2
  exit 1
fi

for pattern in \
  "\"Download artist images to music folders\"" \
  "\"下载艺人图片到音乐文件夹\"" \
  "\"artist images\"" \
  "\"艺人图片\""; do
  if ! rg -n "$pattern" "$strings" >/dev/null; then
    echo "Missing localized artist image setting pattern: $pattern" >&2
    exit 1
  fi
done

if ! rg -n "ArtistImageDownloadManager\\.shared\\.downloadMissingArtistImages\\(using: self\\)" \
  Managers/Library/LMLibrary.swift >/dev/null; then
  echo "Library load does not trigger artist image download pass." >&2
  exit 1
fi
```

- [ ] **Step 2: Run the guard and confirm it fails for the missing store**

Run:

```bash
bash Scripts/test-artist-image-sidecar-download.sh
```

Expected: FAIL with `Missing ArtistImageStore.`

- [ ] **Step 3: Commit the failing guard**

Run:

```bash
git add Scripts/test-artist-image-sidecar-download.sh
git commit -m "test: guard artist image folder display"
```

Expected: commit succeeds.

## Task 2: Add `ArtistImageStore`

**Files:**
- Create: `Core/ArtistImageStore.swift`
- Test: `Scripts/test-artist-image-sidecar-download.sh`

- [ ] **Step 1: Create the file-backed artist image store**

Create `Core/ArtistImageStore.swift`:

```swift
import Foundation

enum ArtistImageStore {
    static let artistImagesDirectoryName = "artist images"
    private static let preferredImageExtension = "jpg"

    static func imageDirectory(forMusicRoot musicRoot: URL) -> URL {
        musicRoot.appendingPathComponent(artistImagesDirectoryName, isDirectory: true)
    }

    static func preferredImageURL(artistName: String, musicRoot: URL) -> URL {
        imageDirectory(forMusicRoot: musicRoot)
            .appendingPathComponent(sanitizedArtistFilename(artistName))
            .appendingPathExtension(preferredImageExtension)
    }

    static func existingImageURL(
        artistName: String,
        musicRoot: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let filename = sanitizedArtistFilename(artistName)
        let directory = imageDirectory(forMusicRoot: musicRoot)

        for fileExtension in AlbumArtFormat.supportedExtensions {
            let candidate = directory
                .appendingPathComponent(filename)
                .appendingPathExtension(fileExtension)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    static func imageData(
        for artistName: String,
        tracks: [Track],
        folders: [Folder],
        fileManager: FileManager = .default
    ) -> Data? {
        for root in musicRoots(for: artistName, tracks: tracks, folders: folders) {
            guard let imageURL = existingImageURL(
                artistName: artistName,
                musicRoot: root,
                fileManager: fileManager
            ) else {
                continue
            }

            guard let attributes = try? fileManager.attributesOfItem(atPath: imageURL.path),
                  let fileSize = attributes[.size] as? NSNumber,
                  fileSize.intValue <= AlbumArtFormat.maxArtworkSize,
                  let data = try? Data(contentsOf: imageURL),
                  data.count <= AlbumArtFormat.maxArtworkSize else {
                continue
            }

            return data
        }

        return nil
    }

    static func groupedArtistsByMusicRoot(
        from tracks: [Track],
        folders: [Folder]
    ) -> [URL: Set<String>] {
        var result: [URL: Set<String>] = [:]
        let unknownArtist = LibraryFilterType.artists.unknownPlaceholder

        for track in tracks {
            guard let root = musicRoot(containing: track.url, folders: folders) else {
                continue
            }

            for artist in ArtistParser.parse(track.artist, unknownPlaceholder: unknownArtist) {
                let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != unknownArtist else { continue }
                result[root, default: []].insert(trimmed)
            }
        }

        return result
    }

    static func musicRoot(containing url: URL, folders: [Folder]) -> URL? {
        let filePath = url.standardizedFileURL.path
        return folders
            .map(\.url)
            .sorted {
                $0.standardizedFileURL.path.count > $1.standardizedFileURL.path.count
            }
            .first { root in
                let rootPath = root.standardizedFileURL.path
                return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
            }
    }

    @discardableResult
    static func writeImage(
        _ data: Data,
        artistName: String,
        musicRoot: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = imageDirectory(forMusicRoot: musicRoot)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = preferredImageURL(artistName: artistName, musicRoot: musicRoot)
        guard !fileManager.fileExists(atPath: destination.path) else {
            return destination
        }

        try data.write(to: destination, options: [.atomic])
        return destination
    }

    static func sanitizedArtistFilename(_ artistName: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        let parts = artistName.components(separatedBy: invalidCharacters)
        let sanitized = parts.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Unknown Artist" : sanitized
    }

    private static func musicRoots(
        for artistName: String,
        tracks: [Track],
        folders: [Folder]
    ) -> [URL] {
        let normalizedArtistName = ArtistParser.normalizeArtistName(artistName)
        let unknownArtist = LibraryFilterType.artists.unknownPlaceholder
        var seen: Set<String> = []
        var roots: [URL] = []

        for track in tracks {
            let artists = ArtistParser.parse(track.artist, unknownPlaceholder: unknownArtist)
            let hasArtist = artists.contains {
                ArtistParser.normalizeArtistName($0) == normalizedArtistName
            }
            guard hasArtist,
                  let root = musicRoot(containing: track.url, folders: folders) else {
                continue
            }

            let key = root.standardizedFileURL.path
            if seen.insert(key).inserted {
                roots.append(root)
            }
        }

        return roots
    }
}
```

- [ ] **Step 2: Run the guard and confirm it now fails at downloader wiring**

Run:

```bash
bash Scripts/test-artist-image-sidecar-download.sh
```

Expected: FAIL with a message mentioning `ArtistImageDownloadManager missing expected pattern`.

- [ ] **Step 3: Commit the store**

Run:

```bash
git add Core/ArtistImageStore.swift
git commit -m "feat: add artist image file store"
```

Expected: commit succeeds.

## Task 3: Write Artist Images Under Music Roots

**Files:**
- Modify: `Managers/ArtistImageDownloadManager.swift`
- Modify: `Utilities/Constants.swift`
- Test: `Scripts/test-artist-image-sidecar-download.sh`

- [ ] **Step 1: Add an artist image file-change notification**

In `Utilities/Constants.swift`, add this line to the existing `extension Notification.Name` near `libraryDataDidChange`:

```swift
static let artistImagesDidChange = Notification.Name("ArtistImagesDidChange")
```

- [ ] **Step 2: Replace track-directory grouping with root grouping**

In `downloadMissingArtistImages(using:)`, replace the detached task body with:

```swift
downloadTask = Task.detached(priority: .utility) { [weak self] in
    guard let self else { return }

    let tracks = libraryManager.databaseManager.getAllTracks()
    let folders = libraryManager.databaseManager.getAllFolders()
    let work = ArtistImageStore.groupedArtistsByMusicRoot(from: tracks, folders: folders)
    guard !work.isEmpty else { return }

    Logger.info("ArtistImageDownloadManager: checking artist images in \(work.count) music folders")

    var imageCache: [String: Data] = [:]
    var failedArtists: Set<String> = []

    var wroteAnyImage = false

    for (musicRoot, artistNames) in work.sorted(by: {
        $0.key.path.localizedCaseInsensitiveCompare($1.key.path) == .orderedAscending
    }) {
        guard !Task.isCancelled, self.isEnabled else { break }

        for artistName in artistNames.sorted(by: {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }) {
            guard !Task.isCancelled, self.isEnabled else { break }

            guard ArtistImageStore.existingImageURL(
                artistName: artistName,
                musicRoot: musicRoot,
                fileManager: self.fileManager
            ) == nil else {
                continue
            }

            let normalizedArtistName = ArtistParser.normalizeArtistName(artistName)
            let imageData: Data

            if let cached = imageCache[normalizedArtistName] {
                imageData = cached
            } else {
                guard !failedArtists.contains(normalizedArtistName),
                      let downloaded = await self.fetchArtistImage(name: artistName) else {
                    failedArtists.insert(normalizedArtistName)
                    continue
                }
                imageCache[normalizedArtistName] = downloaded
                imageData = downloaded
            }

            do {
                let destination = try ArtistImageStore.writeImage(
                    imageData,
                    artistName: artistName,
                    musicRoot: musicRoot,
                    fileManager: self.fileManager
                )
                wroteAnyImage = true
                Logger.info("ArtistImageDownloadManager: wrote \(destination.lastPathComponent)")
            } catch {
                Logger.error("ArtistImageDownloadManager: failed to write artist image for '\(artistName)' in \(musicRoot.path): \(error.localizedDescription)")
            }
        }
    }

    if wroteAnyImage {
        await MainActor.run {
            NotificationCenter.default.post(name: .artistImagesDidChange, object: nil)
        }
    }

    Logger.info("ArtistImageDownloadManager: finished artist image folder pass")
}
```

- [ ] **Step 3: Delete obsolete private path helpers**

Remove these methods from `Managers/ArtistImageDownloadManager.swift`:

```swift
private func artistDirectories(from tracks: [Track]) -> [String: Set<URL>]
private func artistImageExists(artistName: String, in directory: URL) -> Bool
private func writeArtistImage(_ data: Data, artistName: String, directory: URL)
private func sanitizedArtistFilename(_ artistName: String) -> String
```

The downloader must use `ArtistImageStore` for all local artist image paths after this step.

- [ ] **Step 4: Run the guard and confirm it now fails at UI wiring or localization**

Run:

```bash
bash Scripts/test-artist-image-sidecar-download.sh
```

Expected: FAIL with a message mentioning either `Artist grid`, `Artist detail`, or localized setting patterns.

- [ ] **Step 5: Commit the downloader change**

Run:

```bash
git add Managers/ArtistImageDownloadManager.swift Utilities/Constants.swift
git commit -m "feat: store downloaded artist images by music root"
```

Expected: commit succeeds.

## Task 4: Display File-Backed Artist Images in the Home Grid

**Files:**
- Modify: `Views/Components/EntityGridView.swift`
- Test: `Scripts/test-artist-image-sidecar-download.sh`

- [ ] **Step 1: Pass `LibraryManager` into grid item loading**

In `EntityGridView`, add a refresh token:

```swift
@State private var artistImageRefreshID = UUID()
```

When constructing each `EntityGridItem`, pass the token:

```swift
artistImageRefreshID: artistImageRefreshID,
```

Add this modifier to the outer `ScrollView`:

```swift
.onReceive(NotificationCenter.default.publisher(for: .artistImagesDidChange)) { _ in
    artistImageRefreshID = UUID()
}
```

Inside `private struct EntityGridItem<T: Entity>: View`, add:

```swift
let artistImageRefreshID: UUID

@EnvironmentObject private var libraryManager: LibraryManager
```

- [ ] **Step 2: Include artist image availability in the grid cache key**

Replace `artworkTaskID` with:

```swift
private var artworkTaskID: String {
    "\(entity.id.uuidString)-\(entity.artworkData?.count ?? 0)-\(artistImageRefreshID.uuidString)"
}
```

- [ ] **Step 3: Prefer file-backed artist image data in `loadArtwork()`**

Replace `loadArtwork()` with:

```swift
private func loadArtwork() async {
    if let artist = entity as? ArtistEntity {
        let image = await loadArtistArtwork(for: artist)
        guard !Task.isCancelled else { return }
        renderedImage = image
        return
    }

    if let cached = EntityArtworkCache.shared.getCachedImage(for: entity) {
        renderedImage = cached
        return
    }

    let image = await EntityArtworkCache.shared.loadImage(for: entity)

    guard !Task.isCancelled else { return }
    renderedImage = image
}
```

Then add this helper below `loadArtwork()`:

```swift
private func loadArtistArtwork(for artist: ArtistEntity) async -> NSImage? {
    let artistName = artist.name
    let artistTracks = artist.tracks
    let folders = libraryManager.folders
    let databaseManager = libraryManager.databaseManager

    if let imageData = await Task.detached(priority: .utility, operation: {
        let tracks = artistTracks.isEmpty
            ? databaseManager.getTracksForArtistEntity(artistName)
            : artistTracks
        return ArtistImageStore.imageData(for: artistName, tracks: tracks, folders: folders)
    }).value,
       let rendered = await EntityArtworkCache.shared.loadRenderedImage(from: imageData, cacheKey: "artist-\(artist.id.uuidString)-file") {
        return rendered
    }

    if let cached = EntityArtworkCache.shared.getCachedImage(for: artist) {
        return cached
    }

    return await EntityArtworkCache.shared.loadImage(for: artist)
}
```

- [ ] **Step 4: Expose an async rendered-image helper on `EntityArtworkCache`**

Inside `EntityArtworkCache`, add:

```swift
func loadRenderedImage(from data: Data, cacheKey: String) async -> NSImage? {
    let key = cacheKey as NSString
    if let cached = cache.object(forKey: key) {
        return cached
    }

    return await loadQueue.renderArtwork { [self] in
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let image = createRenderedImage(from: data) else {
            return nil
        }

        cache.setObject(image, forKey: key, cost: Self.bytesPerImage)
        return image
    }
}
```

- [ ] **Step 5: Run the guard and confirm it now fails at detail or localization**

Run:

```bash
bash Scripts/test-artist-image-sidecar-download.sh
```

Expected: FAIL with a message mentioning either `Artist detail` or localized setting patterns.

- [ ] **Step 6: Commit the grid display change**

Run:

```bash
git add Views/Components/EntityGridView.swift
git commit -m "feat: show artist image files in home grid"
```

Expected: commit succeeds.

## Task 5: Display File-Backed Artist Images in Entity Detail

**Files:**
- Modify: `Views/Home/EntityDetailView.swift`
- Test: `Scripts/test-artist-image-sidecar-download.sh`

- [ ] **Step 1: Add artist image state**

Near the existing `resolvedArtworkData` state, add:

```swift
@State private var artistImageData: Data?
```

- [ ] **Step 2: Prefer artist image data in the header artwork**

In `entityArtwork`, insert this branch after the album branch and before the `entity.artworkData` branch:

```swift
} else if let artistImageData,
          let nsImage = NSImage(data: artistImageData) {
    Image(nsImage: nsImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
```

- [ ] **Step 3: Load the artist image after tracks load**

At the end of `loadTracks()`, just before `self.isLoading = false`, add:

```swift
loadArtistImage(from: fetchedTracks)
```

Then add this method in the `extension EntityDetailView` block:

```swift
private func loadArtistImage(from fetchedTracks: [Track]) {
    guard entity is ArtistEntity else {
        artistImageData = nil
        return
    }

    let artistName = entity.name
    let folders = libraryManager.folders
    let entityID = entity.id

    Task {
        let data = await Task.detached(priority: .utility) {
            ArtistImageStore.imageData(for: artistName, tracks: fetchedTracks, folders: folders)
        }.value

        guard entity.id == entityID else { return }
        artistImageData = data
        resolvedArtworkData = data
        updateGradientColors()
    }
}
```

- [ ] **Step 4: Reset stale artist image state when entity changes**

In the `.onChange(of: entity.id)` block, before `loadTracks()`, add:

```swift
artistImageData = nil
resolvedArtworkData = nil
```

- [ ] **Step 5: Refresh the detail image after background downloads**

Add this modifier alongside the existing `.onChange` modifiers in `body`:

```swift
.onReceive(NotificationCenter.default.publisher(for: .artistImagesDidChange)) { _ in
    loadArtistImage(from: tracks)
}
```

- [ ] **Step 6: Run the guard and confirm it now fails only at localization**

Run:

```bash
bash Scripts/test-artist-image-sidecar-download.sh
```

Expected: FAIL with a message mentioning localized artist image setting patterns.

- [ ] **Step 7: Commit the detail display change**

Run:

```bash
git add Views/Home/EntityDetailView.swift
git commit -m "feat: show artist image files in entity detail"
```

Expected: commit succeeds.

## Task 6: Localize the Artist Image Setting

**Files:**
- Modify: `Views/Settings/IntegrationsTabView.swift`
- Modify: `Resources/Localizable.xcstrings`
- Test: `Scripts/test-artist-image-sidecar-download.sh`
- Test: `Scripts/test-localization-format-specifiers.sh`

- [ ] **Step 1: Update the setting label and help text in SwiftUI**

Replace the current artist image toggle block with:

```swift
Toggle("Download artist images to music folders", isOn: $artistImageDownloadEnabled)
    .help("Automatically save downloaded artist images in each music folder's artist images folder")
    .onChange(of: artistImageDownloadEnabled) { _, enabled in
        if enabled, let coordinator = AppCoordinator.shared {
            ArtistImageDownloadManager.shared.downloadMissingArtistImages(using: coordinator.libraryManager)
        }
    }
```

- [ ] **Step 2: Add localized strings**

In `Resources/Localizable.xcstrings`, add entries matching the existing JSON style:

```json
"Automatically save downloaded artist images in each music folder's artist images folder": {
  "comment": "Help text for the setting that downloads artist images to an artist images folder inside each music folder.",
  "isCommentAutoGenerated": true,
  "localizations": {
    "zh-Hans": {
      "stringUnit": {
        "state": "translated",
        "value": "自动将下载的艺人图片保存到每个音乐文件夹下的 artist images 文件夹"
      }
    }
  }
},
"Download artist images to music folders": {
  "comment": "A toggle that enables downloading artist images into each music folder's artist images directory.",
  "isCommentAutoGenerated": true,
  "localizations": {
    "zh-Hans": {
      "stringUnit": {
        "state": "translated",
        "value": "下载艺人图片到音乐文件夹"
      }
    }
  }
},
```

Place the keys alphabetically near the existing `Download` and `Automatically` keys, preserving valid JSON commas.

- [ ] **Step 3: Run focused checks**

Run:

```bash
bash Scripts/test-artist-image-sidecar-download.sh
bash Scripts/test-localization-format-specifiers.sh
```

Expected: both commands exit 0.

- [ ] **Step 4: Commit localization**

Run:

```bash
git add Views/Settings/IntegrationsTabView.swift Resources/Localizable.xcstrings
git commit -m "feat: localize artist image download setting"
```

Expected: commit succeeds.

## Task 7: Final Verification

**Files:**
- Verify all changed files.

- [ ] **Step 1: Run the focused artist image guard**

Run:

```bash
bash Scripts/test-artist-image-sidecar-download.sh
```

Expected: exits 0.

- [ ] **Step 2: Run the localization guard**

Run:

```bash
bash Scripts/test-localization-format-specifiers.sh
```

Expected: exits 0.

- [ ] **Step 3: Run all shell checks**

Run:

```bash
for script in Scripts/test-*.sh; do bash "$script"; done
```

Expected: exits 0. A script may print `rg: .github/workflows/ci.yml: No such file or directory`; that is acceptable only if the overall command exits 0.

- [ ] **Step 4: Check whitespace**

Run:

```bash
git diff --check
```

Expected: exits 0.

- [ ] **Step 5: Build Debug without local signing**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Expected: output ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit any verification-driven fixes**

If verification required fixes, commit them:

```bash
git add Core/ArtistImageStore.swift Managers/ArtistImageDownloadManager.swift Views/Components/EntityGridView.swift Views/Home/EntityDetailView.swift Views/Settings/IntegrationsTabView.swift Resources/Localizable.xcstrings Scripts/test-artist-image-sidecar-download.sh
git commit -m "fix: stabilize artist image folder display"
```

Expected: commit succeeds only if there are pending fixes. If `git status --short` is clean, skip this step.
