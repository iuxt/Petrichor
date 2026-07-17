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

if "self.wantsPlaybackActive && engineState != .playing && !self.isPlaying" not in timer_body:
    raise SystemExit("PlaybackManager must only resync playing UI from progress when the latest intent still wants playback.")

if "self.wantsPlaybackActive = true" in timer_body:
    raise SystemExit("Playback progress recovery must not overwrite an explicit pause intent.")

if "self.setPlaybackActive(true)" not in timer_body:
    raise SystemExit("PlaybackManager must resync isPlaying when engine progress proves audio is still playing.")

if "private var progressResolver = PlaybackProgressResolver()" not in manager:
    raise SystemExit("PlaybackManager must own the progress resolver.")

if "private var lastProgressSampleUptime: TimeInterval?" not in manager:
    raise SystemExit("PlaybackManager must measure sampler elapsed time with monotonic system uptime.")

if "let resolution = self.progressResolver.resolve(" not in timer_body:
    raise SystemExit("PlaybackManager must resolve raw engine samples before publishing them.")

if "ProcessInfo.processInfo.systemUptime" not in timer_body:
    raise SystemExit("PlaybackManager progress fallback must use monotonic system uptime.")

if "playbackIsActive: self.wantsPlaybackActive" not in timer_body:
    raise SystemExit("Playback progress fallback must require the latest active playback intent.")

if "self.currentTime = resolvedProgress" not in timer_body:
    raise SystemExit("PlaybackManager must publish the resolved progress value.")

if "self.currentTime = engineProgress" in timer_body:
    raise SystemExit("PlaybackManager must not bypass the resolver with the raw engine sample.")

if "case .enteredFallback:" not in timer_body or "case .recovered:" not in timer_body:
    raise SystemExit("PlaybackManager must log one fallback entry and one recovery transition.")

if "private func resetProgressResolution" not in manager:
    raise SystemExit("PlaybackManager must centralize progress resolver lifecycle resets.")

for function_name in (
    "func seekTo(time: Double)",
    "func reloadPlaybackEngine()",
    "private func startPlayback",
    "private func handleGaplessAdvance",
):
    function_start = manager.index(function_name)
    next_marker = manager.find("\n    func ", function_start + 1)
    private_marker = manager.find("\n    private func ", function_start + 1)
    candidates = [index for index in (next_marker, private_marker) if index != -1]
    function_end = min(candidates) if candidates else len(manager)
    if "resetProgressResolution" not in manager[function_start:function_end]:
        raise SystemExit(f"{function_name} must reset frozen-progress recovery state.")

print("Playback progress state race checks passed")
PY
