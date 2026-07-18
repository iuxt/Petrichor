#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-metadata-model.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cp "$ROOT_DIR/Core/Metadata/TrackMetadataEditModel.swift" "$TMP_DIR/TrackMetadataEditModel.swift"

cat >"$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let first = TrackEditableTags(
    title: "One",
    artist: "Artist",
    album: nil,
    albumArtist: nil,
    composer: nil,
    genre: "Rock",
    releaseDate: "2025",
    trackNumber: 1,
    trackTotal: 10,
    discNumber: 1,
    discTotal: 1,
    bpm: 120,
    compilation: false,
    comment: nil
)
let second = TrackEditableTags(
    title: "Two",
    artist: "Artist",
    album: "",
    albumArtist: nil,
    composer: nil,
    genre: "Jazz",
    releaseDate: "2025",
    trackNumber: 2,
    trackTotal: 10,
    discNumber: 1,
    discTotal: 1,
    bpm: 120,
    compilation: true,
    comment: nil
)

var form = TrackMetadataEditForm(tags: [first, second])
expect(form.artist.text == "Artist", "common artist must be displayed")
expect(!form.artist.showsMixedPlaceholder, "common artist must not be mixed")
expect(form.title.text.isEmpty, "mixed title control must start empty")
expect(form.title.showsMixedPlaceholder, "mixed title must show the placeholder")
expect(form.album.text.isEmpty, "nil and empty album must aggregate as empty")
expect(!form.album.showsMixedPlaceholder, "nil and empty album must be equal")
expect(form.compilation.value == nil, "mixed compilation must be indeterminate")

let untouched = try form.makePatch()
expect(untouched.isEmpty, "untouched mixed values must produce no patch")

form.setText("Shared", for: .title)
form.setText("", for: .genre)
form.setText("2024-02-29", for: .releaseDate)
form.setCompilation(false)
let changed = try form.makePatch()
expect(changed.title == .set("Shared"), "typed title must apply to every file")
expect(changed.genre == .remove, "cleared dirty genre must remove the tag")
expect(changed.releaseDate == .set("2024-02-29"), "valid ISO date must be retained")
expect(changed.compilation == .set(false), "compilation off must be explicit")
expect(
    TrackMetadataPatch(album: .remove).mismatchedFields(in: second).isEmpty,
    "empty stored strings must compare as absent tags"
)

var newlineForm = TrackMetadataEditForm(tags: [first])
newlineForm.setText(
    "  A\nB\r\nC\u{000B}D\u{000C}E\u{0085}F\u{2028}G\u{2029}H  ",
    for: .title
)
newlineForm.setText("  First line\nSecond line\r\nThird line  ", for: .comment)
let newlinePatch = try newlineForm.makePatch()
expect(
    newlinePatch.title == .set("A B C D E F G H"),
    "single-line fields must flatten every Foundation newline sequence to one space"
)
expect(
    newlinePatch.comment == .set("First line\nSecond line\r\nThird line"),
    "comments must preserve internal newlines"
)

let retryResults = [
    TrackMetadataBatchResult(target: .init(trackID: 1, url: URL(fileURLWithPath: "/tmp/one.flac")), outcome: .saved),
    TrackMetadataBatchResult(target: .init(trackID: 2, url: URL(fileURLWithPath: "/tmp/two.flac")), outcome: .failed("write")),
    TrackMetadataBatchResult(target: .init(trackID: 3, url: URL(fileURLWithPath: "/tmp/three.aac")), outcome: .skipped("read-only"))
]
expect(
    TrackMetadataBatchResult.retryTargets(from: retryResults).map(\.trackID) == [2],
    "retry must include failed writable targets only"
)

form.setText("2023-02-29", for: .releaseDate)
do {
    _ = try form.makePatch()
    expect(false, "invalid calendar date must fail validation")
} catch let error as TrackMetadataValidationError {
    expect(error.field == .releaseDate, "date error must identify release date")
    expect(
        error.kind == .invalidReleaseDate,
        "date validation must expose a structured failure kind"
    )
    expect(
        error.message == "The release date must use YYYY or YYYY-MM-DD.",
        "date validation must retain an English standalone fallback"
    )
}

form.setText("", for: .releaseDate)
form.setText("0", for: .bpm)
do {
    _ = try form.makePatch()
    expect(false, "zero BPM must fail validation")
} catch let error as TrackMetadataValidationError {
    expect(error.field == .bpm, "integer error must identify BPM")
    expect(
        error.kind == .positiveInteger,
        "integer validation must expose a structured failure kind"
    )
    expect(
        error.message == "BPM must be a positive integer.",
        "integer validation must retain an English standalone fallback"
    )
}

var restoredMixed = TrackMetadataEditForm(tags: [first, second])
restoredMixed.setText("temporary", for: .title)
restoredMixed.setText("", for: .title)
let restoredMixedPatch = try restoredMixed.makePatch()
expect(
    restoredMixedPatch.title == .remove,
    "typing then clearing a mixed field must be an explicit removal"
)

print("Track metadata edit model checks passed")
SWIFT

xcrun swiftc \
    "$TMP_DIR/TrackMetadataEditModel.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/test-track-metadata-edit-model"
"$TMP_DIR/test-track-metadata-edit-model"
