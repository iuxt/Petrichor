#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLAYBACK="$ROOT_DIR/Managers/PlaybackManager.swift"
PLAYLIST="$ROOT_DIR/Managers/Playlist/PMTrackUpdate.swift"
LIBRARY="$ROOT_DIR/Managers/Library/LMTrackMetadataEditing.swift"

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! rg -n "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern "$PLAYBACK" 'struct MetadataEditPlaybackSnapshot' 'Playback metadata snapshot is missing.'
require_pattern "$PLAYBACK" 'let queueIndex: Int' 'The snapshot must preserve queue position.'
require_pattern "$PLAYBACK" 'func prepareCurrentTrackForMetadataEdit' 'Playback preparation is missing.'
require_pattern "$PLAYBACK" 'let wasPlaying = wantsPlaybackActive \|\| isPlaying' 'Playback restoration must snapshot the requested playing intent.'
require_pattern "$PLAYBACK" 'func restoreCurrentTrackAfterMetadataEdit' 'Playback restoration is missing.'
require_pattern "$PLAYBACK" 'shouldResume: Bool' 'Deferred restoration must distinguish playing from paused.'
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

printf '%s\n' 'Track metadata playback restore checks passed'
