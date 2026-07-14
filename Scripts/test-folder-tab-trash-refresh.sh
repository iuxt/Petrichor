#!/usr/bin/env bash
set -euo pipefail

folders_view="Views/Folders/FoldersView.swift"
folders_sidebar="Views/Folders/FolderSidebarView.swift"
hierarchy_builder="Managers/FolderHierarchyBuilder.swift"

if ! rg -U 'onReceive\(NotificationCenter\.default\.publisher\(for: \.libraryDataDidChange\)\) \{ _ in\n\s+handleFolderNodeSelection\(selectedFolderNode\)' "$folders_view" >/dev/null; then
    printf 'FoldersView must reload the selected folder after library data changes.\n' >&2
    exit 1
fi

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

if ! rg -F '@State private var hierarchyLoadGeneration = 0' "$folders_sidebar" >/dev/null ||
   ! rg -F 'hierarchyLoadGeneration += 1' "$folders_sidebar" >/dev/null ||
   ! rg -F 'guard generation == hierarchyLoadGeneration else { return }' "$folders_sidebar" >/dev/null; then
    printf 'Folder hierarchy refresh must ignore stale asynchronous rebuilds.\n' >&2
    exit 1
fi

printf 'Folder tab Trash refresh checks passed\n'
