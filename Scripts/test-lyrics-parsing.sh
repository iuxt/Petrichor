#!/usr/bin/env bash
# Unit tests for LyricLine.parseLRC / parseSRT, covering the fixes in the
# code review: SRT blocks without a sequence number (spec-valid), LRC
# fractional-second parsing, and empty/gap cases.
set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/main.swift" <<'SWIFT'
import Foundation

// --- LRC: fractional seconds ---
// [00:12.5]  -> 12.5s (deci)
// [00:12.50] -> 12.5s (centi)
// [00:12.500] -> 12.5s (milli)
let lrcMixed = """
[00:12.5]deci line
[00:12.50]centi line
[00:12.500]milli line
"""
let lrcLines = LyricLine.parseLRC(from: lrcMixed)
precondition(lrcLines.count == 3, "Expected 3 LRC lines, got \(lrcLines.count)")
// All three should resolve to 12.5s regardless of fractional width.
for line in lrcLines {
    precondition(abs(line.startTime - 12.5) < 0.001,
                 "LRC fractional second mismatch: \(line.startTime) for '\(line.text)'")
}
print("LRC fractional-second widths OK")

// --- LRC: multiple timestamps on one line ---
let lrcMulti = "[00:01.00][00:05.00]repeated"
let multi = LyricLine.parseLRC(from: lrcMulti)
precondition(multi.count == 2, "Expected 2 lines from multi-timestamp LRC, got \(multi.count)")
precondition(multi[0].startTime == 1.0 && multi[1].startTime == 5.0, "Multi-timestamp parse wrong")
print("LRC multi-timestamp OK")

// --- SRT: with sequence number (classic) ---
let srtWithIndex = """
1
00:00:01,000 --> 00:00:02,000
First

2
00:00:03,000 --> 00:00:04,000
Second
"""
let srtIndexed = LyricLine.parseSRT(from: srtWithIndex)
precondition(srtIndexed.count == 2, "Expected 2 indexed SRT blocks, got \(srtIndexed.count)")
precondition(srtIndexed[0].startTime == 1.0 && srtIndexed[0].text == "First", "Indexed SRT[0] wrong")
precondition(srtIndexed[1].startTime == 3.0 && srtIndexed[1].text == "Second", "Indexed SRT[1] wrong")
print("SRT with sequence numbers OK")

// --- SRT: WITHOUT sequence number (spec-valid, previously dropped) ---
let srtNoIndex = """
00:00:01,000 --> 00:00:02,000
First

00:00:03,000 --> 00:00:04,000
Second
"""
let srtIndexless = LyricLine.parseSRT(from: srtNoIndex)
precondition(srtIndexless.count == 2,
             "Expected 2 index-less SRT blocks, got \(srtIndexless.count); these used to be silently dropped")
precondition(srtIndexless[0].startTime == 1.0 && srtIndexless[0].text == "First", "Index-less SRT[0] wrong")
precondition(srtIndexless[1].startTime == 3.0 && srtIndexless[1].text == "Second", "Index-less SRT[1] wrong")
print("SRT without sequence numbers OK (regression fixed)")

// --- SRT: mixed (some with index, some without) ---
let srtMixed = """
1
00:00:01,000 --> 00:00:02,000
Indexed

00:00:03,000 --> 00:00:04,000
Indexless
"""
let srtMixedResult = LyricLine.parseSRT(from: srtMixed)
precondition(srtMixedResult.count == 2, "Expected 2 mixed SRT blocks, got \(srtMixedResult.count)")
precondition(srtMixedResult[0].text == "Indexed", "Mixed SRT[0] wrong")
precondition(srtMixedResult[1].text == "Indexless", "Mixed SRT[1] wrong")
print("SRT mixed (indexed + index-less) OK")

// --- SRT: multi-line text within a block ---
let srtMultiline = """
00:00:01,000 --> 00:00:02,000
Line one
Line two
"""
let multiline = LyricLine.parseSRT(from: srtMultiline)
precondition(multiline.count == 1, "Expected 1 multi-line SRT block, got \(multiline.count)")
precondition(multiline[0].text == "Line one\nLine two", "Multi-line SRT text wrong: '\(multiline[0].text)'")
print("SRT multi-line text OK")

// --- KSC: line timing, stable sorting, escapes, grapheme timing ---
let ksc = #"""
karaoke.songname := 'ignored metadata';
karaoke.add('0:12.500', '0:14.000', 'A\'好👨‍👩‍👧‍👦', '100,200,300,400');
karaoke.add('00:00:02.250', '00:00:03.000', '先', '750');
"""#
let kscLines = LyricLine.parseKSC(from: ksc.replacingOccurrences(of: "\n", with: "\r\n"))
precondition(kscLines.count == 2, "Expected 2 KSC lines, got \(kscLines.count)")
precondition(kscLines[0].text == "先" && abs(kscLines[0].startTime - 2.25) < 0.001,
             "KSC lines must be sorted by start time")
precondition(kscLines[1].text == "A'好👨‍👩‍👧‍👦", "KSC escaped lyric text was parsed incorrectly")
precondition(kscLines[1].endTime == 14.0, "KSC end time was parsed incorrectly")
let segments = kscLines[1].timingSegments ?? []
precondition(segments.count == 4, "Expected one KSC segment per grapheme cluster")
precondition(segments.map(\.text) == ["A", "'", "好", "👨‍👩‍👧‍👦"], "KSC grapheme splitting was incorrect")
precondition(abs(segments[1].startOffset - 0.1) < 0.001 && abs(segments[3].startOffset - 0.6) < 0.001,
             "KSC segment offsets were not accumulated")
precondition(abs(segments[3].duration - 0.4) < 0.001, "KSC millisecond duration was not converted to seconds")

// --- KSC: only supported quote/slash escapes consume the backslash ---
let kscEscapes = #"""
karaoke.add('00:20.000', '00:21.000', 'A\'B', '100,100,100');
karaoke.add('00:21.000', '00:22.000', 'A\\B', '100,100,100');
karaoke.add('00:22.000', '00:23.000', 'A\qB', '100,100,100,100');
"""#
let escapedLines = LyricLine.parseKSC(from: kscEscapes)
precondition(escapedLines.map(\.text) == ["A'B", #"A\B"#, #"A\qB"#],
             "KSC quote, slash, and unknown escape handling must preserve the intended text")
precondition(escapedLines.allSatisfy { $0.timingSegments != nil },
             "Preserved KSC escape characters must still align with grapheme durations")

// --- KSC: non-finite fields and overflowing computed timestamps are invalid ---
let nonFiniteKSC = """
karaoke.add('inf:01.000', 'inf:02.000', 'bad minute', '1000');
karaoke.add('inf:00:01.000', 'inf:00:02.000', 'bad hour', '1000');
karaoke.add('00:nan', '00:02.000', 'bad second', '1000');
karaoke.add('1e308:00:01.000', '1e308:00:02.000', 'overflow', '1000');
karaoke.add('00:24.000', '00:25.000', 'valid', '1000');
"""
let finiteKSC = LyricLine.parseKSC(from: nonFiniteKSC)
precondition(finiteKSC.count == 1 && finiteKSC[0].text == "valid",
             "KSC parsing must reject non-finite fields and computed timestamps")
precondition(finiteKSC.allSatisfy { $0.startTime.isFinite && $0.endTime?.isFinite == true },
             "Every accepted KSC line timestamp must be finite")

// --- KSC: invalid segment metadata degrades without dropping the line ---
let kscFallback = """
karaoke.add('00:01.000', '00:02.000', '两个', '500');
karaoke.add('00:02.000', '00:03.000', '坏时长', '100,nope,300');
karaoke.add('00:03.000', '00:04.000', '零', '0');
karaoke.add('00:05.000', '00:04.000', '倒序', '100,100');
"""
let fallbackLines = LyricLine.parseKSC(from: kscFallback)
precondition(fallbackLines.count == 3, "Only the reversed KSC line should be dropped")
precondition(fallbackLines[0].timingSegments == nil, "Mismatched KSC duration count must degrade to line timing")
precondition(fallbackLines[1].timingSegments == nil, "Non-numeric KSC duration must degrade to line timing")
precondition(fallbackLines[2].timingSegments?.first?.duration == 0, "Zero-duration KSC segments must remain valid")
print("KSC parsing and degradation OK")

// --- Empty/garbage input is handled gracefully ---
precondition(LyricLine.parseLRC(from: "").isEmpty, "Empty LRC should yield no lines")
precondition(LyricLine.parseSRT(from: "").isEmpty, "Empty SRT should yield no blocks")
precondition(LyricLine.parseSRT(from: "not a valid srt").isEmpty, "Garbage SRT should yield no blocks")
precondition(LyricLine.parseKSC(from: "").isEmpty, "Empty KSC should yield no lines")
precondition(LyricLine.parseKSC(from: "karaoke.clear();").isEmpty, "KSC without add commands should yield no lines")
print("Empty/garbage input OK")

print("All lyrics parsing tests passed")
SWIFT

swiftc Models/Core/Lyrics.swift "$tmpdir/main.swift" -o "$tmpdir/lyrics-test"
"$tmpdir/lyrics-test"
