#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

touch "$TMP_DIR/Priority.flac" "$TMP_DIR/Fallback.flac" "$TMP_DIR/TTML.flac" "$TMP_DIR/Duet.flac" \
    "$TMP_DIR/InvalidTTML.flac" "$TMP_DIR/UTF16TTML.flac" "$TMP_DIR/GBK.flac" \
    "$TMP_DIR/UTF16LEBOMKSC.flac" "$TMP_DIR/UTF16BEBOMSRT.flac" \
    "$TMP_DIR/UTF16LEBOMLRC.flac" "$TMP_DIR/UTF16BEBomlessKSC.flac" \
    "$TMP_DIR/NonFiniteFallback.flac"
printf "%s\n" "karaoke.add('00:01.000','00:02.000','KSC','1000');" > "$TMP_DIR/Priority.ksc"
printf "%s\n" "[00:01.00]LRC" > "$TMP_DIR/Priority.lrc"
cat > "$TMP_DIR/Priority.ttml" <<'TTML'
<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="1s" end="2s"><span begin="1s" end="2s">TTML</span></p></div></body></tt>
TTML
cat > "$TMP_DIR/TTML.ttml" <<'TTML'
<?xml version="1.0" encoding="UTF-8"?>
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word">
  <head><metadata><title>Ignore this</title></metadata></head>
  <body><div>
    <p begin="00:10.000" end="00:13.000" itunes:key="L1">
      <span begin="10s" end="10.5s">Hello </span><span begin="10.5s" end="11.25s">world</span>
      <span ttm:role="x-translation" xml:lang="zh-CN">你好世界</span>
      <span ttm:role="x-bg"><span begin="12s" end="13s">(yeah)</span></span>
    </p>
    <p begin="00:14.000" end="00:15.000">Plain &amp; timed</p>
  </div></body>
</tt>
TTML
cat > "$TMP_DIR/Duet.ttml" <<'TTML'
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <head><metadata>
    <ttm:agent type="person" xml:id="v1"/><ttm:agent type="person" xml:id="v2"/>
    <ttm:agent type="group" xml:id="v1000"/>
  </metadata></head>
  <body><div>
    <p begin="1s" end="3s" ttm:agent="v2"><span begin="1s" end="3s">Singer B</span></p>
    <p begin="2s" end="4s" ttm:agent="v1"><span begin="2s" end="4s">Singer A</span></p>
    <p begin="4s" end="5s" ttm:agent="v1000">Together</p>
  </div></body>
</tt>
TTML
printf '%s\n' '<tt><body><p begin="1s"><span>broken</p></body></tt>' > "$TMP_DIR/InvalidTTML.ttml"
printf "%s\n" "[00:03.00]LRC fallback" > "$TMP_DIR/InvalidTTML.lrc"
printf '\xFF\xFE' > "$TMP_DIR/UTF16TTML.ttml"
printf '%s\n' '<?xml version="1.0" encoding="UTF-16"?><tt><body><p begin="2s" end="3s">UTF16 XML</p></body></tt>' \
    | iconv -f UTF-8 -t UTF-16LE >> "$TMP_DIR/UTF16TTML.ttml"
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
touch "$TMP_DIR/Variant.flac"
cat > "$TMP_DIR/Variant.ttml" <<'TTML'
<?xml version="1.0" encoding="UTF-8"?>
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word" xml:lang="zh-Hant">
  <head><metadata>
    <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal"><translations>
      <translation type="replacement" xml:lang="zh-Hans">
        <text for="L1"><span begin="1s" end="2s">简体歌词</span></text>
      </translation>
    </translations></iTunesMetadata>
  </metadata></head>
  <body><div>
    <p begin="1s" end="2s" itunes:key="L1"><span begin="1s" end="2s">繁體歌詞</span></p>
    <p begin="3s" end="4s" itunes:key="L2"><span begin="3s" end="4s">第二行繁體</span></p>
  </div></body>
</tt>
TTML

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
precondition(priority.source == .ttml && priority.lyrics.first?.text == "TTML", "TTML must outrank KSC and LRC")

let ttml = require("TTML")
precondition(ttml.source == .ttml && ttml.lyrics.count == 2, "TTML sidecar should load both lines")
precondition(ttml.lyrics[0].text == "Hello world(yeah)", "Auxiliary translation must not enter the sung line")
precondition(ttml.lyrics[0].timingSegments?.map(\.text) == ["Hello ", "world", "(yeah)"], "TTML word text should survive")
precondition(ttml.lyrics[0].timingSegments?.map(\.startOffset) == [0, 0.5, 2], "TTML word timing should survive")
precondition(ttml.lyrics[1].text == "Plain & timed" && ttml.lyrics[1].timingSegments == nil, "Line-timed TTML should display")

let duet = require("Duet")
precondition(duet.lyrics.map(\.duetSide) == [.right, .left, nil], "Agent definitions should keep singers on stable opposite sides")
precondition(duet.lyrics[0].isActive(at: 2.5) && duet.lyrics[1].isActive(at: 2.5), "Overlapping duet lines should both be active")
let solo = TTMLLyricsParser.parse(Data("<tt><body><p begin=\"1s\" end=\"2s\" ttm:agent=\"v1\" xmlns:ttm=\"http://www.w3.org/ns/ttml#metadata\">Solo</p></body></tt>".utf8)).lines
precondition(solo.first?.duetSide == nil, "A solo performer must remain centered")

let invalidTTML = require("InvalidTTML")
precondition(invalidTTML.source == .lrc && invalidTTML.lyrics.first?.text == "LRC fallback", "Malformed TTML must fall back")

let utf16TTML = require("UTF16TTML")
precondition(utf16TTML.source == .ttml && utf16TTML.lyrics.first?.text == "UTF16 XML", "TTML XML declaration and BOM should be honored")

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

// --- Script variants: the loader applies the requested writing script ---
let variantOriginal = require("Variant")
precondition(variantOriginal.lyrics.map(\.text) == ["繁體歌詞", "第二行繁體"], "Default load keeps the body script")
precondition(variantOriginal.availableScripts == [.original, .simplified], "Availability must report the replacement block")
guard let variantSimplified = LyricsSidecarLoader.load(
    forAudioURL: root.appendingPathComponent("Variant.flac"), script: .simplified
) else { fatalError("Missing sidecar result for Variant (simplified)") }
precondition(variantSimplified.lyrics.map(\.text) == ["简体歌词", "第二行繁體"],
             "Simplified swaps translated lines and falls back per line")
precondition(variantSimplified.lyrics[0].timingSegments?.map(\.startOffset) == [0],
             "Simplified segments must keep the word timing")
precondition(priority.availableScripts == [.original] && gbk.availableScripts == [.original],
             "Non-variant TTML and non-TTML sources have no script options")

print("Lyrics sidecar loading checks passed")
SWIFT

xcrun swiftc \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/Lyrics/TTMLLyricsParser.swift" \
    "$ROOT_DIR/Core/LyricsSidecarLoader.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/lyrics-sidecar-test"

"$TMP_DIR/lyrics-sidecar-test" "$TMP_DIR"
