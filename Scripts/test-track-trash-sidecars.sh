#!/usr/bin/env bash
set -euo pipefail

helper="Core/TrackTrashSidecars.swift"
fallback_helper="Core/TrackTrashFallback.swift"

if [[ ! -f "$helper" ]]; then
    printf 'Missing %s\n' "$helper" >&2
    exit 1
fi

if [[ ! -f "$fallback_helper" ]]; then
    printf 'Missing %s\n' "$fallback_helper" >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/main.swift" <<'SWIFT'
import Foundation

// Minimal stubs of the canonical format enums so TrackTrashSidecars (which references
// AudioFormat / AlbumArtFormat) links without pulling in all of Utilities/Constants.swift.
// The sets mirror the real canonical lists.
enum AudioFormat {
    static let supportedExtensions = [
        "mp3", "m4a", "wav", "aac", "aiff", "aif", "alac",
        "flac", "ogg", "oga", "opus", "ape", "mpc", "wv",
        "tta", "spx", "dsf", "dff", "mod", "it", "s3m", "xm", "au"
    ]
}
enum AlbumArtFormat {
    static let supportedExtensions = ["jpg", "jpeg", "png", "tiff", "tif", "bmp"]
    static let knownFilenames = ["cover", "Cover", "folder", "Folder", "album", "Album", "artwork", "Artwork", "front", "Front"]
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let lonely = root.appendingPathComponent("Lonely.flac")
let shared = root.appendingPathComponent("Shared.flac")
let neighbor = root.appendingPathComponent("Neighbor.mp3")
let trashRoot = root.appendingPathComponent("Trash", isDirectory: true)
try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)

func touch(_ url: URL) {
    FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
}

touch(lonely)
touch(root.appendingPathComponent("Lonely.lrc"))
touch(root.appendingPathComponent("Lonely.srt"))
touch(root.appendingPathComponent("cover.jpg"))

let lonelySidecars = Set(TrackTrashSidecars.sidecarURLs(forAudioURL: lonely).map(\.lastPathComponent))
let expectedLonely: Set<String> = ["Lonely.lrc", "Lonely.srt", "cover.jpg"]
guard lonelySidecars == expectedLonely else {
    fputs("Expected lonely sidecars \(expectedLonely), got \(lonelySidecars)\n", stderr)
    exit(1)
}

touch(shared)
touch(neighbor)
let sharedSidecars = Set(TrackTrashSidecars.sidecarURLs(forAudioURL: shared).map(\.lastPathComponent))
guard !sharedSidecars.contains("cover.jpg") else {
    fputs("Cover artwork should not be trashed while another audio file remains\n", stderr)
    exit(1)
}

let fallbackOne = TrackTrashFallback.fallbackURL(for: lonely, trashDirectory: trashRoot)
guard fallbackOne.path.hasSuffix("Trash/Petrichor/Lonely.flac") else {
    fputs("Unexpected fallback path: \(fallbackOne.path)\n", stderr)
    exit(1)
}
try FileManager.default.createDirectory(at: fallbackOne.deletingLastPathComponent(), withIntermediateDirectories: true)
touch(fallbackOne)
let fallbackTwo = TrackTrashFallback.fallbackURL(for: lonely, trashDirectory: trashRoot)
guard fallbackTwo.path.hasSuffix("Trash/Petrichor/Lonely 2.flac") else {
    fputs("Fallback path should avoid collisions, got \(fallbackTwo.path)\n", stderr)
    exit(1)
}

print("Track trash sidecar rules preserved")
SWIFT

swiftc "$helper" "$fallback_helper" "$tmpdir/main.swift" -o "$tmpdir/test-sidecars"
"$tmpdir/test-sidecars" "$tmpdir"

python3 - <<'PY'
import json
from pathlib import Path

strings = json.loads(Path("Resources/Localizable.xcstrings").read_text())
required = {
    "Move to Trash...": "移到废纸篓...",
    "Move to Trash": "移到废纸篓",
    "Failed to move '%@' to Trash: %@": "无法将“%@”移到废纸篓：%@",
}

missing = []
for key, value in required.items():
    unit = strings.get("strings", {}).get(key, {}).get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {})
    if unit.get("value") != value:
        missing.append(key)

if missing:
    raise SystemExit(f"Missing or incorrect zh-Hans localizations: {', '.join(missing)}")
PY

if ! rg -n "startAccessingSecurityScopedResource|withLibraryFolderAccess" Core/TrackTrashManager.swift >/dev/null; then
    printf 'TrackTrashManager must start security-scoped folder access before moving files to Trash.\n' >&2
    exit 1
fi

if ! rg -n "trashItem\\(at:.*resultingItemURL:" Core/TrackTrashManager.swift >/dev/null; then
    printf 'TrackTrashManager must try FileManager.trashItem before using the compatibility fallback.\n' >&2
    exit 1
fi

if ! rg -n "moveItemToLocalTrashFallback|TrackTrashFallback" Core/TrackTrashManager.swift >/dev/null; then
    printf 'TrackTrashManager must fall back to the user Trash when a source volume has no Trash.\n' >&2
    exit 1
fi

if rg -n "NSWorkspace\\.shared\\.recycle" Core/TrackTrashManager.swift >/dev/null; then
    printf 'TrackTrashManager must not use NSWorkspace.recycle for this action.\n' >&2
    exit 1
fi

python3 - <<'PY'
from pathlib import Path

trash_manager = Path("Core/TrackTrashManager.swift").read_text()
playback_manager = Path("Managers/PlaybackManager.swift").read_text()
queue_manager = Path("Managers/Playlist/PMPlayback.swift").read_text()

prepare_call = "playbackManager.prepareCurrentTrackForTrashMove(track)"
advance_call = "playbackManager.handleTrackMovedToTrash(track)"
trash_call = "moveItemToTrash(audioURL"
restore_call = "playbackManager.restoreCurrentTrackAfterFailedTrashMove"

for needle, message in [
    (prepare_call, "TrackTrashManager must ask PlaybackManager to release the current audio file before trashing."),
    (advance_call, "TrackTrashManager must tell PlaybackManager after the file move succeeds."),
    (restore_call, "TrackTrashManager must restore playback state if the file move fails."),
]:
    if needle not in trash_manager:
        raise SystemExit(message)

if trash_manager.index(prepare_call) > trash_manager.index(trash_call):
    raise SystemExit("Playback must release the current audio file before it is moved to Trash.")

if trash_manager.index(advance_call) < trash_manager.index(trash_call):
    raise SystemExit("Playback queue/library changes must happen only after the current audio file moves to Trash.")

if "func handleTrackMovedToTrash(_ track: Track)" not in playback_manager:
    raise SystemExit("PlaybackManager must expose a focused handler for trashed current tracks.")

if "playNextAfterRemovingCurrentTrack" not in playback_manager:
    raise SystemExit("PlaybackManager must ask PlaylistManager to play the next track after removing the current queue entry.")

if "func playNextAfterRemovingCurrentTrack(_ track: Track) -> Bool" not in queue_manager:
    raise SystemExit("PlaylistManager must support advancing after the current queue entry is removed.")
PY
