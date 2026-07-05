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
  "waitForRateLimit" \
  "successfulDisplayCache" \
  "SuccessfulDisplayCache\\.cooldown" \
  "SuccessfulDisplayCache\\.maxEntries" \
  "cachedOnlineDisplayResult\\(for:" \
  "storeOnlineDisplayResult\\(" \
  "kCGImagePropertyPixelWidth" \
  "kCGImagePropertyPixelHeight" \
  "MainActor\\.run" \
  "trackArtworkSidecarDidChange" \
  "didWriteSidecar"; do
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
  "fullTrack\\(forAudioURL:"; do
  if ! rg -n "$pattern" "$resolver" >/dev/null; then
    echo "ArtworkResolver missing expected pattern: $pattern" >&2
    exit 1
  fi
done

if rg -n "NotificationCenter\\.default\\.post\\(name: \\.trackArtworkSidecarDidChange" "$resolver" >/dev/null; then
    echo "ArtworkResolver must not post track artwork sidecar refresh notifications." >&2
    exit 1
fi

python3 - <<'PY'
import re
from pathlib import Path

manager = Path("Managers/TrackArtworkDownloadManager.swift").read_text()

def require(pattern, message):
    if pattern not in manager:
        raise SystemExit(message)
    return manager.index(pattern)

def function_body(name):
    marker = f"private func {name}"
    start = manager.index(marker)
    brace = manager.index("{", start)
    depth = 0
    for idx in range(brace, len(manager)):
        char = manager[idx]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return manager[brace + 1:idx]
    raise SystemExit(f"Could not parse {name} body")

def require_in(source, pattern, message):
    if pattern not in source:
        raise SystemExit(message)
    return source.index(pattern)

def all_indices(source, pattern):
    indices = []
    start = 0
    while True:
        idx = source.find(pattern, start)
        if idx < 0:
            return indices
        indices.append(idx)
        start = idx + len(pattern)

def require_all_in(source, pattern, message):
    indices = all_indices(source, pattern)
    if not indices:
        raise SystemExit(message)
    return indices

def require_guard_before(source, idx, guard, message, window_size=180):
    window = source[max(0, idx - window_size):idx]
    if guard not in window:
        raise SystemExit(message)

value_for_waiter = function_body("valueForWaiter")
if re.search(r"if\s+Task\.isCancelled\s*\{\s*Task\s*\{\s*await\s+self\.removeWaiter\(", value_for_waiter, re.S):
    raise SystemExit("Immediate waiter cancellation cleanup must not await an actor-local removeWaiter call.")

perform = function_body("performDownload")

miss_idx = require_in(perform, "recordOnlineMiss(for: fullTrack.url)", "Missing online miss recording.")
miss_window = perform[max(0, miss_idx - 160):miss_idx]
if "Task.isCancelled" not in miss_window:
    raise SystemExit("Cancellation must be checked immediately before recording an online artwork miss.")
if "guard isEnabled else { return nil }" not in miss_window:
    raise SystemExit("Opt-in must be checked immediately before recording an online artwork miss.")

enabled_idx = require("guard isEnabled else { return nil }", "Downloads must remain opt-in.")
cache_idx = require("cachedOnlineDisplayResult(for:", "Missing successful online display cache lookup.")
fetch_idx = require("fetchArtwork(for: fullTrack)", "Missing online artwork fetch.")
if not (enabled_idx < cache_idx < fetch_idx):
    raise SystemExit("Successful display cache must be checked after opt-in and before network fetch.")

write_idx = require_in(perform, "TrackArtworkSidecarWriter.writeResult", "Manager must use race-safe sidecar write result.")
did_write_idx = require_in(perform, "if writeResult.didWriteSidecar", "Manager must gate notifications on actual sidecar writes.")
did_write_block = perform[did_write_idx:perform.index("return TrackArtworkDownloadResult(sidecarURL:", did_write_idx)]
if "await postTrackArtworkSidecarDidChange" not in did_write_block:
    raise SystemExit("Manager must post sidecar refresh only inside the actual-write branch.")

notify_helper = function_body("postTrackArtworkSidecarDidChange")
if "await MainActor.run" not in notify_helper or "NotificationCenter.default.post(name: .trackArtworkSidecarDidChange" not in notify_helper:
    raise SystemExit("Manager must post sidecar refresh notifications from MainActor.run.")

conversion_idx = require_in(perform, "let jpegData = jpegData(from: downloaded)", "Missing downloaded artwork conversion.")
post_conversion = perform[conversion_idx:]
if "guard isEnabled else { return nil }" not in post_conversion[:350]:
    raise SystemExit("Opt-in must be rechecked after network fetch/conversion.")

for side_effect in [
    "storeOnlineDisplayResult(jpegData, for: key)",
    "let writeResult = try TrackArtworkSidecarWriter.writeResult",
    "await postTrackArtworkSidecarDidChange(for: fullTrack.url)",
    "return TrackArtworkDownloadResult(sidecarURL: existing)",
    "return TrackArtworkDownloadResult(displayData: jpegData)",
    "return TrackArtworkDownloadResult(sidecarURL: destination, didWriteSidecar: writeResult.didWriteSidecar)"
]:
    for idx in require_all_in(perform, side_effect, f"Missing side effect marker: {side_effect}"):
        require_guard_before(
            perform,
            idx,
            "guard isEnabled else { return nil }",
            f"Opt-in must be rechecked immediately before side effect: {side_effect}"
        )

if "return cached" not in perform:
    raise SystemExit("performDownload must return cached successful display data through the helper.")

cache_helper = function_body("cachedOnlineDisplayResult")
cached_return_idx = require_in(
    cache_helper,
    "return TrackArtworkDownloadResult(displayData: entry.data)",
    "Successful display cache helper must return cached display data."
)
require_guard_before(
    cache_helper,
    cached_return_idx,
    "guard isEnabled else { return nil }",
    "Successful display cache helper must recheck opt-in before returning cached online display data.",
    window_size=260
)

fetch_body = function_body("fetchArtwork")
network_markers = [
    'await downloadCoverArt(path: "/release/\\(releaseID)/front-500")',
    'await downloadCoverArt(path: "/release-group/\\(releaseGroupID)/front-500")',
    "await searchMusicBrainzRelease(for: fullTrack)",
    'await downloadCoverArt(path: "/release/\\(release.id)/front-500")',
    'return await downloadCoverArt(path: "/release-group/\\(releaseGroupID)/front-500")'
]
for marker in network_markers:
    idx = require_in(fetch_body, marker, f"Missing network marker in fetchArtwork: {marker}")
    window = fetch_body[max(0, idx - 220):idx]
    if "guard isEnabled else { return nil }" not in window:
        raise SystemExit(f"fetchArtwork must recheck opt-in before network step: {marker}")

width_idx = require("kCGImagePropertyPixelWidth", "Missing downloaded artwork pixel width guard.")
height_idx = require("kCGImagePropertyPixelHeight", "Missing downloaded artwork pixel height guard.")
encode_idx = require("ImageUtils.encodeJPEG", "Missing downloaded artwork JPEG encoding.")
if not (width_idx < encode_idx and height_idx < encode_idx):
    raise SystemExit("Downloaded artwork pixel dimensions must be checked before JPEG encoding.")

encoded_bind_idx = require("let encoded = ImageUtils.encodeJPEG", "Downloaded JPEG encoding must bind an encoded result.")
encoded_size_idx = require("encoded.count > 0, encoded.count <= AlbumArtFormat.maxArtworkSize", "Encoded JPEG byte size must be checked before writing.")
return_encoded_idx = require("return encoded", "Downloaded JPEG encoding must return the guarded encoded result.")
jpeg_data_idx = require("let jpegData = jpegData(from: downloaded)", "Write path must use guarded downloaded JPEG data.")
write_result_idx = require("let writeResult = try TrackArtworkSidecarWriter.writeResult", "Manager must use race-safe sidecar write result.")
if not (encoded_bind_idx <= encode_idx < encoded_size_idx < return_encoded_idx):
    raise SystemExit("Encoded JPEG byte size must be checked after encoding before returning data to the write path.")
if not (jpeg_data_idx < write_result_idx):
    raise SystemExit("Sidecar write path must use guarded downloaded JPEG data before writing.")
PY

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
