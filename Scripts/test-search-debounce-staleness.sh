#!/usr/bin/env bash
set -euo pipefail

library_view="Views/Library/LibraryView.swift"
sidebar_view="Views/Library/LibrarySidebarView.swift"
content_view="Views/Main/ContentView.swift"

if ! rg -n 'globalSearchUpdateTask: Task<Void, Never>\?' "$library_view" >/dev/null; then
    printf 'LibraryView must retain and cancel the global-search debounce task.\n' >&2
    exit 1
fi

if ! rg -n 'globalSearchUpdateTask\?\.cancel\(\)' "$library_view" >/dev/null; then
    printf 'LibraryView global-search debounce task is not cancelled before scheduling a new one.\n' >&2
    exit 1
fi

if ! rg -n 'libraryManager\.globalSearchText == searchText' "$library_view" >/dev/null; then
    printf 'LibraryView must verify the debounced search text before applying filtered results.\n' >&2
    exit 1
fi

if ! rg -n 'guard libraryManager\.globalSearchText\.isEmpty,' "$library_view" >/dev/null; then
    printf 'LibraryView delayed non-search filter loads must not overwrite active search results.\n' >&2
    exit 1
fi

if ! rg -n 'globalSearchUpdateTask: Task<Void, Never>\?' "$sidebar_view" >/dev/null; then
    printf 'LibrarySidebarView must retain and cancel the global-search debounce task.\n' >&2
    exit 1
fi

if ! rg -n 'globalSearchUpdateTask\?\.cancel\(\)' "$sidebar_view" >/dev/null; then
    printf 'LibrarySidebarView global-search debounce task is not cancelled before scheduling a new one.\n' >&2
    exit 1
fi

if ! rg -n 'libraryManager\.globalSearchText == newValue' "$sidebar_view" >/dev/null; then
    printf 'LibrarySidebarView must verify the debounced search text before applying sidebar results.\n' >&2
    exit 1
fi

if ! rg -n 'handleGlobalSearchChange\(oldValue: String, newValue: String\)' "$content_view" >/dev/null; then
    printf 'ContentView must synchronize library search state when the toolbar search changes before LibraryView mounts.\n' >&2
    exit 1
fi

if ! rg -n 'oldValue\.isEmpty && !newValue\.isEmpty' "$content_view" >/dev/null; then
    printf 'ContentView must detect the first transition into global search mode.\n' >&2
    exit 1
fi

if ! rg -n 'libraryCachedTracks = libraryManager\.searchResults' "$content_view" >/dev/null; then
    printf 'ContentView must replace stale cached library rows with the first search results.\n' >&2
    exit 1
fi

if ! rg -n 'libraryFilterItem = LibraryFilterItem\.allItem' "$content_view" >/dev/null; then
    printf 'ContentView must select the search "All" item when entering global search before the sidebar mounts.\n' >&2
    exit 1
fi

printf 'Search debounce staleness checks passed\n'
