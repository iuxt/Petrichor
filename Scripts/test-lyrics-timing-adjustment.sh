#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

enum LyricsSource: Equatable { case ttml, ksc, lrc, srt, embedded, none }
extension String { init(appLocalized value: String) { self = value } }

func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let cases: [(LyricsSource, String, String)] = [
    (.lrc, "[00:01.00]Hi <00:01.50>there\n[ar:Artist]\n", "[00:01.100]Hi <00:01.600>there\n[ar:Artist]\n"),
    (.srt, "1\n00:00:01,000 --> 00:00:02,000\nHi\n", "1\n00:00:01,100 --> 00:00:02,100\nHi\n"),
    (.ksc, "karaoke.add('00:01.00','00:02.00','Hi','500,500');\n", "karaoke.add('00:01.100','00:02.100','Hi','500,500');\n"),
    (.ttml, "<p begin=\"1.0s\" end=\"2.0s\"><span begin=\"1.2s\" end=\"1.8s\">Hi</span></p>",
     "<p begin=\"1.100s\" end=\"2.100s\"><span begin=\"1.300s\" end=\"1.900s\">Hi</span></p>"),
]

for (index, (source, input, expected)) in cases.enumerated() {
    let url = directory.appendingPathComponent("case-\(index).txt")
    try Data(input.utf8).write(to: url)
    let snapshot = try LyricsTimingAdjuster.load(at: url, source: source, accessURL: nil)
    check(try String(contentsOf: url, encoding: .utf8) == input, "loading modified \(source)")
    try LyricsTimingAdjuster.save(snapshot, at: url, source: source, offset: 0.1, accessURL: nil)
    let actual = try String(contentsOf: url, encoding: .utf8)
    check(actual == expected, "wrong shifted text for \(source): \(actual)")
    let shifted = try LyricsTimingAdjuster.load(at: url, source: source, accessURL: nil)
    try LyricsTimingAdjuster.save(shifted, at: url, source: source, offset: -0.1, accessURL: nil)
    let restored = try LyricsTimingAdjuster.load(at: url, source: source, accessURL: nil)
    check(abs(restored.minimumTime - snapshot.minimumTime) < 0.000_001,
          "reverse shift did not restore timing for \(source)")
}

let utf16URL = directory.appendingPathComponent("utf16.lrc")
let utf16Text = "[00:01.00]中文\r\n"
let utf16Data = Data([0xFF, 0xFE]) + utf16Text.data(using: .utf16LittleEndian)!
try utf16Data.write(to: utf16URL)
let utf16Snapshot = try LyricsTimingAdjuster.load(at: utf16URL, source: .lrc, accessURL: nil)
try LyricsTimingAdjuster.save(utf16Snapshot, at: utf16URL, source: .lrc, offset: 0.1, accessURL: nil)
let savedUTF16 = try Data(contentsOf: utf16URL)
check(savedUTF16.starts(with: [0xFF, 0xFE]), "UTF-16 BOM was lost")
check(String(data: savedUTF16.dropFirst(2), encoding: .utf16LittleEndian) == "[00:01.100]中文\r\n",
      "UTF-16 content or line endings changed")

let url = directory.appendingPathComponent("guard.lrc")
try Data("[00:00.05]first".utf8).write(to: url)
let snapshot = try LyricsTimingAdjuster.load(at: url, source: .lrc, accessURL: nil)
do {
    try LyricsTimingAdjuster.save(snapshot, at: url, source: .lrc, offset: -0.1, accessURL: nil)
    fatalError("negative timestamp was accepted")
} catch LyricsTimingAdjuster.Failure.invalidTimestamp {}
check(try String(contentsOf: url, encoding: .utf8) == "[00:00.05]first", "failed save changed file")
try Data("[00:00.05]edited".utf8).write(to: url)
do {
    try LyricsTimingAdjuster.save(snapshot, at: url, source: .lrc, offset: 0.1, accessURL: nil)
    fatalError("external edit was overwritten")
} catch LyricsTimingAdjuster.Failure.fileChanged {}

print("Lyrics timing adjustment checks passed")
SWIFT

swiftc "$ROOT_DIR/Core/Lyrics/LyricsTimingAdjuster.swift" "$TMP_DIR/main.swift" -o "$TMP_DIR/check"
"$TMP_DIR/check" "$TMP_DIR"
