#!/usr/bin/env bash
set -euo pipefail

source_file="Core/LyricsLoader.swift"

if ! rg -n 'Task\.detached\(priority: \.utility\)' "$source_file" >/dev/null; then
    printf 'LyricsLoader must read external lyric sidecars off the main actor.\n' >&2
    exit 1
fi

if ! rg -n 'LyricsSidecarLoader\.load\(forAudioURL:' "$source_file" >/dev/null; then
    printf 'LyricsLoader external sidecar delegation is missing.\n' >&2
    exit 1
fi

printf 'Lyrics background IO checks passed\n'
