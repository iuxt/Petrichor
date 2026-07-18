#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLAYBACK="$ROOT_DIR/Managers/PlaybackManager.swift"
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
require_pattern "$PLAYBACK" 'let queueIndex: Int' 'The snapshot must preserve queue position.'
require_pattern "$PLAYBACK" 'func prepareCurrentTrackForMetadataEdit' 'Playback preparation is missing.'
require_pattern "$PLAYBACK" 'let wasPlaying = wantsPlaybackActive \|\| isPlaying' 'Playback restoration must snapshot the requested playing intent.'
require_pattern "$PLAYBACK" 'func restoreCurrentTrackAfterMetadataEdit' 'Playback restoration is missing.'
require_pattern "$PLAYBACK" 'var shouldResume: Bool' 'Pending restoration intent must remain mutable until the paused callback.'
require_pattern "$PLAYBACK" 'if pending.shouldResume' 'Paused restoration must not resume.'
require_pattern "$PLAYBACK" 'seekToPosition > 0 \|\| !resumeAfterRestore' 'A paused track at zero must remain paused.'
require_pattern "$PLAYBACK" 'restoreQueueIndexAfterMetadataEdit\(snapshot.queueIndex\)' 'The queue index must be restored through PlaylistManager.'
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

if (( failures > 0 )); then
    exit 1
fi

printf '%s\n' 'Track metadata playback restore checks passed'
