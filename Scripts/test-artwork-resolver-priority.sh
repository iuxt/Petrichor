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
  'cache\.store\(data, for: key\)'; do
  if ! rg -n "$pattern" "$resolver" >/dev/null; then
    printf 'ArtworkResolver missing expected pattern: %s\n' "$pattern" >&2
    exit 1
  fi
done

python3 - <<'PY'
from pathlib import Path
source = Path("Core/Artwork/ArtworkResolver.swift").read_text()

marker = "func resolveArtwork(for request: ArtworkRequest) async -> Data?"
start = source.find(marker)
if start < 0:
    raise SystemExit("Missing ArtworkResolver.artworkData(for:) priority method")

brace = source.find("{", start)
if brace < 0:
    raise SystemExit("Could not parse ArtworkResolver.artworkData(for:) body")

depth = 0
end = -1
for idx in range(brace, len(source)):
    char = source[idx]
    if char == "{":
        depth += 1
    elif char == "}":
        depth -= 1
        if depth == 0:
            end = idx
            break

if end < 0:
    raise SystemExit("Could not parse ArtworkResolver.artworkData(for:) body")

body = source[brace + 1:end]
patterns = [
    "ExternalArtworkResolver.sameStemArtworkURL",
    "ExternalArtworkResolver.albumNamedArtworkURL",
    "ExternalArtworkResolver.genericArtworkURL",
    "cachedOrEmbeddedArtwork"
]
positions = []
for pattern in patterns:
    idx = body.find(pattern)
    if idx < 0:
        raise SystemExit(f"Missing resolver priority marker: {pattern}")
    positions.append(idx)
if positions != sorted(positions):
    raise SystemExit("ArtworkResolver source order must be same-stem, album-named, generic, embedded")

for path in ["Managers/ArtworkSearchViewModel.swift", "Views/Library/Sheets/ArtworkSearchSheet.swift"]:
    if "hasEmbeddedArtwork" in Path(path).read_text():
        raise SystemExit(f"Embedded artwork must not prevent manual sidecar saves: {path}")
PY

if rg -n 'TrackArtworkDownloadManager|downloadedArtworkData|downloadArtwork\(for:' "$resolver" >/dev/null; then
    printf 'ArtworkResolver still contains online artwork fallback.\n' >&2
    exit 1
fi

if ! rg -n 'func extractEmbeddedArtwork\(from url: URL\)' "$engine" >/dev/null; then
    printf 'MetadataEngine embedded-artwork helper is missing.\n' >&2
    exit 1
fi

if ! rg -n 'func extractEmbeddedArtwork\(from url: URL\).*async -> Data\?' "$engine" "${readers[@]}" >/dev/null; then
    printf 'Metadata readers must expose embedded-artwork extraction.\n' >&2
    exit 1
fi

# Exercise the production resolver and cache with identifiable image bytes.
# Image decoding and metadata extraction are stubs; source selection and file IO are real.
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
cat > "$tmpdir/PriorityRegression.swift" <<'SWIFT'
import Foundation

enum About { static let bundleIdentifier = "artwork-priority-regression" }
enum Logger {
    static func error(_ message: String) { fatalError(message) }
}
enum AlbumArtFormat {
    static let maxArtworkSize = 20 * 1024 * 1024
    static let supportedExtensions = ["jpg", "png"]
    static let knownFilenames = ["cover", "folder"]
    static func isSupported(_ ext: String) -> Bool { supportedExtensions.contains(ext.lowercased()) }
}
enum ImageUtils {
    static func compressImage(from data: Data, source: String) -> Data? {
        data == Data("corrupt".utf8) ? nil : data
    }
    static func downsampledImage(from data: Data, maxDimension: CGFloat) -> Data? {
        compressImage(from: data, source: "thumbnail")
    }
    static func encodeJPEG(_ image: Data, quality: CGFloat) -> Data? { image }
}
actor TrackThumbnailCache {
    static let shared = TrackThumbnailCache()
    func removeAll() {}
}
enum MetadataEngine {
    static let embedded = Data("embedded".utf8)
    static func extractEmbeddedArtwork(from url: URL) async -> Data? { embedded }
    static func extractRawEmbeddedArtwork(from url: URL) async -> Data? { embedded }
}

@main struct PriorityRegression {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let audio = root.appendingPathComponent("Song.flac")
        let audioData = Data("audio-with-embedded-artwork".utf8)
        try audioData.write(to: audio)
        let sameStem = root.appendingPathComponent("Song.jpg")
        let album = root.appendingPathComponent("My Album.jpg")
        let generic = root.appendingPathComponent("cover.jpg")
        let cache = ArtworkFileCache(rootURL: root.appendingPathComponent("cache"))
        let resolver = ArtworkResolver(cache: cache)
        let requests: [ArtworkRequest] = [
            .track(audio),
            .album(albumId: 1, representativeTrackURL: audio, albumTitle: "My Album"),
            .thumbnail(audio, albumTitle: "My Album")
        ]

        // Warm embedded caches first, so a subsequent external save must override them.
        for request in requests {
            let data = await resolver.artworkData(for: request)
            precondition(data == MetadataEngine.embedded, "Embedded artwork is the fallback")
        }
        try Data("generic".utf8).write(to: generic)
        resolver.invalidateMemoryCache()
        for request in requests {
            let data = await resolver.artworkData(for: request)
            precondition(data == Data("generic".utf8), "Folder artwork must override cached embedded artwork")
        }
        try Data("album".utf8).write(to: album)
        resolver.invalidateMemoryCache()
        for request in requests {
            let data = await resolver.artworkData(for: request)
            let expected = request.albumTitle == nil ? "generic" : "album"
            precondition(data == Data(expected.utf8), "Album-named artwork must override folder and embedded artwork")
        }
        try Data("same-stem".utf8).write(to: sameStem)
        resolver.invalidateMemoryCache()
        for request in requests {
            let data = await resolver.artworkData(for: request)
            precondition(data == Data("same-stem".utf8), "Saved song artwork must override every other source")
        }

        // A replaced sidecar must invalidate its disk cache, too.
        try Data("replacement-cover".utf8).write(to: sameStem, options: .atomic)
        resolver.invalidateMemoryCache()
        for request in requests {
            let data = await resolver.artworkData(for: request)
            precondition(data == Data("replacement-cover".utf8), "Sidecar replacement must appear immediately")
        }
        try Data("corrupt".utf8).write(to: sameStem, options: .atomic)
        try Data("corrupt".utf8).write(to: album, options: .atomic)
        resolver.invalidateMemoryCache()
        for request in requests {
            let data = await resolver.artworkData(for: request)
            precondition(data == Data("generic".utf8), "Unreadable external images must fall through to another source")
        }
        try FileManager.default.removeItem(at: generic)
        resolver.invalidateMemoryCache()
        for request in requests {
            let data = await resolver.artworkData(for: request)
            precondition(data == MetadataEngine.embedded, "Unreadable or missing external images must fall back to embedded artwork")
        }
        let unchangedAudio = try Data(contentsOf: audio)
        precondition(unchangedAudio == audioData, "Resolving artwork must preserve the audio file")
        _ = cache.cacheSize() // Drain pending writes before the temporary folder is removed.
        print("External-first artwork resolution and cache regressions passed")
    }
}
SWIFT
swiftc -parse-as-library Core/Artwork/ArtworkRequest.swift Core/Artwork/ArtworkFileCache.swift \
    Core/Artwork/ArtworkLoadLimiter.swift "$resolver" Core/Metadata/ExternalArtworkResolver.swift \
    "$tmpdir/PriorityRegression.swift" -o "$tmpdir/artwork-priority-regression"
"$tmpdir/artwork-priority-regression" "$tmpdir"
