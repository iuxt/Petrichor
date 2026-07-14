# Folder Sidebar Refresh Without Flicker Design

## Problem

The Folders sidebar rebuilds its hierarchy after `.libraryDataDidChange`. Every rebuild sets `isLoadingHierarchy` to `true`, and the view responds by replacing the entire folder tree with `loadingView`. When the asynchronous scan finishes, the tree is inserted again. This makes a successful track deletion look as though the sidebar disappears and reappears even though existing hierarchy data is still valid enough to display during the refresh.

## Desired Behavior

- The existing folder tree remains visible while a library-data refresh is in progress.
- No refresh indicator replaces or overlays an already loaded tree.
- Updated folder counts and hierarchy appear together after the background rebuild completes.
- Selection and expanded branches remain stable across the refresh.
- The initial hierarchy load may continue to show the existing loading view because there is no previous tree to preserve.
- Empty folders remain visible and continue to show `0 tracks`.

## Design

### Loading-State Policy

`FoldersSidebarView.loadFolderHierarchy()` will only enable the full-sidebar loading state when `folderNodes` is empty. Once a hierarchy is visible, subsequent refreshes keep `isLoadingHierarchy` false, leaving the current `ScrollView` mounted throughout the asynchronous rebuild.

This is intentionally a presentation-state change rather than a new hierarchy architecture. The existing tree remains the temporary visible snapshot until the replacement hierarchy is ready.

### Refresh Data Flow

The `.libraryDataDidChange` subscription continues to start `loadFolderHierarchy()`. At the beginning of the load, the view captures the current selected path and expanded paths and increments `hierarchyLoadGeneration`. It then rebuilds the hierarchy and counts in the background without clearing `folderNodes`.

When the latest rebuild finishes, the view restores expansion state on the new nodes and assigns the completed hierarchy in one main-actor update. It then restores selection by filesystem path. The existing generation guard continues to discard stale asynchronous results, so rapid or batch deletions cannot roll the sidebar back to an older count.

The replacement is not explicitly animated. Users see the old hierarchy continuously, followed by the updated counts and structure, without an intermediate empty or loading screen.

### Empty and Initial States

On the first load, `folderNodes` is empty, so the existing `loadingView` remains appropriate. When loading completes, the sidebar shows either the hierarchy or the existing empty state.

If no hierarchy is currently available during a later refresh, the loading view may appear because there is no old content to retain. This does not affect the requested behavior for an already visible folder list.

## Testing

Extend `Scripts/test-folder-tab-trash-refresh.sh` before changing production code. The regression check will require hierarchy loading to derive its visible loading state from whether an existing tree is present, and it will reject the previous unconditional `isLoadingHierarchy = true` behavior.

After the focused check demonstrates the regression and then passes with the implementation, run the existing track-trash checks, localization format-specifier check, `git diff --check`, and a Debug build with code signing disabled.

## Scope

This change only adjusts the Folders sidebar loading presentation during hierarchy refresh. It does not change Trash behavior, database updates, filesystem scanning rules, folder identity, or the existing selection, expansion, empty-folder, and stale-refresh protections.
