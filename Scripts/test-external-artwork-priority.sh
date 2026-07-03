#!/usr/bin/env bash
set -euo pipefail

helper="Core/Metadata/ExternalArtworkResolver.swift"

if [[ ! -f "$helper" ]]; then
    printf 'Missing %s\n' "$helper" >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/main.swift" <<'SWIFT'
import Foundation

enum AlbumArtFormat {
    static let supportedExtensions = ["jpg", "jpeg", "png", "tiff", "tif", "bmp"]
    static let knownFilenames = [
        "cover", "Cover",
        "folder", "Folder",
        "album", "Album",
        "artwork", "Artwork",
        "front", "Front"
    ]

    static func isSupported(_ fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension.lowercased())
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let song = root.appendingPathComponent("Song.flac")
let neighbor = root.appendingPathComponent("Neighbor.flac")
let songPNG = root.appendingPathComponent("Song.png")
let songJPG = root.appendingPathComponent("Song.jpg")
let cover = root.appendingPathComponent("cover.jpg")
let folder = root.appendingPathComponent("folder.png")
let album = root.appendingPathComponent("album.bmp")
let unrelated = root.appendingPathComponent("Other.jpg")

func touch(_ url: URL) {
    FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
}

[song, neighbor, songPNG, songJPG, cover, folder, album, unrelated].forEach(touch)

let candidates = [folder, unrelated, songPNG, cover, songJPG]

guard ExternalArtworkResolver.artworkURL(forAudioURL: song, candidates: candidates) == songJPG else {
    fputs("Same-name artwork should beat generic artwork and use extension priority\n", stderr)
    exit(1)
}

guard ExternalArtworkResolver.artworkURL(forAudioURL: neighbor, candidates: candidates) == cover else {
    fputs("Generic cover artwork should be used when same-name artwork is absent\n", stderr)
    exit(1)
}

guard ExternalArtworkResolver.artworkURL(forAudioURL: neighbor, candidates: [folder]) == folder else {
    fputs("Folder artwork should be used when cover artwork is absent\n", stderr)
    exit(1)
}

guard ExternalArtworkResolver.artworkURL(forAudioURL: neighbor, candidates: [album]) == album else {
    fputs("Album artwork should be used when cover and folder artwork are absent\n", stderr)
    exit(1)
}

guard ExternalArtworkResolver.artworkURL(forAudioURL: neighbor, candidates: [unrelated]) == nil else {
    fputs("Unrelated artwork should not be selected\n", stderr)
    exit(1)
}

print("External artwork priority preserved")
SWIFT

swiftc "$helper" "$tmpdir/main.swift" -o "$tmpdir/test-external-artwork"
"$tmpdir/test-external-artwork" "$tmpdir"
