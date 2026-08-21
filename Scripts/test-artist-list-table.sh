#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOME_VIEW="$ROOT_DIR/Views/Home/HomeView.swift"
ENTITY_TABLE="$ROOT_DIR/Views/Components/EntityTableView.swift"

if [ ! -f "$ENTITY_TABLE" ]; then
    printf 'ArtistTableView source file must exist.\n' >&2
    exit 1
fi

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"

    if ! rg -n "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

reject_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"

    if rg -n "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

# Artists page renders through the multi-column artist table.
require_pattern "$HOME_VIEW" 'ArtistTableView\(' \
    'HomeView artists page must render ArtistTableView.'
require_pattern "$HOME_VIEW" 'sortOrder: \$artistSortOrder' \
    'ArtistTableView must receive the artist sort order binding.'

# Only the albums page keeps the entity grid (exactly one EntityView usage).
grid_count="$(rg -c 'EntityView\(' "$HOME_VIEW" || true)"
if [ "${grid_count:-0}" != "1" ]; then
    printf 'HomeView must use EntityView only for albums (expected 1 usage, found %s).\n' \
        "${grid_count:-0}" >&2
    exit 1
fi

# Header sort toggle is gone; sorting lives in table column headers.
reject_pattern "$HOME_VIEW" 'entitySortAscending\.toggle' \
    'Artists header must not keep the asc/desc toggle button.'
reject_pattern "$HOME_VIEW" 'func sortArtistEntities' \
    'sortArtistEntities is obsolete after the table owns sorting.'
reject_pattern "$HOME_VIEW" 'func sortEntities\(' \
    'sortEntities helper is obsolete after the table owns sorting.'

# Table structure: columns, localized sort, selection-driven interactions.
require_pattern "$ENTITY_TABLE" 'struct ArtistTableView: View' \
    'ArtistTableView view must exist.'
require_pattern "$ENTITY_TABLE" 'Table\(sortedArtists, selection: \$selection, sortOrder: \$sortOrder\)' \
    'Artist table must use Table with selection and sort order.'
require_pattern "$ENTITY_TABLE" 'TableColumn\("Artist", value: \.name\)' \
    'Artist table needs the Artist column.'
require_pattern "$ENTITY_TABLE" 'TableColumn\("Songs", value: \.trackCount\)' \
    'Artist table needs the Songs column.'
require_pattern "$ENTITY_TABLE" 'localizedCaseInsensitiveCompare' \
    'Artist sorting must stay locale-aware.'
require_pattern "$ENTITY_TABLE" 'contextMenu\(forSelectionType: ArtistEntity\.ID\.self\)' \
    'Artist table must support the selection context menu.'
require_pattern "$ENTITY_TABLE" 'primaryAction' \
    'Artist table must open detail via the double-click primary action.'
require_pattern "$ENTITY_TABLE" '"artistTableSortOrder"' \
    'Artist sort order must persist across launches.'

printf 'Artist list table checks passed.\n'
