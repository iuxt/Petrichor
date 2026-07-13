#!/usr/bin/env bash
set -euo pipefail

source_file="Views/Main/TrackLyricsView.swift"

if rg -n '\.animation\(.*value: currentLineIndex\)' "$source_file" >/dev/null; then
    printf 'Lyric highlight styles must switch immediately instead of animating with currentLineIndex.\n' >&2
    exit 1
fi

if rg -nU '(?s)private func updateCurrentLine\(for time: TimeInterval\).*?withAnimation.*?currentLineIndex = newIndex' "$source_file" >/dev/null; then
    printf 'The current lyric index must update outside an animation transaction.\n' >&2
    exit 1
fi

if ! rg -n '^[[:space:]]*currentLineIndex = newIndex$' "$source_file" >/dev/null; then
    printf 'The current lyric index update is missing.\n' >&2
    exit 1
fi

if ! rg -nU '(?s)\.onChange\(of: currentLineIndex\).*?withAnimation[[:space:]]*\{.*?proxy\.scrollTo\(newIndex, anchor: \.center\)' "$source_file" >/dev/null; then
    printf 'Lyric auto-scrolling must remain animated.\n' >&2
    exit 1
fi

printf 'Track lyrics highlight transition checks passed\n'
