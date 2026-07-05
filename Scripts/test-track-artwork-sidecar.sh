#!/usr/bin/env bash
set -euo pipefail

helper="Core/Artwork/TrackArtworkSidecarWriter.swift"

if [[ ! -f "$helper" ]]; then
    printf 'Missing %s\n' "$helper" >&2
    exit 1
fi

if ! grep -Eq 'artwork\.write\(to: sidecarURL, options: \[[^]]*\.withoutOverwriting' "$helper"; then
    printf 'Sidecar writer must use a no-overwrite write option\n' >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/main.swift" <<'SWIFT'
import Foundation

enum AlbumArtFormat {
    static let supportedExtensions = ["jpg", "jpeg", "png", "tiff", "tif", "bmp"]

    static func isSupported(_ fileExtension: String) -> Bool {
        supportedExtensions.contains(fileExtension.lowercased())
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let audioURL = root.appendingPathComponent("Artist - Song.flac")
let jpgURL = root.appendingPathComponent("Artist - Song.jpg")
let jpegURL = root.appendingPathComponent("Artist - Song.jpeg")
let pngURL = root.appendingPathComponent("Artist - Song.png")
let genericURL = root.appendingPathComponent("cover.jpg")

FileManager.default.createFile(atPath: audioURL.path, contents: Data(), attributes: nil)
FileManager.default.createFile(atPath: genericURL.path, contents: Data([9]), attributes: nil)

guard TrackArtworkSidecarWriter.preferredSidecarURL(forAudioURL: audioURL) == jpgURL else {
    fputs("Downloaded track artwork should be saved beside the audio as a same-stem .jpg\n", stderr)
    exit(1)
}

guard TrackArtworkSidecarWriter.existingSameStemArtworkURL(forAudioURL: audioURL) == nil else {
    fputs("Generic artwork must not count as same-stem artwork\n", stderr)
    exit(1)
}

try TrackArtworkSidecarWriter.write(Data([1, 2, 3]), forAudioURL: audioURL)
guard (try Data(contentsOf: jpgURL)) == Data([1, 2, 3]) else {
    fputs("Sidecar writer did not persist the downloaded image data\n", stderr)
    exit(1)
}

try TrackArtworkSidecarWriter.write(Data([4, 5, 6]), forAudioURL: audioURL)
guard (try Data(contentsOf: jpgURL)) == Data([1, 2, 3]) else {
    fputs("Sidecar writer must not overwrite existing same-stem artwork\n", stderr)
    exit(1)
}

try FileManager.default.removeItem(at: jpgURL)
FileManager.default.createFile(atPath: jpegURL.path, contents: Data([6]), attributes: nil)
FileManager.default.createFile(atPath: pngURL.path, contents: Data([7]), attributes: nil)
try TrackArtworkSidecarWriter.write(Data([8]), forAudioURL: audioURL)
guard !FileManager.default.fileExists(atPath: jpgURL.path) else {
    fputs("Sidecar writer must not create .jpg when another same-stem artwork file exists\n", stderr)
    exit(1)
}

guard TrackArtworkSidecarWriter.existingSameStemArtworkURL(forAudioURL: audioURL) == jpegURL else {
    fputs("Existing same-stem artwork detection should respect supported extension priority\n", stderr)
    exit(1)
}

print("Track artwork sidecar persistence preserved")
SWIFT

swiftc "$helper" "$tmpdir/main.swift" -o "$tmpdir/test-track-artwork-sidecar"
"$tmpdir/test-track-artwork-sidecar" "$tmpdir"
