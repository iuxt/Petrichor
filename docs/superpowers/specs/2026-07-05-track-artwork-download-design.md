# Track Artwork Download Design

## Goal

Add an opt-in automatic track artwork downloader that behaves like online lyrics:
Petrichor first uses local artwork sources, and only downloads artwork when no
local artwork is available. Downloaded artwork is saved as a sidecar image beside
the audio file and is then resolved through the existing artwork cache.

The feature must not write to audio files, must not store artwork blobs in
SQLite, and must not start a full-library network pass.

## User Control

The setting lives in `Settings > Integrations > Lyrics & Metadata`, next to the
existing online lyrics toggle. It uses a new `trackArtworkDownloadEnabled`
preference and is disabled by default.

Suggested user-facing copy:

- Toggle: `Fetch artwork from internet when unavailable`
- Help: `Automatically search for cover artwork online when no local artwork is found`

The strings must be added to `Resources/Localizable.xcstrings`.

## Recommended Architecture

Introduce a focused `TrackArtworkDownloadManager` that owns online discovery,
download, rate limiting, image validation, and sidecar writes. It does not update
database rows, mutate audio files, or talk directly to SwiftUI.

Keep `ArtworkResolver` as the single artwork orchestration boundary. All current
UI and playback callers already request artwork through it, so this keeps the
feature lazy and consistent across now playing, track tables, album grids, detail
views, mini player, immersive mode, and playlist-derived artwork.

`ArtworkResolver` should resolve sources in this order:

1. Embedded artwork from the audio file.
2. Same-stem sidecar artwork beside the audio file, such as `Song.jpg`.
3. Generic folder artwork using the existing `ExternalArtworkResolver` rules,
   such as `cover.jpg`, `folder.png`, `album.bmp`, `artwork.jpg`, and `front.jpg`.
4. Online artwork, only when the new setting is enabled.
5. Existing placeholder behavior.

This intentionally changes the runtime resolver to match the requested product
order. It also aligns playback-time behavior with metadata readers, which already
prefer embedded artwork over external artwork during scan extraction.

## Lazy Loading

The downloader is lazy. It runs only when a caller asks `ArtworkResolver` for a
track or album artwork request and every local source is missing.

There is no background pass when the setting is enabled and no full-library pass
after library refresh. This avoids sending large batches of track metadata to
online services and prevents browsing a large grid from creating uncontrolled
network work.

Each resolver request may trigger at most one online lookup for its request
identity. The downloader must not prefetch neighboring tracks, whole albums, or
other visible rows. Broad views can still cause several lazy requests as the user
scrolls, but those requests are serialized and rate-limited.

Album artwork requests use the request's representative track URL. A successful
download writes sidecar artwork for that representative audio file only. Other
tracks from the same album are not backfilled until they are individually
requested and found to be missing local artwork.

## Online Source

Use MusicBrainz and Cover Art Archive:

1. If the track has a MusicBrainz release ID in extended metadata, request Cover
   Art Archive front artwork for that release.
2. If the track has a MusicBrainz release group ID, request Cover Art Archive
   front artwork for that release group.
3. If no usable MBID exists, search MusicBrainz releases with valid artist,
   album, and title metadata.
4. For a selected release or release group, download the front thumbnail,
   preferring the 500px variant.

Unknown placeholders such as `Unknown Artist` and `Unknown Album` are not valid
for online lookup. If there is not enough metadata to make a reasonably specific
query, the downloader returns nil without making a network request.

## Sidecar Storage

Downloaded artwork is written beside the audio file as:

`audioURL.deletingPathExtension().appendingPathExtension("jpg")`

Rules:

- Never overwrite an existing same-stem artwork file.
- Do not write generic folder artwork such as `cover.jpg`.
- Do not write into the database.
- Do not write or retag the audio file.
- Convert the downloaded image to JPEG before writing.
- Keep existing maximum size and pixel-dimension guards from `AlbumArtFormat`
  and `ImageUtils`.

After a successful write, `ArtworkResolver` reads the written sidecar, compresses
it through the existing image pipeline, stores it in `ArtworkFileCache`, and
returns it to the requesting caller. Future requests then use the local sidecar
and cache instead of re-downloading.

## Caching And Concurrency

The existing `ArtworkFileCache` remains the cache for display-ready images. The
sidecar file is the persistent user-visible source, while the cache is only the
bounded derived display cache.

Add single-flight behavior inside `TrackArtworkDownloadManager` or
`ArtworkResolver` so concurrent requests for the same audio URL or album
representative do not create duplicate network requests or race to write the same
sidecar file.

Negative results do not need durable storage in this design. A failed lookup may
be retried on a later lazy request. In-memory suppression during a single app run
is acceptable if it is small and clearly bounded.

## Rate Limiting And Networking

All requests use `AppInfo.urlSession` and set `AppInfo.userAgent`.

MusicBrainz requests must be serialized to respect the public service guidance
of roughly one request per second per source IP. Cover Art Archive currently does
not publish equivalent strict per-client rules, but requests should still be
serialized or gently throttled because they are triggered from user browsing.

Expected HTTP handling:

- `200`: validate and decode image data.
- `307`: allow URLSession's normal redirect handling for Cover Art Archive
  image endpoints.
- `400`, `404`: no match; return nil.
- `503`: rate-limited or unavailable; return nil and log at low severity.
- Other failures: return nil and log enough context for diagnostics.

## Refresh And Notifications

The immediate requesting view gets the downloaded artwork from the resolver's
return value. To help other visible views refresh after a sidecar write, add a
notification such as `trackArtworkSidecarDidChange`, carrying the audio URL or a
small value object with the affected path.

Views that already load artwork through `AsyncArtworkImage` can either refresh
from this notification or rely on their current task completion if they initiated
the request. Playback state should update current-track artwork when the resolver
returns data for the current request.

The notification is not a database invalidation event. It only tells artwork UI
that a filesystem sidecar changed.

## Error Handling

Failures must not block playback or browsing.

- Setting disabled: do not make network requests.
- Missing or placeholder metadata: do not make network requests.
- No online match: return nil silently.
- Network error: log and return nil.
- Oversized or undecodable image: skip it and return nil.
- Existing sidecar appeared before write: do not overwrite; read the existing
  source through normal resolver logic on the next pass.
- Sidecar write failure, including sandbox or permission errors: log and return
  nil, without retry loops in the same request.
- Cache write failure: return the decoded artwork for the current request if
  possible, matching existing cache behavior.

## Privacy And File Safety

The feature is opt-in and disabled by default. It sends track metadata to online
services only when the user has enabled the setting and a visible or playback
surface actually asks for missing artwork.

The feature writes only same-stem `.jpg` sidecar files beside audio files. It
never modifies audio files, never renames user files, and never overwrites an
existing sidecar artwork file.

The downloader must not restore the removed database artwork blob paths and must
not add analytics or background collection.

## Non-Goals

- Full-library artwork download.
- Manual artwork editing UI.
- Writing embedded artwork into audio files.
- Reintroducing database-stored artwork blobs.
- Downloading artist images or biographies.
- Persisting remote image URLs in the database.
- A visible progress UI for artwork downloads.

## Testing

Add or update focused shell checks:

- `ArtworkResolver` keeps the requested source order:
  embedded artwork, same-stem sidecar artwork, generic folder artwork, online
  download, placeholder.
- `TrackArtworkDownloadManager` does not write database artwork and does not
  overwrite an existing same-stem image.
- Downloaded artwork is written as same-stem `.jpg` beside the audio file.
- Network code sets `AppInfo.userAgent` and uses the app URLSession.
- MusicBrainz requests are rate-limited or serialized.
- The settings UI exposes `trackArtworkDownloadEnabled` in
  `IntegrationsTabView`.
- Localized strings exist for the new setting and help text.

Run the narrow checks that cover affected behavior:

- `Scripts/test-external-artwork-priority.sh`
- `Scripts/test-artwork-resolver-priority.sh`
- `Scripts/test-ui-artwork-resolver.sh`
- `Scripts/test-localization-format-specifiers.sh`

When feasible, also run:

```sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

## Rollout

1. Add the settings preference and localized strings.
2. Add `TrackArtworkDownloadManager` with online lookup, sidecar writing,
   single-flight behavior, and rate limiting.
3. Adjust `ArtworkResolver` source order and call the downloader only after all
   local sources fail.
4. Add notification support for successful sidecar writes if current view refresh
   paths need it.
5. Add focused shell checks.
6. Run the targeted verification commands and, if practical, a Debug build.

## References

- MusicBrainz API rate limiting:
  `https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting`
- Cover Art Archive API:
  `https://musicbrainz.org/doc/Cover_Art_Archive/API`
