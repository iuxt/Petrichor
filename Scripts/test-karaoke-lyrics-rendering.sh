#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT_DIR/Views/Components/KaraokeLyricText.swift"

test -f "$SOURCE" || { printf 'Missing shared KaraokeLyricText component.\n' >&2; exit 1; }
rg -n 'struct KaraokeLyricText: View' "$SOURCE" >/dev/null
rg -n 'NSViewRepresentable' "$SOURCE" >/dev/null
rg -n 'NSLayoutManager' "$SOURCE" >/dev/null
rg -n 'TimelineView\(\.animation' "$SOURCE" >/dev/null
rg -n 'accessibilityLabel' "$SOURCE" >/dev/null
rg -n 'fineProgressSampling \? \.milliseconds\(500\) : \.seconds\(1\)' \
    "$ROOT_DIR/Managers/PlaybackManager.swift" >/dev/null || {
    printf 'Karaoke rendering must not raise the global playback timer frequency.\n' >&2
    exit 1
}

TRACK_VIEW="$ROOT_DIR/Views/Main/TrackLyricsView.swift"
rg -n 'KaraokeLyricText\(' "$TRACK_VIEW" >/dev/null || {
    printf 'TrackLyricsContent must render timed KSC lines with KaraokeLyricText.\n' >&2
    exit 1
}
rg -n 'sampledPlaybackTime = newTime' "$TRACK_VIEW" >/dev/null || {
    printf 'TrackLyricsContent must anchor the renderer from published playback samples.\n' >&2
    exit 1
}

xcrun swiftc -typecheck \
    "$ROOT_DIR/Models/Core/Lyrics.swift" \
    "$ROOT_DIR/Core/KaraokeTiming.swift" \
    "$SOURCE"

printf 'Karaoke lyrics renderer checks passed\n'
