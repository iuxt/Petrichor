#!/usr/bin/env bash
set -euo pipefail

library_view="Views/Library/LibraryView.swift"
sidebar_view="Views/Library/LibrarySidebarView.swift"

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

printf 'Search debounce staleness checks passed\n'
