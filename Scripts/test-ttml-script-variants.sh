#!/usr/bin/env bash
# Unit tests for TTML script-variant selection (Simplified/Traditional switching).
# Apple TTML keeps one script in the <p> body and embeds the other as
# <translations><translation type="replacement"> line replacements keyed by
# itunes:key, with identical word timings. Verifies variant selection, per-line
# fallback, timing/duet preservation, and script availability reporting.
set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/main.swift" <<'SWIFT'
import Foundation

// Apple-style fixture: zh-Hant body, zh-Hans replacement translations for L1/L2
// (L3 has none — per-line fallback), duet agents v1/v2.
let fixture = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word" xml:lang="zh-Hant"><head><metadata><ttm:agent type="person" xml:id="v1"/><ttm:agent type="person" xml:id="v2"/><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal"><translations><translation type="replacement" xml:lang="zh-Hans"><text for="L1"><span begin="15.424" end="15.857" xmlns="http://www.w3.org/ns/ttml">比</span><span begin="15.857" end="16.886">起母亲</span><span begin="16.886" end="18.685">的总是忧心忡</span><span begin="18.685" end="19.339">忡</span></text><text for="L2"><span begin="20.100" end="21.400">父亲早已</span><span begin="21.400" end="23.000">淹没在人群里</span></text></translation></translations></iTunesMetadata></metadata></head><body><div><p begin="15.424" end="19.339" itunes:key="L1" ttm:agent="v1"><span begin="15.424" end="15.857">比</span><span begin="15.857" end="16.886">起母親</span><span begin="16.886" end="18.685">的總是憂心忡</span><span begin="18.685" end="19.339">忡</span></p><p begin="20.100" end="23.000" itunes:key="L2" ttm:agent="v2"><span begin="20.100" end="21.400">父親早已</span><span begin="21.400" end="23.000">淹沒在人群裡</span></p><p begin="24.000" end="26.000" itunes:key="L3" ttm:agent="v1"><span begin="24.000" end="25.000">一行沒有譯文的</span><span begin="25.000" end="26.000">舊歌</span></p></div></body></tt>
"""

// --- Availability: original plus each script that has replacement text ---
let parsed = TTMLLyricsParser.parse(fixture.data(using: .utf8)!)
precondition(parsed.availableScripts == [.original, .simplified],
             "Expected [.original, .simplified], got \(parsed.availableScripts)")
precondition(parsed.lines.map(\.text) == ["比起母親的總是憂心忡忡", "父親早已淹沒在人群裡", "一行沒有譯文的舊歌"],
             "Original script must keep the zh-Hant body text")
print("Original script and availability OK")

// --- Simplified: translated lines switch, untranslatable line falls back ---
let simplified = TTMLLyricsParser.parse(fixture.data(using: .utf8)!, script: .simplified)
precondition(simplified.lines[0].text == "比起母亲的总是忧心忡忡", "L1 must render in zh-Hans")
precondition(simplified.lines[1].text == "父亲早已淹没在人群里", "L2 must render in zh-Hans")
precondition(simplified.lines[2].text == parsed.lines[2].text,
             "L3 has no replacement text and must keep the original line")
print("Simplified selection with per-line fallback OK")

// --- Word timings, line timings and duet sides are identical across scripts ---
for (original, translated) in zip(parsed.lines, simplified.lines) {
    precondition(original.startTime == translated.startTime && original.endTime == translated.endTime,
                 "Replacement text must not change line timing")
    precondition(original.timingSegments?.count == translated.timingSegments?.count,
                 "Replacement text must keep one segment per word")
    precondition(original.duetSide == translated.duetSide,
                 "Replacement text must keep the performer side")
    for (a, b) in zip(original.timingSegments ?? [], translated.timingSegments ?? []) {
        precondition(a.startOffset == b.startOffset && a.duration == b.duration,
                     "Replacement segments must reuse the word timing")
    }
    // Karaoke renderer invariant: segment text joins to the line text.
    if let segments = translated.timingSegments {
        precondition(segments.map(\.text).joined() == translated.text,
                     "Translated segments must still join to the line text")
    }
}
precondition(simplified.lines[0].duetSide == .left && simplified.lines[1].duetSide == .right,
             "Duet sides must survive variant selection")
print("Timing and duet preservation OK")

// --- Requesting a script the file does not carry falls back to the body ---
let traditional = TTMLLyricsParser.parse(fixture.data(using: .utf8)!, script: .traditional)
precondition(traditional.lines.map(\.text) == parsed.lines.map(\.text),
             "An unavailable script must fall back to the original body")
print("Unavailable script fallback OK")

// --- Plain TTML without a translations block reports original only ---
let plainFixture = """
<tt xmlns="http://www.w3.org/ns/ttml" xml:lang="ja"><body><div><p begin="1" end="2">すし</p></div></body></tt>
"""
let plain = TTMLLyricsParser.parse(plainFixture.data(using: .utf8)!)
precondition(plain.availableScripts == [.original], "No translations means original only")
precondition(plain.lines.map(\.text) == ["すし"], "Plain TTML must keep parsing as before")
precondition(TTMLLyricsParser.parse(plainFixture.data(using: .utf8)!, script: .simplified).lines.map(\.text) == ["すし"],
             "Simplified request on a translation-less file is a silent no-op")
print("Plain TTML OK")

// --- Reverse direction: zh-Hans body carrying a zh-Hant replacement ---
let reverseFixture = """
<tt xmlns="http://www.w3.org/ns/ttml" xml:lang="zh-Hans"><head><metadata><iTunesMetadata><translations><translation type="replacement" xml:lang="zh-Hant"><text for="L1"><span begin="1" end="2">繁體歌詞</span></text></translation></translations></iTunesMetadata></metadata></head><body><div><p begin="1" end="2" itunes:key="L1">简体歌词</p></div></body></tt>
"""
let reverse = TTMLLyricsParser.parse(reverseFixture.data(using: .utf8)!)
precondition(reverse.availableScripts == [.original, .traditional],
             "zh-Hant replacement must be reported as traditional")
precondition(TTMLLyricsParser.parse(reverseFixture.data(using: .utf8)!, script: .traditional).lines[0].text == "繁體歌詞",
             "Traditional selection must use the zh-Hant replacement")
print("Reverse direction OK")

// --- Region tags map to scripts (zh-CN → simplified, zh-TW → traditional) ---
func regionFixture(_ tag: String) -> Data {
    Data("""
    <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="zh-Hant"><head><metadata><iTunesMetadata><translations><translation type="replacement" xml:lang="\(tag)"><text for="L1"><span begin="1" end="2">替换</span></text></translation></translations></iTunesMetadata></metadata></head><body><div><p begin="1" end="2" itunes:key="L1">替換</p></div></body></tt>
    """.utf8)
}
precondition(TTMLLyricsParser.parse(regionFixture("zh-CN")).availableScripts.contains(.simplified),
             "zh-CN replacement must count as simplified")
precondition(TTMLLyricsParser.parse(regionFixture("zh-TW")).availableScripts.contains(.traditional),
             "zh-TW replacement must count as traditional")
precondition(TTMLLyricsParser.parse(regionFixture("en-US")).availableScripts == [.original],
             "Non-CJK replacements are real translations, not script variants")
print("Region tag mapping OK")

// --- Foreign-language replacement blocks never leak into the body ---
precondition(TTMLLyricsParser.parse(regionFixture("en-US"), script: .simplified).lines[0].text == "替換",
             "Unmapped replacements must never replace body text")
print("Foreign replacement isolation OK")

print("All TTML script variant tests passed")
SWIFT

swiftc Core/Lyrics/TTMLLyricsParser.swift Models/Core/Lyrics.swift "$tmpdir/main.swift" -o "$tmpdir/ttml-test"
"$tmpdir/ttml-test"
