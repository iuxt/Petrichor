#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path

source = Path("Managers/PlaybackManager.swift").read_text()

if "private var wantsPlaybackActive" not in source:
    raise SystemExit("PlaybackManager must track whether the latest transport intent wants active playback.")

toggle_start = source.index("func togglePlayPause()")
toggle_end = source.index("func stop()", toggle_start)
toggle_body = source[toggle_start:toggle_end]

resume_index = toggle_body.index("audioPlayer.resume()")
resume_branch_start = toggle_body.rindex("} else", 0, resume_index)
resume_tail = toggle_body[resume_branch_start:toggle_body.index("}", resume_index)]
pause_index = toggle_body.index("audioPlayer.pause()")
pause_branch_start = toggle_body.rindex("if isPlaying", 0, pause_index)
pause_tail = toggle_body[pause_branch_start:toggle_body.index("} else", pause_index)]

if "syncPlaybackStateWithEngine()" in pause_tail:
    raise SystemExit(
        "togglePlayPause must not immediately re-read engine state after pause(); "
        "async backends can still report .playing and overwrite the paused UI."
    )

if "setPlaybackActive(false)" not in pause_tail:
    raise SystemExit("togglePlayPause must immediately mark the app playback state paused after a pause command.")

if "wantsPlaybackActive = false" not in pause_tail:
    raise SystemExit("togglePlayPause must record a pause intent before stale playing callbacks can arrive.")

if "isPlaying = true" in resume_tail:
    raise SystemExit(
        "togglePlayPause must not optimistically mark playback as playing after resume(); "
        "the engine can reject a resume while not actually paused/loaded, leaving the play button stale."
    )

if "wantsPlaybackActive = true" not in resume_tail:
    raise SystemExit("togglePlayPause must record a play intent before resume callbacks arrive.")

if "syncPlaybackStateWithEngine()" not in toggle_body:
    raise SystemExit(
        "togglePlayPause must reconcile app playback state with the engine after transport commands."
    )

if "guard shouldAcceptPlayPauseToggle() else" not in toggle_body:
    raise SystemExit("togglePlayPause must throttle rapid repeated transport commands.")

throttle_index = toggle_body.index("shouldAcceptPlayPauseToggle()")
if throttle_index > pause_index:
    raise SystemExit("togglePlayPause must throttle before issuing pause/resume commands.")

active_start = source.index("private func setPlaybackActive")
active_end = source.index("private func syncPlaybackStateWithEngine", active_start)
active_body = source[active_start:active_end]

for expected in (
    "isPlaying = playing",
    "startStateSaveTimer()",
    "stopStateSaveTimer()",
    "updateNowPlayingInfo()",
):
    if expected not in active_body:
        raise SystemExit(f"setPlaybackActive must handle {expected}")

helper_start = source.index("private func syncPlaybackStateWithEngine()")
helper_end = source.index("private func startPlayback", helper_start)
helper_body = source[helper_start:helper_end]

for expected in (
    "case .playing:",
    "case .paused, .stopped, .ready:",
    "setPlaybackActive(wantsPlaybackActive)",
    "setPlaybackActive(false)",
):
    if expected not in helper_body:
        raise SystemExit(f"syncPlaybackStateWithEngine must handle {expected}")

start_start = source.index("func audioPlayerDidStartPlaying")
start_end = source.index("func audioPlayerStateChanged", start_start)
start_body = source[start_start:start_end]

if "self.audioPlayer.state == .playing" not in start_body:
    raise SystemExit("audioPlayerDidStartPlaying must re-check the current engine state before marking UI playing.")

if "self.wantsPlaybackActive" not in start_body:
    raise SystemExit("audioPlayerDidStartPlaying must ignore stale start callbacks after a pause intent.")

pending_index = start_body.index("if let pending = self.pendingNext")
pending_body = start_body[pending_index:start_body.index("} else", pending_index)]

if "guard self.wantsPlaybackActive" not in pending_body:
    raise SystemExit("audioPlayerDidStartPlaying must not promote gapless advances after a pause intent.")

if "entryId == self.currentEntryId" not in start_body:
    raise SystemExit("audioPlayerDidStartPlaying must ignore start callbacks for non-current entries.")

if "self.setPlaybackActive(true)" not in start_body:
    raise SystemExit("audioPlayerDidStartPlaying must update app playback state through setPlaybackActive.")

state_start = source.index("func audioPlayerStateChanged")
state_end = source.index("func audioPlayerDidFinishPlaying", state_start)
state_body = source[state_start:state_end]

if "let effectiveState = self.audioPlayer.state" not in state_body:
    raise SystemExit("PlaybackManager state callbacks must re-read the current engine state before updating UI.")

if "switch newState" in state_body:
    raise SystemExit("PlaybackManager state callbacks must not switch on potentially stale callback state.")

if "switch effectiveState" not in state_body:
    raise SystemExit("PlaybackManager state callbacks must switch on current effective engine state.")

playing_index = state_body.index("case .playing:")
playing_body = state_body[playing_index:state_body.index("case .paused:", playing_index)]

if "self.wantsPlaybackActive" not in playing_body:
    raise SystemExit("PlaybackManager must not let stale .playing callbacks override a pause intent.")

ready_index = state_body.index("case .ready:")
ready_body = state_body[ready_index:state_body.index("}", ready_index)]

if "self.setPlaybackActive(false)" not in ready_body:
    raise SystemExit("PlaybackManager must treat backend .ready as not playing in state callbacks.")

throttle_start = source.index("private func shouldAcceptPlayPauseToggle")
throttle_end = source.index("private func setPlaybackActive", throttle_start)
throttle_body = source[throttle_start:throttle_end]

for expected in (
    "Date().timeIntervalSinceReferenceDate",
    "playPauseToggleThrottleInterval",
    "lastPlayPauseToggleTime",
    "lastPlayPauseToggleTime = now",
):
    if expected not in throttle_body:
        raise SystemExit(f"shouldAcceptPlayPauseToggle must use {expected}")

print("Playback toggle state consistency checks passed")
PY
