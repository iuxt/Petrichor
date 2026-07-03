#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if rg -n \
  "populateAlbumArtworkForTracks|populateAlbumArtworkForFullTrack|populateAlbumArtwork\(|populateTrackArtwork\(|Album\.Columns\.artworkData" \
  Managers/Database Managers/Library Application Views \
  -g '*.swift'; then
  echo "Unexpected database artwork read/population path remains." >&2
  exit 1
fi

if ! rg -n "struct AsyncArtworkImage|ArtworkResolver\.shared\.artworkData" Views/Components/Artwork/AsyncArtworkImage.swift >/dev/null; then
  echo "AsyncArtworkImage is missing or does not use ArtworkResolver." >&2
  exit 1
fi
