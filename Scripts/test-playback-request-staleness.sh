#!/usr/bin/env bash
set -euo pipefail

manager="Managers/PlaybackManager.swift"
sfb="Core/Playback/SFBPlaybackBackend.swift"

if ! rg -n 'playbackRequestGeneration' "$manager" >/dev/null; then
    printf 'PlaybackManager must track playback request generations so stale async loads cannot start playback.\n' >&2
    exit 1
fi

if ! rg -n 'beginPlaybackRequest' "$manager" >/dev/null; then
    printf 'PlaybackManager must create a token for each playback request.\n' >&2
    exit 1
fi

if ! rg -n 'isCurrentPlaybackRequest' "$manager" >/dev/null; then
    printf 'PlaybackManager must verify async playback loads before applying them.\n' >&2
    exit 1
fi

if ! rg -n 'playGeneration' "$sfb" >/dev/null; then
    printf 'SFBPlaybackBackend must guard asynchronous pre-buffer completions with a generation token.\n' >&2
    exit 1
fi

if ! rg -n 'guard self\.playGeneration == generation' "$sfb" >/dev/null; then
    printf 'SFBPlaybackBackend must ignore stale pre-buffer completions.\n' >&2
    exit 1
fi

printf 'Playback request staleness checks passed\n'
