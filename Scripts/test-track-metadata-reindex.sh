#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REINDEX="$ROOT_DIR/Managers/Database/DMTrackMetadataEditing.swift"
PROCESSING="$ROOT_DIR/Managers/Database/DMTrackProcessing.swift"

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! rg -n "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

reject_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if rg -n "$pattern" "$file" >/dev/null 2>&1; then
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
reject_pattern "$REINDEX" 'scan|processFilesInBatches|refreshFolder' 'Metadata saving must not rescan a folder.'
reject_pattern "$PROCESSING" 'processUpdatedTrack\([^\n]*metadata:' 'The unused metadata parameter must be removed.'

printf '%s\n' 'Track metadata reindex checks passed'
