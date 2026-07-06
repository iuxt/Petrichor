#!/usr/bin/env bash
set -euo pipefail

discover="Managers/Library/LMDiscover.swift"
folders="Managers/Library/LMFolders.swift"

if [[ ! -f "$discover" ]]; then
    printf 'Missing %s\n' "$discover" >&2
    exit 1
fi

if [[ ! -f "$folders" ]]; then
    printf 'Missing %s\n' "$folders" >&2
    exit 1
fi

if ! rg -n "func invalidateDiscoverTracks\\(" "$discover" >/dev/null; then
    printf 'LibraryManager must expose a focused Discover cache invalidation helper.\n' >&2
    exit 1
fi

if ! rg -n "removeObject\\(forKey: Self\\.discoverTrackIdsKey\\)" "$discover" >/dev/null; then
    printf 'Discover invalidation must remove saved track IDs, not just the timestamp.\n' >&2
    exit 1
fi

if ! rg -n "removeObject\\(forKey: Self\\.discoverLastUpdatedKey\\)" "$discover" >/dev/null; then
    printf 'Discover invalidation must remove the saved update timestamp.\n' >&2
    exit 1
fi

if ! rg -n "let savedIds = userDefaults\\.array\\(forKey: Self\\.discoverTrackIdsKey\\) as\\? \\[Int64\\]" "$discover" >/dev/null ||
   ! rg -n "tracks\\.count != savedIds\\.count|tracks\\.count < min\\(savedIds\\.count, discoverTrackCount\\)" "$discover" >/dev/null; then
    printf 'Loading cached Discover IDs must detect stale missing tracks and regenerate the list.\n' >&2
    exit 1
fi

if [[ $(rg -n "refreshDiscoverTracks\\(\\)" "$folders" | wc -l | tr -d ' ') -lt 3 ]]; then
    printf 'Folder add, remove, and refresh paths must refresh Discover tracks after library content changes.\n' >&2
    exit 1
fi

printf 'Discover cache invalidation checks passed\n'
