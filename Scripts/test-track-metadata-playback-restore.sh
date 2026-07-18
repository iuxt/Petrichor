#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLAYBACK="$ROOT_DIR/Managers/PlaybackManager.swift"
SUSPENSION="$ROOT_DIR/Core/Playback/MetadataEditPlaybackSuspension.swift"
NOW_PLAYING="$ROOT_DIR/Managers/NowPlayingManager.swift"
PLAYLIST="$ROOT_DIR/Managers/Playlist/PMTrackUpdate.swift"
LIBRARY="$ROOT_DIR/Managers/Library/LMTrackMetadataEditing.swift"
ENGINE="$ROOT_DIR/Core/Playback/PlaybackEngine.swift"
CRESCENDO="$ROOT_DIR/Core/Playback/CrescendoPlaybackBackend.swift"
SFB="$ROOT_DIR/Core/Playback/SFBPlaybackBackend.swift"

failures=0

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! rg -n -U "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        failures=$((failures + 1))
    fi
}

require_pattern "$PLAYBACK" 'struct MetadataEditPlaybackSnapshot' 'Playback metadata snapshot is missing.'
require_pattern "$PLAYBACK" 'let suspensionGeneration: UInt64' 'Playback snapshots must identify their metadata-write suspension.'
require_pattern "$PLAYBACK" 'private var metadataEditSuspension: MetadataEditPlaybackSuspension\?' 'PlaybackManager must retain an active metadata-write suspension.'
require_pattern "$PLAYBACK" 'private var metadataEditSuspensionGeneration: UInt64' 'Metadata-write suspensions must use a monotonic generation.'
require_pattern "$PLAYBACK" 'let queueIndex: Int' 'The snapshot must preserve queue position.'
require_pattern "$PLAYBACK" 'func prepareCurrentTrackForMetadataEdit' 'Playback preparation is missing.'
require_pattern "$PLAYBACK" 'let wasPlaying = wantsPlaybackActive \|\| isPlaying' 'Playback restoration must snapshot the requested playing intent.'
require_pattern "$PLAYBACK" 'func restoreCurrentTrackAfterMetadataEdit' 'Playback restoration is missing.'
require_pattern "$PLAYBACK" 'var shouldResume: Bool' 'Pending restoration intent must remain mutable until the paused callback.'
require_pattern "$PLAYBACK" 'if pending.shouldResume' 'Paused restoration must not resume.'
require_pattern "$PLAYBACK" 'seekToPosition > 0 \|\| !resumeAfterRestore' 'A paused track at zero must remain paused.'
require_pattern "$PLAYBACK" 'restoreQueueIndexAfterMetadataEdit\(queueIndex\)' 'An authoritative snapshot queue index must be restored through PlaylistManager.'
require_pattern "$PLAYBACK" 'currentArtworkIdentity = nil' 'Album changes must invalidate current artwork identity.'
require_pattern "$PLAYBACK" 'metadataRestoreCompletion' 'Playback restoration must report its terminal result.'
require_pattern "$PLAYBACK" 'metadataRestoreGeneration' 'Playback restoration timeouts must be generation-guarded.'
require_pattern "$PLAYBACK" 'struct MetadataRestoreOperation' 'Playback restoration must bind completion to an engine entry.'
require_pattern "$PLAYBACK" 'cancelMetadataRestoreForPlaybackChange' 'Superseding playback must terminate metadata restoration.'
require_pattern "$PLAYBACK" 'handleMetadataRestoreTimeout' 'Timed-out restoration must neutralize its pending engine entry.'
require_pattern "$PLAYBACK" 'pending.track == next.track' 'Edited gapless lookahead metadata must be re-primed.'
require_pattern "$PLAYBACK" 'pendingNext\?\.track\.trackId == track\.trackId' 'Cached gapless metadata must be invalidated synchronously.'
require_pattern "$PLAYLIST" 'func applyMetadataEditResult' 'Queue and playlist cache replacement is missing.'
require_pattern "$PLAYLIST" 'playlists\[playlistIndex\]\.tracks\[trackIndex\]\.trackId' 'Loaded playlist tracks must be replaced by ID.'
require_pattern "$PLAYLIST" 'audioPlayer\?\.applyMetadataEditResult\(track\)' 'Playback caches must receive edited track values.'
require_pattern "$LIBRARY" 'func applyMetadataEditResult' 'Library cache replacement is missing.'
require_pattern "$LIBRARY" 'refreshLibraryCategories\(\)' 'Metadata categories must refresh.'
require_pattern "$LIBRARY" 'refreshEntities\(notify: false\)' 'Album and artist entities must refresh without duplicate notification.'
require_pattern "$ENGINE" 'func backendUnexpectedError\(error: AudioPlayerError, entryId: AudioEntryId\?\)' 'Backend errors must propagate their originating entry identity.'
require_pattern "$ENGINE" 'audioPlayerUnexpectedError\(player: self, error: error, entryId: entryId\)' 'The playback facade must forward error entry identity.'
require_pattern "$CRESCENDO" 'owner\?\.handleError\(error, entryId: entryId\)' 'Crescendo must preserve the entry identity supplied by its error callback.'
require_pattern "$SFB" 'backendUnexpectedError\(error: \.engineError\(error\), entryId: entryId\)' 'Known SFB playback errors must preserve their entry identity.'
require_pattern "$PLAYBACK" 'let originatingEntryId,\s+originatingEntryId == operation.entryId' 'Only an error from the restoring entry may fail metadata restoration.'
require_pattern "$PLAYBACK" 'guard finishedEntryIsCurrent else \{\s+Logger\.error\(\"Ignoring stale playback error for non-current entry' 'A stale error finish must not tear down current playback.'
require_pattern "$PLAYBACK" 'let snapshotPosition = currentTime\.isFinite && currentTime >= 0 \? currentTime : 0' 'Metadata playback snapshots must sanitize invalid positions.'
require_pattern "$PLAYBACK" 'position: snapshotPosition' 'The metadata snapshot must store the sanitized position.'
require_pattern "$PLAYBACK" 'pending\.shouldResume\.toggle\(\)' 'A toggle during pending restoration must change only its requested intent.'
require_pattern "$PLAYBACK" 'if togglePendingMetadataRestoreIntent\(\) \{\s+return\s+\}\s+cancelMetadataRestoreForPlaybackChange\(\)' 'Pending restore intent must be handled before cancellation.'
require_pattern "$PLAYBACK" 'deferMetadataEditPlayIfNeeded\(track\)' 'Same-track play must defer while its metadata file is being written.'
require_pattern "$PLAYBACK" 'stageMetadataEditSupersedingTrack\(track\)' 'Different-track loading must clear the edited FullTrack before returning to normal transport.'
require_pattern "$PLAYBACK" 'deferMetadataEditToggleIfNeeded\(\)' 'Toggle must update the suspended post-write intent.'
require_pattern "$PLAYBACK" 'deferMetadataEditStopIfNeeded\(\)' 'Stop must update the suspended post-write intent.'
require_pattern "$PLAYBACK" 'deferMetadataEditSeekIfNeeded\(time:' 'Seek must update the suspended post-write position.'
require_pattern "$PLAYBACK" 'func requestPlay\(\) -> Bool' 'Explicit remote Play must have non-toggle semantics.'
require_pattern "$PLAYBACK" 'func requestPause\(\) -> Bool' 'Explicit remote Pause must have non-toggle semantics.'
require_pattern "$PLAYBACK" 'setPendingMetadataRestoreIntent\(shouldResume: true\)' 'Explicit Play must idempotently update an in-flight restore.'
require_pattern "$PLAYBACK" 'setPendingMetadataRestoreIntent\(shouldResume: false\)' 'Explicit Pause must idempotently update an in-flight restore.'
require_pattern "$PLAYBACK" 'consumeMetadataEditSuspension\(for: snapshot\)' 'Restoration must consume only its matching metadata-write suspension.'
require_pattern "$PLAYBACK" 'if let queueIndex = restoration\.queueIndex' 'A superseding queue choice must not be rewound to the snapshot index.'
require_pattern "$NOW_PLAYING" 'audioPlayer\.requestPlay\(\)' 'Remote Play must set an explicit playing intent.'
require_pattern "$NOW_PLAYING" 'audioPlayer\.requestPause\(\)' 'Remote Pause must set an explicit paused intent.'

if [[ ! -f "$SUSPENSION" ]]; then
    printf '%s\n' 'The metadata-write suspension reducer is missing.' >&2
    failures=$((failures + 1))
fi

if (( failures > 0 )); then
    exit 1
fi

python3 - "$PLAYBACK" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()

def body(start_marker: str, end_marker: str) -> str:
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    return source[start:end]

prepare = body(
    "func prepareCurrentTrackForMetadataEdit",
    "func applyMetadataEditResult",
)
if prepare.index("metadataEditSuspension =") > prepare.index("audioPlayer.stop()"):
    raise SystemExit(
        "The metadata-write suspension must become active before preparation stops the engine."
    )

play = body("func playTrack(_ track: Track)", "func togglePlayPause()")
if play.index("deferMetadataEditPlayIfNeeded(track)") > play.index(
    "cancelMetadataRestoreForPlaybackChange()"
):
    raise SystemExit(
        "Play requests must consult the active write suspension before normal playback starts."
    )

deferred_play = body(
    "private func deferMetadataEditPlayIfNeeded",
    "private func stageMetadataEditSupersedingTrack",
)
same_track_branch = deferred_play[deferred_play.index("case .deferEditedTrack:"):]
for forbidden in (
    "currentTrack = track",
    "refreshCurrentTrackArtworkIfNeeded",
    "ArtworkResolver",
):
    if forbidden in same_track_branch:
        raise SystemExit(
            "Deferred same-track play must not publish the edited track or trigger "
            f"artwork/file reads during its metadata write ({forbidden})."
        )

toggle = body("func togglePlayPause()", "func stop()")
if toggle.index("deferMetadataEditToggleIfNeeded()") > toggle.index(
    "togglePendingMetadataRestoreIntent()"
):
    raise SystemExit(
        "Toggle must update a write-window intent before consulting post-write restoration."
    )

stop = body("func stop()", "func stopGracefully()")
if stop.index("deferMetadataEditStopIfNeeded()") > stop.index(
    "cancelMetadataRestoreForPlaybackChange()"
):
    raise SystemExit(
        "Stop must be deferred before the public transport path tears playback down."
    )

seek = body("func seekTo(time: Double)", "func setVolume")
if seek.index("deferMetadataEditSeekIfNeeded(time: time)") > seek.index(
    "audioPlayer.seek("
):
    raise SystemExit(
        "Seek must update the suspension before any engine seek can touch the edited file."
    )

restore = body(
    "func restoreCurrentTrackAfterMetadataEdit",
    "func restoreCurrentTrackAfterFailedTrashMove",
)
consume = restore.index("consumeMetadataEditSuspension(for: snapshot)")
for mutation in (
    "restoreQueueIndexAfterMetadataEdit",
    "currentTrack = track",
    "startPlayback(",
):
    if consume > restore.index(mutation):
        raise SystemExit(
            f"Restoration must consume its generation before {mutation} mutates playback."
        )
PY

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-metadata-suspension.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let editedURL = URL(fileURLWithPath: "/tmp/music/../music/edited.flac")
let canonicalEditedURL = URL(fileURLWithPath: "/tmp/music/edited.flac")
let otherURL = URL(fileURLWithPath: "/tmp/music/other.flac")

var playing = MetadataEditPlaybackSuspension(
    generation: 7,
    trackID: 41,
    url: editedURL,
    position: 42,
    wasPlaying: true,
    wasEngineActive: true,
    queueIndex: 3
)
expect(playing.generation == 7, "the reducer must preserve its generation")
expect(playing.requestPlaying(), "explicit Play must be deferred")
expect(
    playing.restoration == .restore(
        mode: .playing,
        position: 42,
        queueIndex: 3
    ),
    "untouched playing state must resume at the original queue and position"
)
expect(playing.toggle(), "a non-superseded toggle must be deferred")
expect(
    playing.restoration == .restore(
        mode: .paused,
        position: 42,
        queueIndex: 3
    ),
    "toggle while playing must become a paused final intent"
)
expect(playing.seek(to: 17) == 17, "seek must be deferred and sanitized")
expect(
    playing.restoration == .restore(
        mode: .paused,
        position: 17,
        queueIndex: 3
    ),
    "the latest deferred seek must win"
)
expect(playing.requestStop(), "stop must be deferred while the edited file is suspended")
expect(playing.restoration == .stop, "explicit stop must win over the original playing snapshot")

var paused = MetadataEditPlaybackSuspension(
    generation: 8,
    trackID: 42,
    url: editedURL,
    position: 9,
    wasPlaying: false,
    wasEngineActive: true,
    queueIndex: 1
)
expect(paused.requestPaused(), "explicit Pause must be deferred")
expect(
    paused.restoration == .restore(mode: .paused, position: 9, queueIndex: 1),
    "untouched paused state must remain paused"
)
expect(paused.toggle(), "paused toggle must be deferred")
expect(
    paused.restoration == .restore(mode: .playing, position: 9, queueIndex: 1),
    "toggle while paused must request playing"
)

let idle = MetadataEditPlaybackSuspension(
    generation: 9,
    trackID: 43,
    url: editedURL,
    position: 5,
    wasPlaying: false,
    wasEngineActive: false,
    queueIndex: 2
)
expect(
    idle.restoration == .restore(mode: .idle, position: 5, queueIndex: 2),
    "untouched idle selected playback must remain stopped at the same position"
)

var sameTrack = MetadataEditPlaybackSuspension(
    generation: 10,
    trackID: 44,
    url: editedURL,
    position: 23,
    wasPlaying: false,
    wasEngineActive: true,
    queueIndex: 4
)
expect(
    sameTrack.requestPlay(trackID: 44, url: otherURL) == .deferEditedTrack,
    "stable database identity must defer the edited track even if its URL spelling differs"
)
expect(
    sameTrack.restoration == .restore(mode: .playing, position: 0, queueIndex: nil),
    "explicit same-track play must defer from zero without rewinding the user's queue"
)

var superseded = MetadataEditPlaybackSuspension(
    generation: 11,
    trackID: 45,
    url: editedURL,
    position: 12,
    wasPlaying: true,
    wasEngineActive: true,
    queueIndex: 5
)
expect(
    superseded.requestPlay(trackID: 99, url: otherURL) == .playDifferentTrack,
    "a different track must be allowed to play during the write"
)
expect(
    superseded.restoration == .superseded,
    "a different-track choice must suppress stale restoration"
)
expect(!superseded.toggle(), "toggle after supersession must apply to the new track normally")
expect(superseded.seek(to: 7) == nil, "seek after supersession must apply to the new track normally")
expect(!superseded.requestStop(), "stop after supersession must apply to the new track normally")
expect(
    superseded.requestPlay(trackID: 45, url: canonicalEditedURL) == .deferEditedTrack,
    "reselecting the edited track must defer it again"
)
expect(
    superseded.restoration == .restore(mode: .playing, position: 0, queueIndex: nil),
    "the latest same-track choice must replace supersession without restoring stale queue state"
)

var urlIdentity = MetadataEditPlaybackSuspension(
    generation: 12,
    trackID: nil,
    url: editedURL,
    position: 2,
    wasPlaying: false,
    wasEngineActive: false,
    queueIndex: 0
)
expect(
    urlIdentity.requestPlay(trackID: nil, url: canonicalEditedURL) == .deferEditedTrack,
    "standardized URLs must identify an edited track without database IDs"
)
var mismatchedIDSameFile = MetadataEditPlaybackSuspension(
    generation: 13,
    trackID: 100,
    url: editedURL,
    position: 2,
    wasPlaying: false,
    wasEngineActive: false,
    queueIndex: 0
)
expect(
    mismatchedIDSameFile.requestPlay(
        trackID: 101,
        url: canonicalEditedURL
    ) == .deferEditedTrack,
    "the same edited URL must never reopen during a write even if IDs disagree"
)

print("Metadata edit playback suspension reducer checks passed")
SWIFT

xcrun swiftc \
    "$SUSPENSION" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/test-metadata-edit-playback-suspension"
"$TMP_DIR/test-metadata-edit-playback-suspension"

printf '%s\n' 'Track metadata playback restore checks passed'
