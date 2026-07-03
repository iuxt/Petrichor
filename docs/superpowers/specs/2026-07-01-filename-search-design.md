# Filename Search Design

## Context

Petrichor's library search currently uses the `tracks_fts` FTS5 table. The FTS table indexes track metadata fields such as title, artist, album, composer, genre, and year. The `tracks` table already stores a `filename` value for each track, but that value is not part of FTS, so searching by the original file name does not match tracks.

The requested behavior is that search should match the original file name without its extension. For a file named `01 - Intro.flac`, searches such as `01`, `Intro`, or `01 Intro` should be eligible to match, while `flac` should not match solely because it is the extension.

## Goals

- Global library search matches track metadata and the extensionless original file name.
- Playlist-add search uses the same filename matching behavior as global library search.
- Filename matching does not include file extensions.
- Existing libraries get the behavior after migration without requiring a manual rescan.
- New, updated, and deleted tracks keep the search index synchronized automatically.

## Non-Goals

- Do not add UI controls or a separate search mode for filename search.
- Do not change sorting or result ranking beyond FTS naturally considering the new indexed field.
- Do not match folder names or full file paths.
- Do not search the extension as part of the file name.

## Recommended Approach

Add an extensionless filename column to `tracks_fts`, named `filename_stem`, and keep it synchronized from the `tracks` table.

The stem should be derived from the original stored file name or path by removing only the last extension component. Examples:

| File name | Indexed `filename_stem` |
| --- | --- |
| `01 - Intro.flac` | `01 - Intro` |
| `song.demo.v2.mp3` | `song.demo.v2` |
| `README` | `README` |

This keeps search in the database layer, so every existing caller of `searchTracksUsingFTS` and `searchTracksForPlaylist` receives consistent behavior without UI-specific filtering.

## Data Flow

1. A track is inserted or updated in `tracks`.
2. The FTS trigger writes metadata fields plus `filename_stem` into `tracks_fts`.
3. Search methods build the existing FTS5 query and run it against `tracks_fts`.
4. Matching track IDs are loaded from `tracks` using the current lightweight fetch paths.

## Migration

Add a new migration after `v12_backfill_album_artists`.

The migration should:

- Drop the existing FTS triggers.
- Drop and recreate `tracks_fts` with the new `filename_stem` column.
- Recreate triggers so inserts and updates populate `filename_stem`.
- Backfill `tracks_fts` from current `tracks` rows.

Fresh database setup should create the new FTS table shape directly, so new installs do not need a rebuild.

## Implementation Notes

- Prefer a single helper for deriving the extensionless filename so setup, migration, and tests share one behavior.
- SQLite trigger expressions can derive the stem from `NEW.filename` by removing the last extension. If the SQL expression becomes too brittle, prefer a deterministic Swift-side backfill/helper for migrations and store `filename_stem` as a real column in `tracks`.
- Keep the current FTS tokenizer and `buildFTS5Query` behavior.
- Do not use in-memory fallback when FTS returns no results.

## Error Handling

Search methods should retain their current behavior:

- If the FTS query succeeds with no matches, return an empty result.
- If the FTS query throws, log the error and return an empty result.
- Migration failures should fail migration normally so the database is not silently left with an inconsistent search index.

## Testing And Verification

There is currently no XCTest target in the project. Verification should include:

- A focused test or helper-level validation for extensionless filename derivation.
- Build verification with `xcodebuild` where the local Xcode environment allows it.
- Code review checks for all FTS lifecycle paths: fresh setup, migration rebuild, insert trigger, update trigger, delete trigger, global search, and playlist-add search.

## Open Decisions

The user confirmed that file extensions should not be included in filename search.
