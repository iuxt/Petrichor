#!/usr/bin/env bash
set -euo pipefail

actual="$(
sqlite3 :memory: <<'SQL'
CREATE TABLE tracks(id INTEGER PRIMARY KEY, title TEXT, album TEXT, artist TEXT);
CREATE VIRTUAL TABLE tracks_fts USING fts5(track_id UNINDEXED, title, album, artist);

INSERT INTO tracks VALUES (1, 'Unrelated title', 'Love Collection', 'Someone');
INSERT INTO tracks VALUES (2, 'Love', 'Single', 'Someone');

INSERT INTO tracks_fts(rowid, track_id, title, album, artist)
VALUES (1, 1, 'Unrelated title', 'Love Collection', 'Someone');
INSERT INTO tracks_fts(rowid, track_id, title, album, artist)
VALUES (2, 2, 'Love', 'Single', 'Someone');

SELECT group_concat(id, ',')
FROM (
    SELECT t.id AS id
    FROM tracks t
    JOIN tracks_fts fts ON t.id = fts.track_id
    WHERE tracks_fts MATCH 'love*'
    ORDER BY rank
);
SQL
)"

expected="2,1"

if [[ "$actual" != "$expected" ]]; then
    printf 'Expected ranked search order %s, got %s\n' "$expected" "$actual" >&2
    exit 1
fi

if rg -n "matchingTrackIds|matchingTrackIds\\.contains" Managers/Database/DMSearchQueries.swift >/dev/null; then
    printf 'Global search fetches ranked IDs and then refetches tracks, which loses FTS rank order.\n' >&2
    exit 1
fi

printf 'Search ranking preserved: %s\n' "$actual"
