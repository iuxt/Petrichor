# Artist List Table Design

## Goal

Show the Home sidebar's Artists category as a multi-column table list, matching the presentation of the Songs (All Tracks) page, instead of the current artwork grid.

## Current Context

- `HomeView.artistsView` renders artists through `EntityView` → `EntityGridView`: large artwork cards in an adaptive `LazyVGrid`, single click opens `EntityDetailView`.
- `HomeView.tracksView` renders songs through `TrackView` → `TrackTableView`: a SwiftUI `Table` with sortable column headers, row selection, and a double-click primary action.
- The artists header currently shows a dedicated ascending/descending toggle button; the tracks header has no such button (sorting lives in column headers).

## Recommended Approach

Add a dedicated `ArtistTableView` in `Views/Components/EntityTableView.swift` and use it from `artistsView` in place of `EntityView`.

- `Table` with two columns: Artist (`\.name`) and Songs (`\.trackCount`).
- Sorting goes through a `sortOrder: [KeyPathComparator<ArtistEntity>]` binding with a localized string comparator (`localizedCaseInsensitiveCompare`), preserving current sort behavior for Chinese and other locales.
- Row styling follows `TrackTableView`: 13pt fonts, `monospacedDigit` for the count column, hidden scroll background.
- Single click selects; double click (`contextMenu(forSelectionType:primaryAction:)`) opens the artist detail overlay. Right-click menu items stay `libraryManager.contextMenuItems(for:)`.
- The grid remains for albums; `EntityView`/`EntityGridView` and their caches are untouched.

Alternatives considered:

- A compact single-column row list (avatar + name + count). Rejected: the user explicitly chose the multi-column table to match the Songs page.
- A generic `EntityTableView` shared with albums. Deferred: `Table` columns are declared statically per entity type, and albums keep the grid (YAGNI).

## HomeView Changes

- Replace `EntityView` with `ArtistTableView` in `artistsView`.
- Header keeps the title and track count; remove the ascending/descending toggle button (column headers now control sort order, same as the Songs page).
- Replace `sortedArtistEntities`/`sortArtistEntities()` state with a `@State artistSortOrder` binding owned by the table; re-sort when the entity cache updates (`onReceive(libraryManager.$cachedArtistEntities)`).
- Persist the sort field/direction to UserDefaults under `artistTableSortOrder` in the same `{key, ascending}` dictionary shape `TrackTableView` uses, restored on appear. `entitySortAscending` remains for the albums page only.

## UI Behavior

- Artist rows show the localized display name and the track count; no artwork in rows.
- Clicking the Artist or Songs header sorts by that column and toggles direction on repeat click, with the standard header indicator.
- Double click opens `EntityDetailView` as a full overlay, unchanged; going back returns to the table with selection intact.
- Empty library keeps showing `NoMusicEmptyStateView`.

## Data Flow and Error Handling

No data-model or database changes. `libraryManager.artistEntities` remains the source; the view sorts it locally. Empty artist lists render the existing empty state.

## Testing and Verification

Add `Scripts/test-artist-list-table.sh` source checks verifying:

- `artistsView` uses `ArtistTableView` (not `EntityView`).
- The artist table declares Artist/Songs columns with a localized comparator and a double-click primary action.
- The header's ascending/descending toggle is gone.

Run the new check and build the Petrichor scheme with `CODE_SIGNING_ALLOWED=NO` (no signing certificate on this machine).

## Out of Scope

- Changing the albums page presentation.
- Adding artist avatars to table rows, row-size options, or a column-customization dropdown for this table.
- Changing `EntityDetailView`, context menus, or entity data models.
