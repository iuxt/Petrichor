#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("FAIL: \(message)\nexpected: \(expected)\nactual: \(actual)\n", stderr)
        exit(1)
    }
}

func assertNil<T>(_ actual: T?, _ message: String) {
    if actual != nil {
        fputs("FAIL: \(message)\nexpected nil, actual: \(String(describing: actual))\n", stderr)
        exit(1)
    }
}

let timed = [
    LyricLine(text: "first", startTime: 0, endTime: 10),
    LyricLine(text: "", startTime: 10, endTime: 12),
    LyricLine(text: "second", startTime: 12, endTime: 20),
    LyricLine(text: "third", startTime: 20, endTime: nil)
]

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: timed, at: 4),
    DesktopLyricsDisplayLines(current: "first", next: "second"),
    "synced lyrics select current line and next non-empty line"
)

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: timed, at: 11),
    DesktopLyricsDisplayLines(current: "second", next: "third"),
    "empty active lines advance to the next non-empty line"
)

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: timed, at: -1),
    DesktopLyricsDisplayLines(current: "first", next: "second"),
    "times before the first timestamp show the first two non-empty lines"
)

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: timed, at: 22),
    DesktopLyricsDisplayLines(current: "third", next: nil),
    "last synced line has no next line"
)

let emptyTail = [
    LyricLine(text: "first", startTime: 0, endTime: 10),
    LyricLine(text: "", startTime: 10, endTime: nil)
]

assertNil(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: emptyTail, at: 12),
    "empty active tail line does not wrap to earlier lyrics"
)

let finiteTimed = [
    LyricLine(text: "first", startTime: 0, endTime: 1),
    LyricLine(text: "second", startTime: 5, endTime: 6)
]

assertNil(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: finiteTimed, at: 3),
    "finite-ended timed lyrics return nil during gaps"
)

assertNil(
    DesktopLyricsLineSelection.syncedDisplayLines(lines: finiteTimed, at: 7),
    "finite-ended timed lyrics return nil after the final line"
)

let plain = [
    LyricLine(text: "", startTime: 0),
    LyricLine(text: "plain one", startTime: 0),
    LyricLine(text: "plain two", startTime: 0)
]

assertEqual(
    DesktopLyricsLineSelection.plainDisplayLines(lines: plain),
    DesktopLyricsDisplayLines(current: "plain one", next: "plain two"),
    "plain lyrics use first two non-empty lines"
)

assertNil(
    DesktopLyricsLineSelection.plainDisplayLines(lines: [LyricLine(text: "   ", startTime: 0)]),
    "blank lyrics do not produce display lines"
)

print("Desktop lyrics line selection tests passed")
SWIFT

swiftc \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/DesktopLyricsLineSelection.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/DesktopLyricsLineSelectionTests"

"$TMP_DIR/DesktopLyricsLineSelectionTests"
