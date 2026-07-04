#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

manager="Managers/ArtistImageDownloadManager.swift"

if [[ ! -f "$manager" ]]; then
  echo "Missing ArtistImageDownloadManager." >&2
  exit 1
fi

for pattern in \
  "final class ArtistImageDownloadManager" \
  "static let shared = ArtistImageDownloadManager" \
  "artistImageDownloadEnabled" \
  "https://musicbrainz.org/ws/2/artist/" \
  "https://www.wikidata.org/w/api.php" \
  "commonsThumbUrl" \
  "sanitizedArtistFilename" \
  "writeArtistImage" \
  "\\.appendingPathComponent\\(filename\\)\\.appendingPathExtension\\(\"jpg\"\\)" \
  "UserDefaults\\.standard\\.bool\\(forKey: Self\\.artistImageDownloadEnabledKey\\)"; do
  if ! rg -n "$pattern" "$manager" >/dev/null; then
    echo "ArtistImageDownloadManager missing expected pattern: $pattern" >&2
    exit 1
  fi
done

if rg -n "DatabaseManager|updateArtist|artwork_data|artistArtwork|artist\\.artworkData" "$manager" >/dev/null; then
  echo "Artist image downloader must not write artist artwork to the database." >&2
  exit 1
fi

if ! rg -n "@AppStorage\\(\"artistImageDownloadEnabled\"\\)" Views/Settings/IntegrationsTabView.swift >/dev/null; then
  echo "Missing artist image download setting." >&2
  exit 1
fi

if ! rg -n "Download artist images to song folders|ArtistImageDownloadManager\\.shared\\.downloadMissingArtistImages" \
  Views/Settings/IntegrationsTabView.swift >/dev/null; then
  echo "Settings UI does not expose or trigger artist image downloads." >&2
  exit 1
fi

if ! rg -n "ArtistImageDownloadManager\\.shared\\.downloadMissingArtistImages\\(using: self\\)" \
  Managers/Library/LMLibrary.swift >/dev/null; then
  echo "Library load does not trigger artist image sidecar download pass." >&2
  exit 1
fi
