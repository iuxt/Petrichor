#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REINDEX="$ROOT_DIR/Managers/Database/DMTrackMetadataEditing.swift"
PROCESSING="$ROOT_DIR/Managers/Database/DMTrackProcessing.swift"

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! rg -n -U "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

reject_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if rg -n -U "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern "$REINDEX" 'func reindexEditedTrack\(' 'The verified-track reindex entry point is missing.'
require_pattern "$REINDEX" 'verified.tags' 'The database must consume verified file values.'
require_pattern "$REINDEX" 'track.albumId = nil' 'Old album association must be cleared before rebuilding.'
require_pattern "$REINDEX" 'try processUpdatedTrack\(' 'Normalized relations must use the existing update path.'
require_pattern "$REINDEX" 'refreshDuplicateGroups\(' 'Only affected duplicate groups must be refreshed.'
require_pattern "$REINDEX" 'pruneOrphanedMetadata\(' 'Old normalized parents must be pruned.'
require_pattern "$REINDEX" 'oldAlbumArtistIDs = try AlbumArtist' 'Old album-only artists must be captured before album mutation.'
require_pattern "$REINDEX" 'oldTrackArtistIDs\.union\(oldAlbumArtistIDs\)' 'Old track and album artist IDs must be pruned together.'
require_pattern "$REINDEX" 'target\.url\.standardizedFileURL == track\.url\.standardizedFileURL' 'A stale track ID must not reindex a different file path.'
require_pattern "$REINDEX" 'verified\.target == target' 'The verified snapshot must belong to the requested target.'
require_pattern "$REINDEX" 'let affectedTracks: \[Track\]' 'The reindex result must return duplicate peers whose flags changed.'
require_pattern "$REINDEX" 'let affectedAlbumIDs = Set\(' 'Old and new album IDs must be collected for relationship rebuilding.'
require_pattern "$REINDEX" 'try rebuildAlbumArtists\(' 'Affected album-artist junctions must be rebuilt authoritatively.'
require_pattern "$REINDEX" 'AlbumArtist[\s\S]*\.deleteAll\(db\)' 'Album-artist rebuilding must remove stale junctions before inserting current relationships.'
require_pattern "$REINDEX" 'try updateEntityStats\(in: db\)' 'Artist and album aggregate counts must refresh in the reindex transaction.'
require_pattern "$REINDEX" 'private func refreshDuplicateGroups\([\s\S]*\) throws -> \[Track\]' 'Duplicate refresh must return every affected lightweight track.'
reject_pattern "$REINDEX" 'scan|processFilesInBatches|refreshFolder' 'Metadata saving must not rescan a folder.'
reject_pattern "$PROCESSING" 'processUpdatedTrack\([^\n]*metadata:' 'The unused metadata parameter must be removed.'

printf '%s\n' 'Track metadata reindex checks passed'
