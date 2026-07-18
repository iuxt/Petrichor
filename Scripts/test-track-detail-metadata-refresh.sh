#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DETAIL="$ROOT_DIR/Views/Main/TrackDetailView.swift"

require_pattern() {
    local pattern="$1"
    local message="$2"
    if ! rg -n -U "$pattern" "$DETAIL" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern '@State private var fullTrackLoadTask: Task<Void, Never>\?' \
    'Track detail must retain and cancel its active full-track load.'
require_pattern '@State private var fullTrackLoadGeneration: UInt64' \
    'Track detail must generation-guard overlapping metadata reloads.'
require_pattern 'publisher\(for: \.libraryDataDidChange\)' \
    'Track detail must observe authoritative metadata refresh notifications.'
require_pattern 'guard track\.trackId == stableTrackID' \
    'Notification reloads must be bound to the displayed stable database ID.'
require_pattern 'fullTrackLoadTask\?\.cancel\(\)' \
    'A newer detail reload must cancel the older task.'
require_pattern 'requestGeneration == fullTrackLoadGeneration' \
    'A stale detail task must not publish after a newer reload.'
require_pattern 'requestedTrackID == track\.trackId' \
    'A detail load must not publish into a different displayed track.'
require_pattern '\.onDisappear[\s\S]*fullTrackLoadTask\?\.cancel\(\)' \
    'Closing track detail must cancel its outstanding load.'

printf '%s\n' 'Track detail metadata refresh checks passed'
