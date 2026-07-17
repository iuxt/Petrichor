#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func assertClose(_ actual: Double?, _ expected: Double, _ message: String) {
    guard let actual, abs(actual - expected) < 0.0001 else {
        preconditionFailure("\(message): expected \(expected), got \(String(describing: actual))")
    }
}

var resolver = PlaybackProgressResolver()

let normal = resolver.resolve(
    engineProgress: 2,
    previousEngineProgress: 1,
    displayedProgress: 1,
    elapsed: 1,
    duration: 120,
    playbackIsActive: true
)
assertClose(normal.progress, 2, "Advancing engine time must remain authoritative")
precondition(normal.transition == .none)

resolver.reset()
let firstStall = resolver.resolve(
    engineProgress: 0,
    previousEngineProgress: 0,
    displayedProgress: 0,
    elapsed: 1,
    duration: 120,
    playbackIsActive: true
)
assertClose(firstStall.progress, 0, "The first stalled sample must not extrapolate")
precondition(firstStall.transition == .none)

let secondStall = resolver.resolve(
    engineProgress: 0,
    previousEngineProgress: 0,
    displayedProgress: 0,
    elapsed: 1,
    duration: 120,
    playbackIsActive: true
)
assertClose(secondStall.progress, 1, "The second stalled sample must advance from monotonic elapsed time")
precondition(secondStall.transition == .enteredFallback)

let continuedStall = resolver.resolve(
    engineProgress: 0,
    previousEngineProgress: 0,
    displayedProgress: 1,
    elapsed: 0.5,
    duration: 120,
    playbackIsActive: true
)
assertClose(continuedStall.progress, 1.5, "Fallback must keep shared progress moving")
precondition(continuedStall.transition == .none)

let recovered = resolver.resolve(
    engineProgress: 4,
    previousEngineProgress: 0,
    displayedProgress: 1.5,
    elapsed: 0.5,
    duration: 120,
    playbackIsActive: true
)
assertClose(recovered.progress, 4, "A caught-up engine sample must retake authority")
precondition(recovered.transition == .recovered)

resolver.reset()
_ = resolver.resolve(
    engineProgress: 0,
    previousEngineProgress: 0,
    displayedProgress: 0,
    elapsed: 1,
    duration: 120,
    playbackIsActive: true
)
_ = resolver.resolve(
    engineProgress: 0,
    previousEngineProgress: 0,
    displayedProgress: 0,
    elapsed: 1,
    duration: 120,
    playbackIsActive: true
)
let laggingRecovery = resolver.resolve(
    engineProgress: 0.5,
    previousEngineProgress: 0,
    displayedProgress: 1,
    elapsed: 1,
    duration: 120,
    playbackIsActive: true
)
assertClose(laggingRecovery.progress, 2, "A still-lagging engine must not move visible progress backward")
precondition(laggingRecovery.transition == .none)

let paused = resolver.resolve(
    engineProgress: 1.8,
    previousEngineProgress: 0.5,
    displayedProgress: 2,
    elapsed: 1,
    duration: 120,
    playbackIsActive: false
)
assertClose(paused.progress, 1.8, "Paused playback must accept the stable engine position")
precondition(paused.transition == .recovered)

resolver.reset()
_ = resolver.resolve(
    engineProgress: 9.5,
    previousEngineProgress: 9.5,
    displayedProgress: 9.5,
    elapsed: 1,
    duration: 10,
    playbackIsActive: true
)
let clamped = resolver.resolve(
    engineProgress: 9.5,
    previousEngineProgress: 9.5,
    displayedProgress: 9.5,
    elapsed: 1,
    duration: 10,
    playbackIsActive: true
)
assertClose(clamped.progress, 10, "Fallback must not exceed track duration")

resolver.reset()
_ = resolver.resolve(
    engineProgress: 0,
    previousEngineProgress: 0,
    displayedProgress: 0,
    elapsed: 1,
    duration: 120,
    playbackIsActive: true
)
resolver.reset()
let resetFirstStall = resolver.resolve(
    engineProgress: 0,
    previousEngineProgress: 0,
    displayedProgress: 0,
    elapsed: 1,
    duration: 120,
    playbackIsActive: true
)
assertClose(resetFirstStall.progress, 0, "Reset must discard the prior track's stall count")
precondition(resetFirstStall.transition == .none)

let inactive = resolver.resolve(
    engineProgress: 3,
    previousEngineProgress: 2,
    displayedProgress: 2,
    elapsed: 10,
    duration: 120,
    playbackIsActive: false
)
assertClose(inactive.progress, 3, "Inactive playback must never extrapolate")

let invalid = resolver.resolve(
    engineProgress: .nan,
    previousEngineProgress: 3,
    displayedProgress: 3,
    elapsed: 1,
    duration: 120,
    playbackIsActive: true
)
precondition(invalid.progress == nil, "Invalid engine time must not publish")

print("Playback progress resolver checks passed")
SWIFT

xcrun swiftc \
    "$ROOT_DIR/Core/Playback/PlaybackProgressResolver.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/playback-progress-resolver-test"

"$TMP_DIR/playback-progress-resolver-test"
