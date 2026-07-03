#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! rg -n "v16_clear_artwork_blobs" Managers/Database/DatabaseMigration.swift >/dev/null; then
  echo "Missing v16_clear_artwork_blobs migration." >&2
  exit 1
fi

for statement in \
  "UPDATE albums SET artwork_data = NULL" \
  "UPDATE artists SET artwork_data = NULL" \
  "UPDATE tracks SET track_artwork_data = NULL" \
  "v8_background_convert_artwork_to_heic"; do
  if ! rg -n "$statement" Managers/Database/DatabaseMigration.swift >/dev/null; then
    echo "Migration is missing expected statement: $statement" >&2
    exit 1
  fi
done

if rg -n "INSERT INTO background_migrations .*v8_background_convert_artwork_to_heic|flagged for background artwork conversion" \
  Managers/Database/DatabaseMigration.swift Managers/Database/DMBackgroundMigration.swift >/dev/null; then
  echo "v8 artwork background migration is still being scheduled." >&2
  exit 1
fi
