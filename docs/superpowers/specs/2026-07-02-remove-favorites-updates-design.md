# Remove Favorites and Update Checking Design

## Goal

Remove the track favorites feature completely and remove the app update-checking feature completely.

This is a hard removal, not a UI-only hide. After implementation, production code should no longer expose favorite actions, favorite state, favorite smart-playlist criteria, favorite automation, Last.fm Loved sync from favorites, Sparkle update checking, or settings for automatic updates.

## Current Context

Petrichor is a SwiftUI/AppKit macOS music player. Favorites currently span UI, model, database, playlist logic, Last.fm integration, automation, localization, and docs. Update checking is implemented through Sparkle and appears in app startup, the app menu, settings, Info.plist, package/project dependencies, localization, acknowledgements, and docs.

The repository already has unrelated uncommitted work in files such as `Managers/Database/DMFolders.swift`, `Managers/Database/DMTrackProcessing.swift`, `Petrichor.xcodeproj/project.pbxproj`, `Utilities/FilesystemUtils.swift`, and new external-artwork files. Implementation must preserve those changes and stage only files intentionally changed for this removal.

## Recommended Approach

Use a full feature removal with a compatibility migration.

This gives the cleanest final state: no dead UI, no dead runtime hooks, no unused favorite schema, and no Sparkle updater code left behind. It has more surface area than hiding controls, but it avoids carrying permanent unused state and reduces future confusion.

Alternatives considered:

- UI/runtime removal while keeping the database column. Lower migration risk, but leaves unused `is_favorite` state forever.
- Two-step removal. First hide behavior, then remove schema later. Safer for staged releases, but unnecessary for the requested cleanup.

## Favorites Removal Scope

Remove all user-visible favorite controls and all associated runtime behavior:

- Track context menus: remove single-track and multi-track Add/Remove Favorites actions.
- Player UI: remove the star/favorite button and any equality/update logic that depends on favorite state.
- App menu and Dock menu: remove favorite menu entries and favorite actions.
- Track table: remove the favorite column, favorite cell button, favorite sort field, and local favorite-state cache.
- Track detail and metadata display: remove Favorite/Yes metadata rows.
- Playlist manager: remove `toggleFavorite`, favorite update methods, favorite notifications, and favorite-specific helper methods.
- Last.fm integration: remove the “Sync favorites as Loved tracks” setting, its explanatory popover, favorite notification observer, and Loved sync behavior triggered by Petrichor favorites.
- Automation: remove the Toggle Favorite intent, shortcut, transport method, and favorite property from track automation entities/snapshots.
- Smart playlists: remove Favorite as a selectable field and remove SQL/in-memory evaluator support for `isFavorite`.
- Localization and docs: remove strings and documentation that describe favorite support, while keeping unrelated uses of the word “favorite” only when they mean generic user preference rather than the removed feature.

## Database and Migration Design

Fresh database setup should stop creating:

- `tracks.is_favorite`
- `idx_tracks_is_favorite`

Existing databases should be migrated with a new migration after the current `v14_remove_builtin_favorites_playlist`:

`v15_remove_track_favorites`

The migration should:

1. Delete saved smart playlists whose criteria JSON references `isFavorite`.
2. Delete related `pinned_items` and `playlist_tracks` rows for those smart playlists.
3. Drop `idx_tracks_is_favorite` if it exists.
4. Drop `tracks.is_favorite` if it exists.

Deleting smart playlists with favorite criteria is explicit and predictable. Rewriting those playlists to match all tracks or silently dropping only the rule would change user intent in surprising ways.

The existing `v14_remove_builtin_favorites_playlist` can remain as historical migration context. New code should not reintroduce `DefaultPlaylists.favorites` runtime behavior.

## Update Checking Removal Scope

Remove Sparkle-based update checking completely:

- Remove `import Sparkle`, `SPUUpdaterDelegate`, and `SPUStandardUpdaterController` usage from app code.
- Stop creating the updater controller at launch.
- Remove the app menu “Check for Updates...” command.
- Remove the General settings “Check for updates automatically” toggle and `automaticUpdatesEnabled` default.
- Remove Sparkle keys from `Configuration/Info.plist`.
- Remove Sparkle from the Xcode project Swift package dependencies and framework linkage, while preserving unrelated project-file changes already present in the worktree.
- Remove Sparkle from `Package.resolved` if no remaining project dependency requires it.
- Update acknowledgements, README, privacy/network-access text, and localization strings so the app no longer claims in-app update support.

The app still has network features for lyrics, artist metadata, and Last.fm. Documentation should remove update-specific network language only.

## Data Flow After Removal

Track state will still include playback-derived metadata such as play count and last played date. These continue to update through existing playback paths and smart playlists.

There will be no favorite state in loaded `Track` or `FullTrack` records, no favorite state encoded to the database, and no notification path for favorite changes.

Smart playlist criteria will only expose fields backed by remaining model/database properties. Existing unsupported favorite criteria are removed during migration instead of being evaluated as false or ignored.

## Error Handling

Migration helpers should be defensive:

- Drop indexes/columns only if they exist.
- Delete only playlists whose persisted criteria references `isFavorite`.
- Keep migration idempotent with existing helper patterns.

If a migrated user database contains old favorite data, that data is intentionally discarded. Launch should continue normally after migration.

If Xcode project dependency removal conflicts with unrelated user edits in `project.pbxproj`, implementation should preserve unrelated edits and resolve only the Sparkle package/product references.

## Testing and Verification

Add or update focused tests/scripts to catch leftover feature hooks:

- A favorite-removal check should fail if production Swift files still contain removed favorite hooks such as `isFavorite`, `toggleFavorite`, `trackFavoriteStatusChanged`, `Add to Favorites`, `Remove from Favorites`, or `ToggleFavoriteIntent`.
- A migration/setup check should assert `v15_remove_track_favorites` exists, setup no longer creates `idx_tracks_is_favorite`, and default Favorites playlist hooks remain absent.
- An update-removal check should fail if production files still contain Sparkle imports, updater controller usage, Sparkle Info.plist keys, `Check for Updates...`, or `automaticUpdatesEnabled`.
- Existing localization format-specifier tests should pass after string removals.
- `xcodebuild` for the Petrichor scheme should be run if local Xcode tooling permits it.

Manual QA after implementation:

- Right-click one or multiple tracks: no favorite action appears.
- Player, Dock menu, and Playback menu have no star/favorite controls.
- Settings no longer shows automatic update controls.
- Smart playlist editor no longer offers Favorite as a field.
- An existing database with old favorite data launches after migration.

## Out of Scope

- Removing generic wording like “favorite music” when it is only prose and not a feature claim.
- Removing network permissions entirely, because lyrics, artist metadata, and Last.fm still use network access.
- Reworking playlist architecture beyond the favorite criteria cleanup required by this removal.
- Modifying unrelated dirty worktree changes.
