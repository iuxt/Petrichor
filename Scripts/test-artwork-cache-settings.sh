#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

for pattern in \
  "ArtworkResolver\\.shared\\.cacheSize" \
  "ArtworkResolver\\.shared\\.clearCache" \
  "Artwork cache" \
  "formatByteCount"; do
  if ! rg -n "$pattern" Views/Settings/LibraryTabView.swift >/dev/null; then
    echo "Missing artwork cache settings hook: $pattern" >&2
    exit 1
  fi
done
