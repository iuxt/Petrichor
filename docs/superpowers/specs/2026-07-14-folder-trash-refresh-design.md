# Folder Track Trash Refresh Design

## Problem

After a track is moved to Trash from the Folders tab, the file and database row are removed, but the visible folder track list remains unchanged. The list is stored in `FoldersView.folderTracks` and is currently recomputed only when the selected folder node changes. The trash flow already posts `.libraryDataDidChange`, but the Folders tab does not consume that event.

The folder sidebar has the same missing invalidation path. Its hierarchy and per-folder track counts are rebuilt only when the configured library roots change, so deleting a track leaves the displayed count stale.

## Desired Behavior

- After a successful track deletion, the current folder track list refreshes immediately.
- Folder sidebar track counts refresh at the same time.
- The selected folder and expanded branches remain selected and expanded across the refresh.
- A subfolder remains visible after its last track is deleted and shows `0 tracks`.
- Failed or cancelled Trash operations do not change the list or counts because they do not publish a successful library-data change.

## Design

### Current Folder Track List

`FoldersView` will subscribe to `.libraryDataDidChange`, matching the existing invalidation pattern in `LibraryView`. When the event arrives, it will rerun the existing folder-node selection handler. That handler queries the database through `FolderNode.getImmediateTracks(using:)`, so the local `folderTracks` state receives the post-deletion result without introducing a second source of filtering logic.

### Folder Sidebar Hierarchy

`FoldersSidebarView` will subscribe to the same event and rebuild the hierarchy. Before replacing the nodes, it will capture the selected folder path and the paths of expanded nodes. After the rebuild it will find nodes by path, restore expansion, and bind the selection to the corresponding new node. Path identity is used because every hierarchy rebuild creates new `FolderNode` UUIDs.

`FolderHierarchyBuilder` will retain filesystem subdirectories even when they contain no supported audio files. This makes an emptied folder stable across hierarchy rebuilds, tab changes, and app launches. Hidden folders remain excluded through the existing `.skipsHiddenFiles` enumeration option.

The sidebar subtitle will always include the immediate track count. A leaf with no tracks displays `0 tracks`; a folder with children displays both its immediate child-folder count and track count, including zero.

### Concurrency and Error Handling

Hierarchy construction remains asynchronous and uses the existing loading state. Database changes are committed before `.libraryDataDidChange` is posted, so both refresh consumers read committed data. If a directory cannot be enumerated, the existing logging behavior remains in place and the rebuild continues with the data available for other roots.

## Testing

Add a focused shell regression check following the repository's existing script-test style. It will verify that:

- `FoldersView` consumes `.libraryDataDidChange` and reloads the selected folder.
- `FoldersSidebarView` consumes `.libraryDataDidChange` and rebuilds its hierarchy.
- the hierarchy builder no longer filters out empty subfolders;
- the sidebar renders a zero track count;
- hierarchy refresh logic restores selection and expansion by folder path.

Run the focused regression check, the existing track-trash checks, and a Debug build.

## Scope

This change does not alter Trash/file operations, database cleanup, playlist storage, or audio-file contents. It only connects the existing successful library-change event to the Folders tab and adjusts folder-tree presentation so empty directories remain visible.
