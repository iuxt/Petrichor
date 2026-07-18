#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REINDEX="$ROOT_DIR/Managers/Database/DMTrackMetadataEditing.swift"
PROCESSING="$ROOT_DIR/Managers/Database/DMTrackProcessing.swift"
ALBUM_AGGREGATE="$ROOT_DIR/Core/Metadata/AlbumMetadataAggregate.swift"

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! rg -n -U "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

reject_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if rg -n -U "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern "$REINDEX" 'func reindexEditedTrack\(' 'The verified-track reindex entry point is missing.'
require_pattern "$REINDEX" 'verified.tags' 'The database must consume verified file values.'
require_pattern "$REINDEX" 'track.albumId = nil' 'Old album association must be cleared before rebuilding.'
require_pattern "$REINDEX" 'try processUpdatedTrack\(' 'Normalized relations must use the existing update path.'
require_pattern "$REINDEX" 'refreshDuplicateGroups\(' 'Only affected duplicate groups must be refreshed.'
require_pattern "$REINDEX" 'pruneOrphanedMetadata\(' 'Old normalized parents must be pruned.'
require_pattern "$REINDEX" 'oldAlbumArtistIDs = try AlbumArtist' 'Old album-only artists must be captured before album mutation.'
require_pattern "$REINDEX" 'oldTrackArtistIDs\.union\(oldAlbumArtistIDs\)' 'Old track and album artist IDs must be pruned together.'
require_pattern "$REINDEX" 'target\.url\.standardizedFileURL == track\.url\.standardizedFileURL' 'A stale track ID must not reindex a different file path.'
require_pattern "$REINDEX" 'verified\.target == target' 'The verified snapshot must belong to the requested target.'
require_pattern "$REINDEX" 'let affectedTracks: \[Track\]' 'The reindex result must return duplicate peers whose flags changed.'
require_pattern "$REINDEX" 'let affectedAlbumIDs = Set\(' 'Old and new album IDs must be collected for relationship rebuilding.'
require_pattern "$REINDEX" 'try rebuildAlbumArtists\(' 'Affected album-artist junctions must be rebuilt authoritatively.'
require_pattern "$REINDEX" 'try rebuildAlbumMetadata\(' 'Affected album metadata aggregates must be rebuilt authoritatively.'
require_pattern "$REINDEX" 'AlbumMetadataAggregator\.aggregate' 'Album aggregate rebuilding must derive values from all remaining tracks.'
require_pattern "$REINDEX" 'album\.releaseDate = aggregate\.releaseDate' 'Album release dates must support replacement and clearing.'
require_pattern "$REINDEX" 'album\.releaseYear = aggregate\.releaseYear' 'Album release years must support replacement and clearing.'
require_pattern "$REINDEX" 'album\.totalDiscs = aggregate\.totalDiscs' 'Album disc totals must support decreases and clearing.'
require_pattern "$REINDEX" 'AlbumArtist[\s\S]*\.deleteAll\(db\)' 'Album-artist rebuilding must remove stale junctions before inserting current relationships.'
require_pattern "$REINDEX" 'try updateEntityStats\(in: db\)' 'Artist and album aggregate counts must refresh in the reindex transaction.'
require_pattern "$REINDEX" 'private func refreshDuplicateGroups\([\s\S]*\) throws -> \[Track\]' 'Duplicate refresh must return every affected lightweight track.'
reject_pattern "$REINDEX" 'scan|processFilesInBatches|refreshFolder' 'Metadata saving must not rescan a folder.'
reject_pattern "$PROCESSING" 'processUpdatedTrack\([^\n]*metadata:' 'The unused metadata parameter must be removed.'

if [[ ! -f "$ALBUM_AGGREGATE" ]]; then
    printf '%s\n' 'The authoritative album metadata aggregator is missing.' >&2
    exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-album-metadata.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func input(
    id: Int64,
    track: Int?,
    date: String?,
    year: String = "",
    discs: Int?
) -> AlbumMetadataAggregateInput {
    AlbumMetadataAggregateInput(
        trackID: id,
        trackNumber: track,
        releaseDate: date,
        year: year,
        totalDiscs: discs
    )
}

let original = AlbumMetadataAggregator.aggregate([
    input(id: 1, track: 1, date: "2024", discs: 2)
])
expect(original.releaseDate == "2024", "baseline release date")
expect(original.releaseYear == 2024, "baseline release year")
expect(original.totalDiscs == 2, "baseline disc total")

let replaced = AlbumMetadataAggregator.aggregate([
    input(id: 1, track: 1, date: "2025-03-04", discs: 1)
])
expect(replaced.releaseDate == "2025-03-04", "release date replacement")
expect(replaced.releaseYear == 2025, "release year replacement")
expect(replaced.totalDiscs == 1, "disc total decrease")

let cleared = AlbumMetadataAggregator.aggregate([
    input(id: 1, track: 1, date: nil, discs: nil)
])
expect(cleared.releaseDate == nil, "release date clearing")
expect(cleared.releaseYear == nil, "release year clearing")
expect(cleared.totalDiscs == nil, "disc total clearing")

let multiTrack = AlbumMetadataAggregator.aggregate([
    input(id: 20, track: 2, date: "2026", discs: 3),
    input(id: 10, track: 1, date: "2025", discs: 2)
])
expect(multiTrack.releaseDate == "2025", "track-order representative date")
expect(multiTrack.releaseYear == 2025, "track-order representative year")
expect(multiTrack.totalDiscs == 3, "maximum remaining disc total")

let yearFallback = AlbumMetadataAggregator.aggregate([
    input(id: 1, track: nil, date: nil, year: "2023", discs: nil)
])
expect(yearFallback.releaseDate == nil, "year fallback must not invent a date")
expect(yearFallback.releaseYear == 2023, "legacy year fallback")

let belowSchemaRange = AlbumMetadataAggregator.aggregate([
    input(id: 1, track: 1, date: "1800", discs: nil)
])
expect(
    belowSchemaRange.releaseYear == nil,
    "release year below the album schema range"
)

let aboveSchemaRange = AlbumMetadataAggregator.aggregate([
    input(id: 1, track: 1, date: "2101", discs: nil)
])
expect(
    aboveSchemaRange.releaseYear == nil,
    "release year above the album schema range"
)

print("Album metadata aggregate behavior checks passed")
SWIFT

swiftc \
    -module-cache-path "${SWIFT_MODULECACHE_PATH:-$TMP_DIR/swift-module-cache}" \
    "$ALBUM_AGGREGATE" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/album-metadata-test"

"$TMP_DIR/album-metadata-test"

printf '%s\n' 'Track metadata reindex checks passed'
