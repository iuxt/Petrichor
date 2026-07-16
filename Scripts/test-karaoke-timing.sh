#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func assertClose(_ actual: Double, _ expected: Double, _ message: String) {
    precondition(abs(actual - expected) < 0.0001, "\(message): expected \(expected), got \(actual)")
}

let line = LyricLine(
    text: "ab",
    startTime: 10,
    endTime: 12,
    timingSegments: [
        LyricTimingSegment(text: "a", startOffset: 0, duration: 0.5),
        LyricTimingSegment(text: "b", startOffset: 0.5, duration: 1),
    ]
)

precondition(KaraokeTiming.fillFractions(for: line, at: 9.5) == [0, 0], "Progress before the line must be empty")
let firstMiddle = KaraokeTiming.fillFractions(for: line, at: 10.25)!
assertClose(firstMiddle[0], 0.5, "First glyph midpoint")
assertClose(firstMiddle[1], 0, "Second glyph before start")
precondition(KaraokeTiming.fillFractions(for: line, at: 10.5) == [1, 0], "Glyph boundary must be exact")
let secondMiddle = KaraokeTiming.fillFractions(for: line, at: 11)!
assertClose(secondMiddle[1], 0.5, "Second glyph midpoint")
precondition(KaraokeTiming.fillFractions(for: line, at: 12) == [1, 1], "Line end must complete all glyphs")
precondition(KaraokeTiming.fillFractions(for: LyricLine(text: "plain", startTime: 0), at: 1) == nil,
             "Untimed lines must not synthesize glyph progress")

let clock = ContinuousClock()
let instant = clock.now
let playing = KaraokePlaybackTimeAnchor(sampleTime: 4, sampleInstant: instant, isPlaying: true)
assertClose(playing.time(at: instant.advanced(by: .milliseconds(250)), upperBound: 10), 4.25, "Playing anchor interpolation")
assertClose(playing.time(at: instant.advanced(by: .seconds(20)), upperBound: 5), 5, "Anchor upper-bound clamp")

let paused = KaraokePlaybackTimeAnchor(sampleTime: 4, sampleInstant: instant, isPlaying: false)
assertClose(paused.time(at: instant.advanced(by: .seconds(2)), upperBound: 10), 4, "Paused anchors must freeze")

let seeked = KaraokePlaybackTimeAnchor(sampleTime: 1.5, sampleInstant: instant, isPlaying: true)
assertClose(seeked.time(at: instant.advanced(by: .milliseconds(100)), upperBound: nil), 1.6, "A new anchor must reset after seeking")

print("Karaoke timing checks passed")
SWIFT

xcrun swiftc \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/KaraokeTiming.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/karaoke-timing-test"

"$TMP_DIR/karaoke-timing-test"
