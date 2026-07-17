# Modern Playback Progress Freeze Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the shared playback progress and synchronized lyrics moving when the modern playback engine temporarily reports a frozen time, while upgrading CrescendoKit to the fixed 1.1.1 release.

**Architecture:** Add a small pure `PlaybackProgressResolver` beside the playback backends. `PlaybackManager` remains the single sampler and passes raw engine samples through the resolver, which trusts advancing engine time and uses bounded monotonic extrapolation only after two consecutive stalls during active playback. Lifecycle resets prevent fallback state from crossing seeks, track changes, trash operations, restoration, or backend reloads.

**Tech Stack:** Swift 5 language mode, SwiftUI/Combine, Foundation monotonic system uptime, CrescendoKit 1.1.1, Bash regression scripts, Xcode 16+

## Global Constraints

- Keep playback, progress publication, and UI-facing state on `@MainActor`.
- The fallback affects display progress, synchronized lyrics, and Petrichor's Now Playing time only; it must not seek, change the queue, change engine state, or decide track completion.
- Reset fallback state on manual play, gapless advance, seek, stop, restoration, media-engine reload, and current-track trash workflows.
- Do not modify audio files, add runtime network music services, or change library and playlist storage.
- Preserve the existing classic-engine stale-state recovery in `shouldPublishProgressSample`.
- Clamp synthesized progress to `0...duration` when duration is known.

---

### Task 1: Add the Pure Playback Progress Resolver

**Files:**
- Create: `Core/Playback/PlaybackProgressResolver.swift`
- Create: `Scripts/test-playback-progress-resolver.sh`

**Interfaces:**
- Consumes: raw engine progress, previous raw engine progress, current published progress, elapsed monotonic time, track duration, and a Boolean stating whether playback is actively intended.
- Produces: `PlaybackProgressResolver.resolve(engineProgress:previousEngineProgress:displayedProgress:elapsed:duration:playbackIsActive:tolerance:) -> PlaybackProgressResolution` and `PlaybackProgressResolver.reset()`.

- [ ] **Step 1: Write the failing pure regression test**

Create `Scripts/test-playback-progress-resolver.sh`:

```bash
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
```

Make it executable:

```bash
chmod +x Scripts/test-playback-progress-resolver.sh
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
Scripts/test-playback-progress-resolver.sh
```

Expected: exit nonzero because `Core/Playback/PlaybackProgressResolver.swift` does not exist.

- [ ] **Step 3: Implement the minimal resolver**

Create `Core/Playback/PlaybackProgressResolver.swift`:

```swift
import Foundation

struct PlaybackProgressResolution: Equatable {
    enum Transition: Equatable {
        case none
        case enteredFallback
        case recovered
    }

    let progress: TimeInterval?
    let transition: Transition
}

struct PlaybackProgressResolver {
    private(set) var isUsingFallback = false
    private var consecutiveStalledSamples = 0

    mutating func resolve(
        engineProgress: TimeInterval,
        previousEngineProgress: TimeInterval?,
        displayedProgress: TimeInterval,
        elapsed: TimeInterval,
        duration: TimeInterval,
        playbackIsActive: Bool,
        tolerance: TimeInterval = 0.05
    ) -> PlaybackProgressResolution {
        guard engineProgress.isFinite, engineProgress >= 0 else {
            return PlaybackProgressResolution(progress: nil, transition: .none)
        }

        let safeDisplayedProgress = displayedProgress.isFinite
            ? max(0, displayedProgress)
            : engineProgress
        let safeElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let safeTolerance = tolerance.isFinite ? max(0, tolerance) : 0

        guard playbackIsActive else {
            let transition: PlaybackProgressResolution.Transition =
                isUsingFallback ? .recovered : .none
            isUsingFallback = false
            consecutiveStalledSamples = 0
            return PlaybackProgressResolution(
                progress: clamped(engineProgress, duration: duration),
                transition: transition
            )
        }

        guard let previousEngineProgress, previousEngineProgress.isFinite else {
            consecutiveStalledSamples = 0
            return PlaybackProgressResolution(
                progress: clamped(engineProgress, duration: duration),
                transition: .none
            )
        }

        let engineAdvanced = engineProgress > previousEngineProgress + safeTolerance
        if engineAdvanced {
            if isUsingFallback,
               engineProgress + safeTolerance < safeDisplayedProgress {
                return PlaybackProgressResolution(
                    progress: clamped(
                        safeDisplayedProgress + safeElapsed,
                        duration: duration
                    ),
                    transition: .none
                )
            }

            let transition: PlaybackProgressResolution.Transition =
                isUsingFallback ? .recovered : .none
            isUsingFallback = false
            consecutiveStalledSamples = 0
            return PlaybackProgressResolution(
                progress: clamped(
                    max(engineProgress, safeDisplayedProgress),
                    duration: duration
                ),
                transition: transition
            )
        }

        consecutiveStalledSamples += 1
        guard consecutiveStalledSamples >= 2 else {
            return PlaybackProgressResolution(
                progress: clamped(
                    max(engineProgress, safeDisplayedProgress),
                    duration: duration
                ),
                transition: .none
            )
        }

        let transition: PlaybackProgressResolution.Transition =
            isUsingFallback ? .none : .enteredFallback
        isUsingFallback = true
        return PlaybackProgressResolution(
            progress: clamped(
                safeDisplayedProgress + safeElapsed,
                duration: duration
            ),
            transition: transition
        )
    }

    mutating func reset() {
        isUsingFallback = false
        consecutiveStalledSamples = 0
    }

    private func clamped(
        _ progress: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        let nonnegativeProgress = max(0, progress)
        guard duration.isFinite, duration > 0 else {
            return nonnegativeProgress
        }
        return min(nonnegativeProgress, duration)
    }
}
```

The `Core` filesystem-synchronized Xcode group automatically includes this Swift file; do not edit `project.pbxproj`.

- [ ] **Step 4: Run the pure test and verify GREEN**

Run:

```bash
Scripts/test-playback-progress-resolver.sh
```

Expected:

```text
Playback progress resolver checks passed
```

- [ ] **Step 5: Review and commit the resolver**

Run:

```bash
git diff --check
git diff -- Core/Playback/PlaybackProgressResolver.swift Scripts/test-playback-progress-resolver.sh
git add Core/Playback/PlaybackProgressResolver.swift Scripts/test-playback-progress-resolver.sh
git commit -m "fix(playback): resolve frozen progress samples"
```

Expected: `git diff --check` exits 0 and the commit contains only the pure resolver and its executable regression test.

---

### Task 2: Integrate Monotonic Recovery into PlaybackManager

**Files:**
- Modify: `Managers/PlaybackManager.swift:59-60`
- Modify: `Managers/PlaybackManager.swift:404-415`
- Modify: `Managers/PlaybackManager.swift:540-568`
- Modify: `Managers/PlaybackManager.swift:652-685`
- Modify: `Managers/PlaybackManager.swift:758-770`
- Modify: `Managers/PlaybackManager.swift:789-875`
- Modify: `Scripts/test-playback-progress-state-race.sh`

**Interfaces:**
- Consumes: `PlaybackProgressResolver`, `PlaybackProgressResolution.Transition`, existing `PlaybackEngine.currentPlaybackProgress`, `wantsPlaybackActive`, `isPlaying`, and `shouldPublishProgressSample`.
- Produces: one shared resolved `PlaybackProgressState.currentTime` used unchanged by all progress bars, lyric views, persistence, and Now Playing publication.

- [ ] **Step 1: Extend the source regression test for the integration**

Append these checks inside the existing Python block in `Scripts/test-playback-progress-state-race.sh`, before its final success print:

```python
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
    next_marker = manager.find("\\n    func ", function_start + 1)
    private_marker = manager.find("\\n    private func ", function_start + 1)
    candidates = [index for index in (next_marker, private_marker) if index != -1]
    function_end = min(candidates) if candidates else len(manager)
    if "resetProgressResolution" not in manager[function_start:function_end]:
        raise SystemExit(f"{function_name} must reset frozen-progress recovery state.")
```

- [ ] **Step 2: Run the integration test and verify RED**

Run:

```bash
Scripts/test-playback-progress-state-race.sh
```

Expected: exit 1 with `PlaybackManager must own the progress resolver.`

- [ ] **Step 3: Add resolver state and the centralized reset helper**

Next to `lastObservedEngineProgress` in `PlaybackManager`, add:

```swift
private var progressResolver = PlaybackProgressResolver()
private var lastProgressSampleUptime: TimeInterval?
```

Before `stopProgressUpdateTimer`, add:

```swift
private func resetProgressResolution(engineProgress: TimeInterval? = nil) {
    progressResolver.reset()
    lastObservedEngineProgress = engineProgress
    lastProgressSampleUptime = nil
}
```

- [ ] **Step 4: Route timer samples through the resolver**

In `startProgressUpdateTimer`, retain the existing raw state/progress capture and `shouldPublishProgressSample` guard. Replace the direct `currentTime = engineProgress` assignment with:

```swift
let sampleUptime = ProcessInfo.processInfo.systemUptime
let elapsed = self.lastProgressSampleUptime
    .map { max(0, sampleUptime - $0) } ?? 0
self.lastProgressSampleUptime = sampleUptime

let engineState = self.audioPlayer.state
let engineProgress = self.audioPlayer.currentPlaybackProgress
let previousEngineProgress = self.lastObservedEngineProgress
self.lastObservedEngineProgress = engineProgress

guard self.shouldPublishProgressSample(
    engineState: engineState,
    engineProgress: engineProgress,
    previousEngineProgress: previousEngineProgress
) else { return }

if self.wantsPlaybackActive && engineState != .playing && !self.isPlaying {
    Logger.warning(
        "Playback progress advanced while engine state was \(engineState); resyncing playback UI"
    )
    self.setPlaybackActive(true)
}

let tolerance = self.fineProgressSampling ? 0.05 : 0.2
let resolution = self.progressResolver.resolve(
    engineProgress: engineProgress,
    previousEngineProgress: previousEngineProgress,
    displayedProgress: self.currentTime,
    elapsed: elapsed,
    duration: self.currentTrack?.duration ?? self.audioPlayer.duration,
    playbackIsActive: self.wantsPlaybackActive
        && (engineState == .playing || self.isPlaying),
    tolerance: tolerance
)

guard let resolvedProgress = resolution.progress else { return }

switch resolution.transition {
case .enteredFallback:
    Logger.warning(
        "Playback progress stalled on \(MediaBackend.current) while engine state was \(engineState); using monotonic display progress from \(engineProgress)s"
    )
case .recovered:
    Logger.info(
        "Playback engine progress recovered at \(engineProgress)s; ending monotonic display fallback"
    )
case .none:
    break
}

self.currentTime = resolvedProgress
```

Keep the existing throttled Now Playing update immediately after the resolved assignment.

- [ ] **Step 5: Reset resolution state at every timeline discontinuity**

Replace direct writes to `lastObservedEngineProgress` with `resetProgressResolution` and add resets at the following operations:

```swift
// restoreUIState and prepareTrackForRestoration, after setting currentTime:
resetProgressResolution(engineProgress: uiState.playbackPosition)
// prepareTrackForRestoration uses:
self.resetProgressResolution(engineProgress: position)

// stop and stopGracefully, after currentTime = 0:
resetProgressResolution(engineProgress: 0)

// prepareCurrentTrackForTrashMove, after restoring snapshot.position:
resetProgressResolution(engineProgress: snapshot.position)

// restoreCurrentTrackAfterFailedTrashMove, after restoring snapshot.position:
resetProgressResolution(engineProgress: snapshot.position)

// handleTrackMovedToTrash, after currentTime = 0:
resetProgressResolution(engineProgress: 0)

// seekTo, replacing lastObservedEngineProgress = clampedTime:
resetProgressResolution(engineProgress: clampedTime)

// reloadPlaybackEngine, after currentTime/restoredPosition handling:
resetProgressResolution(engineProgress: resumePosition)

// startPlayback, replacing its lastObservedEngineProgress assignment:
resetProgressResolution(engineProgress: seekToPosition > 0 ? seekToPosition : 0)

// handleGaplessAdvance, replacing lastObservedEngineProgress = 0:
resetProgressResolution(engineProgress: 0)
```

In current-entry EOF, user-action finish, and error paths that leave `currentTime` at 0 without immediately starting another track, add:

```swift
self.resetProgressResolution(engineProgress: 0)
```

Do not reset from every repeated state callback; the resolver must be able to count two consecutive stalled timer samples.

- [ ] **Step 6: Run focused playback and lyrics tests**

Run:

```bash
Scripts/test-playback-progress-resolver.sh
Scripts/test-playback-progress-state-race.sh
Scripts/test-playback-toggle-state-consistency.sh
Scripts/test-karaoke-timing.sh
Scripts/test-desktop-lyrics-line-selection.sh
Scripts/test-track-lyrics-highlight-transition.sh
```

Expected: all commands exit 0 with their respective `checks passed` messages.

- [ ] **Step 7: Build after integration**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: exit 0 with `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Review and commit the integration**

Run:

```bash
git diff --check
git diff -- Managers/PlaybackManager.swift Scripts/test-playback-progress-state-race.sh
git add Managers/PlaybackManager.swift Scripts/test-playback-progress-state-race.sh
git commit -m "fix(playback): recover frozen display progress"
```

Expected: the diff contains only timer resolution, logging, lifecycle resets, and the focused source regression checks.

---

### Task 3: Upgrade CrescendoKit and Run Full Verification

**Files:**
- Create: `Scripts/test-crescendo-version.sh`
- Modify: `Petrichor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

**Interfaces:**
- Consumes: the existing `upToNextMajorVersion` CrescendoKit requirement with minimum version 1.0.0.
- Produces: a reproducible SwiftPM resolution pinned to CrescendoKit 1.1.1 revision `ef50ecfcafad7b5976735c09a8741158b642d258`.

- [ ] **Step 1: Write the failing dependency-pin check**

Create `Scripts/test-crescendo-version.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import json
from pathlib import Path

resolved = json.loads(
    Path("Petrichor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text()
)
pin = next((pin for pin in resolved["pins"] if pin["identity"] == "crescendokit"), None)
if pin is None:
    raise SystemExit("Package.resolved must contain the CrescendoKit pin.")

state = pin["state"]
expected_version = "1.1.1"
expected_revision = "ef50ecfcafad7b5976735c09a8741158b642d258"

if state.get("version") != expected_version:
    raise SystemExit(
        f"CrescendoKit must be pinned to {expected_version}; found {state.get('version')}."
    )

if state.get("revision") != expected_revision:
    raise SystemExit(
        f"CrescendoKit {expected_version} must use revision {expected_revision}; "
        f"found {state.get('revision')}."
    )

print("CrescendoKit version checks passed")
PY
```

Make it executable:

```bash
chmod +x Scripts/test-crescendo-version.sh
```

- [ ] **Step 2: Run the dependency test and verify RED**

Run:

```bash
Scripts/test-crescendo-version.sh
```

Expected: exit 1 with `CrescendoKit must be pinned to 1.1.1; found 1.0.0.`

- [ ] **Step 3: Update the resolved pin**

In `Petrichor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, change only the CrescendoKit state:

```json
"state" : {
  "revision" : "ef50ecfcafad7b5976735c09a8741158b642d258",
  "version" : "1.1.1"
}
```

Do not change `Petrichor.xcodeproj/project.pbxproj`; its existing `upToNextMajorVersion` requirement already accepts 1.1.1.

- [ ] **Step 4: Run the dependency test and resolve packages**

Run:

```bash
Scripts/test-crescendo-version.sh
xcodebuild -resolvePackageDependencies -project Petrichor.xcodeproj -scheme Petrichor
```

Expected:

```text
CrescendoKit version checks passed
```

and `xcodebuild` exits 0 reporting CrescendoKit 1.1.1.

- [ ] **Step 5: Run all repository shell checks**

Run:

```bash
set -e
for script in Scripts/test-*.sh; do
  bash "$script"
done
```

Expected: every script exits 0. If a pre-existing unrelated script fails, capture its exact name and output before deciding whether it belongs to this task.

- [ ] **Step 6: Run the final Debug build**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: exit 0 with `** BUILD SUCCEEDED **`, with the resolved-package section showing CrescendoKit 1.1.1.

- [ ] **Step 7: Inspect the final scoped diff**

Run:

```bash
git status --short
git diff --check
git diff --stat HEAD~2
git diff HEAD~2 -- \
  Core/Playback/PlaybackProgressResolver.swift \
  Managers/PlaybackManager.swift \
  Scripts/test-playback-progress-resolver.sh \
  Scripts/test-playback-progress-state-race.sh \
  Scripts/test-crescendo-version.sh \
  Petrichor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

Expected: no whitespace errors and no changes outside the six implementation/test/dependency files.

- [ ] **Step 8: Commit the dependency update and verification**

```bash
git add \
  Scripts/test-crescendo-version.sh \
  Petrichor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "fix(playback): update CrescendoKit to 1.1.1"
```

Expected: a focused commit containing the executable dependency regression check and the CrescendoKit pin update.
