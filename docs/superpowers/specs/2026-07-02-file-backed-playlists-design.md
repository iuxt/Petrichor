# File-Backed Playlists Design

## Goal

Use `playlists/*.m3u` and `playlists/*.m3u8` under each added music folder as the final storage for user regular playlists. Remove the manual playlist import/export workflow. Keep the built-in `Top 25 Most Played` and `Top 25 Recently Played` smart playlists.

## Scope

Regular playlists become file-backed. They are discovered from music folders, displayed in the playlist sidebar, and edited by writing the corresponding M3U file. The local database no longer stores regular playlist records or `playlist_tracks` rows for these file-backed playlists.

The built-in smart playlists remain database-driven because they depend on play counts and last-played timestamps. The built-in `Favorites` smart playlist is removed from the playlist list, while the existing favorite track flag and favorite toggle behavior can remain as track metadata.

## Discovery

On startup, after adding folders, and after refreshing the library, the playlist manager scans every added music folder for direct children matching:

- `playlists/*.m3u`
- `playlists/*.m3u8`

Each discovered file becomes one regular playlist. The playlist name is the file name without extension. When multiple music folders contain files with the same display name, the app applies the existing unique-name behavior in memory so the sidebar can distinguish them without renaming files.

## M3U Parsing

The parser keeps the existing M3U behavior:

- ignore blank lines
- ignore comment and `#EXT*` metadata lines
- support UTF-8 with Latin-1 fallback
- support absolute paths, `file://` URLs, network-volume style paths, percent encoding, and Windows path separators

For relative paths, matching tries the music folder root first, then the M3U file's containing directory. This supports the target layout where `Music/playlists/Rock.m3u` contains paths relative to `Music`, while preserving compatibility with playlists whose entries are relative to the `playlists` folder.

Tracks that cannot be matched to the current library are omitted from the displayed playlist and logged as warnings. The file contents are not rewritten just because some tracks are missing.

## Editing

Regular playlist mutations write directly to M3U files:

- New playlist: create `playlists/<sanitized-name>.m3u` under the first added music folder.
- Rename playlist: rename the backing M3U file.
- Delete playlist: move the backing M3U file to Trash.
- Add track, including from any track context menu: append or rewrite the backing M3U file with the new track if it is not already present.
- Remove track: rewrite the backing M3U file without that track.
- Reorder tracks: rewrite the backing M3U file in the requested order.

New playlists use the first added music folder as the default storage root. A later settings option can expose this choice, but this design does not add that setting.

Writes use relative paths from the selected music folder root when possible, and absolute paths only for tracks outside that root. Rewriting preserves playlist order but does not preserve original comments or `#EXTINF` lines; generated files use the app's existing M3U output format.

## UI Changes

Remove user-visible import and export playlist commands from:

- the macOS menu
- the playlist sidebar options menu
- related notifications and sheets

Keep existing playlist creation, rename, delete, add-track, remove-track, context-menu add, and ordering affordances where they apply to file-backed regular playlists.

## Data Flow

1. `LibraryManager` loads or refreshes music folders.
2. `PlaylistManager` asks for current folders and scans each `<folder>/playlists`.
3. M3U files are parsed and resolved against the library database tracks.
4. `PlaylistManager.playlists` is rebuilt from built-in smart playlists plus discovered regular playlists.
5. Regular playlist edits call file-backed write operations and then refresh the affected playlist in memory.

## Error Handling

Unreadable M3U files are skipped and logged. Failed writes show an error notification and leave the in-memory playlist unchanged. If a backing file disappears before an edit, the app reloads file-backed playlists and reports the failure.

If there is no added music folder, creating a regular playlist is unavailable or reports an error. If the `playlists` directory does not exist under the default music folder, creating the first playlist creates it.

## Migration

Existing database regular playlists are no longer the active source for the playlist UI. The implementation may leave old rows in place for compatibility or clean them up in a migration, but runtime behavior must not depend on them.

Default smart playlist seeding changes to create only:

- `Top 25 Most Played`
- `Top 25 Recently Played`

For existing databases, a migration removes the built-in `Favorites` smart playlist record and its playlist pin. It must not alter track favorite flags.

## Testing

Add focused tests or scriptable checks for:

- discovering `playlists/*.m3u` under an added music folder
- resolving relative entries against the music folder root
- falling back to paths relative to the M3U file directory
- creating a playlist in the first added music folder
- adding and removing tracks by rewriting the M3U file
- keeping the two Top 25 smart playlists while removing the built-in Favorites playlist
- absence of import/export UI entry points
