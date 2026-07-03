#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path

source = Path("Core/Playback/SFBPlaybackBackend.swift").read_text()

state_start = source.index("func handlePlaybackStateChanged")
state_end = source.index("func handleEndOfAudio", state_start)
state_body = source[state_start:state_end]

if "let effectiveState = self.sfbPlayer.playbackState" not in state_body:
    raise SystemExit(
        "SFB state callbacks must re-read sfbPlayer.playbackState before updating backend state; "
        "a delayed .stopped callback from shortcut-driven track replacement can otherwise freeze progress."
    )

if "switch newState" in state_body:
    raise SystemExit("SFB state callbacks must not switch directly on the potentially stale callback state.")

if "switch effectiveState" not in state_body:
    raise SystemExit("SFB state callbacks must switch on the current effective playback state.")

finish_start = state_end
finish_end = source.index("/// Reconfigures the audio processing graph", finish_start)
finish_body = source[finish_start:finish_end]

if "sfbPlayer.playbackState != .stopped" not in finish_body:
    raise SystemExit(
        "SFB end-of-audio handling must ignore stale EOF callbacks once replacement playback is active."
    )

manager = Path("Managers/PlaybackManager.swift").read_text()
if "self.audioPlayer.state == .playing" not in manager:
    raise SystemExit(
        "PlaybackManager progress sampling should remain gated by live engine state; "
        "this regression test protects the backend state from stale callbacks instead."
    )

print("Playback progress state race checks passed")
PY
