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
