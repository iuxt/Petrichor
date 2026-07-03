#!/usr/bin/env bash
set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/main.swift" <<'SWIFT'
import Foundation

let root = URL(fileURLWithPath: "/Music")
let playlistFile = root.appendingPathComponent("playlists/Rock.m3u")

let content = """
#EXTM3U
#EXTINF:123,Artist - Title
Artist/Album/Song.flac

./Other/Track.mp3
file:///Music/Encoded%20Name.m4a
"""

let entries = M3UPlaylistCodec.parseTrackEntries(from: content)
precondition(entries == [
    "Artist/Album/Song.flac",
    "./Other/Track.mp3",
    "file:///Music/Encoded%20Name.m4a"
], "Unexpected entries: \(entries)")

let rootRelative = M3UPlaylistCodec.pathVariations(
    for: "Artist/Album/Song.flac",
    musicFolder: root,
    playlistFileURL: playlistFile
)
precondition(rootRelative[0] == "/Music/Artist/Album/Song.flac", rootRelative.joined(separator: "|"))
precondition(rootRelative.contains("/Music/playlists/Artist/Album/Song.flac"), rootRelative.joined(separator: "|"))

let encoded = M3UPlaylistCodec.pathVariations(
    for: "file:///Music/Encoded%20Name.m4a",
    musicFolder: root,
    playlistFileURL: playlistFile
)
precondition(encoded.first == "/Music/Encoded Name.m4a", encoded.joined(separator: "|"))

let rendered = M3UPlaylistCodec.render(
    trackURLs: [
        root.appendingPathComponent("Artist/Album/Song.flac"),
        URL(fileURLWithPath: "/External/Loose.mp3")
    ],
    musicFolder: root
)
precondition(rendered.contains("Artist/Album/Song.flac"), rendered)
precondition(rendered.contains("/External/Loose.mp3"), rendered)
precondition(rendered.hasPrefix("#EXTM3U\r\n"), rendered)

print("M3U codec checks passed")
SWIFT

swiftc Core/M3UPlaylistCodec.swift "$tmpdir/main.swift" -o "$tmpdir/codec-test"
"$tmpdir/codec-test"
