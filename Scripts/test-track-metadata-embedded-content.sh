#!/usr/bin/env bash
set -euo pipefail

# Exercises the production file service on disposable MP3/FLAC/M4A/Ogg files.
# Build Debug first; override PETRICHOR_DERIVED_DATA_DIR and FFMPEG as needed.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
DERIVED="${PETRICHOR_DERIVED_DATA_DIR:-}"
if [[ -z "$DERIVED" ]]; then
    for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/Petrichor-*; do
        if [[ -f "$candidate/Build/Products/Debug/SFBAudioEngine.o" ]]; then
            DERIVED="$candidate"
            break
        fi
    done
fi
if [[ ! -x "$FFMPEG" || ! -f "$DERIVED/Build/Products/Debug/SFBAudioEngine.o" ]]; then
    printf '%s\n' 'Requires ffmpeg and a Debug build (PETRICHOR_DERIVED_DATA_DIR).' >&2
    exit 1
fi
PRODUCTS="$DERIVED/Build/Products/Debug"
CHECKOUTS="$DERIVED/SourcePackages/checkouts"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-embedded-content.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

for format in mp3 flac m4a ogg; do
    "$FFMPEG" -hide_banner -loglevel error -f lavfi \
        -i 'sine=frequency=440:sample_rate=44100' -t 0.2 "$TMP_DIR/sample.$format"
done

cat >"$TMP_DIR/Harness.swift" <<'SWIFT'
import Foundation
import SFBAudioEngine

extension String {
    init(appLocalized key: String) { self = key }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct Harness {
    static func main() async throws {
        let service = SFBTrackMetadataFileService()
        let picture = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aVxkAAAAASUVORK5CYII=")!
        for path in CommandLine.arguments.dropFirst() {
            let source = URL(fileURLWithPath: path)
            let file = try AudioFile(readingPropertiesAndMetadataFrom: source)
            file.metadata.title = "Keep this title"
            file.metadata.artist = "Keep this artist"
            file.metadata.comment = "Keep this comment"
            file.metadata.lyrics = "[00:01.00]内嵌歌词\n[00:02.00]Second line"
            file.metadata.attachPicture(AttachedPicture(imageData: picture, type: .frontCover))
            file.metadata.attachPicture(AttachedPicture(imageData: picture, type: .backCover))
            try file.writeMetadata()

            for artworkFirst in [false, true] {
                let url = source.deletingPathExtension().appendingPathExtension(artworkFirst ? "art-first" : "lyrics-first")
                    .appendingPathExtension(source.pathExtension)
                try FileManager.default.copyItem(at: source, to: url)
                let sidecar = url.deletingPathExtension().appendingPathExtension("lrc")
                let external = url.deletingPathExtension().appendingPathExtension("jpg")
                try Data("External lyrics".utf8).write(to: sidecar)
                try picture.write(to: external)
                let target = TrackMetadataEditTarget(trackID: nil, url: url)
                guard case .loaded(let original) = await service.load(target: target) else {
                    fatalError("Could not read \(url)")
                }
                expect(original.isWritable, "Fixture must be writable")
                expect(original.embeddedLyrics != nil && !original.embeddedArtwork.isEmpty, "Embedded preview must come from the file")
                var patch = TrackMetadataPatch()
                patch.removeEmbeddedLyrics = !artworkFirst
                patch.removeEmbeddedArtwork = artworkFirst
                expect(!patch.isEmpty, "Content-only deletion must be a nonempty patch")
                let first = try await service.write(target: target, patch: patch)
                expect(first.tags == original.tags, "Deleting content must preserve all editable tags")
                if artworkFirst {
                    expect(first.embeddedArtwork.isEmpty && first.embeddedLyrics == original.embeddedLyrics, "Artwork deletion must preserve lyrics")
                } else {
                    expect(first.embeddedLyrics == nil && Set(first.embeddedArtwork) == Set(original.embeddedArtwork), "Lyrics deletion must preserve artwork")
                }
                patch.removeEmbeddedLyrics = artworkFirst
                patch.removeEmbeddedArtwork = !artworkFirst
                let second = try await service.write(target: target, patch: patch)
                expect(second.embeddedLyrics == nil && second.embeddedArtwork.isEmpty, "Both embedded fields must be deleted")
                expect(second.tags == original.tags, "Sequential deletion must preserve tags")
                let externalLyrics = try Data(contentsOf: sidecar)
                let externalArtwork = try Data(contentsOf: external)
                expect(externalLyrics == Data("External lyrics".utf8) && externalArtwork == picture, "External files must be untouched")
                print("Embedded content removal passed: \(url.lastPathComponent)")
            }
        }
    }
}
SWIFT

xcrun clang++ -std=c++17 -fobjc-arc \
    -I"$CHECKOUTS/CXXTagLib/Sources/taglib/include" \
    -c "$ROOT_DIR/Core/Metadata/ID3TagWriterBridge.mm" -o "$TMP_DIR/bridge.o"

MODULE_FLAGS=()
for map in "$CHECKOUTS"/CXX*/Sources/*/include/module.modulemap; do
    MODULE_FLAGS+=(-Xcc "-fmodule-map-file=$map")
done
MODULE_FLAGS+=(-Xcc "-fmodule-map-file=$DERIVED/Build/Intermediates.noindex/GeneratedModuleMaps/CSFBAudioEngine.modulemap")
OBJECTS=()
for name in SFBAudioEngine CSFBAudioEngine AVFAudioExtensions CXXAudioRingBuffer \
    CXXDispatchSemaphore CXXRingBuffer CXXUnfairLock MAC dumb speex taglib; do
    OBJECTS+=("$PRODUCTS/$name.o")
done
FRAMEWORK_FLAGS=()
for name in wavpack ogg FLAC opus vorbis lame mpc mpg123 sndfile tta-cpp; do
    FRAMEWORK_FLAGS+=(-framework "$name")
done
xcrun swiftc -parse-as-library -swift-version 5 \
    -I "$PRODUCTS" -I "$CHECKOUTS/SFBAudioEngine/Sources/CSFBAudioEngine/include" -F "$PRODUCTS" -F "$PRODUCTS/PackageFrameworks" \
    "${MODULE_FLAGS[@]}" -import-objc-header "$ROOT_DIR/Core/Metadata/ID3TagWriterBridge.h" \
    "$ROOT_DIR/Core/Metadata/TrackMetadataEditModel.swift" \
    "$ROOT_DIR/Core/Metadata/ID3TrackMetadataWriter.swift" \
    "$ROOT_DIR/Core/Metadata/SFBTrackMetadataFileService.swift" \
    "$TMP_DIR/Harness.swift" "$TMP_DIR/bridge.o" "${OBJECTS[@]}" \
    "${FRAMEWORK_FLAGS[@]}" -framework Accelerate -framework AudioToolbox \
    -framework AVFAudio -framework CoreAudio -framework ImageIO -framework UniformTypeIdentifiers \
    -lc++ -lz -Xlinker -rpath -Xlinker "$PRODUCTS" -o "$TMP_DIR/harness"

"$TMP_DIR/harness" "$TMP_DIR/sample.mp3" "$TMP_DIR/sample.flac" "$TMP_DIR/sample.m4a" "$TMP_DIR/sample.ogg"
for format in mp3 flac m4a ogg; do
    before="$("$FFMPEG" -v error -i "$TMP_DIR/sample.$format" -map 0:a:0 -f hash -hash sha256 -)"
    for order in art-first lyrics-first; do
        after="$("$FFMPEG" -v error -i "$TMP_DIR/sample.$order.$format" -map 0:a:0 -f hash -hash sha256 -)"
        [[ "$before" == "$after" ]] || { printf '%s\n' "Audio changed: $format ($order)" >&2; exit 1; }
    done
done
printf '%s\n' 'Embedded content real-file checks passed; decoded audio is unchanged.'
