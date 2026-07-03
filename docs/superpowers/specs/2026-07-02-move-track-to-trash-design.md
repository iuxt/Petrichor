# Move Track to Trash Design

## Goal

Add a destructive context-menu action for a track that moves the selected audio file to the macOS Trash after confirmation. When confirmed, the app also removes orphaned sidecar files and cleans up library database records.

## User Flow

The track context menu shows `Move to Trash...` with a destructive role. Choosing it opens an `NSAlert` that names the track and explains that the audio file will be moved to Trash. The alert also states that orphaned lyrics and cover artwork sidecars may be moved to Trash. Cancel leaves files and library data unchanged.

## File Rules

The action uses macOS Trash, not permanent deletion.

- Always trash the selected audio file.
- Trash same-basename external lyrics next to the audio file: `.lrc` and `.srt`.
- Trash known external album artwork files in the same directory only when, after removing the selected audio file, no other supported audio files remain in that directory.
- Skip missing sidecars without error.

## Library Cleanup

After file trash succeeds, delete the track row from the app database and run the existing orphan cleanup path. That removes stale playlist rows, FTS entries, extended metadata, album/artist/genre rows that are no longer referenced, and pinned items that now point to missing entities. Refresh in-memory library state and category/entity caches so the UI updates immediately.

## Error Handling

If the user cancels, do nothing. If the Trash operation fails, do not remove database records and show an error notification. If database cleanup fails after files were trashed, report the failure and trigger a library refresh so a later scan can reconcile state.

## Testing

Add a small executable regression script covering sidecar selection rules:

- Same-basename `.lrc` and `.srt` are included.
- Cover artwork is included only when the directory becomes empty of other audio tracks.
- Cover artwork is not included when another supported audio file remains.
