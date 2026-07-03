# Move Track to Trash Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a confirmed track context-menu action that moves the audio file and orphaned sidecars to macOS Trash, then removes the track from the library.

**Architecture:** Add a focused `TrackTrashManager` for sidecar selection, Trash operations, database deletion, and UI notifications. Keep `TrackContextMenu` responsible only for presenting the menu item and confirmation alert. Use the existing database orphan cleanup and library refresh methods after successful file trashing.

**Tech Stack:** Swift, SwiftUI context menus, AppKit `NSAlert`, `FileManager.trashItem`, GRDB-backed `DatabaseManager`.

---

### Task 1: Sidecar Selection Regression

**Files:**
- Create: `Scripts/test-track-trash-sidecars.sh`

- [ ] **Step 1: Write a failing shell regression test**

Create a script that checks source text for a sidecar helper and verifies it handles lyrics and cover artwork rules through a temporary fixture.

- [ ] **Step 2: Run the script**

Run: `bash Scripts/test-track-trash-sidecars.sh`

Expected before implementation: FAIL because `Core/TrackTrashManager.swift` does not exist.

### Task 2: Trash Manager

**Files:**
- Create: `Core/TrackTrashManager.swift`
- Modify: `Managers/Database/DMCleanup.swift`

- [ ] **Step 1: Implement sidecar selection**

Add `sidecarURLs(for:)` that includes same-basename `.lrc`/`.srt` and known cover artwork only when no other supported audio remains.

- [ ] **Step 2: Implement confirmed trash flow**

Move all selected URLs to Trash. If any Trash operation fails, do not delete the database track.

- [ ] **Step 3: Implement database track removal**

Add `removeTrackFromLibrary(_:)` in `DatabaseManager` to delete the track row and run comprehensive orphan cleanup.

### Task 3: Context Menu Integration

**Files:**
- Modify: `Views/Components/TrackContextMenu.swift`

- [ ] **Step 1: Add the destructive menu item**

Add `Move to Trash...` near `Reveal in Finder`, with a confirmation `NSAlert`.

- [ ] **Step 2: Trigger the manager after confirmation**

On confirm, call `TrackTrashManager.moveTrackToTrash(track)` asynchronously.

### Task 4: Verification

**Files:**
- Run existing and new verification commands.

- [ ] **Step 1: Run sidecar regression**

Run: `bash Scripts/test-track-trash-sidecars.sh`

Expected: PASS.

- [ ] **Step 2: Check patch whitespace**

Run: `git diff --check`

Expected: PASS.

- [ ] **Step 3: Build without local signing**

Run: `xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug CODE_SIGNING_ALLOWED=NO build`

Expected: BUILD SUCCEEDED.
