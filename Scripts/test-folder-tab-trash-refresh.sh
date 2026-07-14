#!/usr/bin/env bash
set -euo pipefail

folders_view="Views/Folders/FoldersView.swift"

if ! rg -U 'onReceive\(NotificationCenter\.default\.publisher\(for: \.libraryDataDidChange\)\) \{ _ in\n\s+handleFolderNodeSelection\(selectedFolderNode\)' "$folders_view" >/dev/null; then
    printf 'FoldersView must reload the selected folder after library data changes.\n' >&2
    exit 1
fi

printf 'Folder tab Trash refresh checks passed\n'
