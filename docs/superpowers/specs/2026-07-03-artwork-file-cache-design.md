# Artwork File Cache Design

## Goal

Move artwork image storage out of SQLite while preserving album and track artwork display performance. Artwork should be resolved from source files and stored only in a bounded file cache. The artist artwork feature will be removed because the current implementation stores album artwork as artist imagery, which is misleading and increases database size.

## Current State

Petrichor stores compressed artwork blobs in SQLite:

- `albums.artwork_data` for album artwork.
- `artists.artwork_data` for artist artwork.
- `tracks.track_artwork_data` for tracks without album artwork.
- `playlists.cover_artwork_data` for playlist covers.

The local database inspection showed most database space is artwork blob data: album artwork is about 78 MB, artist artwork about 43 MB, and track artwork about 7 MB. The existing metadata scan already supports external artwork files beside audio files, including same-stem artwork and generic names such as cover or folder artwork. Scan code currently resolves those sources, compresses them, and then persists the result in SQLite.

## Non-Goals

- Do not remove album or track artwork display.
- Do not store original artwork files in the cache.
- Do not add online artwork download or external artist image fetching.
- Do not keep artist artwork as a separate feature.
- Do not migrate user audio files or sidecar artwork files.

## Recommended Approach

Use a bounded file cache for resolved artwork thumbnails:

1. Resolve artwork from source files on demand.
2. Compress the artwork to the app's display/cache format.
3. Store the compressed image in `Application Support/org.Petrichor/ArtworkCache/`.
4. Track cache freshness through deterministic keys derived from source identity and source file metadata.
5. Enforce a maximum cache size with least-recently-used cleanup.

SQLite keeps metadata and relationships only. It no longer stores artwork image bytes for albums, artists, tracks, or generated playlist covers.

## Artwork Resolution

Introduce an artwork resolving boundary, tentatively `ArtworkResolver`, that callers use instead of reading image blobs from database rows.

For track and album artwork, the resolver uses this priority:

1. Same-stem external artwork file in the audio file's directory.
2. Generic external artwork in the same directory, using the existing `AlbumArtFormat.knownFilenames` priority.
3. Embedded artwork from the audio file.
4. Generated placeholder artwork.

For album views, the resolver uses a representative track for the album. The representative track should be stable and cheap to query, such as the first non-duplicate track ordered by disc number, track number, then filename.

For now playing views, the resolver uses the currently playing track directly.

For playlists, generated collage artwork may continue to be derived from member track artwork through the resolver. This change does not add or preserve persistent custom playlist cover storage in SQLite.

## Artist Artwork Removal

Artist entities no longer have artwork loaded from the database or resolved as a separate image type.

UI behavior:

- Artist grids and artist detail headers should use generated placeholders or text-forward layouts.
- Artist detail pages continue to show the artist's tracks and albums.
- No UI should imply that a representative album cover is an artist portrait.

Code behavior:

- Stop writing `Artist.artworkData`.
- Stop querying artist artwork for category/entity views.
- Remove merge carry-over logic for artist artwork.
- Remove background artwork optimization for artists.
- Remove artist artwork update APIs.

Database behavior:

- Add a migration that clears existing artist artwork blobs.
- Existing artist image metadata fields can remain only if they are still used for non-image metadata. If they are only tied to removed artist artwork behavior, disconnect them from runtime behavior.

## Cache Keys and Freshness

Cache keys must prevent stale artwork after files change. A cache key should include:

- Artwork kind: `track`, `album`, or `playlist-derived`.
- Stable entity identifier: track path for track artwork, album id plus representative track path for album artwork, playlist id plus track identifiers for derived playlist artwork.
- Source file path.
- Source file size.
- Source file modification timestamp.
- Cache version.

When the same audio file switches from embedded artwork to a newer external artwork file, the source path and metadata change, producing a new cache key. Old cache files become unreachable and are removed by cleanup.

## Cache Storage

Cache files live under:

`Application Support/<bundle id>/ArtworkCache/`

Recommended layout:

- `ArtworkCache/images/<hash>.heic` or the current compressed output format.
- Optional `ArtworkCache/metadata.json` only if filesystem metadata is insufficient for cleanup.

The cache should use file access time where available, or explicitly touch files when they are read. If relying on access time is unreliable on macOS volumes, maintain a compact sidecar index with path, byte size, and last access timestamp.

## Cache Limits and Cleanup

Default cache limit: 512 MB.

Cleanup rules:

- Run opportunistically after writes.
- If total size exceeds the limit, delete least-recently-used cache files until the cache is below 90% of the limit.
- Ignore unknown files outside the expected cache images directory.
- Provide a clear-cache operation that removes all artwork cache files.
- Provide a trim-cache operation that enforces the current limit immediately.

Settings integration:

- Add controls for clearing artwork cache and trimming/optimizing it.
- The cache limit is fixed at 512 MB for this implementation.

## Database Migration

Add a migration that clears existing artwork blob data from SQLite. This implementation keeps the existing columns empty rather than rebuilding tables to drop columns, reducing schema migration risk while still removing stored image bytes.

Required effects:

- Clear `albums.artwork_data`.
- Clear `artists.artwork_data`.
- Clear `tracks.track_artwork_data`.
- Clear `playlists.cover_artwork_data`.
- Stop runtime writes to those columns.
- Run `VACUUM` through the existing database maintenance path after destructive blob cleanup, or prompt/perform a maintenance operation so disk space is reclaimed.

## Data Flow

1. Library query returns track, album, and artist metadata without artwork blobs.
2. UI requests artwork asynchronously through `ArtworkResolver`.
3. Resolver checks the file cache by deterministic key.
4. On hit, resolver loads the cached image data and updates access metadata.
5. On miss, resolver reads external artwork or embedded artwork, compresses it, writes it to cache, trims cache if needed, and returns the data.
6. UI falls back to placeholders when resolution fails or is still loading.

## Error Handling

- Missing source file: return placeholder and do not write cache.
- Corrupt sidecar image: skip it and try the next source.
- Corrupt embedded artwork: return placeholder if no other source works.
- Cache write failure: log the failure and return the decoded artwork in memory for the current request.
- Cache cleanup failure: log and continue; do not block playback or browsing.

## Performance

The resolver should avoid unbounded concurrent audio metadata reads. Use a small operation queue or actor to deduplicate simultaneous requests for the same cache key.

List and grid views should request artwork lazily and cancel work when rows disappear. Existing view-level image rendering queues can be reused or adapted.

## Testing

Add focused tests or scripts for:

- External same-stem artwork beats generic directory artwork.
- Generic directory artwork beats embedded artwork when no same-stem artwork exists.
- Embedded artwork is used when there is no external artwork.
- Cache hit avoids re-reading source artwork.
- Cache key changes when source file modification date or size changes.
- Cache trim removes oldest files and keeps cache below the target threshold.
- Database migration removes existing artwork blob storage.
- Artist views no longer query or display artist artwork.

## Rollout

Implement in stages:

1. Add file cache manager and resolver.
2. Move album/track artwork display to resolver.
3. Remove artist artwork display and write paths.
4. Add migration to clear artwork blobs.
5. Add settings maintenance actions.
6. Verify database size can be reclaimed after migration and vacuum.
