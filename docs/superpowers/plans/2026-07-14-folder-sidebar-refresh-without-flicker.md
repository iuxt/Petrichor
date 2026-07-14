# Folder Sidebar Refresh Without Flicker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the existing Folders sidebar hierarchy visible while track deletion triggers an asynchronous hierarchy refresh.

**Architecture:** Preserve the current hierarchy as the visible snapshot whenever `folderNodes` is nonempty. Continue rebuilding the complete hierarchy in the background, then use the existing generation guard, path-based expansion restoration, and atomic `folderNodes` assignment to apply only the latest result.

**Tech Stack:** Swift, SwiftUI, Foundation notifications, Bash/`rg` regression scripts, Xcode 16+

## Global Constraints

- An already visible folder tree must remain mounted for the entire refresh and must not show a loading indicator or overlay.
- The existing loading view remains available for the initial hierarchy load when no previous tree exists.
- Updated counts and hierarchy must continue to appear together after the asynchronous rebuild completes.
- Preserve the existing selected-path restoration, expanded-path restoration, empty-folder behavior, `0 tracks` display, and generation guard.
- Do not change Trash behavior, database updates, filesystem scanning rules, folder identity, or audio files.
- Do not add dependencies or modify Xcode project metadata.

---

### Task 1: Keep the Existing Folder Tree Visible During Refresh

**Files:**
- Modify: `Scripts/test-folder-tab-trash-refresh.sh`
- Modify: `Views/Folders/FolderSidebarView.swift:96-106`

**Interfaces:**
- Consumes: `folderNodes: [FolderNode]`, `isLoadingHierarchy: Bool`, and the existing `loadFolderHierarchy() async` refresh pipeline.
- Produces: A loading-state assignment that is `true` only when no existing hierarchy can remain visible.

- [ ] **Step 1: Add a failing regression check for the loading-state policy**

Append these checks before the final success message in `Scripts/test-folder-tab-trash-refresh.sh`:

```bash
if ! rg -F 'isLoadingHierarchy = folderNodes.isEmpty' "$folders_sidebar" >/dev/null; then
    printf 'Folder hierarchy refresh must keep an existing tree visible while loading.\n' >&2
    exit 1
fi

if rg -n '^[[:space:]]*isLoadingHierarchy = true$' "$folders_sidebar" >/dev/null; then
    printf 'Folder hierarchy refresh must not unconditionally replace the tree with loading UI.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run the focused check and verify the new assertion fails**

Run:

```bash
Scripts/test-folder-tab-trash-refresh.sh
```

Expected: exit status `1` with `Folder hierarchy refresh must keep an existing tree visible while loading.`

- [ ] **Step 3: Implement the minimal loading-state change**

In the initial `MainActor.run` block of `FoldersSidebarView.loadFolderHierarchy()`, replace the unconditional loading assignment:

```swift
isLoadingHierarchy = true
```

with:

```swift
isLoadingHierarchy = folderNodes.isEmpty
```

Do not clear or replace `folderNodes` before `FolderHierarchyBuilder.buildHierarchy(...)` finishes. Leave the generation guard and the final main-actor assignment unchanged.

- [ ] **Step 4: Run the focused check and verify it passes**

Run:

```bash
Scripts/test-folder-tab-trash-refresh.sh
```

Expected: exit status `0` with `Folder tab Trash refresh checks passed`.

- [ ] **Step 5: Run the related regression suite and whitespace check**

Run:

```bash
bash Scripts/test-track-trash-order.sh
bash Scripts/test-track-trash-sidecars.sh
bash Scripts/test-localization-format-specifiers.sh
git diff --check
```

Expected:

```text
Track trash ordering checks passed
Track trash sidecar rules preserved
Localization format specifier checks passed
```

`git diff --check` must produce no output and exit with status `0`.

- [ ] **Step 6: Build the app without code signing**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Expected: exit status `0` ending with `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Review the focused diff and commit**

Run:

```bash
git diff -- Scripts/test-folder-tab-trash-refresh.sh Views/Folders/FolderSidebarView.swift
git status --short
```

Confirm that only the focused regression assertion and conditional loading assignment are present, then commit:

```bash
git add Scripts/test-folder-tab-trash-refresh.sh Views/Folders/FolderSidebarView.swift
git commit -m "fix: keep folder sidebar visible while refreshing"
```
