#!/usr/bin/env bash
set -euo pipefail

source_file="Core/TrackTrashManager.swift"

prepare_line="$(rg -n 'prepareCurrentTrackForTrashMove' "$source_file" | head -n 1 | cut -d: -f1 || true)"
move_line="$(rg -n 'try moveItemToTrash\(audioURL' "$source_file" | head -n 1 | cut -d: -f1 || true)"
commit_line="$(rg -n 'handleTrackMovedToTrash' "$source_file" | head -n 1 | cut -d: -f1 || true)"
restore_line="$(rg -n 'restoreCurrentTrackAfterFailedTrashMove' "$source_file" | head -n 1 | cut -d: -f1 || true)"

if [ -z "$prepare_line" ] || [ -z "$move_line" ] || [ -z "$commit_line" ] || [ -z "$restore_line" ]; then
    printf 'Track trash flow must prepare playback, move the file, restore on failure, then commit queue/library changes.\n' >&2
    exit 1
fi

if [ "$commit_line" -le "$move_line" ]; then
    printf 'Track trash flow must not remove the current track from playback/queue before the file move succeeds.\n' >&2
    exit 1
fi

if [ "$restore_line" -le "$move_line" ]; then
    printf 'Track trash flow must restore playback state only from the move failure path.\n' >&2
    exit 1
fi

printf 'Track trash ordering checks passed\n'
