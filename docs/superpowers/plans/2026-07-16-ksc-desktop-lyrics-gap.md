# KSC Desktop Lyrics Gap Handling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent KSC desktop lyrics from temporarily showing “No Lyrics Available” between timed lines while preserving existing behavior for other synchronized formats.

**Architecture:** Add an explicit gap behavior to the pure desktop line selector, defaulting to the current empty-gap result. The desktop provider opts into holding the most recently started non-empty line only when the loaded source is KSC, so parsing, timestamps, SRT behavior, and other lyrics views remain unchanged.

**Tech Stack:** Swift, Swift concurrency and Combine, shell-based Swift regression tests, SwiftUI, Xcode 16+

---

## File map

- `Scripts/test-desktop-lyrics-line-selection.sh`: Add pure selector cases and a provider integration fixture covering a KSC gap and the post-final-line interval.
- `Core/DesktopLyricsLineSelection.swift`: Define the gap policy and deterministically choose the previous non-empty, already-started line when requested.
- `Views/DesktopLyrics/DesktopLyricsLineProvider.swift`: Select the hold policy only for KSC lyrics.
- `docs/superpowers/specs/2026-07-16-ksc-desktop-lyrics-gap-design.md`: Read-only source of approved behavior; no implementation edits.

### Task 1: Add KSC gap selection and provider regression coverage

**Files:**
- Modify: `Scripts/test-desktop-lyrics-line-selection.sh:66-79`
- Modify: `Scripts/test-desktop-lyrics-line-selection.sh:262-266`
- Test: `Scripts/test-desktop-lyrics-line-selection.sh`

- [ ] **Step 1: Add failing pure selector cases without changing the existing default-gap assertions**

Immediately after the two `assertNil` checks for `finiteTimed`, add:

```swift
assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(
        lines: finiteTimed,
        at: 3,
        gapBehavior: .holdPreviousLine
    ),
    DesktopLyricsDisplayLines(current: finiteTimed[0], next: finiteTimed[1]),
    "KSC gaps hold the most recently started non-empty line"
)

assertEqual(
    DesktopLyricsLineSelection.syncedDisplayLines(
        lines: finiteTimed,
        at: 7,
        gapBehavior: .holdPreviousLine
    ),
    DesktopLyricsDisplayLines(current: finiteTimed[1], next: nil),
    "KSC keeps the final non-empty line after its end time"
)
```

These cases prove both the sentence gap and the interval after the final KSC line. The existing `assertNil` cases prove that `.empty` remains the default behavior.

- [ ] **Step 2: Add a failing provider integration fixture**

In `DesktopLyricsProviderIntegrationTests.main()`, after the first provider lifecycle assertion and before the success `print`, add:

```swift
        let gapFirst = LyricLine(
            text: "gap first",
            startTime: 0,
            endTime: 1,
            timingSegments: [
                LyricTimingSegment(text: "gap first", startOffset: 0, duration: 1),
            ]
        )
        let gapSecond = LyricLine(
            text: "gap second",
            startTime: 5,
            endTime: 6,
            timingSegments: [
                LyricTimingSegment(text: "gap second", startOffset: 0, duration: 1),
            ]
        )
        let gapTrack = Track(id: UUID())
        LyricsStore.shared.cached = LyricsStore.Lyrics(
            trackId: gapTrack.id,
            lines: [gapFirst, gapSecond],
            hasTimed: true,
            isKaraoke: true
        )
        let gapPlaybackManager = PlaybackManager(
            currentTrack: gapTrack,
            currentTime: 3,
            isPlaying: false
        )
        let gapProvider = DesktopLyricsLineProvider(
            playbackManager: gapPlaybackManager,
            libraryManager: libraryManager
        )

        gapProvider.appear()
        assertCurrent(
            gapProvider,
            equals: gapFirst,
            message: "A loaded KSC gap must keep the completed previous line"
        )
        gapProvider.playbackTimeChanged(7)
        assertCurrent(
            gapProvider,
            equals: gapSecond,
            message: "KSC must keep the final line after its end time"
        )
        gapProvider.disappear()
        precondition(gapPlaybackManager.fineSamplingConsumers == 0,
                     "Gap provider lifecycle must release fine progress sampling")
```

This uses a paused provider so wall-clock timing cannot make the regression test flaky.

- [ ] **Step 3: Run the focused test and verify RED**

Run:

```bash
Scripts/test-desktop-lyrics-line-selection.sh
```

Expected: compilation fails because `syncedDisplayLines` has no `gapBehavior` parameter and `.holdPreviousLine` does not exist. This confirms the new tests exercise behavior absent from production code.

### Task 2: Implement the explicit KSC-only gap policy

**Files:**
- Modify: `Core/DesktopLyricsLineSelection.swift:8-37`
- Modify: `Core/DesktopLyricsLineSelection.swift:50-62`
- Modify: `Views/DesktopLyrics/DesktopLyricsLineProvider.swift:163-171`
- Test: `Scripts/test-desktop-lyrics-line-selection.sh`

- [ ] **Step 1: Define the policy and extend the selector API**

At the start of `DesktopLyricsLineSelection`, add the nested policy and replace the selector signature:

```swift
enum DesktopLyricsLineSelection {
    enum GapBehavior: Equatable {
        case empty
        case holdPreviousLine
    }

    static func syncedDisplayLines(
        lines: [LyricLine],
        at time: TimeInterval,
        gapBehavior: GapBehavior = .empty
    ) -> DesktopLyricsDisplayLines? {
```

The default keeps all existing call sites and non-KSC behavior source-compatible.

- [ ] **Step 2: Select the previous line only when the policy requests it**

Replace the final `else` in the `currentIndex` decision with:

```swift
        } else if gapBehavior == .holdPreviousLine {
            currentIndex = lastStartedNonEmptyIndex(in: lines, at: time)
        } else {
            currentIndex = nil
        }
```

Add this helper immediately before `trimmedText`:

```swift
    private static func lastStartedNonEmptyIndex(
        in lines: [LyricLine],
        at time: TimeInterval
    ) -> Int? {
        lines.lastIndex { line in
            time >= line.startTime && !trimmedText(line).isEmpty
        }
    }
```

The helper recalculates from playback time, so seeks cannot retain a stale UI line. It ignores blank KSC rows and naturally returns the final non-empty line after its end.

- [ ] **Step 3: Opt the desktop provider into the policy only for KSC**

Replace the selector call inside `updateTimedDisplay(at:)` with:

```swift
        let gapBehavior: DesktopLyricsLineSelection.GapBehavior = isKaraokeLyrics
            ? .holdPreviousLine
            : .empty
        if let lines = DesktopLyricsLineSelection.syncedDisplayLines(
            lines: lyricLines,
            at: time,
            gapBehavior: gapBehavior
        ) {
            state = .lyrics(lines)
        } else {
            state = .empty
        }
```

Do not change KSC parsing, `endTime`, renderer sample time, or boundary scheduling.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
Scripts/test-desktop-lyrics-line-selection.sh
```

Expected output includes:

```text
Desktop lyrics line selection tests passed
Desktop lyrics provider boundary/sample integration tests passed
```

- [ ] **Step 5: Run adjacent karaoke regression checks**

Run:

```bash
Scripts/test-karaoke-timing.sh
Scripts/test-karaoke-lyrics-rendering.sh
```

Expected output includes:

```text
Karaoke timing checks passed
Karaoke lyrics renderer checks passed
```

- [ ] **Step 6: Run the app build**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: command exits with status 0 and ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Inspect the final diff and commit the implementation**

Run:

```bash
git diff --check
git diff -- Scripts/test-desktop-lyrics-line-selection.sh Core/DesktopLyricsLineSelection.swift Views/DesktopLyrics/DesktopLyricsLineProvider.swift
git status --short
git add Scripts/test-desktop-lyrics-line-selection.sh Core/DesktopLyricsLineSelection.swift Views/DesktopLyrics/DesktopLyricsLineProvider.swift
git commit -m "fix(lyrics): keep KSC desktop lines through gaps"
```

Expected: no whitespace errors; the diff contains only the approved selector policy, KSC provider opt-in, and regression coverage; the commit succeeds.
