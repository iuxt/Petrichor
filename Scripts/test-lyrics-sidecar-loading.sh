#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

touch "$TMP_DIR/Priority.flac" "$TMP_DIR/Fallback.flac" "$TMP_DIR/GBK.flac"
printf "%s\n" "karaoke.add('00:01.000','00:02.000','KSC','1000');" > "$TMP_DIR/Priority.ksc"
printf "%s\n" "[00:01.00]LRC" > "$TMP_DIR/Priority.lrc"
printf "%s\n" "not valid ksc" > "$TMP_DIR/Fallback.ksc"
printf "%s\n" "[00:02.00]fallback" > "$TMP_DIR/Fallback.lrc"
printf "%s\n" "karaoke.add('00:03.000','00:04.000','中文','500,500');" \
    | iconv -f UTF-8 -t GBK > "$TMP_DIR/GBK.ksc"

cat > "$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func require(_ name: String) -> LyricsSidecarLoader.Result {
    guard let result = LyricsSidecarLoader.load(forAudioURL: root.appendingPathComponent("\(name).flac")) else {
        fatalError("Missing sidecar result for \(name)")
    }
    return result
}

let priority = require("Priority")
precondition(priority.source == .ksc && priority.lyrics.first?.text == "KSC", "KSC must outrank LRC")

let fallback = require("Fallback")
precondition(fallback.source == .lrc && fallback.lyrics.first?.text == "fallback", "Invalid KSC must fall back to LRC")

let gbk = require("GBK")
precondition(gbk.source == .ksc && gbk.lyrics.first?.text == "中文", "GBK KSC decoding failed")

print("Lyrics sidecar loading checks passed")
SWIFT

xcrun swiftc \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/LyricsSidecarLoader.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/lyrics-sidecar-test"

"$TMP_DIR/lyrics-sidecar-test" "$TMP_DIR"
