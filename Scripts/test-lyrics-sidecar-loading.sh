#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

touch "$TMP_DIR/Priority.flac" "$TMP_DIR/Fallback.flac" "$TMP_DIR/GBK.flac" \
    "$TMP_DIR/UTF16LEBOMKSC.flac" "$TMP_DIR/UTF16BEBOMSRT.flac" \
    "$TMP_DIR/UTF16LEBOMLRC.flac" "$TMP_DIR/UTF16BEBomlessKSC.flac" \
    "$TMP_DIR/NonFiniteFallback.flac"
printf "%s\n" "karaoke.add('00:01.000','00:02.000','KSC','1000');" > "$TMP_DIR/Priority.ksc"
printf "%s\n" "[00:01.00]LRC" > "$TMP_DIR/Priority.lrc"
printf "%s\n" "not valid ksc" > "$TMP_DIR/Fallback.ksc"
printf "%s\n" "[00:02.00]fallback" > "$TMP_DIR/Fallback.lrc"
printf "%s\n" "karaoke.add('00:03.000','00:04.000','中文','500,500');" \
    | iconv -f UTF-8 -t GBK > "$TMP_DIR/GBK.ksc"
printf '\xFF\xFE' > "$TMP_DIR/UTF16LEBOMKSC.ksc"
printf "%s\n" "karaoke.add('00:04.000','00:05.000','KSC UTF16','1000');" \
    | iconv -f UTF-8 -t UTF-16LE >> "$TMP_DIR/UTF16LEBOMKSC.ksc"
printf '\xFE\xFF' > "$TMP_DIR/UTF16BEBOMSRT.srt"
printf "%s\n%s\n" "00:00:05,000 --> 00:00:06,000" "SRT UTF16" \
    | iconv -f UTF-8 -t UTF-16BE >> "$TMP_DIR/UTF16BEBOMSRT.srt"
printf '\xFF\xFE' > "$TMP_DIR/UTF16LEBOMLRC.lrc"
printf "%s\n" "[00:06.00]LRC UTF16" \
    | iconv -f UTF-8 -t UTF-16LE >> "$TMP_DIR/UTF16LEBOMLRC.lrc"
printf "%s\n" "karaoke.add('00:07.000','00:08.000','BE','500,500');" \
    | iconv -f UTF-8 -t UTF-16BE > "$TMP_DIR/UTF16BEBomlessKSC.ksc"
printf "%s\n" "karaoke.add('inf:01.000','inf:02.000','invalid','1000');" \
    > "$TMP_DIR/NonFiniteFallback.ksc"
printf "%s\n" "[00:08.00]finite fallback" > "$TMP_DIR/NonFiniteFallback.lrc"

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

let utf16LEBOMKSC = require("UTF16LEBOMKSC")
precondition(
    utf16LEBOMKSC.source == .ksc && utf16LEBOMKSC.lyrics.first?.text == "KSC UTF16",
    "UTF-16LE BOM KSC decoding failed"
)

let utf16BEBOMSRT = require("UTF16BEBOMSRT")
precondition(
    utf16BEBOMSRT.source == .srt && utf16BEBOMSRT.lyrics.first?.text == "SRT UTF16",
    "UTF-16BE BOM SRT decoding failed"
)

let utf16LEBOMLRC = require("UTF16LEBOMLRC")
precondition(
    utf16LEBOMLRC.source == .lrc && utf16LEBOMLRC.lyrics.first?.text == "LRC UTF16",
    "UTF-16LE BOM LRC decoding failed"
)

let utf16BEBomlessKSC = require("UTF16BEBomlessKSC")
precondition(
    utf16BEBomlessKSC.source == .ksc && utf16BEBomlessKSC.lyrics.first?.text == "BE",
    "BOM-less UTF-16BE KSC decoding failed"
)

let nonFiniteFallback = require("NonFiniteFallback")
precondition(
    nonFiniteFallback.source == .lrc && nonFiniteFallback.lyrics.first?.text == "finite fallback",
    "A KSC with non-finite timestamps must not block the valid LRC fallback"
)

print("Lyrics sidecar loading checks passed")
SWIFT

xcrun swiftc \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/LyricsSidecarLoader.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/lyrics-sidecar-test"

"$TMP_DIR/lyrics-sidecar-test" "$TMP_DIR"
