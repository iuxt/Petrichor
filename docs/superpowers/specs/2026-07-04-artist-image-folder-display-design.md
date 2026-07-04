# Artist Image Folder Display Design

Date: 2026-07-04

## Context

Petrichor recently removed database-backed artist artwork and added an opt-in artist image downloader. The current downloader saves downloaded artist images next to songs as `<artist>.jpg`. The next iteration should use a fixed per-library-root folder instead and make those images visible in the Home artist UI.

The user requirements are:

- The Home artist page must read and display artist avatars.
- Any UI path backed by `ArtistEntity` should try to show an artist avatar.
- Downloaded artist images must be stored under each music root folder's `artist images` directory.
- The Settings toggle for artist image downloading must support English and Simplified Chinese localization.
- Artist images must remain outside the database.

## Storage Model

Introduce a file-backed artist image component named `ArtistImageStore`, responsible for all local artist image paths.

For each configured music folder root:

```text
<music root>/artist images/<safe artist name>.jpg
```

The store will:

- Resolve an artist image directory for a music root.
- Sanitize artist names into safe filenames using the same rules for read and write.
- Check for existing images with supported artwork extensions, prioritizing `.jpg` but accepting `.jpeg`, `.png`, `.tiff`, `.tif`, and `.bmp` so user-supplied images work.
- Return image data for an artist by inspecting the music roots that contain that artist's tracks.

The store will not persist image data or image paths into SQLite.

## Download Flow

`ArtistImageDownloadManager` keeps the existing network source chain:

1. MusicBrainz artist search.
2. MusicBrainz URL relationships.
3. Wikidata P18 image claim.
4. Wikimedia Commons thumbnail download.

Only the destination model changes:

- The `artistImageDownloadEnabled` preference remains opt-in and defaults to off.
- When enabled, library load triggers a background artist image pass.
- Tracks are grouped by configured music root instead of by individual song directory.
- For each root, the downloader creates or reuses `<root>/artist images/`.
- For each artist present under that root, the downloader skips work if `<root>/artist images/<safe artist name>.*` already exists.
- Missing images are downloaded once per artist/root pair and written as `<safe artist name>.jpg`.
- Directory creation or file writing failures are logged and do not block library loading.

If the same artist appears under multiple music roots, each root may contain its own copy in its own `artist images` directory.

## Display Flow

The UI should not load artist images through `ArtistEntity.artworkData`. That property can keep serving the current generated initials artwork fallback.

Instead:

- `EntityGridView` detects `ArtistEntity` and asynchronously asks `ArtistImageStore` for image data.
- `EntityDetailView` does the same for the 120x120 header artwork area.
- Any `ArtistEntity` consumer benefits, including regular Artists and pinned album artists or composers that are represented as `ArtistEntity`.
- If no file image is found, the current initials placeholder remains.
- When the detail view loads a file-backed artist image, that image can feed the existing gradient color calculation.

This keeps artist avatar file IO in UI-facing async loaders and avoids putting image bytes back into entity models or database rows.

## Localization

The Settings toggle label will be changed from the current hard-coded English string to a localized string:

- English: `Download artist images to music folders`
- Simplified Chinese: `下载艺人图片到音乐文件夹`

The help text will also be localized and mention that images are saved under each music folder's `artist images` directory.

The setting remains in the existing `Lyrics & Metadata` section, next to the online lyrics toggle.

## Error Handling

- Missing `artist images` folders are created only when downloading is enabled and a root needs downloads.
- Read failures in the UI fall back to initials without user-visible errors.
- Unsupported or oversized images are ignored using existing artwork size constraints.
- Network failures remain best-effort and logged.
- All image reads, writes, and network calls stay off the main thread.

## Testing

Add or update focused shell checks to cover:

- The artist image downloader writes to an `artist images` directory under music roots, not directly beside each song.
- UI code for `ArtistEntity` uses the file-backed artist image store.
- The Settings label and help text are present in `Localizable.xcstrings` with Simplified Chinese translations.
- Artist image code does not write artwork blobs to database fields.

Run:

```sh
bash Scripts/test-artist-image-sidecar-download.sh
bash Scripts/test-localization-format-specifiers.sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The full `Scripts/test-*.sh` sweep should also pass before merging.
