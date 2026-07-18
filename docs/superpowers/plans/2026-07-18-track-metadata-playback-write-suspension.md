# Track Metadata Playback Write Suspension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the edited current file closed for the complete metadata-write window while honoring the latest user transport intent.

**Architecture:** Add a Foundation-only suspension reducer and let `PlaybackManager` own one generation-scoped instance. Transport entry points consult it before engine effects; restoration atomically consumes the matching generation and either applies the latest deferred intent or yields to a superseding track choice.

**Tech Stack:** Swift 6, Swift concurrency, SwiftUI-facing `@MainActor` coordination, shell regression harnesses, Xcode 16.

## Global Constraints

- Do not change database, SFBAudioEngine, playback-backend, tag-model, or mixed-field setter semantics.
- The token starts before preparation stops the engine and ends only through matching restoration or cleanup.
- Same-track play is deferred; different-track play supersedes and preserves the new queue/current choice.
- Toggle, stop, and seek are deferred before supersession; explicit stop never auto-replays.
- Every completion is exactly once.

---

### Task 1: RED suspension behavior

**Files:**
- Modify: `Scripts/test-track-metadata-playback-restore.sh`
- Modify: `Scripts/test-track-metadata-editor-orchestration.sh`
- Test: `Scripts/test-track-metadata-playback-restore.sh`
- Test: `Scripts/test-track-metadata-editor-orchestration.sh`

**Interfaces:**
- Consumes: existing metadata prepare/restore API.
- Produces: executable expectations for `MetadataEditPlaybackSuspension` and generation-carrying snapshots.

- [ ] **Step 1: Add a compiled reducer harness**

Add scenarios for original playing/paused/idle state, toggle, seek, explicit
stop, same-track defer, different-track supersession, and same-track reselection.

- [ ] **Step 2: Add orchestration token assertions**

Make the playback double assign a generation during prepare and reject a
duplicate or mismatched restore. Assert success, failure, and cancellation each
consume exactly one token.

- [ ] **Step 3: Run both scripts against the baseline**

Run:

```sh
Scripts/test-track-metadata-playback-restore.sh
Scripts/test-track-metadata-editor-orchestration.sh
```

Expected: both exit nonzero because the reducer, snapshot generation, and
matching-token contract do not exist at `ca8d1b6`.

### Task 2: GREEN reducer and playback integration

**Files:**
- Create: `Core/Playback/MetadataEditPlaybackSuspension.swift`
- Modify: `Managers/PlaybackManager.swift`
- Test: `Scripts/test-track-metadata-playback-restore.sh`
- Test: `Scripts/test-track-metadata-editor-orchestration.sh`

**Interfaces:**
- Consumes: track ID/URL, snapshot state, queue index, and transport requests.
- Produces: `MetadataEditPlaybackSuspension`, its restore disposition, and a generation on `MetadataEditPlaybackSnapshot`.

- [ ] **Step 1: Implement the minimal pure reducer**

Represent desired mode, position, queue-restore authority, edited identity, and
supersession. Return explicit play and restore dispositions.

- [ ] **Step 2: Create the token before the internal stop**

Increment the suspension generation, store the reducer, copy the generation
into the snapshot, then directly stop the engine.

- [ ] **Step 3: Intercept transport entry points**

Handle toggle, stop, seek, and play before engine effects. Defer the edited
identity and let a different identity continue normally after marking the
snapshot superseded.

- [ ] **Step 4: Consume the token during restoration**

Require matching generation, clear the session first, preserve superseding
queue/current choices, and apply the reducer's position/mode through the
existing asynchronous restore operation where necessary.

- [ ] **Step 5: Run focused GREEN**

Run:

```sh
Scripts/test-track-metadata-playback-restore.sh
Scripts/test-track-metadata-editor-orchestration.sh
```

Expected: both print their pass messages and exit zero.

### Task 3: Regression verification and report

**Files:**
- Modify: `.superpowers/sdd/final-review-fixes-report.md`

**Interfaces:**
- Consumes: verified implementation and command output.
- Produces: a Playback report section with RED/GREEN evidence and final commit.

- [ ] **Step 1: Run all playback regressions**

Run:

```sh
for script in Scripts/test-*playback*.sh; do "$script"; done
```

Expected: every playback script exits zero.

- [ ] **Step 2: Run an unsigned Debug build**

Run:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/PetrichorClangModuleCache \
SWIFT_MODULECACHE_PATH=/tmp/PetrichorSwiftModuleCache \
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor \
  -configuration Debug -derivedDataPath /tmp/PetrichorMetadataSuspensionDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Review and record evidence**

Inspect the scoped diff, request an independent code review, resolve every
critical or important finding, and append the RED/GREEN commands and outcomes
to the Playback section of the final-review report.

- [ ] **Step 4: Commit**

Stage only the suspension implementation, focused harnesses, design/plan, and
Playback report section. Commit with:

```sh
git commit -m "fix(metadata): suspend playback through tag writes"
```
