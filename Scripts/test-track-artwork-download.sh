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
from pathlib import Path

manager = Path("Managers/TrackArtworkDownloadManager.swift").read_text()

def require(pattern, message):
    if pattern not in manager:
        raise SystemExit(message)
    return manager.index(pattern)

cancel_idx = require("guard !Task.isCancelled else { return nil }", "Missing cancellation guard before recording online miss.")
miss_idx = require("recordOnlineMiss(for: fullTrack.url)", "Missing online miss recording.")
if cancel_idx > miss_idx:
    raise SystemExit("Cancellation must be checked before recording an online artwork miss.")

enabled_idx = require("guard isEnabled else { return nil }", "Downloads must remain opt-in.")
cache_idx = require("cachedOnlineDisplayResult(for:", "Missing successful online display cache lookup.")
fetch_idx = require("fetchArtwork(for: fullTrack)", "Missing online artwork fetch.")
if not (enabled_idx < cache_idx < fetch_idx):
    raise SystemExit("Successful display cache must be checked after opt-in and before network fetch.")

write_idx = require("TrackArtworkSidecarWriter.writeResult", "Manager must use race-safe sidecar write result.")
notify_idx = require("NotificationCenter.default.post(name: .trackArtworkSidecarDidChange", "Manager must post sidecar refresh notifications.")
main_actor_idx = manager.rfind("MainActor.run", 0, notify_idx)
did_write_idx = manager.rfind("didWriteSidecar", 0, notify_idx)
if main_actor_idx < 0 or did_write_idx < 0 or not (write_idx < did_write_idx < main_actor_idx < notify_idx):
    raise SystemExit("Manager must post notification from MainActor.run only after an actual sidecar write.")

width_idx = require("kCGImagePropertyPixelWidth", "Missing downloaded artwork pixel width guard.")
height_idx = require("kCGImagePropertyPixelHeight", "Missing downloaded artwork pixel height guard.")
encode_idx = require("ImageUtils.encodeJPEG", "Missing downloaded artwork JPEG encoding.")
if not (width_idx < encode_idx and height_idx < encode_idx):
    raise SystemExit("Downloaded artwork pixel dimensions must be checked before JPEG encoding.")
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
