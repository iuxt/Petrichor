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

if ! rg -n 'clipView\.animator\(\)\.setBoundsOrigin\(origin\)' "$source_file" >/dev/null; then
    printf 'Lyric auto-scrolling must animate the macOS clip view.\n' >&2
    exit 1
fi

if ! rg -n 'accessibilityDisplayShouldReduceMotion' "$source_file" >/dev/null; then
    printf 'Lyric auto-scrolling must respect Reduce Motion.\n' >&2
    exit 1
fi

if rg -n 'proxy\.scrollTo\(' "$source_file" >/dev/null; then
    printf 'Lyric auto-scrolling must not use the jumping SwiftUI scrollTo path.\n' >&2
    exit 1
fi

printf 'Track lyrics highlight transition checks passed\n'
