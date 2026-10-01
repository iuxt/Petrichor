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

rg -n 'holdPreviousLine: usesImmersiveStyle' "$source_file" >/dev/null

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/main.swift" <<'SWIFT'
import Foundation

let lines = [
    LyricLine(text: "first", startTime: 2, endTime: 4),
    LyricLine(text: " \n", startTime: 4, endTime: 5),
    LyricLine(text: "second", startTime: 8, endTime: 10)
]

func check(_ time: TimeInterval, _ expected: Int, hold: Bool = true) {
    let actual = TrackLyricsLineSelection.currentIndex(in: lines, at: time, holdPreviousLine: hold)
    precondition(actual == expected, "At \(time), expected \(expected), got \(actual)")
}

check(1, -1) // Do not start the first line early.
check(2, 0)
check(3.9, 0)
check(4, 0) // Keep readable text through a blank interval marker.
check(6, 0) // Hold the previous line during the gap.
check(7.999, 0)
check(8, 2) // Switch exactly when the next line starts.
check(10, 2) // Keep the final line readable after its end.
check(6, 0) // Seeking backward into a gap recomputes the held line.
check(1, -1) // Seeking before the first line clears the old selection.
check(4, 1, hold: false) // Preserve the compact views' blank markers.
check(6, -1, hold: false)
check(10, -1, hold: false)
precondition(TrackLyricsLineSelection.currentIndex(in: [], at: 5, holdPreviousLine: true) == -1)

let duet = [
    LyricLine(text: "left", startTime: 1, endTime: 5, duetSide: .left),
    LyricLine(text: "right", startTime: 2, endTime: 3, duetSide: .right)
]
precondition(TrackLyricsLineSelection.currentIndex(in: duet, at: 2.5, holdPreviousLine: true) == 1)
precondition(TrackLyricsLineSelection.currentIndex(in: duet, at: 4, holdPreviousLine: true) == 0,
             "An active duet voice must take priority over a completed line")

print("Immersive lyrics gap selection checks passed")
SWIFT

xcrun swiftc Models/Core/Lyrics.swift Core/Lyrics/TrackLyricsLineSelection.swift \
    "$tmp_dir/main.swift" -o "$tmp_dir/lyrics-gap-tests"
"$tmp_dir/lyrics-gap-tests"
