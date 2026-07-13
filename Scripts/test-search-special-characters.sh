#!/usr/bin/env bash
set -euo pipefail

source_file="Managers/Database/DMSearchQueries.swift"
setup_file="Managers/Database/DMSetup.swift"

if ! rg -n 'needsLikeFallback' "$source_file" >/dev/null; then
    printf 'Search must route tokens shorter than three characters around trigram FTS.\n' >&2
    exit 1
fi

if ! rg -n 'quotedFTSToken' "$source_file" >/dev/null; then
    printf 'FTS query building must quote tokens so special characters remain literal.\n' >&2
    exit 1
fi

if ! rg -n -F 'FTS5TokenizerDescriptor(components: ["trigram"])' "$setup_file" >/dev/null; then
    printf 'The tracks FTS table must use the trigram tokenizer.\n' >&2
    exit 1
fi

actual="$(sqlite3 :memory: <<'SQL'
CREATE VIRTUAL TABLE tracks_fts USING fts5(track_id UNINDEXED, title, artist, tokenize='trigram');
INSERT INTO tracks_fts(rowid, track_id, title, artist) VALUES (1, 1, 'Back in Black', 'AC/DC');
INSERT INTO tracks_fts(rowid, track_id, title, artist) VALUES (2, 2, 'Code', 'C++');
INSERT INTO tracks_fts(rowid, track_id, title, artist) VALUES (3, 3, 'Blackbird', 'The Beatles');

SELECT 'acdc=' || IFNULL(group_concat(track_id, ','), '')
FROM (SELECT track_id FROM tracks_fts WHERE tracks_fts MATCH '"AC/DC"' ORDER BY rowid);
SELECT 'cplusplus=' || IFNULL(group_concat(track_id, ','), '')
FROM (SELECT track_id FROM tracks_fts WHERE tracks_fts MATCH '"C++"' ORDER BY rowid);
SELECT 'substring=' || IFNULL(group_concat(track_id, ','), '')
FROM (SELECT track_id FROM tracks_fts WHERE tracks_fts MATCH '"lack"' ORDER BY rowid);
SELECT 'and=' || IFNULL(group_concat(track_id, ','), '')
FROM (SELECT track_id FROM tracks_fts WHERE tracks_fts MATCH '"Back" AND "AC/DC"' ORDER BY rowid);
SQL
)"

expected="$(printf 'acdc=1\ncplusplus=2\nsubstring=1,3\nand=1')"

if [ "$actual" != "$expected" ]; then
    printf 'Unexpected trigram FTS results.\nExpected:\n%s\nActual:\n%s\n' "$expected" "$actual" >&2
    exit 1
fi

printf 'Search special-character query checks passed\n'
