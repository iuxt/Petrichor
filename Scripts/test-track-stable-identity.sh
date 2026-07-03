#!/usr/bin/env bash
set -euo pipefail

queue_file="Managers/Playlist/PMQueue.swift"

if ! rg -n 'isSameTrack' "$queue_file" >/dev/null; then
    printf 'Queue operations must use a stable track identity helper.\n' >&2
    exit 1
fi

if rg -n '\.id == track\.id|\.id == currentTrack\.id' "$queue_file" >/dev/null; then
    printf 'Queue operations must not compare transient Track.id values for track identity.\n' >&2
    exit 1
fi

printf 'Stable track identity checks passed\n'
