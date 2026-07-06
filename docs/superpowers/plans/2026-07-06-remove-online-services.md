# Remove Online Music Services Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Petrichor's runtime online music-service features while preserving local lyrics, local artwork, and local artist-image display.

**Architecture:** Add a removal guard first, then delete runtime networking managers and their call sites. Keep local resolver boundaries (`LyricsLoader`, `ArtworkResolver`, `ArtistImageStore`) but reduce them to local-only behavior, then clean settings, configuration, localization, docs, and obsolete tests.

**Tech Stack:** Swift, SwiftUI, AppKit, Foundation, shell regression scripts, Xcode project build.

---

## File Structure

- Create `Scripts/test-online-services-removed.sh`: removal guard for deleted online services and settings.
- Modify `Application/AppCoordinator.swift`: remove scrobble manager ownership.
- Modify `Application/AppDelegate.swift`: remove custom URL callback handling.
- Delete `Utilities/URLSchemeHandler.swift`: Last.fm callback handler.
- Delete `Utilities/KeychainManager.swift`: only remaining keychain use is Last.fm session storage.
- Modify `Managers/PlaybackManager.swift`: remove Last.fm scrobble hooks.
- Delete `Managers/ScrobbleManager.swift`: Last.fm authentication and API calls.
- Delete `Managers/LyricsManager.swift`: LRCLIB lookup and sidecar-writing fallback.
- Delete `Managers/TrackArtworkDownloadManager.swift`: MusicBrainz/Cover Art Archive lookup and artwork sidecar writing.
- Delete `Managers/ArtistImageDownloadManager.swift`: MusicBrainz/Wikidata/Wikimedia artist-image downloading.
- Modify `Managers/Library/LMLibrary.swift`: remove automatic artist-image download pass.
- Modify `Core/LyricsLoader.swift`: keep local/embedded lyrics only.
- Delete `Core/LyricsSidecarWriter.swift`: only used by online lyrics downloads.
- Modify `Core/Artwork/ArtworkResolver.swift`: keep embedded, same-stem, and generic local artwork only.
- Delete `Core/Artwork/TrackArtworkSidecarWriter.swift`: only used by online artwork downloads.
- Modify `Views/Components/Artwork/AsyncArtworkImage.swift`: remove online sidecar refresh notification listener.
- Modify `Core/ArtistImageStore.swift`: keep local image reads; remove downloader-only grouping and write helpers.
- Modify `Utilities/Constants.swift`: remove `trackArtworkSidecarDidChange`; keep `artistImagesDidChange` because local image files can still change outside the app while views are open.
- Modify `Utilities/AppInfo.swift`: remove unused `userAgent` and `urlSession`.
- Modify `Utilities/DiagnosticSnapshot.swift`: remove the `integrations` diagnostics section.
- Delete `Views/Settings/IntegrationsTabView.swift`: all controls in the tab are removed online-service settings.
- Modify `Views/Settings/SettingsView.swift`: remove the Integrations tab enum case, icon, and switch case.
- Modify `Views/Settings/LibraryTabView.swift`: remove Last.fm keychain cleanup from reset logic.
- Modify `Configuration/Info.plist`: remove callback URL type and removed service credential keys.
- Modify `Configuration/Secrets.xcconfig.template`: remove removed service credential placeholders.
- Modify `Resources/Localizable.xcstrings`: remove strings only used by deleted settings and online-service notifications.
- Delete unused service logo asset directories: `logo-lastfm`, `logo-musicbrainz`, `logo-tmdb`, and `logo-wikidata`.
- Modify `ACKNOWLEDGEMENTS.md` and `README.md`: remove claims for removed runtime online services.
- Delete or replace obsolete online-feature scripts: `test-online-lyrics-sidecar.sh`, `test-track-artwork-download.sh`, `test-artist-image-sidecar-download.sh`, and `test-track-artwork-sidecar.sh`.
- Modify `Scripts/test-artwork-resolver-priority.sh`: assert the local-only artwork priority.

### Task 1: Add Online-Service Removal Guard

**Files:**
- Create: `Scripts/test-online-services-removed.sh`

- [ ] **Step 1: Create the failing removal guard**

Create `Scripts/test-online-services-removed.sh` with this content:

```bash
#!/usr/bin/env bash
set -euo pipefail

removed_files=(
  "Managers/ScrobbleManager.swift"
  "Managers/LyricsManager.swift"
  "Managers/TrackArtworkDownloadManager.swift"
  "Managers/ArtistImageDownloadManager.swift"
  "Views/Settings/IntegrationsTabView.swift"
  "Utilities/URLSchemeHandler.swift"
  "Utilities/KeychainManager.swift"
  "Core/LyricsSidecarWriter.swift"
  "Core/Artwork/TrackArtworkSidecarWriter.swift"
)

for removed_file in "${removed_files[@]}"; do
  if [[ -e "$removed_file" ]]; then
    printf '%s should be removed with online music services.\n' "$removed_file" >&2
    exit 1
  fi
done

removed_asset_dirs=(
  "Resources/Assets.xcassets/logo-lastfm.imageset"
  "Resources/Assets.xcassets/logo-musicbrainz.imageset"
  "Resources/Assets.xcassets/logo-tmdb.imageset"
  "Resources/Assets.xcassets/logo-wikidata.imageset"
)

for removed_asset_dir in "${removed_asset_dirs[@]}"; do
  if [[ -e "$removed_asset_dir" ]]; then
    printf '%s should be removed with online music services.\n' "$removed_asset_dir" >&2
    exit 1
  fi
done

if rg -n 'ScrobbleManager|LyricsManager|TrackArtworkDownloadManager|ArtistImageDownloadManager|IntegrationsTabView|URLSchemeHandler|KeychainManager|LyricsSidecarWriter|TrackArtworkSidecarWriter|lastfmUsername|lastfmAvatarData|scrobblingEnabled|onlineLyricsEnabled|trackArtworkDownloadEnabled|artistImageDownloadEnabled|lastfm-callback|LASTFM_API_KEY|LASTFM_SHARED_SECRET|TMDB_READ_ACCESS_TOKEN|Fetch lyrics from internet when unavailable|Fetch artwork from internet when unavailable|Download artist images to music folders|Lyrics & Metadata|Track your listening history on Last\.fm|Connect your Last\.fm account|Disconnected from Last\.fm|Connected to Last\.fm|Failed to connect to Last\.fm|Last\.fm API|Last\.fm authorization|Last\.fm error' \
  Application Managers Views Core Utilities Models Configuration Resources/Localizable.xcstrings PetrichorApp.swift >/dev/null
then
  printf 'Removed online-service wiring, settings, credentials, or strings are still present.\n' >&2
  exit 1
fi

if rg -n 'https://(lrclib\.net/api|ws\.audioscrobbler\.com/2\.0|www\.last\.fm/api|musicbrainz\.org/ws/2|coverartarchive\.org|www\.wikidata\.org/w/api\.php|upload\.wikimedia\.org/wikipedia/commons)' \
  Application Managers Views Core Utilities Models Configuration Resources/Localizable.xcstrings PetrichorApp.swift >/dev/null
then
  printf 'Removed online-service endpoint is still referenced by runtime code.\n' >&2
  exit 1
fi

printf 'Online music services removed\n'
```

- [ ] **Step 2: Make the guard executable**

Run:

```bash
chmod +x Scripts/test-online-services-removed.sh
```

Expected: command exits 0.

- [ ] **Step 3: Run the guard and verify it fails before removal**

Run:

```bash
Scripts/test-online-services-removed.sh
```

Expected: FAIL with a message naming an existing removed file such as `Managers/ScrobbleManager.swift should be removed with online music services.`

- [ ] **Step 4: Commit the failing guard**

Run:

```bash
git add Scripts/test-online-services-removed.sh
git commit -m "test: guard online service removal"
```

Expected: commit succeeds.

### Task 2: Remove Last.fm Runtime, Callback, Settings Tab, And Credentials

**Files:**
- Delete: `Managers/ScrobbleManager.swift`
- Delete: `Utilities/URLSchemeHandler.swift`
- Delete: `Utilities/KeychainManager.swift`
- Delete: `Views/Settings/IntegrationsTabView.swift`
- Modify: `Application/AppCoordinator.swift`
- Modify: `Application/AppDelegate.swift`
- Modify: `Managers/PlaybackManager.swift`
- Modify: `Views/Settings/SettingsView.swift`
- Modify: `Views/Settings/LibraryTabView.swift`
- Modify: `Utilities/DiagnosticSnapshot.swift`
- Modify: `Configuration/Info.plist`
- Modify: `Configuration/Secrets.xcconfig.template`

- [ ] **Step 1: Delete Last.fm-only files**

Run:

```bash
rm Managers/ScrobbleManager.swift Utilities/URLSchemeHandler.swift Utilities/KeychainManager.swift Views/Settings/IntegrationsTabView.swift
```

Expected: command exits 0.

- [ ] **Step 2: Remove AppCoordinator scrobble ownership**

In `Application/AppCoordinator.swift`, remove the property:

```swift
let scrobbleManager: ScrobbleManager
```

Also remove the initialization block:

```swift
// Setup Scrobbling
scrobbleManager = ScrobbleManager()
```

Expected: `AppCoordinator` no longer references `ScrobbleManager`.

- [ ] **Step 3: Remove AppDelegate URL opening callback**

In `Application/AppDelegate.swift`, remove this method entirely:

```swift
func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
        URLSchemeHandler.handle(url)
    }
}
```

Expected: `Application/AppDelegate.swift` no longer references `URLSchemeHandler`.

- [ ] **Step 4: Remove PlaybackManager scrobble property and calls**

In `Managers/PlaybackManager.swift`, remove this computed property:

```swift
private var scrobbleManager: ScrobbleManager? {
    AppCoordinator.shared?.scrobbleManager
}
```

Remove each scrobble call:

```swift
scrobbleManager?.trackStarted(lightweightTrack)
scrobbleManager?.trackStarted(pending.track)
self.scrobbleManager?.trackFinished(finishedTrack)
```

Change this log line:

```swift
Logger.info("Track completed naturally, updating play count, last played date, and scrobbling it if configured")
```

to:

```swift
Logger.info("Track completed naturally, updating play count and last played date")
```

Expected: `Managers/PlaybackManager.swift` no longer references `scrobble`.

- [ ] **Step 5: Remove the Integrations tab from SettingsView**

In `Views/Settings/SettingsView.swift`, remove this enum case:

```swift
case integrations = "Integrations"
```

Remove the icon cases:

```swift
case .integrations: return Icons.globe
```

Remove the view switch case:

```swift
case .integrations:
    IntegrationsTabView()
```

Expected: `SettingsTab.allCases` contains only `general`, `appearance`, `library`, and `about`.

- [ ] **Step 6: Remove Last.fm keychain cleanup from library reset**

In `Views/Settings/LibraryTabView.swift`, remove this line from `resetLibraryData()`:

```swift
KeychainManager.delete(key: KeychainManager.Keys.lastfmSessionKey)
```

Expected: `Views/Settings/LibraryTabView.swift` no longer references `KeychainManager`.

- [ ] **Step 7: Remove integrations diagnostics**

In `Utilities/DiagnosticSnapshot.swift`, delete the entire `integrations` entry from `payload["settings"]`:

```swift
"integrations": [
    "lastfmUsername": defaults.string(forKey: "lastfmUsername") != nil ? "<set>" : "<unset>",
    "scrobblingEnabled": defaults.boolOrNull("scrobblingEnabled"),
    "onlineLyricsEnabled": defaults.boolOrNull("onlineLyricsEnabled"),
    "trackArtworkDownloadEnabled": defaults.boolOrNull("trackArtworkDownloadEnabled"),
    "artistImageDownloadEnabled": defaults.boolOrNull("artistImageDownloadEnabled")
]
```

Expected: the settings snapshot keeps `general`, `appearance`, and `library` entries and has no `integrations` entry.

- [ ] **Step 8: Remove callback and service credentials from Info.plist**

In `Configuration/Info.plist`, delete the entire `CFBundleURLTypes` key and array:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>org.Petrichor.callback</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>petrichor</string>
        </array>
    </dict>
</array>
```

Also delete these credential entries:

```xml
<!--  Last.fm Scrobble  -->
<key>LASTFM_API_KEY</key>
<string>$(LASTFM_API_KEY)</string>
<key>LASTFM_SHARED_SECRET</key>
<string>$(LASTFM_SHARED_SECRET)</string>

<!--  TMDB  -->
<key>TMDB_READ_ACCESS_TOKEN</key>
<string>$(TMDB_READ_ACCESS_TOKEN)</string>
```

Expected: `Info.plist` has no callback registration and no removed service credential keys.

- [ ] **Step 9: Remove service credentials from Secrets template**

Replace `Configuration/Secrets.xcconfig.template` with:

```text
// Local developer secrets template
// Petrichor currently has no runtime online music-service credentials.
```

Expected: the template no longer references Last.fm or TMDB.

- [ ] **Step 10: Verify Last.fm removal compiles at the text level**

Run:

```bash
rg -n 'ScrobbleManager|scrobbleManager|lastfm|Last\.fm|LASTFM|KeychainManager|URLSchemeHandler|IntegrationsTabView|CFBundleURLTypes|TMDB_READ_ACCESS_TOKEN' Application Managers Views Utilities Configuration PetrichorApp.swift
```

Expected: no output.

- [ ] **Step 11: Commit Last.fm and settings removal**

Run:

```bash
git add Application/AppCoordinator.swift Application/AppDelegate.swift Managers/PlaybackManager.swift Views/Settings/SettingsView.swift Views/Settings/LibraryTabView.swift Utilities/DiagnosticSnapshot.swift Configuration/Info.plist Configuration/Secrets.xcconfig.template
git add -u Managers/ScrobbleManager.swift Utilities/URLSchemeHandler.swift Utilities/KeychainManager.swift Views/Settings/IntegrationsTabView.swift
git commit -m "remove lastfm integration"
```

Expected: commit succeeds.

### Task 3: Remove Online Lyrics, Online Artwork, And Artist-Image Downloads

**Files:**
- Delete: `Managers/LyricsManager.swift`
- Delete: `Managers/TrackArtworkDownloadManager.swift`
- Delete: `Managers/ArtistImageDownloadManager.swift`
- Delete: `Core/LyricsSidecarWriter.swift`
- Delete: `Core/Artwork/TrackArtworkSidecarWriter.swift`
- Modify: `Core/LyricsLoader.swift`
- Modify: `Core/Artwork/ArtworkResolver.swift`
- Modify: `Views/Components/Artwork/AsyncArtworkImage.swift`
- Modify: `Managers/Library/LMLibrary.swift`
- Modify: `Core/ArtistImageStore.swift`
- Modify: `Utilities/Constants.swift`
- Modify: `Utilities/AppInfo.swift`

- [ ] **Step 1: Delete online download managers and write helpers**

Run:

```bash
rm Managers/LyricsManager.swift Managers/TrackArtworkDownloadManager.swift Managers/ArtistImageDownloadManager.swift Core/LyricsSidecarWriter.swift Core/Artwork/TrackArtworkSidecarWriter.swift
```

Expected: command exits 0.

- [ ] **Step 2: Make LyricsLoader local-only**

In `Core/LyricsLoader.swift`, remove this online fallback block:

```swift
// 3. Online lyrics
if lines == nil,
   let fullTrack = fullTrack,
   let onlineText = await LyricsManager.shared.fetchLyrics(for: fullTrack) {
    lines = parseAnyLyrics(onlineText)
    source = .online
}
```

Change this comment:

```swift
// Attempt LRC parsing (covers embedded/online that already have timestamps)
```

to:

```swift
// Attempt LRC parsing first, covering external and embedded timestamped lyrics.
```

Remove the enum case:

```swift
case online
```

Expected: `LyricsSource` contains only `lrc`, `srt`, `embedded`, and `none`.

- [ ] **Step 3: Make ArtworkResolver local-only**

In `Core/Artwork/ArtworkResolver.swift`, replace the end of `artworkData(for:)`:

```swift
if let genericURL = externalArtworkURL(for: request.audioURL, kind: .generic),
   let generic = cachedOrFileArtwork(for: request, fileURL: genericURL) {
    return generic
}

return await downloadedArtworkData(for: request)
```

with:

```swift
if let genericURL = externalArtworkURL(for: request.audioURL, kind: .generic),
   let generic = cachedOrFileArtwork(for: request, fileURL: genericURL) {
    return generic
}

return nil
```

Delete the entire `downloadedArtworkData(for:)` method:

```swift
private func downloadedArtworkData(for request: ArtworkRequest) async -> Data? {
    guard let fullTrack = await AppCoordinator.shared?.libraryManager.databaseManager.fullTrack(forAudioURL: request.audioURL) else {
        return nil
    }

    guard let result = await TrackArtworkDownloadManager.shared.downloadArtwork(for: fullTrack) else {
        return nil
    }

    if let sidecarURL = result.sidecarURL,
       let data = cachedOrFileArtwork(for: request, fileURL: sidecarURL) {
        return data
    }

    if let displayData = result.displayData {
        return displayData
    }

    return nil
}
```

Expected: `Core/Artwork/ArtworkResolver.swift` no longer references `TrackArtworkDownloadManager` or `downloadedArtworkData`.

- [ ] **Step 4: Remove online sidecar notification listener from AsyncArtworkImage**

In `Views/Components/Artwork/AsyncArtworkImage.swift`, remove the `reloadToken` state:

```swift
@State private var reloadToken = 0
```

Remove this `.onReceive` modifier from `body`:

```swift
.onReceive(NotificationCenter.default.publisher(for: .trackArtworkSidecarDidChange)) { notification in
    guard let changedURL = notification.object as? URL,
          let request,
          changedURL.standardizedFileURL.path == request.audioURL.standardizedFileURL.path else {
        return
    }

    reloadToken &+= 1
}
```

Change `taskID` from:

```swift
return "\(request.kind.rawValue)-\(request.identity)-\(request.audioURL.path)-\(reloadToken)"
```

to:

```swift
return "\(request.kind.rawValue)-\(request.identity)-\(request.audioURL.path)"
```

Expected: `AsyncArtworkImage` has no `trackArtworkSidecarDidChange` dependency.

- [ ] **Step 5: Remove library-load artist image download pass**

In `Managers/Library/LMLibrary.swift`, remove:

```swift
ArtistImageDownloadManager.shared.downloadMissingArtistImages(using: self)
```

Expected: library load still posts `LibraryDidLoad` and refreshes entities, but does not start a download task.

- [ ] **Step 6: Remove downloader-only write helpers from ArtistImageStore**

In `Core/ArtistImageStore.swift`, remove these declarations:

```swift
static func preferredImageURL(artistName: String, musicRoot: URL) -> URL {
    imageDirectory(forMusicRoot: musicRoot)
        .appendingPathComponent(sanitizedArtistFilename(artistName))
        .appendingPathExtension(preferredImageExtension)
}
```

```swift
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
```

```swift
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
```

Also remove:

```swift
private static let preferredImageExtension = "jpg"
```

Expected: `ArtistImageStore` still provides `imageData`, `versionedImageData`, `existingImageURL`, `imageDirectory`, `musicRoot`, and `sanitizedArtistFilename`.

- [ ] **Step 7: Remove unused notification and network helpers**

In `Utilities/Constants.swift`, remove:

```swift
static let trackArtworkSidecarDidChange = Notification.Name("TrackArtworkSidecarDidChange")
```

Keep:

```swift
static let artistImagesDidChange = Notification.Name("ArtistImagesDidChange")
```

because local artist image views still subscribe to it.

In `Utilities/AppInfo.swift`, remove:

```swift
static let userAgent = "\(About.appTitle)/\(AppInfo.version) (\(About.appWebsite))"
```

and the whole networking block:

```swift
// MARK: - Networking

static let urlSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 30
    return URLSession(configuration: config)
}()
```

Expected: `AppInfo` no longer imports or exposes app-owned networking helpers.

- [ ] **Step 8: Verify local-only runtime references**

Run:

```bash
rg -n 'LyricsManager|TrackArtworkDownloadManager|ArtistImageDownloadManager|LyricsSidecarWriter|TrackArtworkSidecarWriter|trackArtworkSidecarDidChange|online lyrics|Online lyrics|LRCLIB|lrclib|MusicBrainz error|Cover Art Archive|coverartarchive|Wikidata|Wikimedia|artistImageDownloadEnabled|trackArtworkDownloadEnabled|onlineLyricsEnabled|AppInfo\.urlSession|AppInfo\.userAgent' Application Managers Views Core Utilities Models PetrichorApp.swift
```

Expected: no output, except `MusicBrainz` comments or model fields are acceptable only if they refer to embedded metadata and are not matched by this command.

- [ ] **Step 9: Commit local-only runtime flow**

Run:

```bash
git add Core/LyricsLoader.swift Core/Artwork/ArtworkResolver.swift Views/Components/Artwork/AsyncArtworkImage.swift Managers/Library/LMLibrary.swift Core/ArtistImageStore.swift Utilities/Constants.swift Utilities/AppInfo.swift
git add -u Managers/LyricsManager.swift Managers/TrackArtworkDownloadManager.swift Managers/ArtistImageDownloadManager.swift Core/LyricsSidecarWriter.swift Core/Artwork/TrackArtworkSidecarWriter.swift
git commit -m "remove online lyrics and artwork downloads"
```

Expected: commit succeeds.

### Task 4: Update Tests For Local-Only Behavior

**Files:**
- Modify: `Scripts/test-artwork-resolver-priority.sh`
- Delete: `Scripts/test-online-lyrics-sidecar.sh`
- Delete: `Scripts/test-track-artwork-download.sh`
- Delete: `Scripts/test-artist-image-sidecar-download.sh`
- Delete: `Scripts/test-track-artwork-sidecar.sh`

- [ ] **Step 1: Update artwork resolver priority script**

In `Scripts/test-artwork-resolver-priority.sh`, replace the first pattern loop with:

```bash
for pattern in \
  'MetadataEngine\.extractEmbeddedArtwork\(' \
  'ExternalArtworkResolver\.sameStemArtworkURL\(forAudioURL:' \
  'ExternalArtworkResolver\.genericArtworkURL\(forAudioURL:' \
  'cache\.store\(data, for: key\)'; do
  if ! rg -n "$pattern" "$resolver" >/dev/null; then
    printf 'ArtworkResolver missing expected pattern: %s\n' "$pattern" >&2
    exit 1
  fi
done
```

Replace the Python `patterns` array with:

```python
patterns = [
    "cachedOrEmbeddedArtwork",
    "sameStemArtworkURL",
    "genericArtworkURL"
]
```

Replace the order error message with:

```python
raise SystemExit("ArtworkResolver source order must be embedded, same-stem, generic")
```

Add this shell check after the Python block:

```bash
if rg -n 'TrackArtworkDownloadManager|downloadedArtworkData|downloadArtwork\(for:' "$resolver" >/dev/null; then
    printf 'ArtworkResolver still contains online artwork fallback.\n' >&2
    exit 1
fi
```

Expected: the script asserts embedded, same-stem, generic local artwork only.

- [ ] **Step 2: Delete obsolete online-feature scripts**

Run:

```bash
rm Scripts/test-online-lyrics-sidecar.sh Scripts/test-track-artwork-download.sh Scripts/test-artist-image-sidecar-download.sh Scripts/test-track-artwork-sidecar.sh
```

Expected: command exits 0.

- [ ] **Step 3: Run updated tests and removal guard**

Run:

```bash
Scripts/test-artwork-resolver-priority.sh
Scripts/test-online-services-removed.sh
```

Expected: both scripts exit 0 after Tasks 2 and 3 are complete.

- [ ] **Step 4: Commit test updates**

Run:

```bash
git add Scripts/test-artwork-resolver-priority.sh Scripts/test-online-services-removed.sh
git add -u Scripts/test-online-lyrics-sidecar.sh Scripts/test-track-artwork-download.sh Scripts/test-artist-image-sidecar-download.sh Scripts/test-track-artwork-sidecar.sh
git commit -m "test: enforce local-only media services"
```

Expected: commit succeeds.

### Task 5: Clean Localization, Assets, And Docs

**Files:**
- Modify: `Resources/Localizable.xcstrings`
- Delete: `Resources/Assets.xcassets/logo-lastfm.imageset`
- Delete: `Resources/Assets.xcassets/logo-musicbrainz.imageset`
- Delete: `Resources/Assets.xcassets/logo-tmdb.imageset`
- Delete: `Resources/Assets.xcassets/logo-wikidata.imageset`
- Modify: `ACKNOWLEDGEMENTS.md`
- Modify: `README.md`
- Modify: `docs/LOCALIZATION.md`

- [ ] **Step 1: Remove deleted-service localized strings with a parser**

Run this script from the repository root:

```bash
python3 - <<'PY'
import json
from pathlib import Path

path = Path("Resources/Localizable.xcstrings")
data = json.loads(path.read_text())

keys_to_remove = {
    "Automatically search for lyrics online when no local lyrics are found",
    "Automatically search for cover artwork online when no local artwork is found",
    "Automatically save downloaded artist images in each music folder's artist images folder",
    "Connect your Last.fm account to start scrobbling",
    "Connected to Last.fm as %@",
    "Disconnect from Last.fm?",
    "Disconnected from Last.fm",
    "Download artist images to music folders",
    "Enable scrobbling",
    "Failed to connect to Last.fm",
    "Fetch artwork from internet when unavailable",
    "Fetch lyrics from internet when unavailable",
    "Integrations",
    "Last.fm",
    "Last.fm API credentials not configured",
    "Last.fm API key not configured",
    "Last.fm authorization failed: missing token",
    "Last.fm error: %@",
    "Lyrics & Metadata",
    "Not connected",
    "Track your listening history on Last.fm",
    "Your listening activity will no longer be scrobbled to Last.fm once you disconnect.",
}

for key in keys_to_remove:
    data["strings"].pop(key, None)

path.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=False) + "\n")
PY
```

Expected: command exits 0 and removes only the listed keys.

- [ ] **Step 2: Delete unused service logo asset directories**

Run:

```bash
rm -r Resources/Assets.xcassets/logo-lastfm.imageset Resources/Assets.xcassets/logo-musicbrainz.imageset Resources/Assets.xcassets/logo-tmdb.imageset Resources/Assets.xcassets/logo-wikidata.imageset
```

Expected: command exits 0.

- [ ] **Step 3: Remove removed services from acknowledgements**

In `ACKNOWLEDGEMENTS.md`, delete the online database/services section entries for:

```markdown
- **MusicBrainz** - https://musicbrainz.org/
- **Wikidata / Wikimedia Commons** - https://www.wikidata.org/
- **TMDB (The Movie Database)** - https://www.themoviedb.org/
- **Last.fm** - https://www.last.fm/
- **LRCLIB** - https://lrclib.net/
```

Keep acknowledgements for actual bundled dependencies such as SFBAudioEngine, GRDB, FFmpeg, and TagLib.

Expected: `ACKNOWLEDGEMENTS.md` no longer claims runtime use of removed online services.

- [ ] **Step 4: Remove Last.fm claims from README**

In `README.md`, remove the feature bullet:

```markdown
- Last.fm scrobbling support
```

Also remove the privacy subsection:

```markdown
- Last.fm scrobbling (disabled by default)
    - When enabled, app may ask to store your Last.fm session information in macOS Keychain, if you choose to allow it, macOS will ask for your user account password to store the information in Keychain.
    - App **does not** store your Last.fm username or password, you still have to provide it on Last.fm website that opens in browser during configuration, once done, app only receives a session key to scrobble track playbacks with your account.
```

Expected: `README.md` no longer advertises Last.fm support.

- [ ] **Step 5: Update localization guidance examples**

In `docs/LOCALIZATION.md`, replace:

```markdown
5. **Don't translate** brand names and proper nouns (e.g. `Last.fm`,
   `MusicBrainz`, `Petrichor`). Right-click such a string and choose
```

with:

```markdown
5. **Don't translate** brand names and proper nouns (e.g. `Petrichor`).
   Right-click such a string and choose
```

Expected: localization docs no longer use removed services as examples.

- [ ] **Step 6: Verify removed strings and assets**

Run:

```bash
rg -n 'Last\.fm|LRCLIB|lrclib|MusicBrainz|Wikidata|Wikimedia|TMDB|Fetch lyrics from internet|Fetch artwork from internet|Download artist images to music folders|Lyrics & Metadata|Integrations' Resources/Localizable.xcstrings ACKNOWLEDGEMENTS.md README.md docs/LOCALIZATION.md Resources/Assets.xcassets
```

Expected: no output from these app-facing resources. Mentions in old `docs/superpowers` specs and plans are allowed because they are historical design records and are not included in this command.

- [ ] **Step 7: Commit localization, asset, and docs cleanup**

Run:

```bash
git add Resources/Localizable.xcstrings ACKNOWLEDGEMENTS.md README.md docs/LOCALIZATION.md
git add -u Resources/Assets.xcassets/logo-lastfm.imageset Resources/Assets.xcassets/logo-musicbrainz.imageset Resources/Assets.xcassets/logo-tmdb.imageset Resources/Assets.xcassets/logo-wikidata.imageset
git commit -m "docs: remove online service references"
```

Expected: commit succeeds.

### Task 6: Final Verification And Build

**Files:**
- No new source files.
- Verification-only task.

- [ ] **Step 1: Run the removal guard**

Run:

```bash
Scripts/test-online-services-removed.sh
```

Expected: PASS with `Online music services removed`.

- [ ] **Step 2: Run retained local lyrics and artwork checks**

Run:

```bash
Scripts/test-desktop-lyrics-line-selection.sh
Scripts/test-external-artwork-priority.sh
Scripts/test-artwork-resolver-priority.sh
Scripts/test-ui-artwork-resolver.sh
```

Expected: all commands exit 0.

- [ ] **Step 3: Run localization format check**

Run:

```bash
Scripts/test-localization-format-specifiers.sh
```

Expected: command exits 0.

- [ ] **Step 4: Run a broad source scan for removed runtime services**

Run:

```bash
rg -n 'ScrobbleManager|LyricsManager|TrackArtworkDownloadManager|ArtistImageDownloadManager|IntegrationsTabView|URLSchemeHandler|KeychainManager|LyricsSidecarWriter|TrackArtworkSidecarWriter|lastfmUsername|lastfmAvatarData|scrobblingEnabled|onlineLyricsEnabled|trackArtworkDownloadEnabled|artistImageDownloadEnabled|lastfm-callback|LASTFM_API_KEY|LASTFM_SHARED_SECRET|TMDB_READ_ACCESS_TOKEN|https://(lrclib\.net/api|ws\.audioscrobbler\.com/2\.0|www\.last\.fm/api|musicbrainz\.org/ws/2|coverartarchive\.org|www\.wikidata\.org/w/api\.php|upload\.wikimedia\.org/wikipedia/commons)' Application Managers Views Core Utilities Models Configuration Resources/Localizable.xcstrings PetrichorApp.swift
```

Expected: no output.

- [ ] **Step 5: Build the app**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: build succeeds.

- [ ] **Step 6: Check git status**

Run:

```bash
git status --short
```

Expected: no unstaged changes from this task. If unrelated user changes are present, leave them untouched and mention them in the handoff.

- [ ] **Step 7: Handle verification failures**

If any command in this task fails, return to the task that owns the failing file
or behavior, apply the correction there, rerun that task's verification step,
and amend or create the task-specific commit described in that task. Do not
create a catch-all verification commit from this final task.

Expected: final verification ends with all checks passing and no catch-all
cleanup commit.

## Manual QA Checklist

- Settings shows General, Appearance, Library, and About tabs only.
- Starting playback does not mention scrobbling in logs.
- Finishing a track still increments local play count and last-played metadata.
- A track with a same-stem `.lrc` or `.srt` still shows lyrics.
- A track with embedded lyrics still shows lyrics.
- A track with embedded artwork still shows artwork.
- A track with same-stem or generic folder artwork still shows artwork.
- Existing local `artist images` files still display in artist grid and detail views.
