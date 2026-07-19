#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLAYBACK="$ROOT_DIR/Managers/PlaybackManager.swift"
SUSPENSION="$ROOT_DIR/Core/Playback/MetadataEditPlaybackSuspension.swift"
WRITE_GUARD="$ROOT_DIR/Core/Playback/MetadataWriteAccessGuard.swift"
NOW_PLAYING="$ROOT_DIR/Managers/NowPlayingManager.swift"
AUTOMATION="$ROOT_DIR/Managers/Automation/AMTransport.swift"
PLAYER_VIEW="$ROOT_DIR/Views/Main/PlayerView.swift"
NOW_PLAYING_CONTROLS="$ROOT_DIR/Views/Components/NowPlaying/NowPlayingControlsView.swift"
MENU_BAR="$ROOT_DIR/Managers/MenuBarManager.swift"
APP_DELEGATE="$ROOT_DIR/Application/AppDelegate.swift"
PLAYLIST="$ROOT_DIR/Managers/Playlist/PMTrackUpdate.swift"
PLAYLIST_PLAYBACK="$ROOT_DIR/Managers/Playlist/PMPlayback.swift"
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
require_pattern "$PLAYBACK" 'private var metadataWriteAccessGuard: MetadataWriteAccessGuard\?' 'Every metadata target needs an active file-access guard.'
require_pattern "$PLAYBACK" 'func beginMetadataWriteAccess' 'Metadata writes must publish their target before opening the file.'
require_pattern "$PLAYBACK" 'func endMetadataWriteAccess' 'Metadata writes must release their target on every terminal path.'
require_pattern "$PLAYBACK" 'let queueIndex: Int' 'The snapshot must preserve queue position.'
require_pattern "$PLAYBACK" 'func prepareCurrentTrackForMetadataEdit' 'Playback preparation is missing.'
require_pattern "$PLAYBACK" 'cancelCurrentArtworkLoad\(\)' 'Playback preparation must cancel its current artwork task.'
require_pattern "$PLAYBACK" 'private func cancelCurrentArtworkLoad\(\)' 'Artwork cancellation must not await a reader queued behind the active writer.'
require_pattern "$PLAYBACK" 'let wasPlaying = wantsPlaybackActive \|\| isPlaying' 'Playback restoration must snapshot the requested playing intent.'
require_pattern "$PLAYBACK" 'func restoreCurrentTrackAfterMetadataEdit' 'Playback restoration is missing.'
require_pattern "$PLAYBACK" 'var position: Double' 'Pending restoration position must remain mutable until restoration reaches a terminal callback.'
require_pattern "$PLAYBACK" 'var shouldResume: Bool' 'Pending restoration intent must remain mutable until the paused callback.'
require_pattern "$PLAYBACK" 'var didApplyPosition: Bool' 'Pending restoration must distinguish a position already applied to the loaded engine.'
require_pattern "$PLAYBACK" 'if pending.shouldResume' 'Paused restoration must not resume.'
require_pattern "$PLAYBACK" 'seekToPosition > 0\s+\|\|\s+!resumeAfterRestore' 'A paused track at zero must remain paused.'
require_pattern "$PLAYBACK" 'restoredEntryId != nil\s+\|\|\s+seekToPosition > 0\s+\|\|\s+!resumeAfterRestore' 'Metadata and async-request restores at zero must still settle through a mutable pending intent.'
require_pattern "$PLAYBACK" 'restoreQueueIndexAfterMetadataEdit\(' 'An authoritative snapshot queue identity must be restored through PlaylistManager.'
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
require_pattern "$PLAYLIST_PLAYBACK" 'func restoreQueueIndexAfterMetadataEdit\(\s*_ preferredIndex: Int,\s*matching track: Track\s*\)' 'Queue restoration must accept the edited track identity.'
require_pattern "$PLAYLIST_PLAYBACK" 'currentQueue\.firstIndex' 'Queue restoration must relocate a shuffled track.'
require_pattern "$PLAYLIST_PLAYBACK" 'queueTrack\.trackId == trackId' 'Queue restoration must prefer stable track identity.'
require_pattern "$PLAYLIST_PLAYBACK" 'standardizedFileURL' 'Queue restoration must fall back to canonical file identity.'
require_pattern "$LIBRARY" 'func applyMetadataEditResult' 'Library cache replacement is missing.'
require_pattern "$LIBRARY" 'func finishMetadataEditRefresh\(\) async' 'The final library refresh must await a duplicate-filtered track reload.'
require_pattern "$LIBRARY" 'databaseManager\.getAllTracks\(\)' 'The final library refresh must reload duplicate-filtered library membership.'
require_pattern "$LIBRARY" 'tracks = reloadedTracks' 'The in-memory All Tracks cache must adopt the duplicate-filtered reload.'
require_pattern "$LIBRARY" 'refreshLibraryCategories\(\)' 'Metadata categories must refresh.'
require_pattern "$LIBRARY" 'refreshEntities\(notify: false\)' 'Album and artist entities must refresh without duplicate notification.'
require_pattern "$ENGINE" 'func backendUnexpectedError\(error: AudioPlayerError, entryId: AudioEntryId\?\)' 'Backend errors must propagate their originating entry identity.'
require_pattern "$ENGINE" 'var currentEntryId: AudioEntryId\?' 'The playback facade must expose the backend entry that actually owns the file handle.'
require_pattern "$ENGINE" 'audioPlayerUnexpectedError\(player: self, error: error, entryId: entryId\)' 'The playback facade must forward error entry identity.'
require_pattern "$CRESCENDO" 'owner\?\.handleError\(error, entryId: entryId\)' 'Crescendo must preserve the entry identity supplied by its error callback.'
require_pattern "$CRESCENDO" 'player\.currentEntryId\.map' 'Crescendo must expose the engine entry that has actually been promoted.'
require_pattern "$SFB" 'backendUnexpectedError\(error: \.engineError\(error\), entryId: entryId\)' 'Known SFB playback errors must preserve their entry identity.'
require_pattern "$PLAYBACK" 'let originatingEntryId,\s+originatingEntryId == operation.entryId' 'Only an error from the restoring entry may fail metadata restoration.'
require_pattern "$PLAYBACK" 'guard finishedEntryIsCurrent else \{\s+Logger\.error\(\"Ignoring stale playback error for non-current entry' 'A stale error finish must not tear down current playback.'
require_pattern "$PLAYBACK" 'let snapshotPosition = currentTime\.isFinite && currentTime >= 0 \? currentTime : 0' 'Metadata playback snapshots must sanitize invalid positions.'
require_pattern "$PLAYBACK" 'position: snapshotPosition' 'The metadata snapshot must store the sanitized position.'
require_pattern "$PLAYBACK" 'pending\.shouldResume\.toggle\(\)' 'A toggle during pending restoration must change only its requested intent.'
require_pattern "$PLAYBACK" 'if togglePendingPlaybackRequestIntent\(\) \{\s+return\s+\}\s+if togglePendingPlaybackRestoreIntent\(\) \{\s+return\s+\}\s+recordSupersededMetadataFallback\(shouldPlay: !isPlaying\)\s+cancelMetadataRestoreForPlaybackChange\(\)' 'The newest async-load intent must be handled before an older engine settlement.'
require_pattern "$PLAYBACK" 'deferMetadataEditPlayIfNeeded\(track\)' 'Same-track play must defer while its metadata file is being written.'
require_pattern "$PLAYBACK" 'deferMetadataWritePlayIfNeeded\(track\)' 'A non-current write target must also defer playback.'
require_pattern "$PLAYBACK" 'stageMetadataEditSupersedingTrack\(track\)' 'Different-track loading must clear the edited FullTrack before returning to normal transport.'
require_pattern "$PLAYBACK" 'deferMetadataEditToggleIfNeeded\(\)' 'Toggle must update the suspended post-write intent.'
require_pattern "$PLAYBACK" 'deferMetadataEditStopIfNeeded\(\)' 'Stop must update the suspended post-write intent.'
require_pattern "$PLAYBACK" 'deferMetadataEditSeekIfNeeded\(time:' 'Seek must update the suspended post-write position.'
require_pattern "$PLAYBACK" 'deferPendingPlaybackRestoreSeekIfNeeded\(time:' 'Seek must update a track whose engine is still settling.'
require_pattern "$PLAYBACK" 'clearPendingPlaybackRestore\(matching:' 'Engine failures must clear generic pending settlement state.'
require_pattern "$PLAYBACK" 'func requestPlay\(\) -> Bool' 'Explicit remote Play must have non-toggle semantics.'
require_pattern "$PLAYBACK" 'func requestPause\(\) -> Bool' 'Explicit remote Pause must have non-toggle semantics.'
require_pattern "$PLAYBACK" 'setPendingPlaybackRestoreIntent\(shouldResume: true\)' 'Explicit Play must idempotently update any in-flight engine settlement.'
require_pattern "$PLAYBACK" 'setPendingPlaybackRestoreIntent\(shouldResume: false\)' 'Explicit Pause must idempotently update any in-flight engine settlement.'
require_pattern "$PLAYBACK" 'struct PendingPlaybackRequest' 'Async full-track loading must retain an explicit pending play intent.'
require_pattern "$PLAYBACK" 'let track: Track' 'An in-flight playback request must expose its target to the metadata write guard.'
require_pattern "$PLAYBACK" 'setPendingPlaybackRequestIntent\(shouldStartPlaying: true\)' 'Explicit Play must update an async full-track load intent.'
require_pattern "$PLAYBACK" 'setPendingPlaybackRequestIntent\(shouldStartPlaying: false\)' 'Explicit Pause must update an async full-track load intent.'
require_pattern "$PLAYBACK" 'togglePendingPlaybackRequestIntent\(\)' 'Toggle must update an async full-track load intent.'
require_pattern "$PLAYBACK" 'consumePendingPlaybackRequest\(generation: requestGeneration\)' 'Async full-track completion must consume the latest pending play intent.'
require_pattern "$PLAYBACK" 'applyPendingPlaybackFallbackIntent' 'Async-load intent changes must keep the currently loaded engine and public state consistent.'
require_pattern "$PLAYBACK" 'restoreMetadataSuspensionAfterFailedPlaybackRequest' 'A failed superseding load must reinstate the suspended current track fallback.'
require_pattern "$PLAYBACK" 'completeMetadataSupersessionForPlaybackStart' 'A successfully loaded replacement must become the fallback authority.'
require_pattern "$PLAYBACK" 'preservePendingPlaybackRestore' 'A replacement selected during restore must keep the old engine as its fallback until loading succeeds.'
require_pattern "$PLAYBACK" 'fallbackIntentWasExplicitlySet' 'A pending replacement must distinguish its initial fallback from later transport commands.'
require_pattern "$SUSPENSION" 'var fallbackRestoration: Restoration' 'Superseded playback must retain the edited track fallback mode and position.'
require_pattern "$PLAYBACK" 'recordSupersededMetadataFallback' 'Replacement transport must carry its fallback intent across another track selection.'
require_pattern "$PLAYBACK" 'recordSupersededMetadataFallbackStop' 'Stop must remain authoritative across another replacement request.'
require_pattern "$PLAYBACK" 'invalidatePlaybackRequestsForMetadataPreparation\(of: track\)' 'Preparing A must preserve a pending request for a different track B.'
require_pattern "$PLAYBACK" 'guardState\.takeDeferredPlayback\(\)' 'A same-target pending request must transfer into the current-track suspension.'
require_pattern "$PLAYBACK" 'suspension\.requestPlay\(\s*trackID: pending\.track\.trackId,\s*url: pending\.track\.url\s*\)' 'A preserved different-track request must supersede A before later transport commands arrive.'
require_pattern "$PLAYBACK" 'metadataEditRestoration\(for: snapshot\)' 'Restoration must inspect only its matching metadata-write suspension.'
require_pattern "$PLAYBACK" 'synchronizeActiveMetadataRestore' 'Transport changes must update an active metadata restoration.'
require_pattern "$PLAYBACK" 'clearMetadataEditSuspension\(generation: operation\.suspensionGeneration\)' 'Only a terminal restore callback may clear its matching suspension token.'
require_pattern "$PLAYBACK" 'if let queueIndex = restoration\.queueIndex' 'A superseding queue choice must not be rewound to the snapshot index.'
require_pattern "$PLAYBACK" 'restoreQueueIndexAfterMetadataEdit\(\s*queueIndex,\s*matching: snapshot\.track\s*\)' 'Queue restoration must relocate the edited track by identity after shuffle.'
require_pattern "$PLAYBACK" 'case \.superseded\? = metadataEditSuspension\?\.restoration' 'A user-selected different track must complete an in-flight metadata restore successfully.'
require_pattern "$PLAYBACK" 'restoreSupersededPendingPlaybackFallback' 'A pending different-track load must keep the edited track available as a fallback after writing.'
require_pattern "$NOW_PLAYING" 'audioPlayer\.requestPlay\(\)' 'Remote Play must set an explicit playing intent.'
require_pattern "$NOW_PLAYING" 'audioPlayer\.requestPause\(\)' 'Remote Pause must set an explicit paused intent.'
require_pattern "$AUTOMATION" 'func play\(\) \{\s+_ = playback\?\.requestPlay\(\)\s+\}' 'Automation Play must issue an explicit play request.'
require_pattern "$AUTOMATION" 'func pause\(\) \{\s+_ = playback\?\.requestPause\(\)\s+\}' 'Automation Pause must issue an explicit pause request.'
require_pattern "$PLAYER_VIEW" 'playbackManager\.isPlaying\s+\?\s+playbackManager\.requestPause\(\)\s+:\s+playbackManager\.requestPlay\(\)' 'The labeled player button must issue the explicit action it displays.'
require_pattern "$NOW_PLAYING_CONTROLS" 'playbackManager\.isPlaying\s+\?\s+playbackManager\.requestPause\(\)\s+:\s+playbackManager\.requestPlay\(\)' 'The labeled now-playing button must issue the explicit action it displays.'
require_pattern "$MENU_BAR" 'playbackManager\.isPlaying\s+\?\s+playbackManager\.requestPause\(\)\s+:\s+playbackManager\.requestPlay\(\)' 'The labeled menu-bar item must issue the explicit action it displays.'
require_pattern "$APP_DELEGATE" 'playbackManager\.isPlaying\s+\?\s+playbackManager\.requestPause\(\)\s+:\s+playbackManager\.requestPlay\(\)' 'The labeled Dock menu item must issue the explicit action it displays.'

if [[ ! -f "$SUSPENSION" ]]; then
    printf '%s\n' 'The metadata-write suspension reducer is missing.' >&2
    failures=$((failures + 1))
fi

if [[ ! -f "$WRITE_GUARD" ]]; then
    printf '%s\n' 'The metadata target file-access guard is missing.' >&2
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
if prepare.index("cancelCurrentArtworkLoad()") > prepare.index(
    "metadataEditSuspension ="
):
    raise SystemExit(
        "The current artwork task must be canceled before metadata-write suspension is published."
    )
if prepare.count("guard isCurrentTrack(track)") < 2:
    raise SystemExit(
        "Async artwork draining must revalidate that the edited track is still current."
    )
if prepare.index("metadataEditSuspension =") > prepare.index("audioPlayer.stop()"):
    raise SystemExit(
        "The metadata-write suspension must become active before preparation stops the engine."
    )
if "invalidatePlaybackRequests()" in prepare:
    raise SystemExit(
        "Metadata preparation must not unconditionally discard a different-track async request."
    )
if "deferredMetadataWriteTrack != nil" not in prepare:
    raise SystemExit(
        "Preparation must distinguish a selected target from a current-track transport seed."
    )
for required in ("suspension.requestPlaying()", "suspension.requestPaused()"):
    if required not in prepare:
        raise SystemExit(
            "Current-track transport seeds must preserve the snapshot position and queue."
        )

begin_write = body(
    "func beginMetadataWriteAccess",
    "func endMetadataWriteAccess",
)
for required in (
    "audioPlayer.currentEntryId == pending.entryId",
    "handleGaplessAdvance(to: pending)",
    "audioPlayer.clearNextTrack()",
):
    if required not in begin_write:
        raise SystemExit(
            "A promoted gapless target must become current before metadata preparation."
        )
end_write = body(
    "func endMetadataWriteAccess",
    "@MainActor\n    func prepareCurrentTrackForMetadataEdit",
)
for required in ("requestPlay()", "requestPause()"):
    if required not in end_write:
        raise SystemExit(
            "A skipped current-target write must apply its seeded transport through the normal engine path."
        )
if "applyPendingPlaybackFallbackIntent" in end_write:
    raise SystemExit(
        "Seeded Play on a stopped current track must not use the pending-load-only fallback helper."
    )

cancel_artwork = body(
    "private func cancelCurrentArtworkLoad()",
    "private func artworkIdentity",
)
for required in (
    "artworkLoadTask = nil",
    "artworkLoadTask?.cancel()",
):
    if required not in cancel_artwork:
        raise SystemExit(
            f"Artwork draining must include {required} before metadata writes can begin."
        )
if "await" in cancel_artwork:
    raise SystemExit(
        "Preparation must not await an artwork reader that may be queued behind its writer gate."
    )

play = body("func playTrack(_ track: Track)", "func togglePlayPause()")
if play.index("FileManager.default.fileExists") > play.index(
    "deferMetadataEditPlayIfNeeded(track)"
):
    raise SystemExit(
        "A missing replacement file must be rejected before it supersedes the edited track."
    )
if play.index("deferMetadataEditPlayIfNeeded(track)") > play.index(
    "cancelMetadataRestoreForPlaybackChange()"
):
    raise SystemExit(
        "Play requests must consult the active write suspension before normal playback starts."
    )
if play.index("deferMetadataWritePlayIfNeeded(track)") > play.index(
    "cancelMetadataRestoreForPlaybackChange()"
):
    raise SystemExit(
        "A guarded non-current target must defer before normal playback starts."
    )
if play.index("stagePendingPlaybackRequest(") > play.index(
    "track.fullTrack("
):
    raise SystemExit(
        "The pending play intent must exist before asynchronous full-track loading begins."
    )
if play.index("consumePendingPlaybackRequest(generation: requestGeneration)") > play.index(
    "startPlayback("
):
    raise SystemExit(
        "Full-track completion must resolve the latest play/pause intent before starting."
    )
completion = play[play.index("consumePendingPlaybackRequest(generation: requestGeneration)"):]
if "deferMetadataEditPlayIfNeeded(track)" not in completion:
    raise SystemExit(
        "A pending different-track completion must supersede metadata restoration before starting."
    )
if completion.index("cancelMetadataRestoreForPlaybackChange()") > completion.index(
    "startPlayback("
):
    raise SystemExit(
        "A carried async request must terminally complete an active metadata restore before starting."
    )
if completion.index(
    "completeMetadataSupersessionForPlaybackStart(track)"
) > completion.index("startPlayback("):
    raise SystemExit(
        "A successfully loaded replacement must retire the older edited-track fallback before starting."
    )
if play.count("discardPendingPlaybackRequest(generation: requestGeneration)") < 2:
    raise SystemExit(
        "Missing-data and thrown full-track loads must both discard their stale transport intent."
    )

pending_request_helpers = source[source.index("private func setPendingPlaybackRequestIntent"):
                                 source.index("private func artworkIdentity")]
if pending_request_helpers.count("applyPendingPlaybackFallbackIntent") < 4:
    raise SystemExit(
        "Explicit, toggle, and failure paths must synchronize the old engine while a new track loads."
    )
discard = pending_request_helpers[
    pending_request_helpers.index("private func discardPendingPlaybackRequest"):
]
if "applyPendingPlaybackFallbackIntent" not in discard:
    raise SystemExit(
        "A failed async load must restore the final fallback intent on the engine that remains loaded."
    )
fallback = pending_request_helpers[
    pending_request_helpers.index("private func applyPendingPlaybackFallbackIntent"):
]
for required in (
    "audioPlayer.pause()",
    "setPlaybackActive(false)",
    "audioPlayer.resume()",
    "syncPlaybackStateWithEngine()",
    "pendingPlaybackRestore",
    "settling.shouldResume = shouldPlay",
):
    if required not in fallback:
        raise SystemExit(
            f"Pending load intent synchronization is missing {required}."
        )
if "wantsPlaybackActive = false" in discard:
    raise SystemExit(
        "A failed async load must not force a still-playing old engine into a false intent."
    )

request_pause = body("func requestPause() -> Bool", "func togglePlayPause()")
if request_pause.index(
    "setPendingPlaybackRequestIntent(shouldStartPlaying: false)"
) > request_pause.index("guard isPlaying"):
    raise SystemExit(
        "Pause must change an async load intent even while public isPlaying is still false."
    )
if request_pause.index(
    "setPendingPlaybackRequestIntent(shouldStartPlaying: false)"
) > request_pause.index(
    "setPendingPlaybackRestoreIntent(shouldResume: false)"
):
    raise SystemExit(
        "Pause for a newer async request must also supersede an older engine settlement."
    )

request_play = body("func requestPlay() -> Bool", "func requestPause() -> Bool")
if request_play.index(
    "setPendingPlaybackRequestIntent(shouldStartPlaying: true)"
) > request_play.index(
    "setPendingPlaybackRestoreIntent(shouldResume: true)"
):
    raise SystemExit(
        "Play for a newer async request must also supersede an older engine settlement."
    )

deferred_play = body(
    "private func deferMetadataWritePlayIfNeeded",
    "private func deferMetadataWritePlayingIfNeeded",
)
if "invalidatePlaybackRequests()" not in deferred_play[
    deferred_play.index("case .deferTarget:"):
]:
    raise SystemExit(
        "Selecting the guarded target must supersede an older different-track async request."
    )
if "seedMetadataWriteIntentForCurrentTrack" not in source:
    raise SystemExit(
        "Transport must seed a deferred intent when the current pre-buffering track is the write target."
    )

write_transport = source[
    source.index("private func deferMetadataWritePlayingIfNeeded"):
    source.index("private func deferMetadataEditPlayIfNeeded")
]
if write_transport.count("seedMetadataWriteIntentForCurrentTrack") < 4:
    raise SystemExit(
        "Play, Pause, Toggle, and Stop must all guard a current target even before a deferred request exists."
    )
if "applyPendingPlaybackFallbackIntent" in write_transport:
    raise SystemExit(
        "Transport during the preflight guard must record intent without mutating the engine before its snapshot."
    )

deferred_play = body(
    "private func deferMetadataEditPlayIfNeeded",
    "private func stageMetadataEditSupersedingTrack",
)
different_track_branch = deferred_play[
    deferred_play.index("case .playDifferentTrack:"):
    deferred_play.index("case .deferEditedTrack:")
]
if different_track_branch.index("metadataRestoreOperation != nil") > \
        different_track_branch.index("stageMetadataEditSupersedingTrack(track)"):
    raise SystemExit(
        "A replacement selected during engine restore must leave the old engine settling as its fallback."
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
    "togglePendingPlaybackRequestIntent()"
):
    raise SystemExit(
        "Toggle must update a write-window intent before consulting post-write restoration."
    )
if toggle.index("togglePendingPlaybackRequestIntent()") > toggle.index(
    "togglePendingPlaybackRestoreIntent()"
):
    raise SystemExit(
        "Toggle for a newer async request must also supersede an older engine settlement."
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
fallback_restore = body(
    "private func restoreSupersededPendingPlaybackFallback",
    "func restoreCurrentTrackAfterFailedTrashMove",
)
for forbidden in ("snapshot.position", "snapshot.wasEngineActive"):
    if forbidden in fallback_restore:
        raise SystemExit(
            "Late replacement fallback must use the reducer's latest state, not "
            f"the stale snapshot ({forbidden})."
        )
if "fallbackRestoration" not in fallback_restore:
    raise SystemExit(
        "Late replacement fallback must consume the reducer's preserved mode and position."
    )
if "consumeMetadataEditSuspension(for: snapshot)" in restore:
    raise SystemExit(
        "Starting restoration must not consume the metadata suspension before a terminal callback."
    )
superseded_branch = restore[
    restore.index("case .superseded:"):
    restore.index("case .stop:")
]
if "restoreSupersededPendingPlaybackFallback" not in superseded_branch:
    raise SystemExit(
        "Superseded metadata restoration must restart the old track while the new track is still loading."
    )
inspect = restore.index("metadataEditRestoration(for: snapshot)")
for mutation in (
    "restoreQueueIndexAfterMetadataEdit",
    "currentTrack = track",
    "startPlayback(",
):
    if inspect > restore.index(mutation):
        raise SystemExit(
            f"Restoration must validate its generation before {mutation} mutates playback."
        )

seek_restore = source[source.index("private func deferMetadataEditSeekIfNeeded"):
                      source.index("private func metadataEditRestoration")]
if "synchronizeActiveMetadataRestore" not in seek_restore:
    raise SystemExit(
        "A seek during engine restoration must replace the pending restore position."
    )

seek = body("func seekTo(time: Double)", "func setVolume")
if seek.index("deferPendingPlaybackRestoreSeekIfNeeded(time: time)") > seek.index(
    "audioPlayer.seek(to: clampedTime)"
):
    raise SystemExit(
        "A seek during generic engine settlement must replace its pending position before touching the engine."
    )

finish = body("private func finishMetadataRestore", "private func metadataRestoreOperation")
if "clearMetadataEditSuspension(generation: operation.suspensionGeneration)" not in finish:
    raise SystemExit(
        "Metadata suspension cleanup must happen in the restore terminal path."
    )

prime = body("private func primeNextTrack()", "private func handleGaplessAdvance")
if "metadataWriteAccessGuard" not in prime or "audioPlayer.clearNextTrack()" not in prime:
    raise SystemExit(
        "Gapless lookahead must not open a target while its metadata is being written."
    )

cancel_restore = body(
    "private func cancelMetadataRestoreForPlaybackChange",
    "private func finishMetadataRestore",
)
if "pendingPlaybackRestore = nil" in cancel_restore:
    raise SystemExit(
        "Restore cancellation must let finishMetadataRestore decide whether the old engine fallback is preserved."
    )
for required in (
    "case .superseded? = metadataEditSuspension?.restoration",
    ".success(())",
):
    if required not in cancel_restore:
        raise SystemExit(
            "A user supersession during engine settlement must finish restoration successfully."
        )

paused_restore = source[source.index("if effectiveState == .paused,"):
                        source.index("if effectiveState == .playing,", source.index("if effectiveState == .paused,"))]
if paused_restore.index("pendingPlaybackRestore = nil") < paused_restore.index(
    "audioPlayer.seek(to: pending.position)"
):
    raise SystemExit(
        "The pending restore must remain mutable until its final position is applied."
    )

playing_restore = source[source.index("if effectiveState == .playing,",
                                      source.index("if effectiveState == .paused,")):
                         source.index("// Prime the gapless next",
                                      source.index("if effectiveState == .paused,"))]
if "let pending = self.pendingPlaybackRestore" not in playing_restore:
    raise SystemExit(
        "Playing settlement must consume a pending intent even without a metadata restore operation."
    )
if playing_restore.index("self.pendingPlaybackRestore = nil") > playing_restore.index(
    "if let operation = self.metadataRestoreOperation"
):
    raise SystemExit(
        "A general async-load pending intent must clear before optional metadata completion."
    )

finish_error = source[source.index("case .error:"):
                      source.index("func audioPlayerUnexpectedError")]
if finish_error.index("clearPendingPlaybackRestore(matching: entryId)") > finish_error.index(
    "if let operation = self.metadataRestoreOperation"
):
    raise SystemExit(
        "A normal engine error must clear generic pending state before optional metadata failure handling."
    )

unexpected_error = body(
    "func audioPlayerUnexpectedError",
    "func audioPlayerDidSkipQueueEntry",
)
if "clearPendingPlaybackRestore(matching: originatingEntryId)" not in unexpected_error:
    raise SystemExit(
        "An unexpected engine error must clear matching generic pending state."
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

var failedSupersession = MetadataEditPlaybackSuspension(
    generation: 14,
    trackID: 46,
    url: editedURL,
    position: 33,
    wasPlaying: true,
    wasEngineActive: true,
    queueIndex: 6
)
_ = failedSupersession.requestPlay(trackID: 99, url: otherURL)
expect(
    failedSupersession.restoreAfterFailedSupersession(shouldPlay: false),
    "a failed different-track load must reinstate the suspended fallback"
)
expect(
    failedSupersession.restoration == .restore(
        mode: .paused,
        position: 33,
        queueIndex: nil
    ),
    "the fallback must keep the original position and latest pause intent without rewinding the changed queue"
)

var preservedFallback = MetadataEditPlaybackSuspension(
    generation: 15,
    trackID: 47,
    url: editedURL,
    position: 10,
    wasPlaying: true,
    wasEngineActive: true,
    queueIndex: 7
)
expect(
    preservedFallback.seek(to: 30) == 30,
    "a seek before selecting another track must update the fallback position"
)
_ = preservedFallback.requestPlay(trackID: 99, url: otherURL)
expect(
    preservedFallback.fallbackRestoration == .restore(
        mode: .playing,
        position: 30,
        queueIndex: nil
    ),
    "supersession must retain the latest playing fallback without rewinding the queue"
)
expect(
    preservedFallback.restoreAfterFailedSupersession(shouldPlay: nil),
    "a failed replacement without a later transport command must restore the original intent"
)
expect(
    preservedFallback.restoration == .restore(
        mode: .playing,
        position: 30,
        queueIndex: nil
    ),
    "a failed replacement must preserve the reducer's latest position and playing mode"
)

var stoppedFallback = MetadataEditPlaybackSuspension(
    generation: 16,
    trackID: 48,
    url: editedURL,
    position: 19,
    wasPlaying: true,
    wasEngineActive: true,
    queueIndex: 8
)
expect(stoppedFallback.requestStop(), "Stop must become the latest fallback state")
_ = stoppedFallback.requestPlay(trackID: 99, url: otherURL)
expect(
    stoppedFallback.fallbackRestoration == .stop,
    "selecting another track must not erase an explicit Stop fallback"
)
expect(
    stoppedFallback.restoreAfterFailedSupersession(shouldPlay: nil),
    "a stopped fallback must still be restorable after replacement failure"
)
expect(
    stoppedFallback.restoration == .stop,
    "replacement failure must not reopen a track stopped before selection"
)

var explicitlyPausedStoppedFallback = MetadataEditPlaybackSuspension(
    generation: 17,
    trackID: 49,
    url: editedURL,
    position: 21,
    wasPlaying: true,
    wasEngineActive: true,
    queueIndex: 9
)
expect(
    explicitlyPausedStoppedFallback.requestStop(),
    "the second stopped fallback must start from an explicit Stop"
)
_ = explicitlyPausedStoppedFallback.requestPlay(
    trackID: 99,
    url: otherURL
)
expect(
    explicitlyPausedStoppedFallback.restoreAfterFailedSupersession(
        shouldPlay: false
    ),
    "an explicit Pause for the replacement must still resolve its failure"
)
expect(
    explicitlyPausedStoppedFallback.restoration == .stop,
    "Pause must not resurrect an edited track that was already explicitly stopped"
)

var chainedFallback = MetadataEditPlaybackSuspension(
    generation: 18,
    trackID: 50,
    url: editedURL,
    position: 24,
    wasPlaying: true,
    wasEngineActive: true,
    queueIndex: 10
)
_ = chainedFallback.requestPlay(trackID: 98, url: otherURL)
expect(
    chainedFallback.updateFallbackPlayback(shouldPlay: false),
    "Pause on a pending replacement must update the superseded fallback"
)
_ = chainedFallback.requestPlay(
    trackID: 99,
    url: URL(fileURLWithPath: "/tmp/music/third.flac")
)
expect(
    chainedFallback.fallbackRestoration == .restore(
        mode: .paused,
        position: 24,
        queueIndex: nil
    ),
    "a second replacement must inherit the first replacement's paused fallback"
)
expect(
    chainedFallback.requestFallbackStop(),
    "Stop on a replacement must update the superseded fallback"
)
_ = chainedFallback.requestPlay(trackID: 100, url: otherURL)
expect(
    chainedFallback.fallbackRestoration == .stop,
    "another replacement must not resurrect a fallback stopped earlier in the chain"
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

var writeGuard = MetadataWriteAccessGuard(
    generation: 21,
    trackID: 200,
    url: editedURL
)
expect(
    writeGuard.requestPlay(trackID: 200, url: otherURL) == .deferTarget,
    "the active write target must defer by stable database identity"
)
expect(
    writeGuard.deferredShouldStartPlaying == true,
    "a deferred target selection must retain its playing intent"
)
expect(writeGuard.requestPaused(), "Pause must update a deferred target request")
expect(
    writeGuard.deferredShouldStartPlaying == false,
    "the latest deferred Pause must win"
)
expect(writeGuard.toggle(), "Toggle must update a deferred target request")
expect(
    writeGuard.deferredShouldStartPlaying == true,
    "Toggle must invert the deferred target intent"
)
expect(
    writeGuard.requestPlay(trackID: 201, url: otherURL) == .allowDifferentTarget,
    "an unrelated track must remain playable during a metadata write"
)
expect(
    writeGuard.deferredShouldStartPlaying == nil,
    "an unrelated track choice must supersede a deferred guarded target"
)
expect(
    writeGuard.seedDeferredPlayback(
        trackID: 200,
        url: canonicalEditedURL,
        shouldStartPlaying: true
    ),
    "a current pre-buffering write target must seed its engine intent"
)
expect(writeGuard.toggle(), "a seeded pre-buffering target must defer Toggle")
expect(
    writeGuard.deferredShouldStartPlaying == false,
    "Toggle must not reopen a guarded pre-buffering target"
)
expect(
    writeGuard.adoptPendingPlayback(
        trackID: 200,
        url: canonicalEditedURL,
        shouldStartPlaying: false
    ),
    "a same-target async request already in flight must transfer into the write guard"
)
expect(
    writeGuard.deferredShouldStartPlaying == false,
    "the transferred async request must preserve its latest pause intent"
)
expect(
    writeGuard.takeDeferredPlayback() == false,
    "current-track suspension must consume the transferred request exactly once"
)
expect(
    writeGuard.deferredShouldStartPlaying == nil,
    "a consumed request must not replay again when file access ends"
)
_ = writeGuard.requestPlay(trackID: 200, url: canonicalEditedURL)
expect(writeGuard.requestStop(), "Stop must cancel a deferred target request")
expect(
    writeGuard.deferredShouldStartPlaying == nil,
    "Stop must leave no target to reopen after the write"
)

print("Metadata edit playback suspension reducer checks passed")
SWIFT

xcrun swiftc \
    "$SUSPENSION" \
    "$WRITE_GUARD" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/test-metadata-edit-playback-suspension"
"$TMP_DIR/test-metadata-edit-playback-suspension"

printf '%s\n' 'Track metadata playback restore checks passed'
