# Remove Online Music Services Design

## Goal

Remove Petrichor's runtime online music-service features completely:

- Last.fm authentication, scrobbling, and avatar fetching.
- Online lyrics lookup through LRCLIB.
- Online track artwork lookup through MusicBrainz and Cover Art Archive.
- Online artist image lookup through MusicBrainz, Wikidata, and Wikimedia.

This is a hard removal, not a UI-only hide. After implementation, production
runtime code should no longer upload listening activity, download lyrics,
download cover artwork, download artist images, expose settings for those
features, or keep unused service credentials and diagnostic fields.

## Current Context

The online-service code is split across four focused managers:

- `Managers/ScrobbleManager.swift`
- `Managers/LyricsManager.swift`
- `Managers/TrackArtworkDownloadManager.swift`
- `Managers/ArtistImageDownloadManager.swift`

The settings UI exposes all of these features through
`Views/Settings/IntegrationsTabView.swift`. The tab currently contains only
Last.fm and online metadata controls.

Runtime hooks exist in playback, lyrics loading, artwork resolution, and library
loading:

- `PlaybackManager` calls the scrobble manager when tracks start and finish.
- `LyricsLoader` falls back to online lyrics after local and embedded lyrics.
- `ArtworkResolver` falls back to online artwork after embedded and local image
  sources.
- `LibraryManager` triggers an artist-image download pass after loading the
  library.

The repository also contains shell checks that currently assert some online
features exist. Those checks need to be removed or inverted so they guard the
new offline-only behavior.

## Recommended Approach

Use full runtime feature removal with focused cleanup.

This gives the clean final state requested by the user: no hidden settings, no
dead network managers, no Last.fm keychain state, and no runtime code paths that
can contact the removed services.

Alternatives considered:

- Hide settings and leave disabled no-op managers. This has lower compile risk
  but leaves the redundant code in place.
- Remove every external URL and project link. This is broader than the product
  goal and would risk deleting dependency metadata, acknowledgements, or project
  links that are not runtime music-service features.

The implementation should remove only runtime online music services and their
direct residue. It should not attempt to make the repository completely free of
external URLs.

## Runtime Behavior After Removal

Petrichor remains a local offline music player.

Lyrics resolve in this order:

1. Same-stem local `.lrc` or `.srt` file beside the audio file.
2. Embedded lyrics already stored in extended metadata.
3. Empty lyrics when no local or embedded source exists.

Artwork resolves in this order:

1. Embedded artwork extracted from the audio file.
2. Same-stem local artwork beside the audio file, such as `Song.jpg`.
3. Generic local folder artwork using existing `ExternalArtworkResolver` rules,
   such as `cover.jpg`, `folder.png`, `album.bmp`, `artwork.jpg`, and
   `front.jpg`.
4. Existing placeholder behavior when no local source exists.

Artist images continue to display from existing local `artist images` folders
through `ArtistImageStore`. The app no longer creates or updates those files by
downloading images.

Playback continues to update local play count and last-played metadata. It no
longer sends "now playing" or scrobble requests to Last.fm.

## Removal Scope

Delete these runtime managers if no remaining local behavior depends on them:

- `ScrobbleManager`
- `LyricsManager`
- `TrackArtworkDownloadManager`
- `ArtistImageDownloadManager`

Remove their runtime call sites:

- `AppCoordinator` no longer owns or initializes `ScrobbleManager`.
- `PlaybackManager` no longer calls `trackStarted` or `trackFinished` on a
  scrobble manager.
- `LyricsLoader` no longer calls `LyricsManager.shared.fetchLyrics`.
- `ArtworkResolver` no longer calls
  `TrackArtworkDownloadManager.shared.downloadArtwork`.
- `LibraryManager` no longer calls
  `ArtistImageDownloadManager.shared.downloadMissingArtistImages`.
- `IntegrationsTabView` and the `Integrations` settings tab are removed because
  the tab has no remaining offline controls.
- `URLSchemeHandler` no longer handles `lastfm-callback`. Because the current
  callback scheme exists for Last.fm authentication, remove the handler if it has
  no remaining cases and remove the `petrichor` callback registration from
  `Configuration/Info.plist`.

Keep these local/offline capabilities:

- Local `.lrc` and `.srt` lyrics loading.
- Desktop lyrics rendering and line selection.
- Embedded lyrics.
- Embedded artwork extraction.
- Same-stem and generic local artwork resolution.
- Artwork file cache.
- Local artist image display from `ArtistImageStore`.
- MusicBrainz IDs and other metadata fields read from audio files.

## Settings, Preferences, And Configuration

Remove the `Integrations` settings tab from `SettingsView.SettingsTab` and from
the tab switch.

Remove online-service preferences from settings and diagnostics:

- `lastfmUsername`
- `lastfmAvatarData`
- `scrobblingEnabled`
- `onlineLyricsEnabled`
- `trackArtworkDownloadEnabled`
- `artistImageDownloadEnabled`

No migration is required for historical `UserDefaults` values. Once production
code stops reading them, stale preference values are harmless.

Remove Last.fm keychain state:

- Delete `KeychainManager.Keys.lastfmSessionKey`.
- Remove callers that delete or read that key.
- If `KeychainManager` has no remaining production users after this removal,
  delete `Utilities/KeychainManager.swift`.

Remove service credential configuration:

- `LASTFM_API_KEY`
- `LASTFM_SHARED_SECRET`
- `TMDB_READ_ACCESS_TOKEN`

These should be removed from `Configuration/Info.plist` and
`Configuration/Secrets.xcconfig.template` unless another remaining production
feature still uses them.

## File Safety And Privacy

The removal must not delete user files or change user music folders.

Do not delete existing downloaded `.lrc` files, same-stem artwork sidecars, or
`artist images` folders. Those files are now simply local assets that Petrichor
may continue to read.

After removal, the app should not send listening history, track metadata, album
metadata, artist names, or image queries to the removed online services.

## Localization And Assets

Remove localized strings that are only used by the deleted settings, Last.fm
authentication/scrobbling notifications, online lyrics setting, online artwork
setting, and artist-image download setting.

Remove service logo assets only when they have no remaining UI or documentation
reference in the app bundle:

- Last.fm logo.
- MusicBrainz logo.
- TMDB logo.
- Wikidata logo.

Do not remove unrelated dependency URLs, project homepage links, or sponsor
links merely because they are external URLs.

Update `ACKNOWLEDGEMENTS.md` and other app-facing docs only for services that
are no longer used by production runtime code. Keep acknowledgements for actual
bundled dependencies.

## Regression Guards

Replace or update tests that currently require online download functionality.
The new guard should fail if production runtime code still references the
removed services or settings.

Suggested checks:

- No `ScrobbleManager`, `LyricsManager`, `TrackArtworkDownloadManager`, or
  `ArtistImageDownloadManager` production file remains.
- No settings tab or setting copy references Last.fm, online lyrics, online
  artwork, or artist-image downloading.
- No production runtime code references LRCLIB, `audioscrobbler.com`,
  `last.fm/api`, `musicbrainz.org`, `coverartarchive.org`, Wikidata/Wikimedia
  image APIs, or removed credential keys.
- Diagnostics no longer include removed online-service preferences.
- Local lyrics and local artwork scripts still pass.

Existing scripts that should remain relevant include:

- `Scripts/test-desktop-lyrics-line-selection.sh`
- `Scripts/test-external-artwork-priority.sh`
- `Scripts/test-artwork-resolver-priority.sh`
- `Scripts/test-ui-artwork-resolver.sh`
- `Scripts/test-localization-format-specifiers.sh`

Scripts that assert removed features exist should be deleted or inverted, such
as online lyrics, track artwork download, and artist image sidecar download
checks.

## Verification

Run the narrow checks covering retained behavior and removal guards:

```sh
Scripts/test-desktop-lyrics-line-selection.sh
Scripts/test-external-artwork-priority.sh
Scripts/test-artwork-resolver-priority.sh
Scripts/test-ui-artwork-resolver.sh
Scripts/test-localization-format-specifiers.sh
```

Run the new or updated online-service removal guard.

When feasible, run:

```sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Manual QA after implementation:

- Settings no longer shows an Integrations tab.
- Starting and finishing playback does not require Last.fm state and does not
  log scrobble attempts.
- A track with a local `.lrc` still shows lyrics.
- A track with embedded lyrics still shows lyrics.
- A track with local same-stem or folder artwork still shows artwork.
- Existing local artist images still display.

## Non-Goals

- Removing the app's general website, sponsor, dependency source URLs, or package
  resolution URLs.
- Removing local lyrics support.
- Removing local artwork sidecar support.
- Removing local artist image display.
- Deleting user-created or previously downloaded sidecar files.
- Removing MusicBrainz ID fields from metadata models or database schema, because
  they can still be embedded metadata read from local audio files.
- Removing all networking entitlements or sandbox behavior unless a separate
  audit shows they are unused after this implementation.
