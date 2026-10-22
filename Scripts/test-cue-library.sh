#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-cue-library.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
# Compile the real metadata projection and CUE preparation with an in-memory
# metadata reader. No user library, network or audio output is involved.
python3 - "$ROOT_DIR" "$TMP_DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
full = (root/'Models/Core/FullTrack.swift').read_text()
fields = full[full.index('    let id = UUID()'):full.index('    // MARK: - DB Configuration')]
metadata = (root/'Core/Metadata/MetadataEngine.swift').read_text()
metadata = metadata[metadata.index('struct TrackMetadata'):metadata.index('// MARK: - Metadata Reader')]
apply = (root/'Managers/Database/DMMetadata.swift').read_text()
apply = apply[apply.index('    func applyMetadataToTrack'):apply.index('    func updateTrackIfNeeded')]
prepare = (root/'Managers/Database/DMCueTracks.swift').read_text()
prepare = prepare[prepare.index('    func prepareCueTracks'):prepare.index('    func saveCueTracks')]
(out/'Projection.swift').write_text('''import Foundation
struct ExtendedMetadata { var lyrics: String? }
extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
enum HelperUtils { static func sanitizedDuration(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 } }
enum Logger { static func warning(_ message: String) {} }
struct FullTrack {
'''+fields+'}\n'+metadata+'''
class DatabaseManager {
'''+apply+prepare+'}\n'+'''
enum MetadataEngine {
    static var values: [String: TrackMetadata] = [:]
    static var reads = 0
    static func extractMetadata(from url: URL) async -> TrackMetadata {
        reads += 1
        return values[url.path] ?? TrackMetadata(url: url)
    }
}
''')
PY
cat > "$TMP_DIR/Harness.swift" <<'SWIFT'
import Foundation
@main struct Main {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cue = root.appendingPathComponent("Album.cue")
        let source = root.appendingPathComponent("image.flac")
        var metadata = TrackMetadata(url: source)
        metadata.title = "Whole image"
        metadata.artist = "Embedded artist"
        metadata.album = "Embedded album"
        metadata.duration = 300
        metadata.sampleRate = 44100
        metadata.codec = "FLAC"
        metadata.sortTitle = "Whole image sort title"
        MetadataEngine.values[source.path] = metadata
        let content = """
        TITLE "Album"
        PERFORMER "Album artist"
        REM DATE 2025
        FILE image.flac WAVE
          TRACK 01 AUDIO
            TITLE "First"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second"
            PERFORMER "Guest"
            INDEX 01 02:30:00
        """
        try content.write(to: cue, atomically: true, encoding: .utf8)
        let database = DatabaseManager()
        let imported = await database.prepareCueTracks(sheets: [cue], audioURLs: [source], folderId: 7, existing: [:]).map(\.0)
        precondition(imported.count == 2)
        precondition(MetadataEngine.reads == 1, "Read a shared audio source once per scan")
        precondition(imported.map(\.title) == ["First", "Second"])
        precondition(imported.allSatisfy { $0.album == "Album" && $0.albumArtist == "Album artist" && $0.year == "2025" && $0.folderId == 7 })
        precondition(imported.map(\.artist) == ["Album artist", "Guest"])
        precondition(imported.map(\.duration) == [150, 150])
        precondition(imported.map(\.trackNumber) == [1, 2])
        precondition(imported.allSatisfy { $0.sampleRate == 44100 && $0.codec == "FLAC" && $0.sortTitle == nil })
        precondition(imported[0].libraryPath != imported[1].libraryPath)
        var old = imported[1]
        old.trackId = 42
        old.playCount = 9
        old.dateAdded = Date(timeIntervalSince1970: 1000)
        try content.replacingOccurrences(of: "Second", with: "Renamed").write(to: cue, atomically: true, encoding: .utf8)
        let refreshed = await database.prepareCueTracks(sheets: [cue], audioURLs: [source], folderId: 7, existing: [old.libraryPath: old]).map(\.0)
        precondition(refreshed[1].title == "Renamed" && refreshed[1].trackId == 42 && refreshed[1].playCount == 9 && refreshed[1].dateAdded == old.dateAdded)
        let replacement = root.appendingPathComponent("replacement.wav")
        MetadataEngine.values[replacement.path] = metadata
        try content.replacingOccurrences(of: "image.flac", with: "replacement.wav").write(to: cue, atomically: true, encoding: .utf8)
        let changed = await database.prepareCueTracks(sheets: [cue], audioURLs: [replacement], folderId: 7, existing: [old.libraryPath: old]).map(\.0)
        precondition(changed[1].trackId == 42 && changed[1].url == replacement && changed[1].format == "wav")
        try content.write(to: cue, atomically: true, encoding: .utf8)
        let missing = await database.prepareCueTracks(sheets: [cue], audioURLs: [], folderId: 7, existing: [:])
        precondition(missing.isEmpty, "Missing source cannot claim/hide audio")
        try content.replacingOccurrences(of: "02:30:00", with: "06:00:00").write(to: cue, atomically: true, encoding: .utf8)
        let invalid = await database.prepareCueTracks(sheets: [cue], audioURLs: [source], folderId: 7, existing: [:])
        precondition(invalid.isEmpty, "Reject the whole sheet if any boundary exceeds source duration")
        try content.write(to: cue, atomically: true, encoding: .utf8)
        let other = root.appendingPathComponent("Other.cue")
        try content.write(to: other, atomically: true, encoding: .utf8)
        let duplicate = await database.prepareCueTracks(sheets: [other, cue], audioURLs: [source], folderId: 7, existing: [:])
        precondition(duplicate.count == 2, "Competing sheets must not duplicate the album")
        let b = root.appendingPathComponent("b.flac")
        var secondMetadata = metadata
        secondMetadata.duration = 120
        MetadataEngine.values[b.path] = secondMetadata
        try """
        FILE image.flac WAVE
        TRACK 01 AUDIO
        INDEX 01 01:00:00
        FILE b.flac WAVE
        TRACK 02 AUDIO
        INDEX 01 00:00:00
        """.write(to: cue, atomically: true, encoding: .utf8)
        let multi = await database.prepareCueTracks(sheets: [cue], audioURLs: [source, b], folderId: 7, existing: [:]).map(\.0)
        precondition(multi.map(\.duration) == [240, 120], "FILE offsets are local; each last track ends at its own source EOF")
        precondition(multi.allSatisfy { $0.album == "Album" && $0.albumArtist == "Embedded artist" }, "Missing sheet metadata still produces one album")
        print("CUE library metadata, bounds, history, file changes, conflicts and multi-file checks passed")
    }
}
SWIFT
xcrun swiftc "$ROOT_DIR/Core/Cue/CueSheet.swift" "$TMP_DIR/Projection.swift" "$TMP_DIR/Harness.swift" -o "$TMP_DIR/cue-library-test"
"$TMP_DIR/cue-library-test" "$TMP_DIR/library"
