#!/usr/bin/env bash
set -euo pipefail

migration="Managers/Database/DatabaseMigration.swift"

if [[ ! -f "$migration" ]]; then
    printf 'Missing %s\n' "$migration" >&2
    exit 1
fi

if ! rg -n 'v16_clear_artwork_blobs' "$migration" >/dev/null; then
    printf 'v16 artwork blob cleanup migration is missing.\n' >&2
    exit 1
fi

for statement in \
    'UPDATE albums SET artwork_data = NULL' \
    'UPDATE artists SET artwork_data = NULL' \
    'UPDATE tracks SET track_artwork_data = NULL' \
    'UPDATE playlists SET cover_artwork_data = NULL'
do
    if ! rg -n "$statement" "$migration" >/dev/null; then
        printf 'Artwork cleanup migration is missing statement: %s\n' "$statement" >&2
        exit 1
    fi
done

printf 'Artwork blob cleanup migration checks passed\n'
