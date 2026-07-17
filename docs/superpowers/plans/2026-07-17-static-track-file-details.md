# Static Track File Details Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make File Details permanently visible and render it with exactly the same metadata-section layout as Details.

**Architecture:** Keep the change inside `TrackDetailView`. Derive file metadata in the parent view and pass it to the existing `metadataSection(title:items:)` builder, then delete the dedicated collapsible subview.

**Tech Stack:** Swift 5, SwiftUI, Bash source-regression checks, Xcode 16+

## Global Constraints

- File Details must remain below Details and always be visible once `FullTrack` loads.
- Preserve all current file metadata fields, ordering, formatting, and localized strings.
- Do not change artwork behavior, track loading, database access, or any audio file.
- Follow the existing compact macOS SwiftUI style.

---

### Task 1: Replace Collapsible File Details with the Shared Metadata Section

**Files:**
- Create: `Scripts/test-static-track-file-details.sh`
- Modify: `Views/Main/TrackDetailView.swift:54-71`
- Modify: `Views/Main/TrackDetailView.swift:264-530`

**Interfaces:**
- Consumes: `metadataSection(title: String, items: [(label: String, value: String)]) -> some View` and the existing `FullTrack` display properties.
- Produces: `fileDetailsItems(for fullTrack: FullTrack) -> [(label: String, value: String)]`, rendered by `metadataSection`.

- [ ] **Step 1: Write the failing source-regression check**

Create `Scripts/test-static-track-file-details.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACK_DETAIL="$ROOT_DIR/Views/Main/TrackDetailView.swift"

require_pattern() {
    local pattern="$1"
    local message="$2"

    if ! rg -n "$pattern" "$TRACK_DETAIL" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

reject_pattern() {
    local pattern="$1"
    local message="$2"

    if rg -n "$pattern" "$TRACK_DETAIL" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern \
    'metadataSection\(title: String\(appLocalized: "File Details"\), items: fileDetailsItems\(for: fullTrack\)\)' \
    'File Details must use the shared metadata section.'
require_pattern \
    'private func fileDetailsItems\(for fullTrack: FullTrack\)' \
    'TrackDetailView must derive file detail items for the shared section.'
reject_pattern \
    'FileDetailsSection|isExpanded' \
    'File Details must not retain a collapsible view or expansion state.'

printf '%s\n' 'Static track file details checks passed'
```

Make the check executable:

```bash
chmod +x Scripts/test-static-track-file-details.sh
```

- [ ] **Step 2: Run the check and verify the RED state**

Run:

```bash
Scripts/test-static-track-file-details.sh
```

Expected: exit 1 with `File Details must use the shared metadata section.`

- [ ] **Step 3: Render File Details with `metadataSection`**

In the loaded-track content of `Views/Main/TrackDetailView.swift`, replace the collapsible view call with:

```swift
metadataSection(
    title: String(appLocalized: "File Details"),
    items: fileDetailsItems(for: fullTrack)
)
```

Inside `TrackDetailView`, add:

```swift
private func fileDetailsItems(for fullTrack: FullTrack) -> [(label: String, value: String)] {
    var items: [(label: String, value: String)] = []

    items.append((String(appLocalized: "Format"), fullTrack.format.uppercased()))

    if let codec = fullTrack.codecDisplay {
        items.append((String(appLocalized: "Codec"), codec))
    }

    if let bitrate = fullTrack.bitrateDisplay {
        items.append((String(appLocalized: "Bitrate"), bitrate))
    }

    if let sampleRate = fullTrack.sampleRateDisplay {
        items.append((String(appLocalized: "Sample Rate"), sampleRate))
    }

    if let bitDepth = fullTrack.bitDepth, bitDepth > 0 {
        items.append((String(appLocalized: "Bit Depth"), String(appLocalized: "\(bitDepth)-bit")))
    }

    if let channels = fullTrack.channelsDisplay {
        items.append((String(appLocalized: "Channels"), channels))
    }

    if let fileSize = fullTrack.fileSize, fileSize > 0 {
        items.append((String(appLocalized: "File Size"), formatFileSize(fileSize)))
    }

    items.append((String(appLocalized: "File Path"), fullTrack.url.path))

    if let dateAdded = fullTrack.dateAdded {
        items.append((String(appLocalized: "Date Added"), formatDate(dateAdded)))
    }

    if let dateModified = fullTrack.dateModified {
        items.append((String(appLocalized: "Date Modified"), formatDate(dateModified)))
    }

    if let mediaType = fullTrack.mediaType, !mediaType.isEmpty {
        items.append((String(appLocalized: "Media Type"), mediaType))
    }

    return items
}

private func formatFileSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
```

Delete the entire private `FileDetailsSection` type. Keep the parent view's existing `formatDate(_ date: Date)` helper, which now formats both playback and file dates.

- [ ] **Step 4: Run focused checks and verify the GREEN state**

Run:

```bash
Scripts/test-static-track-file-details.sh
Scripts/test-localization-format-specifiers.sh
```

Expected:

```text
Static track file details checks passed
Localization format specifier checks passed
```

- [ ] **Step 5: Build the app**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: exit 0 with `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Review the scoped diff**

Run:

```bash
git diff --check
git diff -- Scripts/test-static-track-file-details.sh Views/Main/TrackDetailView.swift
```

Expected: `git diff --check` exits 0, and the diff contains only the focused regression check plus the static File Details presentation change.

- [ ] **Step 7: Commit the implementation**

```bash
git add Scripts/test-static-track-file-details.sh Views/Main/TrackDetailView.swift
git commit -m "fix(track-detail): keep file details visible"
```
