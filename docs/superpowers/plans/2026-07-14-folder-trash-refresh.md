# Folder Track Trash Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh the selected folder track list and folder-sidebar counts immediately after a successful track deletion while retaining empty folders and the user's hierarchy state.

**Architecture:** Reuse the existing `.libraryDataDidChange` event as the semantic invalidation boundary. `FoldersView` will reload its local track snapshot, while `FoldersSidebarView` will rebuild the filesystem hierarchy and restore selection/expansion by standardized path because rebuilt `FolderNode` values have new UUIDs.

**Tech Stack:** Swift 5/6, SwiftUI, Foundation `NotificationCenter`, repository shell regression checks, Xcode 16+ on macOS 14+

## Global Constraints

- Do not alter Trash/file operations, database cleanup, playlist storage, or audio-file contents.
- Keep UI state mutations and hierarchy-state restoration on the main actor.
- Continue excluding hidden directories through `.skipsHiddenFiles`.
- Reuse existing localized folder-count strings; do not add user-facing copy.
- Do not modify generated Xcode project metadata because no project file is added.

## File Structure

- Create `Scripts/test-folder-tab-trash-refresh.sh`: focused source-level regression check following the repository's existing shell-test convention.
- Modify `Views/Folders/FoldersView.swift`: consume library-data invalidation and refresh the selected folder's local track snapshot.
- Modify `Views/Folders/FolderSidebarView.swift`: consume invalidation, rebuild counts/tree, restore path-based UI state, and always render an immediate track count.
- Modify `Managers/FolderHierarchyBuilder.swift`: retain empty filesystem directories in the hierarchy.

---

### Task 1: Refresh the Current Folder Track List

**Files:**
- Create: `Scripts/test-folder-tab-trash-refresh.sh`
- Modify: `Views/Folders/FoldersView.swift:15-23`

**Interfaces:**
- Consumes: `Notification.Name.libraryDataDidChange` and `handleFolderNodeSelection(_ node: FolderNode?)`.
- Produces: a `FoldersView` subscription that reloads `folderTracks` after committed library changes.

- [ ] **Step 1: Write the failing list-refresh regression check**

Create `Scripts/test-folder-tab-trash-refresh.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

folders_view="Views/Folders/FoldersView.swift"

if ! rg -U 'onReceive\(NotificationCenter\.default\.publisher\(for: \.libraryDataDidChange\)\) \{ _ in\n\s+handleFolderNodeSelection\(selectedFolderNode\)' "$folders_view" >/dev/null; then
    printf 'FoldersView must reload the selected folder after library data changes.\n' >&2
    exit 1
fi

printf 'Folder tab Trash refresh checks passed\n'
```

Make the check executable:

```bash
chmod +x Scripts/test-folder-tab-trash-refresh.sh
```

- [ ] **Step 2: Run the check and verify RED**

Run:

```bash
Scripts/test-folder-tab-trash-refresh.sh
```

Expected: exit 1 with `FoldersView must reload the selected folder after library data changes.`

- [ ] **Step 3: Add the minimal current-list invalidation handler**

In `Views/Folders/FoldersView.swift`, extend the modifier chain on `folderTracksView`:

```swift
folderTracksView
    .onChange(of: selectedFolderNode) { _, newNode in
        handleFolderNodeSelection(newNode)
    }
    .onReceive(NotificationCenter.default.publisher(for: .libraryDataDidChange)) { _ in
        handleFolderNodeSelection(selectedFolderNode)
    }
```

This deliberately calls the existing selection handler so both a real folder switch and a data invalidation share the same database-backed reload path.

- [ ] **Step 4: Run the check and verify GREEN**

Run:

```bash
Scripts/test-folder-tab-trash-refresh.sh
```

Expected: exit 0 with `Folder tab Trash refresh checks passed`.

- [ ] **Step 5: Commit the list refresh**

```bash
git add Scripts/test-folder-tab-trash-refresh.sh Views/Folders/FoldersView.swift
git commit -m "fix: refresh folder tracks after deletion"
```

---

### Task 2: Refresh Sidebar Counts and Preserve Empty-Folder State

**Files:**
- Modify: `Scripts/test-folder-tab-trash-refresh.sh`
- Modify: `Views/Folders/FolderSidebarView.swift:10-110,130-175`
- Modify: `Managers/FolderHierarchyBuilder.swift:40-58`

**Interfaces:**
- Consumes: `FolderHierarchyBuilder.buildHierarchy(for:trackCountsByFolder:)`, `FolderNode.url`, `FolderNode.children`, and `FolderNode.isExpanded`.
- Produces: `expandedNodePaths(in:) -> Set<String>`, `findNode(atPath:in:) -> FolderNode?`, and `restoreExpansion(in:expandedPaths:)` as private sidebar helpers.

- [ ] **Step 1: Extend the regression check with the sidebar requirements**

Insert these variables after `folders_view`:

```bash
folders_sidebar="Views/Folders/FolderSidebarView.swift"
hierarchy_builder="Managers/FolderHierarchyBuilder.swift"
```

Insert these checks before the final success message:

```bash
if ! rg -U 'onReceive\(NotificationCenter\.default\.publisher\(for: \.libraryDataDidChange\)\) \{ _ in\n\s+Task \{\n\s+await loadFolderHierarchy\(\)' "$folders_sidebar" >/dev/null; then
    printf 'FoldersSidebarView must rebuild after library data changes.\n' >&2
    exit 1
fi

if rg -F 'if childNode.immediateTrackCount > 0 || !childNode.children.isEmpty {' "$hierarchy_builder" >/dev/null; then
    printf 'Folder hierarchy must not discard empty subfolders.\n' >&2
    exit 1
fi

if ! rg -n '^[[:space:]]*subfolders\.append\(childNode\)$' "$hierarchy_builder" >/dev/null; then
    printf 'Folder hierarchy must retain every visible filesystem subfolder.\n' >&2
    exit 1
fi

if ! rg -F 'private var subtitle: String {' "$folders_sidebar" >/dev/null ||
   ! rg -F 'return String(appLocalized: "\(trackCount) tracks")' "$folders_sidebar" >/dev/null; then
    printf 'Folder sidebar must render a track count, including zero, for every node.\n' >&2
    exit 1
fi

if ! rg -F 'selectedNode?.url.standardizedFileURL.path' "$folders_sidebar" >/dev/null ||
   ! rg -F 'expandedNodePaths(in: folderNodes)' "$folders_sidebar" >/dev/null ||
   ! rg -F 'restoreExpansion(in: nodes, expandedPaths: expandedPaths)' "$folders_sidebar" >/dev/null ||
   ! rg -F 'findNode(atPath: selectedPath, in: nodes)' "$folders_sidebar" >/dev/null; then
    printf 'Folder hierarchy refresh must restore selection and expansion by path.\n' >&2
    exit 1
fi
```

- [ ] **Step 2: Run the expanded check and verify RED**

Run:

```bash
Scripts/test-folder-tab-trash-refresh.sh
```

Expected: exit 1 with `FoldersSidebarView must rebuild after library data changes.`

- [ ] **Step 3: Retain empty subfolders in the hierarchy**

In `Managers/FolderHierarchyBuilder.swift`, replace the conditional child insertion:

```swift
// Recursively build its subtree
await buildSubtree(for: childNode, tracksByFolder: tracksByFolder)

subfolders.append(childNode)
```

Do not change the existing `.skipsHiddenFiles` option or directory error logging.

- [ ] **Step 4: Subscribe the sidebar to committed library changes**

In `Views/Folders/FolderSidebarView.swift`, add this modifier after the existing `libraryManager.folders` change handler:

```swift
.onReceive(NotificationCenter.default.publisher(for: .libraryDataDidChange)) { _ in
    Task {
        await loadFolderHierarchy()
    }
}
```

- [ ] **Step 5: Capture and restore hierarchy state by standardized path**

Replace `loadFolderHierarchy()` with:

```swift
private func loadFolderHierarchy() async {
    let selectedPath = await MainActor.run {
        selectedNode?.url.standardizedFileURL.path
    }
    let expandedPaths = await MainActor.run {
        expandedNodePaths(in: folderNodes)
    }

    await MainActor.run {
        isLoadingHierarchy = true
    }

    let trackCounts = libraryManager.getTrackCountsByFolderPath()
    let nodes = await hierarchyBuilder.buildHierarchy(
        for: libraryManager.folders,
        trackCountsByFolder: trackCounts
    )

    await MainActor.run {
        restoreExpansion(in: nodes, expandedPaths: expandedPaths)
        folderNodes = nodes
        isLoadingHierarchy = false

        if let selectedPath,
           let restoredNode = findNode(atPath: selectedPath, in: nodes) {
            selectedNode = restoredNode
        } else {
            selectedNode = nodes.first
        }
    }
}
```

Add the three private recursive helpers below it:

```swift
private func expandedNodePaths(in nodes: [FolderNode]) -> Set<String> {
    var paths: Set<String> = []
    for node in nodes {
        if node.isExpanded {
            paths.insert(node.url.standardizedFileURL.path)
        }
        paths.formUnion(expandedNodePaths(in: node.children))
    }
    return paths
}

private func findNode(atPath path: String, in nodes: [FolderNode]) -> FolderNode? {
    for node in nodes {
        if node.url.standardizedFileURL.path == path {
            return node
        }
        if let match = findNode(atPath: path, in: node.children) {
            return match
        }
    }
    return nil
}

private func restoreExpansion(in nodes: [FolderNode], expandedPaths: Set<String>) {
    for node in nodes {
        node.isExpanded = expandedPaths.contains(node.url.standardizedFileURL.path)
        restoreExpansion(in: node.children, expandedPaths: expandedPaths)
    }
}
```

- [ ] **Step 6: Always render the immediate track count**

Replace the optional `subtitle` calculation in `FolderNodeRow` with:

```swift
private var subtitle: String {
    let folderCount = node.immediateFolderCount
    let trackCount = node.displayTrackCount
    if folderCount > 0 {
        return String(appLocalized: "\(folderCount) folders, \(trackCount) tracks")
    }
    return String(appLocalized: "\(trackCount) tracks")
}
```

Replace the optional rendering block:

```swift
if let subtitle {
    Text(subtitle)
        .font(.system(size: 11))
        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
        .lineLimit(1)
}
```

with unconditional rendering:

```swift
Text(subtitle)
    .font(.system(size: 11))
    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
    .lineLimit(1)
```

- [ ] **Step 7: Run focused and related checks**

Run:

```bash
Scripts/test-folder-tab-trash-refresh.sh
Scripts/test-track-trash-order.sh
Scripts/test-track-trash-sidecars.sh
Scripts/test-localization-format-specifiers.sh
git diff --check
```

Expected: all scripts print their success messages, `git diff --check` prints nothing, and every command exits 0.

- [ ] **Step 8: Build the application**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: exit 0 with `** BUILD SUCCEEDED **` and no new warnings from the modified files.

- [ ] **Step 9: Commit the sidebar refresh**

```bash
git add Scripts/test-folder-tab-trash-refresh.sh Views/Folders/FolderSidebarView.swift Managers/FolderHierarchyBuilder.swift
git commit -m "fix: refresh folder sidebar after deletion"
```
