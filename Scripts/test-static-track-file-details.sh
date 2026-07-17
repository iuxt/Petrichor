#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACK_DETAIL="$ROOT_DIR/Views/Main/TrackDetailView.swift"

require_pattern() {
    local pattern="$1"
    local message="$2"

    if ! rg -n "$pattern" "$TRACK_DETAIL" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

reject_pattern() {
    local pattern="$1"
    local message="$2"

    if rg -n "$pattern" "$TRACK_DETAIL" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern \
    'metadataSection\(title: String\(appLocalized: "File Details"\), items: fileDetailsItems\(for: fullTrack\)\)' \
    'File Details must use the shared metadata section.'
require_pattern \
    'private func fileDetailsItems\(for fullTrack: FullTrack\)' \
    'TrackDetailView must derive file detail items for the shared section.'
reject_pattern \
    'FileDetailsSection|isExpanded' \
    'File Details must not retain a collapsible view or expansion state.'

printf '%s\n' 'Static track file details checks passed'
