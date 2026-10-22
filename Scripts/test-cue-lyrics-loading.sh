#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-cue-lyrics.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
# Use the real loader and parsers with an in-memory embedded-lyrics source.
sed '/^import GRDB$/d' "$ROOT_DIR/Core/LyricsLoader.swift" > "$TMP_DIR/LyricsLoader.swift"
cat > "$TMP_DIR/Harness.swift" <<'SWIFT'
import Foundation
struct DatabaseQueue {}
struct ExtendedMetadata { var lyrics: String? }
struct FullTrack { var extendedMetadata: ExtendedMetadata? }
struct Track {
    let url: URL
    let cueSegment: CueTrackSegment?
    var embedded: String? = nil
    var lyricsFileTarget: LyricsFileTarget { LyricsFileTarget(audioURL: url, cueSheetURL: cueSegment?.sheetURL, cueTrackNumber: cueSegment?.number) }
    func fullTrack(using db: DatabaseQueue) async throws -> FullTrack? { FullTrack(extendedMetadata: ExtendedMetadata(lyrics: embedded)) }
}
extension String { init(appLocalized key: String) { self = key } }
@main struct Harness {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let audioDir = root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let sheet = root.appendingPathComponent("Album.cue")
        let audio = audioDir.appendingPathComponent("Image.flac")
        let shared = audio.deletingPathExtension().appendingPathExtension("lrc")
        let segment = CueTrackSegment(sheetPath: sheet.path, sourcePath: audio.path, number: 2, start: 180, end: 300)
        let track = Track(url: audio, cueSegment: segment)
        let target = track.lyricsFileTarget
        let db = DatabaseQueue()
        let original = "[02:50.00]before\n[03:00.00]start\n[03:10.00]current\n[05:00.00]next"
        try original.write(to: shared, atomically: true, encoding: .utf8)
        let unrelatedTTML = audio.deletingPathExtension().appendingPathExtension("ttml")
        try "<tt><body><p begin=\"100s\" end=\"101s\">only an earlier track</p></body></tt>".write(to: unrelatedTTML, atomically: true, encoding: .utf8)
        let sharedResult = try await LyricsLoader.loadLyrics(for: track, using: db)
        precondition(sharedResult.fileURL == shared && sharedResult.source == .lrc)
        precondition(sharedResult.lyrics.map(\.text) == ["start", "current"])
        precondition(sharedResult.lyrics.map(\.startTime) == [0, 10], "Album timeline must be converted once")
        let specific = target.destination(extension: "lrc")
        try "[00:01.00]downloaded\n[00:10.00]track".write(to: specific, atomically: true, encoding: .utf8)
        let ownResult = try await LyricsLoader.loadLyrics(for: track, using: db)
        precondition(ownResult.fileURL == specific && ownResult.lyrics.map(\.startTime) == [1, 10], "Track-local lyrics must never be cropped against album time")
        let snapshot = try LyricsTimingAdjuster.load(at: specific, source: .lrc, accessURL: nil)
        try LyricsTimingAdjuster.save(snapshot, at: specific, source: .lrc, offset: 1, accessURL: nil)
        let adjusted = try await LyricsLoader.loadLyrics(for: track, using: db)
        precondition(adjusted.lyrics.map(\.startTime) == [2, 11])
        precondition(try String(contentsOf: shared, encoding: .utf8) == original, "Adjusting track lyrics must not change shared lyrics")
        try FileManager.default.removeItem(at: specific)
        let fallback = try await LyricsLoader.loadLyrics(for: track, using: db)
        precondition(fallback.fileURL == shared && fallback.lyrics.map(\.startTime) == [0, 10], "Deleting track lyrics falls back to the shared source")
        let ttml = target.destination(extension: "ttml")
        let xml = "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><p begin=\"1s\" end=\"2s\"><span begin=\"1s\" end=\"2s\">word</span></p></body></tt>"
        try xml.write(to: ttml, atomically: true, encoding: .utf8)
        let ttmlResult = try await LyricsLoader.loadLyrics(for: track, using: db)
        precondition(ttmlResult.fileURL == ttml && ttmlResult.source == .ttml && ttmlResult.lyrics[0].startTime == 1)
        precondition(ttmlResult.lyrics[0].timingSegments?.isEmpty == false)
        try FileManager.default.removeItem(at: ttml)
        try FileManager.default.removeItem(at: shared)
        try FileManager.default.removeItem(at: unrelatedTTML)
        var embeddedTrack = track
        embeddedTrack.embedded = original
        let embedded = try await LyricsLoader.loadLyrics(for: embeddedTrack, using: db)
        precondition(embedded.source == .embedded && embedded.fileURL == nil && embedded.lyrics.map(\.startTime) == [0, 10])
        let overlapping = LyricLine(text: "crossing", startTime: 179, endTime: 182,
            timingSegments: [LyricTimingSegment(text: "cross", startOffset: 0, duration: 2), LyricTimingSegment(text: "ing", startOffset: 2, duration: 1)], duetSide: .right)
        let cropped = segment.lyrics(from: [overlapping])
        precondition(cropped.count == 1 && cropped[0].startTime == 0 && cropped[0].endTime == 2)
        precondition(cropped[0].duetSide == .right && cropped[0].timingSegments?[0].duration == 1 && cropped[0].timingSegments?[1].startOffset == 1)
        let unfinished = segment.lyrics(from: [LyricLine(text: "last old line", startTime: 100)])
        precondition(unfinished.isEmpty, "Uncovered tracks must remain eligible for automatic download")
        print("CUE real lyric loading: source priority, time bases, TTML, timing edits, fallback and boundary words passed")
    }
}
SWIFT
# Throwing file reads are evaluated before assertions.
python3 - "$TMP_DIR/Harness.swift" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text().replace('        precondition(try String(contentsOf: shared, encoding: .utf8) == original,', '        let unchanged = try String(contentsOf: shared, encoding: .utf8)\n        precondition(unchanged == original,');p.write_text(s)
PY
xcrun swiftc "$ROOT_DIR/Core/Cue/CueSheet.swift" "$ROOT_DIR/Core/Cue/CueLyrics.swift" \
    "$ROOT_DIR/Core/Lyrics/LyricsFileTarget.swift" "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/Lyrics/TTMLLyricsParser.swift" "$ROOT_DIR/Core/LyricsSidecarLoader.swift" \
    "$ROOT_DIR/Core/Lyrics/LyricsTimingAdjuster.swift" "$TMP_DIR/LyricsLoader.swift" \
    "$TMP_DIR/Harness.swift" -o "$TMP_DIR/cue-lyrics-test"
"$TMP_DIR/cue-lyrics-test" "$TMP_DIR/library"
