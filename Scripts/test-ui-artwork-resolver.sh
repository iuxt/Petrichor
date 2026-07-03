#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

required_patterns=(
  "Views/Components/TrackViews/TrackTableView.swift:ArtworkResolver\\.shared\\.artworkData"
  "Views/Components/EntityGridView.swift:AsyncArtworkImage\\(request: albumEntity\\.artworkRequest"
  "Views/Home/EntityDetailView.swift:AsyncArtworkImage\\("
  "Views/Main/TrackDetailView.swift:AsyncArtworkImage\\("
  "Managers/PlaybackManager.swift:ArtworkResolver\\.shared\\.artworkData"
)

for entry in "${required_patterns[@]}"; do
  file="${entry%%:*}"
  pattern="${entry#*:}"
  if ! rg -n "$pattern" "$file" >/dev/null; then
    echo "Missing expected artwork resolver usage: $file / $pattern" >&2
    exit 1
  fi
done

if rg -n "track\\.albumArtworkData|fullTrack\\.artworkData|filter \\{ \\$0\\.artworkData != nil \\}|collageTracks\\[[^]]+\\]\\.artworkData" \
  Views Models/Core/Playlist.swift \
  -g '*.swift'; then
  echo "UI or playlist collage still depends on model artwork blobs." >&2
  exit 1
fi
