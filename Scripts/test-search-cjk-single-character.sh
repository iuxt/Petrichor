#!/usr/bin/env bash
set -euo pipefail

library_search="Core/LibrarySearch.swift"
playlist_editor="Views/Playlists/Sheets/RegularPlaylistEditorSheet.swift"

if ! rg -n 'isSearchableQuery' "$library_search" >/dev/null; then
    printf 'LibrarySearch must expose a shared query eligibility helper.\n' >&2
    exit 1
fi

if ! rg -n 'isCJKSearchScalar' "$library_search" >/dev/null; then
    printf 'Search eligibility must allow single CJK search scalars.\n' >&2
    exit 1
fi

if rg -n 'guard trimmedQuery\.count >= 2|guard query\.count >= 2' "$library_search" "$playlist_editor" >/dev/null; then
    printf 'Search paths must not reject all single-character queries before checking CJK input.\n' >&2
    exit 1
fi

sqlite3 :memory: <<'SQL' >/dev/null
CREATE VIRTUAL TABLE tracks_fts USING fts5(track_id UNINDEXED, title, artist, tokenize='unicode61');
INSERT INTO tracks_fts(rowid, track_id, title, artist) VALUES (1, 1, '我的歌', '张国荣');
SELECT count(*) FROM tracks_fts WHERE tracks_fts MATCH '我*';
SQL

printf 'Single-character CJK search checks passed\n'
