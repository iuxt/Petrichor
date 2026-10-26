#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-cue.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
cat > "$TMP_DIR/main.swift" <<'SWIFT'
import Foundation
import CoreFoundation

func expect(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}
func rejects(_ text: String) {
    do { _ = try CueSheet.parse(text); preconditionFailure("Accepted invalid sheet: \(text)") }
    catch {}
}
let content = """
\u{FEFF}REM GENRE "Rock"
REM DATE 2024
REM DISCNUMBER 2
PERFORMER "专辑艺人"
TITLE "一张专辑"
FILE "Album image.wav" WAVE
  TRACK 01 AUDIO
    TITLE "第一首"
    SONGWRITER "作者"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "第二首"
    PERFORMER "嘉宾"
    INDEX 00 03:00:00
    INDEX 01 03:02:37
"""
let sheet = try CueSheet.parse(content.replacingOccurrences(of: "\n", with: "\r\n"))
expect(sheet.title == "一张专辑" && sheet.performer == "专辑艺人", "Album metadata")
expect(sheet.genre == "Rock" && sheet.year == "2024" && sheet.discNumber == 2, "REM metadata")
expect(sheet.entries.count == 2 && sheet.entries[1].performer == "嘉宾", "Track metadata")
expect(sheet.entries[0].songwriter == "作者", "Track songwriter")
expect(abs(sheet.entries[1].start! - (182 + 37.0 / 75)) < 0.000001, "75-frame INDEX 01; INDEX 00 is not the track start")
expect(CueSheet.timestamp("01:59:74") != nil, "Last valid frame")
for invalid in ["00:60:00", "00:00:75", "-1:00:00", "00:NaN:00", "00:00", "00:0.5:00"] {
    expect(CueSheet.timestamp(invalid) == nil, "Reject invalid timestamp \(invalid)")
}
rejects("TITLE \"No tracks\"")
rejects("FILE a.flac WAVE\nTRACK 01 AUDIO\nINDEX 00 00:00:00")
rejects("FILE a.flac WAVE\nTRACK 01 AUDIO\nINDEX 01 01:00:00\nTRACK 02 AUDIO\nINDEX 01 00:00:00")
rejects("FILE a.flac WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 01 AUDIO\nINDEX 01 01:00:00")
rejects("TRACK 01 AUDIO\nINDEX 01 00:00:00")
let multi = try CueSheet.parse("""
title "Multi"
file "a.flac" WAVE
track 01 AUDIO
index 01 00:00:00
file "sub\\b.flac" WAVE
track 02 AUDIO
index 01 00:00:00
""")
let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let cueURL = root.appendingPathComponent("disc.cue")
let sources = [root.appendingPathComponent("a.flac"), root.appendingPathComponent("sub/b.flac")]
expect(try multi.resolveSources(relativeTo: cueURL, audioURLs: sources) == sources, "Multi-FILE with Windows path separators")
let albumSource = root.appendingPathComponent("Album image.FLAC")
expect(try sheet.resolveSources(relativeTo: cueURL, audioURLs: [albumSource]) == [albumSource, albumSource], "Correct stale .wav extension and case")
do {
    _ = try sheet.resolveSources(relativeTo: cueURL, audioURLs: [albumSource, root.appendingPathComponent("Album image.ape")])
    preconditionFailure("Ambiguous source should not be guessed")
} catch {}
do {
    _ = try sheet.resolveSources(relativeTo: cueURL, audioURLs: [])
    preconditionFailure("Missing source should not hide ordinary audio")
} catch {}
let absolute = try CueSheet.parse("FILE /private/a.flac WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00")
do {
    _ = try absolute.resolveSources(relativeTo: cueURL, audioURLs: [URL(fileURLWithPath: "/private/a.flac")])
    preconditionFailure("Absolute paths must not escape granted folder")
} catch {}
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let realSource = root.appendingPathComponent("actual.flac")
let linkedSource = root.appendingPathComponent("alias.flac")
try Data().write(to: realSource)
try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: realSource)
let linkedSheet = try CueSheet.parse("FILE alias.flac WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00")
expect(try linkedSheet.resolveSources(relativeTo: cueURL, audioURLs: [realSource]) == [realSource],
       "CUE symlinks must match the scanner's resolved audio paths")
do {
    _ = try linkedSheet.resolveSources(relativeTo: cueURL, audioURLs: [albumSource])
    preconditionFailure("A symlink must not admit an audio source absent from enumeration")
} catch {}
let realDirectory = root.appendingPathComponent("audio")
try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-audio"), withDestinationURL: realDirectory)
let convertedSource = realDirectory.appendingPathComponent("converted.flac")
try Data().write(to: convertedSource)
let linkedDirectorySheet = try CueSheet.parse("FILE linked-audio/converted.wav WAVE\nTRACK 01 AUDIO\nINDEX 01 00:00:00")
expect(try linkedDirectorySheet.resolveSources(relativeTo: cueURL, audioURLs: [convertedSource]) == [convertedSource],
       "Extension correction must still work under a symlinked directory")
for encoding: String.Encoding in [.utf8, .utf16, String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))] {
    try content.data(using: encoding)!.write(to: cueURL)
    let decoded = try CueSheet.read(from: cueURL)
    expect(decoded.title == "一张专辑" && decoded.entries[1].title == "第二首", "Preserve Chinese titles for encoding \(encoding)")
}
let one = CueTrackSegment(sheetPath: cueURL.path, sourcePath: albumSource.path, number: 1, start: 0, end: 182)
let two = CueTrackSegment(sheetPath: cueURL.path, sourcePath: albumSource.path, number: 2, start: 182, end: 300)
expect(one.libraryPath != two.libraryPath && one.sourceURL == two.sourceURL, "Distinct identity for shared image")
expect(CueTrackSegment.decode(two.json) == two, "Database round-trip")
let broken = CueTrackSegment(sheetPath: cueURL.path, sourcePath: albumSource.path, number: 1, start: 10, end: 0)
expect(CueTrackSegment.decode(broken.json) == nil, "Invalid persisted range")
let playlistURL = root.appendingPathComponent("playlists/test.m3u")
let rendered = M3UPlaylistCodec.render(trackURLs: [one, two].map { URL(fileURLWithPath: $0.libraryPath) }, musicFolder: root, playlistFileURL: playlistURL)
let entries = M3UPlaylistCodec.parseTrackEntries(from: rendered)
expect(entries.count == 2 && entries[0] != entries[1], "M3U preserves virtual tracks")
expect(M3UPlaylistCodec.pathVariations(for: entries[1], musicFolder: root, playlistFileURL: playlistURL).first == two.libraryPath, "M3U resolves virtual identity")
let lyrics = two.lyrics(from: [LyricLine(text: "previous", startTime: 100, endTime: 101), LyricLine(text: "current", startTime: 183, endTime: 310), LyricLine(text: "next", startTime: 300)])
expect(lyrics.count == 1 && lyrics[0].text == "current" && lyrics[0].startTime == 1 && lyrics[0].endTime == 118, "Album lyrics are cropped and shifted")
print("CUE parser, encodings, source resolution, identity, M3U and lyrics checks passed")
SWIFT
xcrun swiftc "$ROOT_DIR/Core/Cue/CueSheet.swift" "$ROOT_DIR/Core/Cue/CueLyrics.swift" \
    "$ROOT_DIR/Models/Core/Lyrics.swift" "$ROOT_DIR/Core/M3UPlaylistCodec.swift" \
    "$TMP_DIR/main.swift" -o "$TMP_DIR/cue-test"
"$TMP_DIR/cue-test" "$TMP_DIR/library"
