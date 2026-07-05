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
timer_start = manager.index("private func startProgressUpdateTimer")
timer_end = manager.index("/// Switches the progress sampler", timer_start)
timer_body = manager[timer_start:timer_end]

if "self.audioPlayer.state == .playing" in timer_body:
    raise SystemExit(
        "PlaybackManager progress sampling must not return solely on live engine state; "
        "backend state can be stale while audio is still advancing."
    )

if "let engineState = self.audioPlayer.state" not in timer_body:
    raise SystemExit("PlaybackManager progress sampling must capture the backend state for stale-state recovery.")

if "let engineProgress = self.audioPlayer.currentPlaybackProgress" not in timer_body:
    raise SystemExit("PlaybackManager progress sampling must read engine progress before deciding whether to publish.")

if "shouldPublishProgressSample" not in timer_body:
    raise SystemExit("PlaybackManager progress sampling must delegate stale-state recovery to shouldPublishProgressSample.")

helper_start = manager.index("private func shouldPublishProgressSample")
helper_end = manager.index("private func stopProgressUpdateTimer", helper_start)
helper_body = manager[helper_start:helper_end]

if "engineState == .playing" not in helper_body:
    raise SystemExit("Progress samples must still publish normally when the backend reports .playing.")

if "isPlaying" not in helper_body:
    raise SystemExit("Progress samples must continue while app playback state is playing, even during backend state lag.")

if "previousEngineProgress" not in helper_body or "progressAdvanced" not in helper_body:
    raise SystemExit(
        "Progress sampling must detect consecutive engine-time movement so stale paused/stopped state cannot freeze the UI."
    )

if "self.isPlaying = true" not in timer_body:
    raise SystemExit("PlaybackManager must resync isPlaying when engine progress proves audio is still playing.")

print("Playback progress state race checks passed")
PY
