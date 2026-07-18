# ID3 Selective Metadata Writing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make verified ID3-carrier metadata edits frame-selective and content-probed so untouched ID3v2 data survives every dirty-field write.

**Architecture:** Add the already-resolved CXXTagLib `taglib` product directly to the app target for explicit compile-time access, expose a small C ABI from Objective-C++, translate Swift patches into only dirty operations, and route verified MPEG/WAVE/AIFF/TrueAudio carriers through a format-specific bridge while retaining SFBAudioEngine for native non-ID3 formats and reopen verification. Unverified ID3 carriers are read-only.

**Tech Stack:** Swift 6, Objective-C++17, C ABI, CXXTagLib/TagLib 2.3.0, SFBAudioEngine, shell integration tests, ffmpeg, Xcode 16.

## Global Constraints

- Do not modify database or playback code.
- Never use SFBAudioEngine's whole-metadata write path for an actual ID3
  carrier.
- Never emit an operation for an unchanged patch field.
- Only mutate the frame ID corresponding to a supplied operation.
- Preserve advanced, unknown, repeated, and private ID3v2 frames.
- Preserve `TDRC` input text and remove `TCMP` for false.
- Keep SFBAudioEngine reopen verification after every successful write.

---

### Task 1: RED contract and real-file harness

**Files:**
- Create: `Scripts/test-id3-selective-metadata-write.sh`
- Modify: `Scripts/test-track-metadata-file-service.sh`
- Test: both scripts

- [ ] **Step 1: Add production-route assertions**

Require actual-container probing, bridge-only verified ID3 writes, safe
rejection of unverified carriers, retained native non-ID3 `writeMetadata()`,
and retained SFBAudioEngine reopen verification.

- [ ] **Step 2: Add a real ID3-carrier/TagLib harness**

Generate short MP3, WAVE, AIFF, and TrueAudio fixtures with ffmpeg; seed
repeated `POPM`, `USLT`, `APIC`, unknown `TXXX`, `PRIV`, and `UFID` frames in
each; invoke the production C bridge; compare serialized advanced-frame
payloads; verify exact date and compilation round-trips. Also probe misnamed
MPEG, FLAC-as-MP3, and Shorten-signature-as-MP3 fixtures.

- [ ] **Step 3: Run against the baseline**

```sh
Scripts/test-track-metadata-file-service.sh
Scripts/test-id3-selective-metadata-write.sh
```

Expected: both exit nonzero because selective ID3 routing and the production
bridge do not exist.

- [ ] **Step 4: Commit the design and RED evidence**

Stage only these two scripts plus this plan and its design specification.

### Task 2: Direct dependency and bridge

**Files:**
- Modify: `Petrichor.xcodeproj/project.pbxproj`
- Modify if resolution changes: `Petrichor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Create: `Core/Metadata/PetrichorMetadataBridge.h`
- Create: `Core/Metadata/ID3TagWriterBridge.h`
- Create: `Core/Metadata/ID3TagWriterBridge.mm`
- Create: `Core/Metadata/ID3TrackMetadataWriter.swift`
- Test: `Scripts/test-id3-selective-metadata-write.sh`

- [ ] **Step 1: Add CXXTagLib 2.3.0 directly**

Add the remote package reference, the `taglib` product dependency, the
Frameworks build-phase entry, and the app bridging-header build setting.

- [ ] **Step 2: Implement content probing**

Probe the path as MPEG Layer III, WAVE, AIFF, TrueAudio, and known unsafe ID3
carriers using actual container validity and audio properties. Obtain the
concrete ID3v2 tag and save through that concrete format. Mark DSF/DSDIFF and
FLAC-with-ID3 read-only until equivalent real-file coverage exists.

- [ ] **Step 3: Implement selective frame writes**

Map dirty operations to the specified frame IDs, merge `TRCK`/`TPOS`
components, preserve the existing ID3v2 version, strip nothing, and avoid tag
duplication.

- [ ] **Step 4: Implement Swift patch translation**

Convert only `.set` and `.remove` cases into bridge operations. Encode numeric
values as decimal text and compilation false as remove.

- [ ] **Step 5: Run the real-file harness**

```sh
Scripts/test-id3-selective-metadata-write.sh
```

Expected: all verified temporary ID3 carriers pass payload-preservation and
round-trip assertions.

### Task 3: File-service integration

**Files:**
- Modify: `Core/Metadata/SFBTrackMetadataFileService.swift`
- Test: `Scripts/test-track-metadata-file-service.sh`
- Test: `Scripts/test-id3-selective-metadata-write.sh`

- [ ] **Step 1: Probe actual-container capability**

Make preflight, writable snapshots, and final validation probe every
allowlisted target. Actual verified carriers always select the bridge,
extension `.mp3` requires actual MPEG, and unsafe carriers are read-only.

- [ ] **Step 2: Route verified ID3 writes exclusively through the bridge**

Keep the current SFBAudioEngine metadata mutation/write block for remaining
native non-ID3 formats only.

- [ ] **Step 3: Preserve reopen verification**

After either writer succeeds, reload through SFBAudioEngine and compare every
dirty field.

- [ ] **Step 4: Run focused GREEN**

```sh
Scripts/test-track-metadata-file-service.sh
Scripts/test-id3-selective-metadata-write.sh
```

Expected: both print pass messages and exit zero.

### Task 4: Build, review, and report

**Files:**
- Modify: `.superpowers/sdd/final-review-fixes-report.md`

- [ ] **Step 1: Build the app target**

```sh
CLANG_MODULE_CACHE_PATH=/tmp/PetrichorClangModuleCache \
SWIFT_MODULECACHE_PATH=/tmp/PetrichorSwiftModuleCache \
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor \
  -configuration Debug -derivedDataPath /tmp/PetrichorID3DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`. If the direct product still does not expose
TagLib headers to the `.mm` source, stop and report the exact compiler error;
do not restore whole-metadata ID3 writes.

- [ ] **Step 2: Run metadata regressions**

Run the two focused checks and any adjacent track-metadata scripts affected by
the service integration.

- [ ] **Step 3: Review the scoped diff**

Verify no DB/playback files are staged, request an independent review, resolve
all critical or important findings, and append the SFB/ID3 RED/GREEN/build
evidence to the final-review report.

- [ ] **Step 4: Commit implementation**

Stage only bridge, Swift metadata service, Xcode dependency, focused tests if
adjusted after RED, and the report section.
