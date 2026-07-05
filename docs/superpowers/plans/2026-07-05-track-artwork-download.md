# Track Artwork Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in, lazy track artwork downloader that writes same-stem `.jpg` sidecars only when embedded, same-stem, and generic local artwork are all unavailable.

**Architecture:** Keep `ArtworkResolver` as the single runtime artwork boundary. Add a focused `TrackArtworkDownloadManager` for MusicBrainz/Cover Art Archive lookup and sidecar writes, plus small helpers for same-stem artwork selection and database metadata lookup. The resolver keeps all UI callers lazy and uses notifications only to refresh visible artwork after a sidecar file appears.

**Tech Stack:** Swift, SwiftUI, AppKit, Foundation `URLSession`, GRDB, shell regression scripts, `xcodebuild`.

---

## File Structure

- Create `Core/Artwork/TrackArtworkSidecarWriter.swift`
  - Owns preferred same-stem `.jpg` destination, existing same-stem artwork detection, and non-overwriting sidecar writes.
- Modify `Core/Metadata/ExternalArtworkResolver.swift`
  - Expose same-stem and generic artwork lookup separately while preserving the existing combined `artworkURL` API.
- Create `Managers/TrackArtworkDownloadManager.swift`
  - Owns opt-in state, MusicBrainz/Cover Art Archive lookup, request serialization, single-flight behavior, image conversion, and sidecar writes.
- Modify `Managers/Database/DMQueries.swift`
  - Add a narrow async `FullTrack` lookup by audio URL path for resolver-triggered downloads.
- Modify `Core/Artwork/ArtworkResolver.swift`
  - Enforce source order: embedded, same-stem file, generic folder file, online sidecar. Keep cache writes centralized.
- Modify `Utilities/Constants.swift`
  - Add `Notification.Name.trackArtworkSidecarDidChange`.
- Modify `Views/Components/Artwork/AsyncArtworkImage.swift`
  - Refresh an already-visible artwork view when its audio URL gets a newly written sidecar.
- Modify `Views/Settings/IntegrationsTabView.swift`
  - Add the opt-in toggle under `Lyrics & Metadata`.
- Modify `Utilities/DiagnosticSnapshot.swift`
  - Include the new preference in diagnostics.
- Modify `Resources/Localizable.xcstrings`
  - Add English and Chinese strings for the toggle and help text.
- Modify `Scripts/test-external-artwork-priority.sh`
  - Cover the new same-stem and generic resolver entry points.
- Modify `Scripts/test-artwork-resolver-priority.sh`
  - Enforce resolver source order and downloader hook.
- Create `Scripts/test-track-artwork-sidecar.sh`
  - Verify sidecar naming and no-overwrite behavior.
- Create `Scripts/test-track-artwork-download.sh`
  - Verify manager structure, no database artwork writes, URLSession/User-Agent usage, rate limiting, and setting/diagnostic wiring.

`Petrichor.xcodeproj` uses `PBXFileSystemSynchronizedRootGroup`, so adding Swift files under existing synchronized folders does not require project metadata edits.

## Task 1: Split External Artwork Lookup

**Files:**
- Modify: `Core/Metadata/ExternalArtworkResolver.swift`
- Modify: `Scripts/test-external-artwork-priority.sh`

- [ ] **Step 1: Extend the failing script**

Add these guards to the Swift block in `Scripts/test-external-artwork-priority.sh`, after `let candidates = ...` and before the existing combined-priority guards:

```swift
guard ExternalArtworkResolver.sameStemArtworkURL(forAudioURL: song, candidates: candidates) == songJPG else {
    fputs("Same-stem artwork helper should use extension priority\n", stderr)
    exit(1)
}

guard ExternalArtworkResolver.sameStemArtworkURL(forAudioURL: neighbor, candidates: candidates) == nil else {
    fputs("Same-stem artwork helper should ignore generic artwork\n", stderr)
    exit(1)
}

guard ExternalArtworkResolver.genericArtworkURL(forAudioURL: neighbor, candidates: candidates) == cover else {
    fputs("Generic artwork helper should choose cover artwork first\n", stderr)
    exit(1)
}

guard ExternalArtworkResolver.genericArtworkURL(forAudioURL: song, candidates: candidates) == cover else {
    fputs("Generic artwork helper should be available separately even when same-stem artwork exists\n", stderr)
    exit(1)
}
```

- [ ] **Step 2: Run the script and verify it fails**

Run:

```bash
Scripts/test-external-artwork-priority.sh
```

Expected: compile failure mentioning `type 'ExternalArtworkResolver' has no member 'sameStemArtworkURL'`.

- [ ] **Step 3: Implement the split helper API**

Replace `Core/Metadata/ExternalArtworkResolver.swift` with:

```swift
import Foundation

enum ExternalArtworkResolver {
    private static let genericArtworkNames: [String] = uniqueLowercaseValues(
        AlbumArtFormat.knownFilenames
    )
    private static let extensionPriority: [String] = uniqueLowercaseValues(
        AlbumArtFormat.supportedExtensions
    )

    static func artworkURL(forAudioURL audioURL: URL, candidates: [URL]) -> URL? {
        sameStemArtworkURL(forAudioURL: audioURL, candidates: candidates)
            ?? genericArtworkURL(forAudioURL: audioURL, candidates: candidates)
    }

    static func sameStemArtworkURL(forAudioURL audioURL: URL, candidates: [URL]) -> URL? {
        let audioStem = normalizedStem(audioURL)
        let sameNameCandidates = supportedCandidates(forAudioURL: audioURL, candidates: candidates)
            .filter { normalizedStem($0) == audioStem }
        return preferredArtworkURL(from: sameNameCandidates)
    }

    static func genericArtworkURL(forAudioURL audioURL: URL, candidates: [URL]) -> URL? {
        let genericCandidates = supportedCandidates(forAudioURL: audioURL, candidates: candidates)
            .filter { genericArtworkNames.contains(normalizedStem($0)) }
        return preferredArtworkURL(from: genericCandidates)
    }

    private static func supportedCandidates(forAudioURL audioURL: URL, candidates: [URL]) -> [URL] {
        let directoryPath = audioURL.deletingLastPathComponent().standardizedFileURL.path
        return candidates.filter { candidate in
            AlbumArtFormat.isSupported(candidate.pathExtension)
                && candidate.deletingLastPathComponent().standardizedFileURL.path == directoryPath
        }
    }

    private static func preferredArtworkURL(from candidates: [URL]) -> URL? {
        candidates.sorted { lhs, rhs in
            let lhsNamePriority = artworkNamePriority(lhs)
            let rhsNamePriority = artworkNamePriority(rhs)
            if lhsNamePriority != rhsNamePriority {
                return lhsNamePriority < rhsNamePriority
            }

            let lhsExtensionPriority = fileExtensionPriority(lhs)
            let rhsExtensionPriority = fileExtensionPriority(rhs)
            if lhsExtensionPriority != rhsExtensionPriority {
                return lhsExtensionPriority < rhsExtensionPriority
            }

            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }.first
    }

    private static func artworkNamePriority(_ url: URL) -> Int {
        genericArtworkNames.firstIndex(of: normalizedStem(url)) ?? 0
    }

    private static func fileExtensionPriority(_ url: URL) -> Int {
        extensionPriority.firstIndex(of: url.pathExtension.lowercased()) ?? Int.max
    }

    private static func normalizedStem(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.lowercased()
    }

    private static func uniqueLowercaseValues(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for value in values {
            let normalized = value.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }

        return result
    }
}
```

- [ ] **Step 4: Run the script and verify it passes**

Run:

```bash
Scripts/test-external-artwork-priority.sh
```

Expected: `External artwork priority preserved`.

- [ ] **Step 5: Commit**

```bash
git add Core/Metadata/ExternalArtworkResolver.swift Scripts/test-external-artwork-priority.sh
git commit -m "refactor: split external artwork lookup"
```

## Task 2: Add Track Artwork Sidecar Writer

**Files:**
- Create: `Core/Artwork/TrackArtworkSidecarWriter.swift`
- Create: `Scripts/test-track-artwork-sidecar.sh`

- [ ] **Step 1: Write the failing sidecar script**

Create `Scripts/test-track-artwork-sidecar.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

helper="Core/Artwork/TrackArtworkSidecarWriter.swift"

if [[ ! -f "$helper" ]]; then
    printf 'Missing %s\n' "$helper" >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/main.swift" <<'SWIFT'
import Foundation

enum AlbumArtFormat {
    static let supportedExtensions = ["jpg", "jpeg", "png", "tiff", "tif", "bmp"]

    static func isSupported(_ fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension.lowercased())
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let audioURL = root.appendingPathComponent("Artist - Song.flac")
let jpgURL = root.appendingPathComponent("Artist - Song.jpg")
let pngURL = root.appendingPathComponent("Artist - Song.png")
let genericURL = root.appendingPathComponent("cover.jpg")

FileManager.default.createFile(atPath: audioURL.path, contents: Data(), attributes: nil)
FileManager.default.createFile(atPath: genericURL.path, contents: Data([9]), attributes: nil)

guard TrackArtworkSidecarWriter.preferredSidecarURL(forAudioURL: audioURL) == jpgURL else {
    fputs("Downloaded track artwork should be saved beside the audio as a same-stem .jpg\n", stderr)
    exit(1)
}

guard TrackArtworkSidecarWriter.existingSameStemArtworkURL(forAudioURL: audioURL) == nil else {
    fputs("Generic artwork must not count as same-stem artwork\n", stderr)
    exit(1)
}

try TrackArtworkSidecarWriter.write(Data([1, 2, 3]), forAudioURL: audioURL)
guard (try Data(contentsOf: jpgURL)) == Data([1, 2, 3]) else {
    fputs("Sidecar writer did not persist the downloaded image data\n", stderr)
    exit(1)
}

try TrackArtworkSidecarWriter.write(Data([4, 5, 6]), forAudioURL: audioURL)
guard (try Data(contentsOf: jpgURL)) == Data([1, 2, 3]) else {
    fputs("Sidecar writer must not overwrite existing same-stem artwork\n", stderr)
    exit(1)
}

try FileManager.default.removeItem(at: jpgURL)
FileManager.default.createFile(atPath: pngURL.path, contents: Data([7]), attributes: nil)
try TrackArtworkSidecarWriter.write(Data([8]), forAudioURL: audioURL)
guard !FileManager.default.fileExists(atPath: jpgURL.path) else {
    fputs("Sidecar writer must not create .jpg when another same-stem artwork file exists\n", stderr)
    exit(1)
}

guard TrackArtworkSidecarWriter.existingSameStemArtworkURL(forAudioURL: audioURL) == pngURL else {
    fputs("Existing same-stem artwork detection should respect supported extension priority\n", stderr)
    exit(1)
}

print("Track artwork sidecar persistence preserved")
SWIFT

swiftc "$helper" "$tmpdir/main.swift" -o "$tmpdir/test-track-artwork-sidecar"
"$tmpdir/test-track-artwork-sidecar" "$tmpdir"
```

Make it executable:

```bash
chmod +x Scripts/test-track-artwork-sidecar.sh
```

- [ ] **Step 2: Run the script and verify it fails**

Run:

```bash
Scripts/test-track-artwork-sidecar.sh
```

Expected: `Missing Core/Artwork/TrackArtworkSidecarWriter.swift`.

- [ ] **Step 3: Implement the sidecar writer**

Create `Core/Artwork/TrackArtworkSidecarWriter.swift`:

```swift
import Foundation

enum TrackArtworkSidecarWriter {
    static func preferredSidecarURL(forAudioURL audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("jpg")
    }

    static func existingSameStemArtworkURL(
        forAudioURL audioURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let baseURL = audioURL.deletingPathExtension()

        for fileExtension in AlbumArtFormat.supportedExtensions {
            let candidate = baseURL.appendingPathExtension(fileExtension)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    @discardableResult
    static func write(
        _ artwork: Data,
        forAudioURL audioURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let existing = existingSameStemArtworkURL(forAudioURL: audioURL, fileManager: fileManager) {
            return existing
        }

        let sidecarURL = preferredSidecarURL(forAudioURL: audioURL)
        try artwork.write(to: sidecarURL, options: [.atomic])
        return sidecarURL
    }
}
```

- [ ] **Step 4: Run the script and verify it passes**

Run:

```bash
Scripts/test-track-artwork-sidecar.sh
```

Expected: `Track artwork sidecar persistence preserved`.

- [ ] **Step 5: Commit**

```bash
git add Core/Artwork/TrackArtworkSidecarWriter.swift Scripts/test-track-artwork-sidecar.sh
git commit -m "feat: add track artwork sidecar writer"
```

## Task 3: Add FullTrack Lookup By Audio URL

**Files:**
- Modify: `Managers/Database/DMQueries.swift`
- Create: `Scripts/test-track-artwork-download.sh`

- [ ] **Step 1: Write the failing structural script**

Create `Scripts/test-track-artwork-download.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

manager="Managers/TrackArtworkDownloadManager.swift"
queries="Managers/Database/DMQueries.swift"
resolver="Core/Artwork/ArtworkResolver.swift"
settings="Views/Settings/IntegrationsTabView.swift"
diagnostics="Utilities/DiagnosticSnapshot.swift"
strings="Resources/Localizable.xcstrings"

if ! rg -n "func fullTrack\\(forAudioURL url: URL\\) async -> FullTrack\\?" "$queries" >/dev/null; then
    echo "DatabaseManager must expose a narrow FullTrack lookup by audio URL." >&2
    exit 1
fi

if ! rg -n "FullTrack\\.Columns\\.path == url\\.path" "$queries" >/dev/null; then
    echo "FullTrack lookup must query by the stored audio path." >&2
    exit 1
fi

if [[ ! -f "$manager" ]]; then
    echo "Missing TrackArtworkDownloadManager." >&2
    exit 1
fi

for pattern in \
  "actor TrackArtworkDownloadManager" \
  "static let shared = TrackArtworkDownloadManager" \
  "trackArtworkDownloadEnabled" \
  "https://musicbrainz.org/ws/2/release/" \
  "https://coverartarchive.org" \
  "AppInfo\\.urlSession\\.data\\(for: request\\)" \
  "request\\.setValue\\(AppInfo\\.userAgent, forHTTPHeaderField: \"User-Agent\"\\)" \
  "TrackArtworkSidecarWriter\\.write" \
  "ImageUtils\\.encodeJPEG" \
  "inFlight" \
  "waitForRateLimit"; do
  if ! rg -n "$pattern" "$manager" >/dev/null; then
    echo "TrackArtworkDownloadManager missing expected pattern: $pattern" >&2
    exit 1
  fi
done

if rg -n "updateTrack|artwork_data|trackArtworkData|albumArtworkData|cover_artwork_data" "$manager" >/dev/null; then
    echo "Track artwork downloader must not write artwork through the database or model blobs." >&2
    exit 1
fi

for pattern in \
  "MetadataEngine\\.extractEmbeddedArtwork" \
  "ExternalArtworkResolver\\.sameStemArtworkURL" \
  "ExternalArtworkResolver\\.genericArtworkURL" \
  "TrackArtworkDownloadManager\\.shared\\.downloadArtwork" \
  "fullTrack\\(forAudioURL:" \
  "trackArtworkSidecarDidChange"; do
  if ! rg -n "$pattern" "$resolver" >/dev/null; then
    echo "ArtworkResolver missing expected pattern: $pattern" >&2
    exit 1
  fi
done

if ! rg -n "@AppStorage\\(\"trackArtworkDownloadEnabled\"\\)" "$settings" >/dev/null; then
    echo "Missing track artwork download setting." >&2
    exit 1
fi

if ! rg -n "Fetch artwork from internet when unavailable" "$settings" >/dev/null; then
    echo "Settings UI does not expose online track artwork downloads." >&2
    exit 1
fi

if ! rg -n "trackArtworkDownloadEnabled" "$diagnostics" >/dev/null; then
    echo "Diagnostics must include the track artwork download preference." >&2
    exit 1
fi

for pattern in \
  "\"Fetch artwork from internet when unavailable\"" \
  "\"没有封面时从互联网获取\"" \
  "\"Automatically search for cover artwork online when no local artwork is found\"" \
  "\"找不到本地封面时自动在线搜索封面\""; do
  if ! rg -n "$pattern" "$strings" >/dev/null; then
    echo "Missing localized track artwork setting pattern: $pattern" >&2
    exit 1
  fi
done
```

Make it executable:

```bash
chmod +x Scripts/test-track-artwork-download.sh
```

- [ ] **Step 2: Run the script and verify it fails on the database lookup**

Run:

```bash
Scripts/test-track-artwork-download.sh
```

Expected: `DatabaseManager must expose a narrow FullTrack lookup by audio URL.`

- [ ] **Step 3: Add the database lookup**

Add this method near the other track lookup methods in `Managers/Database/DMQueries.swift`, after `getTracksWithArtwork(byIds:)`:

```swift
    /// Fetch the complete FullTrack record for a source audio URL.
    func fullTrack(forAudioURL url: URL) async -> FullTrack? {
        do {
            return try await dbQueue.read { db in
                try FullTrack
                    .filter(FullTrack.Columns.path == url.path)
                    .fetchOne(db)
            }
        } catch {
            Logger.error("Failed to fetch full track for artwork lookup: \(error)")
            return nil
        }
    }
```

- [ ] **Step 4: Run the script and verify the next expected failure**

Run:

```bash
Scripts/test-track-artwork-download.sh
```

Expected: `Missing TrackArtworkDownloadManager.`

- [ ] **Step 5: Commit**

```bash
git add Managers/Database/DMQueries.swift Scripts/test-track-artwork-download.sh
git commit -m "feat: add artwork metadata lookup"
```

## Task 4: Add Track Artwork Download Manager

**Files:**
- Create: `Managers/TrackArtworkDownloadManager.swift`
- Modify: `Scripts/test-track-artwork-download.sh`

- [ ] **Step 1: Confirm the structural script fails on the missing manager**

Run:

```bash
Scripts/test-track-artwork-download.sh
```

Expected: `Missing TrackArtworkDownloadManager.`

- [ ] **Step 2: Implement the download manager**

Create `Managers/TrackArtworkDownloadManager.swift`:

```swift
import AppKit
import Foundation

actor TrackArtworkDownloadManager {
    static let shared = TrackArtworkDownloadManager()
    static let trackArtworkDownloadEnabledKey = "trackArtworkDownloadEnabled"

    private enum MusicBrainz {
        static let releaseSearchURL = "https://musicbrainz.org/ws/2/release/"
        static let rateLimitDelay: TimeInterval = 1.1
    }

    private enum CoverArtArchive {
        static let baseURL = "https://coverartarchive.org"
        static let rateLimitDelay: TimeInterval = 0.25
    }

    private let fileManager: FileManager
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var lastMusicBrainzRequest: Date?
    private var lastCoverArtRequest: Date?

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.trackArtworkDownloadEnabledKey)
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func downloadArtwork(for fullTrack: FullTrack) async -> URL? {
        guard isEnabled else { return nil }
        guard isValidForArtworkFetch(fullTrack) else { return nil }

        let audioURL = fullTrack.url
        let key = audioURL.standardizedFileURL.path

        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task { [weak self] () -> URL? in
            guard let self else { return nil }
            return await self.performDownload(for: fullTrack)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func performDownload(for fullTrack: FullTrack) async -> URL? {
        if let existing = TrackArtworkSidecarWriter.existingSameStemArtworkURL(
            forAudioURL: fullTrack.url,
            fileManager: fileManager
        ) {
            return existing
        }

        guard let downloaded = await fetchArtwork(for: fullTrack),
              let jpegData = jpegData(from: downloaded) else {
            return nil
        }

        do {
            let destination = try TrackArtworkSidecarWriter.write(
                jpegData,
                forAudioURL: fullTrack.url,
                fileManager: fileManager
            )
            Logger.info("TrackArtworkDownloadManager: wrote \(destination.lastPathComponent)")
            return destination
        } catch {
            Logger.error("TrackArtworkDownloadManager: failed to write artwork sidecar for '\(fullTrack.title)': \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchArtwork(for fullTrack: FullTrack) async -> Data? {
        if let releaseID = fullTrack.extendedMetadata?.musicBrainzAlbumId?.nilIfEmpty,
           let data = await downloadCoverArt(path: "/release/\(releaseID)/front-500") {
            return data
        }

        if let releaseGroupID = fullTrack.extendedMetadata?.musicBrainzReleaseGroupId?.nilIfEmpty,
           let data = await downloadCoverArt(path: "/release-group/\(releaseGroupID)/front-500") {
            return data
        }

        guard let release = await searchMusicBrainzRelease(for: fullTrack) else {
            return nil
        }

        if let data = await downloadCoverArt(path: "/release/\(release.id)/front-500") {
            return data
        }

        if let releaseGroupID = release.releaseGroupID {
            return await downloadCoverArt(path: "/release-group/\(releaseGroupID)/front-500")
        }

        return nil
    }

    private func searchMusicBrainzRelease(for fullTrack: FullTrack) async -> ReleaseMatch? {
        await waitForRateLimit(.musicBrainz)

        guard var components = URLComponents(string: MusicBrainz.releaseSearchURL) else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "query", value: musicBrainzQuery(for: fullTrack)),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "3")
        ]

        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await AppInfo.urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode != 404 {
                    Logger.info("TrackArtworkDownloadManager: MusicBrainz returned status \(httpResponse.statusCode)")
                }
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let releases = json["releases"] as? [[String: Any]] else {
                return nil
            }

            for release in releases {
                guard let id = release["id"] as? String else { continue }
                let releaseGroup = release["release-group"] as? [String: Any]
                let releaseGroupID = releaseGroup?["id"] as? String
                return ReleaseMatch(id: id, releaseGroupID: releaseGroupID)
            }

            return nil
        } catch {
            if !isCancellation(error) {
                Logger.error("TrackArtworkDownloadManager: MusicBrainz error for '\(fullTrack.title)': \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func downloadCoverArt(path: String) async -> Data? {
        await waitForRateLimit(.coverArt)

        guard let url = URL(string: CoverArtArchive.baseURL + path) else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await AppInfo.urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }

            switch httpResponse.statusCode {
            case 200:
                guard data.count > 0, data.count <= AlbumArtFormat.maxArtworkSize else {
                    return nil
                }
                return data
            case 400, 404:
                return nil
            default:
                Logger.info("TrackArtworkDownloadManager: Cover Art Archive returned status \(httpResponse.statusCode)")
                return nil
            }
        } catch {
            if !isCancellation(error) {
                Logger.error("TrackArtworkDownloadManager: cover art download failed for \(path): \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func musicBrainzQuery(for fullTrack: FullTrack) -> String {
        [
            "artist:\"\(escapedQueryValue(fullTrack.artist))\"",
            "release:\"\(escapedQueryValue(fullTrack.album))\"",
            "recording:\"\(escapedQueryValue(fullTrack.title))\""
        ].joined(separator: " AND ")
    }

    private func escapedQueryValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func isValidForArtworkFetch(_ fullTrack: FullTrack) -> Bool {
        let title = fullTrack.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = fullTrack.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = fullTrack.album.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty,
              !artist.isEmpty,
              !album.isEmpty,
              artist != "Unknown Artist",
              album != "Unknown Album" else {
            return false
        }

        return true
    }

    private func jpegData(from data: Data) -> Data? {
        guard data.count > 0, data.count <= AlbumArtFormat.maxArtworkSize else {
            return nil
        }

        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        return ImageUtils.encodeJPEG(cgImage)
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private enum RateLimitBucket {
        case musicBrainz
        case coverArt
    }

    private func waitForRateLimit(_ bucket: RateLimitBucket) async {
        let delay: TimeInterval
        let lastRequest: Date?

        switch bucket {
        case .musicBrainz:
            delay = MusicBrainz.rateLimitDelay
            lastRequest = lastMusicBrainzRequest
        case .coverArt:
            delay = CoverArtArchive.rateLimitDelay
            lastRequest = lastCoverArtRequest
        }

        if let lastRequest {
            let elapsed = Date().timeIntervalSince(lastRequest)
            let waitTime = delay - elapsed
            if waitTime > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
        }

        switch bucket {
        case .musicBrainz:
            lastMusicBrainzRequest = Date()
        case .coverArt:
            lastCoverArtRequest = Date()
        }
    }

    private struct ReleaseMatch {
        let id: String
        let releaseGroupID: String?
    }
}
```

- [ ] **Step 3: Run the structural script and verify the next expected failure**

Run:

```bash
Scripts/test-track-artwork-download.sh
```

Expected: `ArtworkResolver missing expected pattern: ExternalArtworkResolver.sameStemArtworkURL`.

- [ ] **Step 4: Commit**

```bash
git add Managers/TrackArtworkDownloadManager.swift
git commit -m "feat: add track artwork downloader"
```

## Task 5: Wire ArtworkResolver Source Order And Refresh Notification

**Files:**
- Modify: `Core/Artwork/ArtworkResolver.swift`
- Modify: `Utilities/Constants.swift`
- Modify: `Views/Components/Artwork/AsyncArtworkImage.swift`
- Modify: `Scripts/test-artwork-resolver-priority.sh`
- Modify: `Scripts/test-track-artwork-download.sh`

- [ ] **Step 1: Strengthen the resolver priority script**

Replace `Scripts/test-artwork-resolver-priority.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

resolver="Core/Artwork/ArtworkResolver.swift"
engine="Core/Metadata/MetadataEngine.swift"
readers=(Core/Metadata/CrescendoMetadataReader.swift Core/Metadata/SFBMetadataReader.swift)

if ! rg -n 'final class ArtworkResolver|static let shared = ArtworkResolver' "$resolver" >/dev/null; then
    printf 'ArtworkResolver singleton is missing.\n' >&2
    exit 1
fi

for pattern in \
  'MetadataEngine\.extractEmbeddedArtwork\(' \
  'ExternalArtworkResolver\.sameStemArtworkURL\(forAudioURL:' \
  'ExternalArtworkResolver\.genericArtworkURL\(forAudioURL:' \
  'TrackArtworkDownloadManager\.shared\.downloadArtwork\(for:' \
  'cache\.store\(data, for: key\)'; do
  if ! rg -n "$pattern" "$resolver" >/dev/null; then
    printf 'ArtworkResolver missing expected pattern: %s\n' "$pattern" >&2
    exit 1
  fi
done

python3 - <<'PY'
from pathlib import Path
source = Path("Core/Artwork/ArtworkResolver.swift").read_text()
patterns = [
    "cachedOrEmbeddedArtwork",
    "sameStemArtworkURL",
    "genericArtworkURL",
    "downloadArtwork(for:"
]
positions = []
for pattern in patterns:
    idx = source.find(pattern)
    if idx < 0:
        raise SystemExit(f"Missing resolver priority marker: {pattern}")
    positions.append(idx)
if positions != sorted(positions):
    raise SystemExit("ArtworkResolver source order must be embedded, same-stem, generic, online")
PY

if ! rg -n 'func extractEmbeddedArtwork\(from url: URL\)' "$engine" >/dev/null; then
    printf 'MetadataEngine embedded-artwork helper is missing.\n' >&2
    exit 1
fi

if ! rg -n 'func extractEmbeddedArtwork\(from url: URL\).*async -> Data\?' "$engine" "${readers[@]}" >/dev/null; then
    printf 'Metadata readers must expose embedded-artwork extraction.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run scripts and verify resolver failures**

Run:

```bash
Scripts/test-artwork-resolver-priority.sh
Scripts/test-track-artwork-download.sh
```

Expected:

- `Scripts/test-artwork-resolver-priority.sh` fails with a missing `sameStemArtworkURL` or source-order marker.
- `Scripts/test-track-artwork-download.sh` fails with a missing resolver pattern.

- [ ] **Step 3: Add the notification constant**

Add this line to the notification section in `Utilities/Constants.swift`, near `artistImagesDidChange`:

```swift
    static let trackArtworkSidecarDidChange = Notification.Name("TrackArtworkSidecarDidChange")
```

- [ ] **Step 4: Replace ArtworkResolver implementation**

Replace `Core/Artwork/ArtworkResolver.swift` with:

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
        if let embedded = await cachedOrEmbeddedArtwork(for: request) {
            return embedded
        }

        if let sameStemURL = externalArtworkURL(for: request.audioURL, kind: .sameStem),
           let sameStem = cachedOrFileArtwork(for: request, fileURL: sameStemURL) {
            return sameStem
        }

        if let genericURL = externalArtworkURL(for: request.audioURL, kind: .generic),
           let generic = cachedOrFileArtwork(for: request, fileURL: genericURL) {
            return generic
        }

        return await downloadedArtworkData(for: request)
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

    private func cachedOrEmbeddedArtwork(for request: ArtworkRequest) async -> Data? {
        guard let key = cacheKey(for: request, sourceURL: request.audioURL) else {
            return nil
        }

        if let cached = cache.data(for: key) {
            return cached
        }

        guard let data = await MetadataEngine.extractEmbeddedArtwork(from: request.audioURL) else {
            return nil
        }

        cache.store(data, for: key)
        return data
    }

    private func cachedOrFileArtwork(for request: ArtworkRequest, fileURL: URL) -> Data? {
        guard let key = cacheKey(for: request, sourceURL: fileURL) else {
            return nil
        }

        if let cached = cache.data(for: key) {
            return cached
        }

        guard let rawData = try? Data(contentsOf: fileURL),
              rawData.count <= AlbumArtFormat.maxArtworkSize,
              let data = ImageUtils.compressImage(from: rawData, source: fileURL.lastPathComponent) else {
            return nil
        }

        cache.store(data, for: key)
        return data
    }

    private func downloadedArtworkData(for request: ArtworkRequest) async -> Data? {
        guard let fullTrack = await AppCoordinator.shared?.libraryManager.databaseManager.fullTrack(
            forAudioURL: request.audioURL
        ) else {
            return nil
        }

        guard let sidecarURL = await TrackArtworkDownloadManager.shared.downloadArtwork(for: fullTrack) else {
            return nil
        }

        let data = cachedOrFileArtwork(for: request, fileURL: sidecarURL)
        await MainActor.run {
            NotificationCenter.default.post(name: .trackArtworkSidecarDidChange, object: request.audioURL)
        }
        return data
    }

    private enum ExternalArtworkKind {
        case sameStem
        case generic
    }

    private func externalArtworkURL(for audioURL: URL, kind: ExternalArtworkKind) -> URL? {
        let directory = audioURL.deletingLastPathComponent()
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        switch kind {
        case .sameStem:
            return ExternalArtworkResolver.sameStemArtworkURL(forAudioURL: audioURL, candidates: candidates)
        case .generic:
            return ExternalArtworkResolver.genericArtworkURL(forAudioURL: audioURL, candidates: candidates)
        }
    }

    private func cacheKey(for request: ArtworkRequest, sourceURL: URL) -> ArtworkCacheKey? {
        guard let source = sourceIdentity(for: sourceURL) else { return nil }
        return ArtworkCacheKey(
            kind: request.kind,
            identity: request.identity,
            source: source,
            version: ArtworkCacheKey.currentVersion
        )
    }

    private func sourceIdentity(for sourceURL: URL) -> ArtworkSourceIdentity? {
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

- [ ] **Step 5: Refresh visible async artwork images on sidecar changes**

Update `Views/Components/Artwork/AsyncArtworkImage.swift` by adding this modifier after `.task(id: taskID) { ... }`:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .trackArtworkSidecarDidChange)) { notification in
            guard let changedURL = notification.object as? URL,
                  let request,
                  changedURL.standardizedFileURL.path == request.audioURL.standardizedFileURL.path else {
                return
            }

            Task {
                await loadArtwork()
            }
        }
```

The resulting modifier chain should be:

```swift
        .task(id: taskID) {
            await loadArtwork()
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackArtworkSidecarDidChange)) { notification in
            guard let changedURL = notification.object as? URL,
                  let request,
                  changedURL.standardizedFileURL.path == request.audioURL.standardizedFileURL.path else {
                return
            }

            Task {
                await loadArtwork()
            }
        }
```

- [ ] **Step 6: Run resolver scripts and verify they pass**

Run:

```bash
Scripts/test-artwork-resolver-priority.sh
Scripts/test-track-artwork-download.sh
```

Expected:

- `Scripts/test-artwork-resolver-priority.sh` exits 0.
- `Scripts/test-track-artwork-download.sh` still fails on the missing settings toggle.

- [ ] **Step 7: Commit**

```bash
git add Core/Artwork/ArtworkResolver.swift Utilities/Constants.swift Views/Components/Artwork/AsyncArtworkImage.swift Scripts/test-artwork-resolver-priority.sh
git commit -m "feat: resolve artwork downloads lazily"
```

## Task 6: Add Settings, Diagnostics, And Localization

**Files:**
- Modify: `Views/Settings/IntegrationsTabView.swift`
- Modify: `Utilities/DiagnosticSnapshot.swift`
- Modify: `Resources/Localizable.xcstrings`
- Modify: `Scripts/test-track-artwork-download.sh`

- [ ] **Step 1: Confirm the structural script fails on settings**

Run:

```bash
Scripts/test-track-artwork-download.sh
```

Expected: `Missing track artwork download setting.`

- [ ] **Step 2: Add the AppStorage preference to IntegrationsTabView**

In `Views/Settings/IntegrationsTabView.swift`, add this property after `onlineLyricsEnabled`:

```swift
    @AppStorage("trackArtworkDownloadEnabled")
    private var trackArtworkDownloadEnabled: Bool = false
```

Add this toggle immediately after the online lyrics toggle in `onlineFeaturesSection`:

```swift
            Toggle("Fetch artwork from internet when unavailable", isOn: $trackArtworkDownloadEnabled)
                .help("Automatically search for cover artwork online when no local artwork is found")
```

- [ ] **Step 3: Add diagnostics**

In `Utilities/DiagnosticSnapshot.swift`, add the new key in the user defaults snapshot near `onlineLyricsEnabled` and `artistImageDownloadEnabled`:

```swift
                "trackArtworkDownloadEnabled": defaults.boolOrNull("trackArtworkDownloadEnabled"),
```

- [ ] **Step 4: Add localized strings**

Add these entries to `Resources/Localizable.xcstrings`, keeping the file's existing JSON structure and sorted location style:

```json
    "Automatically search for cover artwork online when no local artwork is found": {
      "comment": "Help text for a toggle that enables automatic online cover artwork lookup when local artwork is unavailable.",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Automatically search for cover artwork online when no local artwork is found"
          }
        },
        "zh-Hans": {
          "stringUnit": {
            "state": "translated",
            "value": "找不到本地封面时自动在线搜索封面"
          }
        }
      }
    },
```

```json
    "Fetch artwork from internet when unavailable": {
      "comment": "A toggle that enables automatic online cover artwork lookup when local artwork is unavailable.",
      "localizations": {
        "en": {
          "stringUnit": {
            "state": "translated",
            "value": "Fetch artwork from internet when unavailable"
          }
        },
        "zh-Hans": {
          "stringUnit": {
            "state": "translated",
            "value": "没有封面时从互联网获取"
          }
        }
      }
    },
```

- [ ] **Step 5: Run settings and localization checks**

Run:

```bash
Scripts/test-track-artwork-download.sh
Scripts/test-localization-format-specifiers.sh
```

Expected:

- `Scripts/test-track-artwork-download.sh` exits 0.
- `Scripts/test-localization-format-specifiers.sh` exits 0.

- [ ] **Step 6: Commit**

```bash
git add Views/Settings/IntegrationsTabView.swift Utilities/DiagnosticSnapshot.swift Resources/Localizable.xcstrings Scripts/test-track-artwork-download.sh
git commit -m "feat: add track artwork download setting"
```

## Task 7: Full Verification

**Files:**
- No planned source edits.

- [ ] **Step 1: Run focused artwork and localization checks**

Run:

```bash
Scripts/test-track-artwork-sidecar.sh
Scripts/test-external-artwork-priority.sh
Scripts/test-artwork-resolver-priority.sh
Scripts/test-track-artwork-download.sh
Scripts/test-ui-artwork-resolver.sh
Scripts/test-localization-format-specifiers.sh
```

Expected: every script exits 0. If a script reports a missing static pattern, update the code or the script so the check matches the implemented behavior, then rerun this full command block.

- [ ] **Step 2: Run the Debug build**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Inspect final git diff**

Run:

```bash
git status --short
git diff --stat
```

Expected: only files from this plan are modified. Pre-existing user changes may still appear; do not stage or revert them.

- [ ] **Step 4: Final commit if verification required small fixes**

If Step 1 or Step 2 required code or script fixes, commit only those files:

```bash
git add Core/Artwork Core/Metadata Managers/TrackArtworkDownloadManager.swift Managers/Database/DMQueries.swift Views/Components/Artwork/AsyncArtworkImage.swift Views/Settings/IntegrationsTabView.swift Utilities/Constants.swift Utilities/DiagnosticSnapshot.swift Resources/Localizable.xcstrings Scripts/test-external-artwork-priority.sh Scripts/test-artwork-resolver-priority.sh Scripts/test-track-artwork-sidecar.sh Scripts/test-track-artwork-download.sh
git commit -m "fix: verify track artwork downloads"
```

Expected: no commit is needed if Tasks 1 through 6 already passed all verification.
