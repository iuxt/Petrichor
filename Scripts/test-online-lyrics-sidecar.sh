#!/usr/bin/env bash
set -euo pipefail

helper="Core/LyricsSidecarWriter.swift"
manager="Managers/LyricsManager.swift"

if [[ ! -f "$helper" ]]; then
    printf 'Missing %s\n' "$helper" >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/main.swift" <<'SWIFT'
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let audioURL = root.appendingPathComponent("Artist - Song.flac")
let sidecarURL = root.appendingPathComponent("Artist - Song.lrc")
let expectedLyrics = "[00:01.00]Line one\n[00:02.00]Line two\n"

FileManager.default.createFile(atPath: audioURL.path, contents: Data(), attributes: nil)

guard LyricsSidecarWriter.sidecarURL(forAudioURL: audioURL) == sidecarURL else {
    fputs("Online lyrics should be saved beside the audio file with a .lrc extension\n", stderr)
    exit(1)
}

try LyricsSidecarWriter.write(expectedLyrics, forAudioURL: audioURL)
let savedLyrics = try String(contentsOf: sidecarURL, encoding: .utf8)
guard savedLyrics == expectedLyrics else {
    fputs("Sidecar lyrics were not written as UTF-8 LRC text\n", stderr)
    exit(1)
}

try LyricsSidecarWriter.write("replacement", forAudioURL: audioURL)
let unchangedLyrics = try String(contentsOf: sidecarURL, encoding: .utf8)
guard unchangedLyrics == expectedLyrics else {
    fputs("Existing sidecar lyrics should not be overwritten\n", stderr)
    exit(1)
}

print("Online lyrics sidecar persistence preserved")
SWIFT

swiftc "$helper" "$tmpdir/main.swift" -o "$tmpdir/test-online-lyrics-sidecar"
"$tmpdir/test-online-lyrics-sidecar" "$tmpdir"

if ! rg -n "LyricsSidecarWriter\\.write" "$manager" >/dev/null; then
    printf 'LyricsManager must persist fetched lyrics through LyricsSidecarWriter.\n' >&2
    exit 1
fi

if rg -n "updateTrackLyrics" "$manager" >/dev/null; then
    printf 'LyricsManager must not persist fetched lyrics back into the database.\n' >&2
    exit 1
fi
