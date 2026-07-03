#!/usr/bin/env bash
set -euo pipefail

source_file="Managers/Database/DMSearchQueries.swift"

if ! rg -n 'isPlainFTSToken' "$source_file" >/dev/null; then
    printf 'FTS query building must distinguish plain prefix tokens from tokens that need quoting.\n' >&2
    exit 1
fi

if ! rg -n 'quotedFTSToken' "$source_file" >/dev/null; then
    printf 'FTS query building must quote special-character tokens such as AC/DC and C++.\n' >&2
    exit 1
fi

if rg -n 'CharacterSet\(charactersIn: "\\"\\*\^:\(\)\[\]\{\}~-' "$source_file" >/dev/null; then
    printf 'FTS query building still uses the incomplete special-character allowlist.\n' >&2
    exit 1
fi

sqlite3 :memory: <<'SQL' >/dev/null
CREATE VIRTUAL TABLE tracks_fts USING fts5(track_id UNINDEXED, title, artist);
INSERT INTO tracks_fts(rowid, track_id, title, artist) VALUES (1, 1, 'Back in Black', 'AC/DC');
INSERT INTO tracks_fts(rowid, track_id, title, artist) VALUES (2, 2, 'Code', 'C++');
SELECT count(*) FROM tracks_fts WHERE tracks_fts MATCH '"AC/DC"';
SELECT count(*) FROM tracks_fts WHERE tracks_fts MATCH '"C++"';
SQL

printf 'Search special-character query checks passed\n'
