#!/usr/bin/env bash
# Round-trip and edge-case tests for M3UPlaylistCodec, covering the fixes in the
# code review: write paths relative to the playlist file's directory (not the
# music folder), percent-decoding only scheme entries, and the /Volumes heuristic.
set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/main.swift" <<'SWIFT'
import Foundation

let musicRoot = URL(fileURLWithPath: "/Music")
let playlistFile = musicRoot.appendingPathComponent("playlists/Rock.m3u")

// --- render: track inside music folder -> relative to playlist dir (../) ---
let inside = musicRoot.appendingPathComponent("Artist/Album/Song.flac")
let rendered = M3UPlaylistCodec.render(
    trackURLs: [inside],
    musicFolder: musicRoot,
    playlistFileURL: playlistFile
)
// Playlist lives at /Music/playlists/, track at /Music/Artist/... -> "../Artist/..."
precondition(rendered.contains("../Artist/Album/Song.flac"),
             "Expected track inside music folder to be relative (../) to playlist dir, got:\n\(rendered)")
print("render: inside-folder relative path OK")

// --- render: track outside music folder -> relative path via ../ (still resolvable) ---
let outside = URL(fileURLWithPath: "/External/Loose.mp3")
let renderedOutside = M3UPlaylistCodec.render(
    trackURLs: [outside],
    musicFolder: musicRoot,
    playlistFileURL: playlistFile
)
// /External is reachable from /Music/playlists via ../../External, so a relative
// path is still emitted (and resolvable by external players relative to the .m3u).
precondition(renderedOutside.contains("External/Loose.mp3"),
             "Expected outside-folder track path in output, got:\n\(renderedOutside)")
print("render: outside-folder relative path OK")

// --- round-trip: render then pathVariations resolves back to the original ---
let tracks = [
    musicRoot.appendingPathComponent("Artist/Album/Song.flac"),
    URL(fileURLWithPath: "/External/Loose.mp3")
]
let content = M3UPlaylistCodec.render(
    trackURLs: tracks,
    musicFolder: musicRoot,
    playlistFileURL: playlistFile
)
let entries = M3UPlaylistCodec.parseTrackEntries(from: content)
precondition(entries.count == 2, "Expected 2 entries after round-trip, got \(entries.count)")

// Each entry's first pathVariation should resolve to the standardized original path.
let expectedPaths = Set(tracks.map { $0.standardizedFileURL.path })
for entry in entries {
    let variations = M3UPlaylistCodec.pathVariations(
        for: entry, musicFolder: musicRoot, playlistFileURL: playlistFile
    )
    let matched = variations.first { expectedPaths.contains($0) }
    precondition(matched != nil,
                 "Round-trip failed: entry '\(entry)' did not resolve to any expected path. Variations: \(variations)")
}
print("round-trip: render -> parse resolves back to originals OK")

// --- percent-decoding: only applied to scheme entries, not bare paths ---
let schemeEntry = M3UPlaylistCodec.pathVariations(
    for: "file:///Music/Encoded%20Name.m4a",
    musicFolder: musicRoot,
    playlistFileURL: playlistFile
)
precondition(schemeEntry.contains("/Music/Encoded Name.m4a"),
             "file:// scheme entry should be percent-decoded, got: \(schemeEntry)")
print("percent-decode: scheme entry decoded OK")

// A bare path with a literal % should NOT be decoded. The literal "%20" stays as-is.
let literalPercent = M3UPlaylistCodec.pathVariations(
    for: "/Music/50%20Cool.flac",
    musicFolder: musicRoot,
    playlistFileURL: playlistFile
)
precondition(literalPercent.contains("/Music/50%20Cool.flac"),
             "Bare path with literal % should NOT be percent-decoded, got: \(literalPercent)")
// And it must NOT have been decoded into a space.
precondition(!literalPercent.contains("/Music/50 Cool.flac"),
             "Bare path literal %20 was wrongly decoded to space, got: \(literalPercent)")
print("percent-decode: bare path literal % preserved OK")

// --- /Volumes heuristic: UNC/SMB share maps to /Volumes ---
let unc = M3UPlaylistCodec.pathVariations(
    for: "//server/share/file.flac",
    musicFolder: musicRoot,
    playlistFileURL: playlistFile
)
precondition(unc.contains("/Volumes/server/share/file.flac"),
             "UNC share should map to /Volumes, got: \(unc)")
print("/Volumes heuristic: UNC share OK")

// A bare local path like /tmp/x.flac must NOT be rewritten to /Volumes/tmp/x.flac.
let localTmp = M3UPlaylistCodec.pathVariations(
    for: "/tmp/x.flac",
    musicFolder: musicRoot,
    playlistFileURL: playlistFile
)
precondition(!localTmp.contains("/Volumes/tmp/x.flac"),
             "Bare local path must not be rewritten to /Volumes/..., got: \(localTmp)")
print("/Volumes heuristic: bare local path not fabricated OK")

print("All M3U codec round-trip tests passed")
SWIFT

swiftc Core/M3UPlaylistCodec.swift "$tmpdir/main.swift" -o "$tmpdir/m3u-test"
"$tmpdir/m3u-test"
