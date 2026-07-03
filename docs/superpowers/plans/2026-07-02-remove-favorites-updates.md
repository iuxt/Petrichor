# Remove Favorites and Update Checking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Completely remove track favorites and Sparkle-based update checking from Petrichor.

**Architecture:** Add removal guard scripts first, then delete updater integration, then delete favorite UI, then delete favorite model/database state, then delete dependent smart-playlist, automation, and Last.fm paths. Finish by cleaning localization/docs and running guard scripts plus the app build.

**Tech Stack:** Swift, SwiftUI, AppKit, GRDB migrations, AppIntents, bash scripts, JSON `.xcstrings`, Xcode project files.

---

## File Structure

- Create `Scripts/test-favorites-updates-removed.sh`: regression guard for removed favorite/update hooks.
- Modify `Application/AppDelegate.swift`: remove Sparkle startup and Dock favorite action.
- Modify `PetrichorApp.swift`: remove app menu update command and Playback menu favorite command.
- Modify `Views/Settings/GeneralTabView.swift`: remove automatic update setting and Sparkle import.
- Modify `Configuration/Info.plist`: remove Sparkle keys.
- Modify `Petrichor.xcodeproj/project.pbxproj`: remove Sparkle package, product, and framework references while preserving unrelated project edits.
- Modify `Petrichor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`: remove Sparkle pin.
- Modify `Utilities/DiagnosticSnapshot.swift` and `Utilities/Constants.swift`: remove removed settings and update-checking icon constants.
- Modify `Views/Components/TrackContextMenu.swift`: remove favorite context menu actions.
- Modify `Views/Main/PlayerView.swift`: remove the player favorite button.
- Modify `Views/Components/TrackViews/TrackTableView.swift`: remove favorite column, favorite cache, favorite notification handling, and favorite sort helper.
- Modify `Views/Components/TrackViews/TrackTableOptionsDropdown.swift`: remove favorite sort field.
- Modify `Views/Main/TrackDetailView.swift`: remove favorite metadata display.
- Modify `Views/Playlists/PlaylistDetailView.swift` and `Views/Playlists/PlaylistSidebarView.swift`: replace favorite-based previews.
- Modify `Utilities/Constants.swift`: remove runtime favorites constants/notifications.
- Modify `Models/Core/Track.swift` and `Models/Core/FullTrack.swift`: remove favorite properties/columns/encoding.
- Modify `Managers/Database/DMSetup.swift`: stop creating `is_favorite` and its index.
- Modify `Managers/Database/DatabaseMigration.swift`: add `v15_remove_track_favorites` and decouple `v14` from `DefaultPlaylists.favorites`.
- Modify `Managers/Database/DMTrackUpdate.swift` and `Managers/Playlist/PMTrackUpdate.swift`: remove favorite update APIs.
- Modify `Managers/Playlist/PlaylistManager.swift`: remove favorite toggle APIs and favorite filtering.
- Modify `Models/Core/SmartPlaylistField.swift`, `Managers/Database/DMSmartPlaylistQueries.swift`, and `Managers/Playlist/PMSmartPlaylistEvaluator.swift`: remove favorite criteria support.
- Modify `Views/Settings/IntegrationsTabView.swift` and `Managers/ScrobbleManager.swift`: remove Last.fm Loved sync from favorites.
- Modify `Managers/Automation/AMTransport.swift`, `Managers/Automation/AutomationIntents.swift`, `Managers/Automation/AutomationShortcuts.swift`, `Managers/Automation/AMQuery.swift`, and `Managers/Automation/AutomationEntities.swift`: remove favorite automation.
- Modify `Resources/Localizable.xcstrings`, `README.md`, and `ACKNOWLEDGEMENTS.md`: remove removed feature strings and docs.

### Task 1: Add Removal Guard Script

**Files:**
- Create: `Scripts/test-favorites-updates-removed.sh`

- [ ] **Step 1: Write the failing guard script**

Create `Scripts/test-favorites-updates-removed.sh` with this exact content:

```bash
#!/usr/bin/env bash
set -euo pipefail

mode="${1:-all}"

run_favorite_checks() {
    local swift_paths=(
        Application
        Managers
        Models
        Views
        Utilities
        PetrichorApp.swift
    )

    local favorite_pattern='isFavorite|toggleFavorite|trackFavoriteStatusChanged|Add to Favorites|Remove from Favorites|ToggleFavoriteIntent|FavoriteButton|loveSyncEnabled|trackLoveStatusChanged|setLoveStatus|DefaultPlaylists\.favorites|sortableIsFavorite'

    if rg -n "$favorite_pattern" "${swift_paths[@]}" \
        -g '*.swift' \
        -g '!Managers/Database/DatabaseMigration.swift' >/dev/null; then
        printf 'Favorite feature hooks remain in production Swift files.\n' >&2
        rg -n "$favorite_pattern" "${swift_paths[@]}" \
            -g '*.swift' \
            -g '!Managers/Database/DatabaseMigration.swift' >&2
        exit 1
    fi

    if rg -n '"(Add to Favorites|Remove from Favorites|Favorites|Favorite|Is Favorite|No Favorite Songs|Sync favorites as Loved tracks|Toggle Favorite for Current Track|Tracks you favorite in Petrichor will be loved on Last\.fm|Favorites or unfavorites the current track in Petrichor\.|Mark songs as favorites to see them here)"' Resources/Localizable.xcstrings >/dev/null; then
        printf 'Favorite localization keys remain.\n' >&2
        exit 1
    fi

    if rg -n 'BOOLEAN is_favorite|DefaultPlaylists\.favorites|field: "isFavorite"' README.md Views Models Managers Utilities PetrichorApp.swift \
        -g '!Managers/Database/DatabaseMigration.swift' >/dev/null; then
        printf 'Favorite docs, previews, or runtime references remain.\n' >&2
        exit 1
    fi
}

run_update_checks() {
    local update_pattern='Sparkle|SPUUpdater|SPUStandardUpdaterController|SPUUpdaterDelegate|updaterController|checkForUpdates|Check for Updates|automaticUpdatesEnabled|SUPublicEDKey|SUFeedURL|SUEnableAutomaticChecks|SUEnableInstallerLauncherService|sparkle-project|"identity" : "sparkle"'

    if rg -n "$update_pattern" \
        Application Views Utilities PetrichorApp.swift Configuration/Info.plist Petrichor.xcodeproj README.md ACKNOWLEDGEMENTS.md Resources/Localizable.xcstrings >/dev/null; then
        printf 'Update-checking hooks or docs remain.\n' >&2
        rg -n "$update_pattern" \
            Application Views Utilities PetrichorApp.swift Configuration/Info.plist Petrichor.xcodeproj README.md ACKNOWLEDGEMENTS.md Resources/Localizable.xcstrings >&2
        exit 1
    fi
}

run_migration_checks() {
    if ! rg -n 'v15_remove_track_favorites' Managers/Database/DatabaseMigration.swift >/dev/null; then
        printf 'Migration v15_remove_track_favorites is missing.\n' >&2
        exit 1
    fi

    if rg -n 'is_favorite|idx_tracks_is_favorite' Managers/Database/DMSetup.swift >/dev/null; then
        printf 'Fresh database setup still creates favorite schema.\n' >&2
        exit 1
    fi

    if rg -n 'Columns\.isFavorite|isFavorite' Models/Core/Track.swift Models/Core/FullTrack.swift Managers/Database/DMTrackUpdate.swift Managers/Database/DMSmartPlaylistQueries.swift Managers/Playlist/PMSmartPlaylistEvaluator.swift >/dev/null; then
        printf 'Favorite model or query references remain.\n' >&2
        exit 1
    fi
}

case "$mode" in
    favorite)
        run_favorite_checks
        ;;
    update)
        run_update_checks
        ;;
    migration)
        run_migration_checks
        ;;
    all)
        run_favorite_checks
        run_update_checks
        run_migration_checks
        ;;
    *)
        printf 'Usage: %s [favorite|update|migration|all]\n' "$0" >&2
        exit 2
        ;;
esac

printf 'Favorites and update-checking removal checks passed (%s)\n' "$mode"
```

- [ ] **Step 2: Make the script executable**

Run:

```bash
chmod +x Scripts/test-favorites-updates-removed.sh
```

Expected: no output.

- [ ] **Step 3: Run the guard script and verify it fails before implementation**

Run:

```bash
Scripts/test-favorites-updates-removed.sh all
```

Expected: FAIL with `Favorite feature hooks remain in production Swift files.`

Do not commit this task yet. Commit it with the first removal task once one mode passes.

### Task 2: Remove Sparkle Update Checking

**Files:**
- Modify: `Application/AppDelegate.swift`
- Modify: `PetrichorApp.swift`
- Modify: `Views/Settings/GeneralTabView.swift`
- Modify: `Configuration/Info.plist`
- Modify: `Utilities/DiagnosticSnapshot.swift`
- Modify: `Utilities/Constants.swift`
- Modify: `Petrichor.xcodeproj/project.pbxproj`
- Modify: `Petrichor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Modify: `Resources/Localizable.xcstrings`
- Modify: `README.md`
- Modify: `ACKNOWLEDGEMENTS.md`
- Test: `Scripts/test-favorites-updates-removed.sh`
- Test: `Scripts/test-localization-format-specifiers.sh`

- [ ] **Step 1: Run the update guard to verify it fails**

Run:

```bash
Scripts/test-favorites-updates-removed.sh update
```

Expected: FAIL with `Update-checking hooks or docs remain.`

- [ ] **Step 2: Remove Sparkle from `Application/AppDelegate.swift`**

Make these exact structural changes:

```swift
import Foundation
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
```

Remove this property:

```swift
internal var updaterController: SPUStandardUpdaterController?
```

Remove this launch block completely:

```swift
updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
)
```

In `registerUserDefaultsDefaults()`, remove this entry:

```swift
"automaticUpdatesEnabled": true,
```

- [ ] **Step 3: Remove the app menu update command from `PetrichorApp.swift`**

In `appMenuCommands()`, delete this command group:

```swift
CommandGroup(after: .appInfo) {
    Divider()
    checkForUpdatesMenuItem()
}
```

Remove the whole helper:

```swift
private func checkForUpdatesMenuItem() -> some View {
    Button {
        if let updater = appDelegate.updaterController?.updater {
            updater.checkForUpdates()
        }
    } label: {
        if #available(macOS 26.0, *) {
            Label("Check for Updates...", systemImage: Icons.checkForUpdates)
        } else {
            Text("Check for Updates...")
        }
    }
}
```

- [ ] **Step 4: Remove the automatic update setting from `Views/Settings/GeneralTabView.swift`**

Remove:

```swift
import Sparkle
```

Remove:

```swift
@AppStorage("automaticUpdatesEnabled")
private var automaticUpdatesEnabled = true
```

Remove the whole toggle:

```swift
Toggle("Check for updates automatically", isOn: $automaticUpdatesEnabled)
    .help("Automatically download and install updates when available")
    .onChange(of: automaticUpdatesEnabled) { _, newValue in
        if let appDelegate = NSApp.delegate as? AppDelegate,
           let updater = appDelegate.updaterController?.updater {
            updater.automaticallyChecksForUpdates = newValue
        }
    }
```

- [ ] **Step 5: Remove Sparkle keys from `Configuration/Info.plist`**

Delete this whole block:

```xml
    <!-- Sparkle Configuration -->
    <key>SUPublicEDKey</key>
    <string>YPobXg0pi8vxrnsOk3ApMu2QF46GSFW68vwXjzuNEz4=</string>
    <key>SUFeedURL</key>
    <string>https://kushalpandya.github.io/Petrichor/appcast.xml</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUEnableInstallerLauncherService</key>
    <true/>
```

- [ ] **Step 6: Remove update setting from diagnostics**

In `Utilities/DiagnosticSnapshot.swift`, remove only this line from the `general` dictionary:

```swift
"automaticUpdatesEnabled": defaults.boolOrNull("automaticUpdatesEnabled"),
```

- [ ] **Step 7: Remove update-checking icon constant**

In `Utilities/Constants.swift`, remove:

```swift
static let checkForUpdates = "square.and.arrow.down"
```

- [ ] **Step 8: Remove Sparkle from the Xcode project file**

In `Petrichor.xcodeproj/project.pbxproj`, remove these entries and list references:

```text
55D673CF2E42CEA50095A358 /* Sparkle in Frameworks */
55D673CE2E42CEA50095A358 /* Sparkle */
55D673CD2E42CEA50095A358 /* XCRemoteSwiftPackageReference "Sparkle" */
```

After editing, the `Frameworks` build phase must contain GRDB, SFBAudioEngine, and Crescendo, but not Sparkle:

```text
files = (
    55B0DEC12DE3A58400A41ED9 /* GRDB in Frameworks */,
    552A58402EC0629A00F6D8C0 /* SFBAudioEngine in Frameworks */,
    552CE3E52FE3263900A5C93D /* Crescendo in Frameworks */,
);
```

The target `packageProductDependencies` must not include Sparkle:

```text
packageProductDependencies = (
    55B0DEC02DE3A58400A41ED9 /* GRDB */,
    552A583F2EC0629A00F6D8C0 /* SFBAudioEngine */,
    552CE3E42FE3263900A5C93D /* Crescendo */,
);
```

The project `packageReferences` must not include Sparkle:

```text
packageReferences = (
    55B0DEBF2DE3A58400A41ED9 /* XCRemoteSwiftPackageReference "GRDB" */,
    552A583E2EC0629A00F6D8C0 /* XCRemoteSwiftPackageReference "SFBAudioEngine" */,
    552CE3E32FE3263900A5C93D /* XCRemoteSwiftPackageReference "CrescendoKit" */,
);
```

Delete the complete `XCRemoteSwiftPackageReference "Sparkle"` block and the complete `XCSwiftPackageProductDependency Sparkle` block.

- [ ] **Step 9: Remove the Sparkle pin from `Package.resolved`**

Edit `Petrichor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` and remove the entire object whose identity is `sparkle`:

```json
{
  "identity" : "sparkle",
  "kind" : "remoteSourceControl",
  "location" : "https://github.com/sparkle-project/Sparkle",
  "state" : {
    "revision" : "d46d456107feacc80711b21847b82b07bd9fb46e",
    "version" : "2.9.3"
  }
}
```

Keep the surrounding JSON valid, including commas between adjacent package objects.

- [ ] **Step 10: Remove update localization keys**

Run this script once from the repository root:

```bash
python3 - <<'PY'
import json
from pathlib import Path

path = Path("Resources/Localizable.xcstrings")
data = json.loads(path.read_text())
for key in [
    "Automatically download and install updates when available",
    "Check for updates automatically",
    "Check for Updates...",
]:
    data["strings"].pop(key, None)
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
```

- [ ] **Step 11: Remove update docs and acknowledgements**

In `README.md`, remove these lines:

```markdown
- ~~Automatic in-app updates~~ (✅ [v1.0.0](https://github.com/kushalpandya/Petrichor/releases/tag/v1.0.0) )
- [Sparkle](https://github.com/sparkle-project/Sparkle)
- Core dependencies (SFBAudioEngine, GRDB, Sparkle) are licensed under MIT
    - To check for and install app updates.
```

Replace the dependency sentence with:

```markdown
- Core dependencies (SFBAudioEngine and GRDB) are licensed under MIT
```

In `ACKNOWLEDGEMENTS.md`, remove the Sparkle section, Sparkle row, and Sparkle license link:

```markdown
### Sparkle

- **Source**: https://github.com/sparkle-project/Sparkle
```

```markdown
| Sparkle            | MIT          | No (SPM dependency)                                  |
```

```markdown
- Sparkle: https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE
```

- [ ] **Step 12: Run update verification**

Run:

```bash
Scripts/test-favorites-updates-removed.sh update
Scripts/test-localization-format-specifiers.sh
plutil -lint Configuration/Info.plist Resources/Localizable.xcstrings
```

Expected:

```text
Favorites and update-checking removal checks passed (update)
Localization format specifier checks passed
Configuration/Info.plist: OK
Resources/Localizable.xcstrings: OK
```

- [ ] **Step 13: Commit update removal**

Run:

```bash
git add Scripts/test-favorites-updates-removed.sh Application/AppDelegate.swift PetrichorApp.swift Views/Settings/GeneralTabView.swift Configuration/Info.plist Utilities/DiagnosticSnapshot.swift Utilities/Constants.swift Petrichor.xcodeproj/project.pbxproj Petrichor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Resources/Localizable.xcstrings README.md ACKNOWLEDGEMENTS.md
git commit -m "refactor: remove update checking"
```

### Task 3: Remove Favorite UI Entry Points

**Files:**
- Modify: `Application/AppDelegate.swift`
- Modify: `PetrichorApp.swift`
- Modify: `Views/Components/TrackContextMenu.swift`
- Modify: `Views/Main/PlayerView.swift`
- Modify: `Views/Components/TrackViews/TrackTableView.swift`
- Modify: `Views/Components/TrackViews/TrackTableOptionsDropdown.swift`
- Modify: `Views/Main/TrackDetailView.swift`
- Modify: `Views/Playlists/PlaylistDetailView.swift`
- Modify: `Views/Playlists/PlaylistSidebarView.swift`

- [ ] **Step 1: Run a UI-focused favorite check and verify it fails**

Run:

```bash
rg -n 'FavoriteButton|Add to Favorites|Remove from Favorites|trackFavoriteStatusChanged|sortableIsFavorite|DefaultPlaylists\.favorites|field: "isFavorite"' Application PetrichorApp.swift Views -g '*.swift'
```

Expected: FAIL by printing matches in `Application/AppDelegate.swift`, `PetrichorApp.swift`, `TrackContextMenu.swift`, `PlayerView.swift`, `TrackTableView.swift`, `PlaylistDetailView.swift`, and `PlaylistSidebarView.swift`.

- [ ] **Step 2: Remove favorite action from the Dock menu**

In `Application/AppDelegate.swift`, remove the `Favorite action` block from `applicationDockMenu(_:)`:

```swift
// Favorite action
let favoriteTitle = currentTrack.isFavorite
    ? String(localized: "Remove from Favorites")
    : String(localized: "Add to Favorites")
let favoriteItem = NSMenuItem(
    title: favoriteTitle,
    action: #selector(toggleFavorite),
    keyEquivalent: ""
)
favoriteItem.target = self
menu.addItem(favoriteItem)
```

Remove the Dock action method:

```swift
@objc
private func toggleFavorite() {
    guard let coordinator = AppCoordinator.shared,
          let track = coordinator.playbackManager.currentTrack else { return }

    coordinator.playlistManager.toggleFavorite(for: track)
}
```

- [ ] **Step 3: Remove favorite command from the Playback menu**

In `PetrichorApp.swift`, change `playbackMenuCommands()` so the first part is:

```swift
CommandMenu("Playback") {
    playPauseMenuItem()

    Divider()

    shuffleMenuItem()
    repeatMenuItem()
```

Remove the whole `favoriteMenuItem()` helper:

```swift
private func favoriteMenuItem() -> some View {
    Button {
        if let track = appCoordinator.playbackManager.currentTrack {
            appCoordinator.playlistManager.toggleFavorite(for: track)
            menuUpdateTrigger = UUID()
        }
    } label: {
        let isFavorite = appCoordinator.playbackManager.currentTrack?.isFavorite == true

        if #available(macOS 26.0, *) {
            Label(
                isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"),
                systemImage: isFavorite ? Icons.starFill : Icons.star
            )
        } else {
            Text(isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"))
        }
    }
    .keyboardShortcut("f", modifiers: [.command, .shift])
    .disabled(appCoordinator.playbackManager.currentTrack == nil)
    .id(menuUpdateTrigger)
}
```

- [ ] **Step 4: Remove favorite context menu items**

In `Views/Components/TrackContextMenu.swift`, remove this single-track item from `createPlaylistItems(for:playlistManager:)`:

```swift
items.append(
    .button(
        title: track.isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"),
        icon: track.isFavorite ? Icons.starFill : Icons.star
    ) { playlistManager.toggleFavorite(for: track) }
)
```

In `createBulkPlaylistItems(for:playlistManager:currentContext:)`, remove:

```swift
let allFavorited = tracks.allSatisfy { $0.isFavorite }
let title = allFavorited ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")
items.append(.button(title: title, icon: Icons.star) {
    playlistManager.toggleFavorite(for: tracks, setTo: !allFavorited)
})
```

- [ ] **Step 5: Remove favorite button from player details**

In `Views/Main/PlayerView.swift`, change `PlayerTrackDetailsView` equality to:

```swift
static func == (lhs: PlayerTrackDetailsView, rhs: PlayerTrackDetailsView) -> Bool {
    lhs.track?.id == rhs.track?.id &&
    lhs.showTechnicalInfo == rhs.showTechnicalInfo
}
```

Replace the title row body with:

```swift
Text(track?.title ?? "")
    .font(.system(size: titleFontSize, weight: .medium))
    .lineLimit(1)
    .foregroundColor(.primary)
    .truncationMode(.tail)
    .help(track?.title ?? "")
    .contextMenu {
        TrackContextMenuContent(items: contextMenuItems)
    }
    .frame(height: titleRowHeight)
    .frame(maxWidth: .infinity, alignment: .leading)
```

Delete the entire `FavoriteButtonView` struct.

- [ ] **Step 6: Remove favorite column and live favorite cache from track tables**

In `Views/Components/TrackViews/TrackTableView.swift`, remove:

```swift
@State private var trackFavorites: [Int64: Bool] = [:]
```

Remove the helper:

```swift
private func isFavorite(_ track: Track) -> Bool {
    guard let trackId = track.trackId else { return track.isFavorite }

    if let favorite = trackFavorites[trackId] {
        return favorite
    }

    return track.isFavorite
}
```

Remove the favorite cache rebuild from `.onChange(of: tracks)`:

```swift
trackFavorites = Dictionary(uniqueKeysWithValues:
    newTracks.compactMap { track in
        guard let trackId = track.trackId else { return nil }
        return (trackId, track.isFavorite)
    }
)
```

Remove this receiver:

```swift
.onReceive(NotificationCenter.default.publisher(for: .trackFavoriteStatusChanged)) { notification in
    handleTrackFavoriteStatusChanged(notification)
}
```

Remove the favorite table column:

```swift
// Favorite
TableColumn("★", value: \.sortableIsFavorite) { track in
    FavoriteButtonCell(
        track: track,
        isFavorite: isFavorite(track)
    )
    .frame(maxWidth: .infinity, alignment: .center)
}
.width(15)
.customizationID("favorite")
.defaultVisibility(.hidden)
```

Remove `handleTrackFavoriteStatusChanged(_:)`, remove the entire `FavoriteButtonCell` struct, and remove this sort helper:

```swift
var sortableIsFavorite: Int {
    isFavorite ? 0 : 1
}
```

- [ ] **Step 7: Remove favorite sort field from table options**

In `Views/Components/TrackViews/TrackTableOptionsDropdown.swift`, remove `case favorite`, its display label, its comparator, its entry in `sortFields`, and this comparator map row:

```swift
("sortableIsFavorite", .favorite),
```

The `sortFields` array should become:

```swift
static var sortFields: [TrackSortField] {
    [
        .trackNumber, .discNumber, .title, .artist, .album, .genre,
        .year, .composer, .filename, .duration, .dateAdded
    ]
}
```

- [ ] **Step 8: Remove favorite metadata display**

In `Views/Main/TrackDetailView.swift`, remove:

```swift
if fullTrack.isFavorite {
    items.append((String(localized: "Favorite"), String(localized: "Yes")))
}
```

- [ ] **Step 9: Replace favorite-based previews**

In `Views/Playlists/PlaylistDetailView.swift`, keep the regular playlist preview but change its sample name:

```swift
let samplePlaylist = Playlist(name: "Sample Playlist", tracks: [])
```

Replace the smart playlist preview with a play-count playlist:

```swift
#Preview("Smart Playlist") {
    let smartPlaylist = Playlist(
        name: DefaultPlaylists.mostPlayed,
        criteria: SmartPlaylistCriteria(
            rules: [
                SmartPlaylistCriteria.Rule(
                    field: "playCount",
                    condition: .greaterThanOrEqual,
                    value: "5"
                )
            ],
            limit: 25,
            sortBy: "playCount",
            sortAscending: false
        ),
        isUserEditable: false
    )

    return PlaylistDetailView(playlist: smartPlaylist)
        .environmentObject({
            let manager = PlaylistManager()
            manager.playlists = [smartPlaylist]
            return manager
        }())
        .environmentObject({
            let coordinator = AppCoordinator()
            return coordinator.playbackManager
        }())
        .frame(height: 600)
}
```

In `Views/Playlists/PlaylistSidebarView.swift`, remove the favorite smart playlist from `smartPlaylists` in the preview. Keep only `DefaultPlaylists.mostPlayed` and `DefaultPlaylists.recentlyPlayed`.

- [ ] **Step 10: Run UI-focused verification**

Run:

```bash
if rg -n 'FavoriteButton|Add to Favorites|Remove from Favorites|trackFavoriteStatusChanged|sortableIsFavorite|DefaultPlaylists\.favorites|field: "isFavorite"' Application PetrichorApp.swift Views -g '*.swift'; then
    exit 1
fi
```

Expected: no output and exit code 0.

- [ ] **Step 11: Commit favorite UI removal**

Run:

```bash
git add Application/AppDelegate.swift PetrichorApp.swift Views/Components/TrackContextMenu.swift Views/Main/PlayerView.swift Views/Components/TrackViews/TrackTableView.swift Views/Components/TrackViews/TrackTableOptionsDropdown.swift Views/Main/TrackDetailView.swift Views/Playlists/PlaylistDetailView.swift Views/Playlists/PlaylistSidebarView.swift
git commit -m "refactor: remove favorite UI"
```

### Task 4: Remove Favorite Model and Database State

**Files:**
- Modify: `Models/Core/Track.swift`
- Modify: `Models/Core/FullTrack.swift`
- Modify: `Managers/Database/DMSetup.swift`
- Modify: `Managers/Database/DatabaseMigration.swift`
- Modify: `Managers/Database/DMTrackUpdate.swift`
- Modify: `Managers/Playlist/PlaylistManager.swift`
- Modify: `Managers/Playlist/PMTrackUpdate.swift`
- Modify: `Utilities/Constants.swift`
- Test: `Scripts/test-favorites-updates-removed.sh`

- [ ] **Step 1: Run migration guard and verify it fails**

Run:

```bash
Scripts/test-favorites-updates-removed.sh migration
```

Expected: FAIL with `Migration v15_remove_track_favorites is missing.`

- [ ] **Step 2: Remove favorite state from `Track`**

In `Models/Core/Track.swift`, remove:

```swift
var isFavorite: Bool = false
static let isFavorite = Column("is_favorite")
isFavorite = row[Columns.isFavorite]
container[Columns.isFavorite] = isFavorite
Columns.isFavorite,
```

The full helper to remove is:

```swift
extension Track {
    /// Create a copy with updated favorite status
    func withFavoriteStatus(_ isFavorite: Bool) -> Track {
        var copy = self
        copy.isFavorite = isFavorite
        return copy
    }
}
```

The user interaction state block should become:

```swift
// User interaction state
var playCount: Int = 0
var lastPlayedDate: Date?
```

The `lightweightSelection` list should include `Columns.dateAdded` followed by `Columns.playCount`, with no favorite column between them.

- [ ] **Step 3: Remove favorite state from `FullTrack`**

In `Models/Core/FullTrack.swift`, remove:

```swift
var isFavorite: Bool = false
static let isFavorite = Column("is_favorite")
isFavorite = row[Columns.isFavorite]
container[Columns.isFavorite] = isFavorite
```

The core metadata block should keep:

```swift
var trackArtworkData: Data?
var albumArtworkData: Data?
var playCount: Int = 0
var lastPlayedDate: Date?
```

- [ ] **Step 4: Stop creating favorite schema for fresh databases**

In `Managers/Database/DMSetup.swift`, remove this track column:

```swift
t.column("is_favorite", .boolean).notNull().defaults(to: false)
```

Remove this index:

```swift
try db.createIndexIfNotExists(name: "idx_tracks_is_favorite", table: "tracks", columns: ["is_favorite"])
```

- [ ] **Step 5: Add favorite removal migration**

In `Managers/Database/DatabaseMigration.swift`, change the existing `v14` migration to use a string literal because `DefaultPlaylists.favorites` will be removed:

```swift
migrator.registerMigration("v14_remove_builtin_favorites_playlist") { db in
    let favoriteIds = try String.fetchAll(
        db,
        sql: "SELECT id FROM playlists WHERE name = ? AND type = 'smart' AND is_user_editable = 0",
        arguments: ["Favorites"]
    )

    for playlistId in favoriteIds {
        try db.execute(sql: "DELETE FROM pinned_items WHERE playlist_id = ?", arguments: [playlistId])
        try db.execute(sql: "DELETE FROM playlist_tracks WHERE playlist_id = ?", arguments: [playlistId])
        try db.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [playlistId])
    }

    Logger.info("v14_remove_builtin_favorites_playlist migration completed")
}
```

Add this migration immediately after `v14_remove_builtin_favorites_playlist`:

```swift
migrator.registerMigration("v15_remove_track_favorites") { db in
    let playlistIds = try String.fetchAll(
        db,
        sql: """
            SELECT id FROM playlists
            WHERE type = 'smart'
              AND smart_criteria IS NOT NULL
              AND smart_criteria LIKE '%isFavorite%'
            """
    )

    for playlistId in playlistIds {
        try db.execute(sql: "DELETE FROM pinned_items WHERE playlist_id = ?", arguments: [playlistId])
        try db.execute(sql: "DELETE FROM playlist_tracks WHERE playlist_id = ?", arguments: [playlistId])
        try db.execute(sql: "DELETE FROM playlists WHERE id = ?", arguments: [playlistId])
    }

    try db.dropIndexIfExists("idx_tracks_is_favorite")
    try db.dropColumnIfExists(table: "tracks", column: "is_favorite")

    Logger.info("v15_remove_track_favorites migration completed")
}
```

- [ ] **Step 6: Remove favorite database update API**

In `Managers/Database/DMTrackUpdate.swift`, remove:

```swift
// Updates a track's favorite status
func updateTrackFavoriteStatus(trackId: Int64, isFavorite: Bool) async throws {
    try await dbQueue.write { db in
        try Track
            .filter(Track.Columns.trackId == trackId)
            .updateAll(db, Track.Columns.isFavorite.set(to: isFavorite))
    }
}
```

Update the file comment so it no longer mentions marking as favorite:

```swift
// This extension contains methods for updating individual tracks based on user
// interaction events like play count and last played date.
```

- [ ] **Step 7: Remove favorite playlist manager APIs**

In `Managers/Playlist/PlaylistManager.swift`, remove both `toggleFavorite` overloads.

In `loadPlaylists()`, remove the runtime filter for `DefaultPlaylists.favorites` so the code reads:

```swift
let savedSmartPlaylists = dbManager.loadAllPlaylists()
    .filter { $0.type == .smart }
```

This is safe because `v14` and `v15` remove the old built-in Favorites playlist and favorite-rule user smart playlists.

- [ ] **Step 8: Remove favorite update implementation**

In `Managers/Playlist/PMTrackUpdate.swift`, remove the entire `updateTrackFavoriteStatus(track:isFavorite:)` method.

Update the file comment to:

```swift
// This extension contains methods for updating individual tracks based on user
// interaction events like play count and last played date.
// The methods internally also use DatabaseManager methods to work with database.
```

Keep `handleTrackPropertyUpdate(_:)` because play-count and current-track refresh paths still use it.

- [ ] **Step 9: Remove runtime favorite constants and notification**

In `Utilities/Constants.swift`, remove:

```swift
static let favorites = "Favorites"
static let trackFavoriteStatusChanged = Notification.Name("trackFavoriteStatusChanged")
```

Keep `Icons.sparkles`; it is still used by the Discover and Library optimize UI.

- [ ] **Step 10: Run model and migration verification**

Run:

```bash
Scripts/test-favorites-updates-removed.sh migration
```

Expected:

```text
Favorites and update-checking removal checks passed (migration)
```

- [ ] **Step 11: Commit model and database removal**

Run:

```bash
git add Models/Core/Track.swift Models/Core/FullTrack.swift Managers/Database/DMSetup.swift Managers/Database/DatabaseMigration.swift Managers/Database/DMTrackUpdate.swift Managers/Playlist/PlaylistManager.swift Managers/Playlist/PMTrackUpdate.swift Utilities/Constants.swift
git commit -m "refactor: remove favorite model state"
```

### Task 5: Remove Favorite Smart Playlist, Automation, and Last.fm Behavior

**Files:**
- Modify: `Models/Core/SmartPlaylistField.swift`
- Modify: `Managers/Database/DMSmartPlaylistQueries.swift`
- Modify: `Managers/Playlist/PMSmartPlaylistEvaluator.swift`
- Modify: `Views/Settings/IntegrationsTabView.swift`
- Modify: `Managers/ScrobbleManager.swift`
- Modify: `Managers/Automation/AMTransport.swift`
- Modify: `Managers/Automation/AutomationIntents.swift`
- Modify: `Managers/Automation/AutomationShortcuts.swift`
- Modify: `Managers/Automation/AMQuery.swift`
- Modify: `Managers/Automation/AutomationEntities.swift`
- Modify: `Utilities/DiagnosticSnapshot.swift`

- [ ] **Step 1: Run dependent-code check and verify it fails**

Run:

```bash
rg -n 'isFavorite|Favorite|favorite|loveSyncEnabled|trackLoveStatusChanged|setLoveStatus|ToggleFavoriteIntent' Models/Core/SmartPlaylistField.swift Managers/Database/DMSmartPlaylistQueries.swift Managers/Playlist/PMSmartPlaylistEvaluator.swift Views/Settings/IntegrationsTabView.swift Managers/ScrobbleManager.swift Managers/Automation Utilities/DiagnosticSnapshot.swift
```

Expected: FAIL by printing favorite smart-playlist, integration, scrobble, automation, or diagnostic matches.

- [ ] **Step 2: Remove Favorite from smart playlist fields**

In `Models/Core/SmartPlaylistField.swift`, remove:

```swift
case boolean
case isFavorite
case .isFavorite: return String(localized: "Favorite")
case .isFavorite:
    return .boolean
case .boolean:
    return [.equals]
case .boolean: return "true"
```

The `SmartField` cases should end date fields with:

```swift
// Date fields
case lastPlayedDate
case dateAdded
```

The `valueKind` switch should not have a boolean branch. The `operators` switch should only handle `.text`, `.number`, `.duration`, and `.date`. The `defaultValue` switch should only handle `.text`, `.number`, `.duration`, and `.date`.

- [ ] **Step 3: Remove favorite smart playlist query support**

In `Managers/Database/DMSmartPlaylistQueries.swift`, remove this branch:

```swift
case "isFavorite":
    return buildBooleanExpression(column: Track.Columns.isFavorite, rule: rule)
```

Remove the helper:

```swift
private func buildBooleanExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
    let value = rule.value.lowercased() == "true"

    switch rule.condition {
    case .equals:
        return column == value
    default:
        return nil
    }
}
```

- [ ] **Step 4: Remove favorite in-memory evaluator support**

In `Managers/Playlist/PMSmartPlaylistEvaluator.swift`, remove:

```swift
case "isFavorite":
    return evaluateBooleanRule(track.isFavorite, condition: rule.condition, value: rule.value)
```

Remove the helper:

```swift
private func evaluateBooleanRule(_ value: Bool, condition: SmartPlaylistCriteria.Condition, value ruleValue: String) -> Bool {
    let expectedValue = ruleValue.lowercased() == "true"

    switch condition {
    case .equals:
        return value == expectedValue
    default:
        return false
    }
}
```

- [ ] **Step 5: Remove boolean editor path from the smart playlist sheet**

In `Views/Playlists/Sheets/SmartPlaylistEditorSheet.swift`, remove boolean-specific cases:

```swift
case .boolean, .date:
    return true
```

Replace with:

```swift
case .date:
    return true
```

Remove the `.boolean` case from `valueEditor`:

```swift
case .boolean:
    Picker("", selection: boolBinding) {
        Text("Yes").tag(true)
        Text("No").tag(false)
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .frame(width: RuleLayout.valueWidth)
```

Remove the `boolBinding` property.

- [ ] **Step 6: Remove Last.fm Loved sync UI**

In `Views/Settings/IntegrationsTabView.swift`, remove:

```swift
@AppStorage("loveSyncEnabled")
private var loveSyncEnabled: Bool = true
```

Remove:

```swift
@State private var showLoveSyncInfo = false
```

Remove this toggle from `connectedView`:

```swift
Toggle(isOn: $loveSyncEnabled) {
    HStack(spacing: 4) {
        Text("Sync favorites as Loved tracks")

        Button {
            showLoveSyncInfo.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showLoveSyncInfo, arrowEdge: .trailing) {
            Text("Tracks you favorite in Petrichor will be loved on Last.fm. Loved tracks on Last.fm won't sync back to Petrichor.")
                .font(.system(size: 12))
                .padding(10)
                .frame(width: 220)
        }
    }
}
```

In `disconnect()`, remove:

```swift
loveSyncEnabled = true
```

- [ ] **Step 7: Remove Last.fm Loved sync runtime code**

In `Managers/ScrobbleManager.swift`, remove:

```swift
private var isLoveSyncEnabled: Bool {
    UserDefaults.standard.bool(forKey: "loveSyncEnabled")
}
```

Remove the `loveSyncEnabled` default setup block:

```swift
if UserDefaults.standard.object(forKey: "loveSyncEnabled") == nil {
    UserDefaults.standard.set(true, forKey: "loveSyncEnabled")
}
```

Remove the favorite notification observer:

```swift
// Observe favorite status changes
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleFavoriteStatusChanged(_:)),
    name: .trackFavoriteStatusChanged,
    object: nil
)
```

Remove:

```swift
func trackLoveStatusChanged(_ track: Track, isLoved: Bool) {
    guard isConnected, isLoveSyncEnabled else { return }

    Task {
        await setLoveStatus(track, loved: isLoved)
    }
}
```

Remove:

```swift
private func setLoveStatus(_ track: Track, loved: Bool) async {
    guard let apiKey = apiKey,
          let sharedSecret = sharedSecret,
          let sessionKey = sessionKey else { return }

    let method = loved ? "track.love" : "track.unlove"

    var params: [String: String] = [
        "method": method,
        "api_key": apiKey,
        "sk": sessionKey,
        "artist": track.artist,
        "track": track.title
    ]

    params["api_sig"] = generateSignature(params: params, secret: sharedSecret)
    params["format"] = "json"

    do {
        _ = try await makePostRequest(params: params)
        Logger.info("\(loved ? "Loved" : "Unloved") - \(track.artist) - \(track.title)")
    } catch {
        Logger.error("Love status update failed - \(error.localizedDescription)")
    }
}
```

Remove the notification handler at the bottom:

```swift
@objc
private func handleFavoriteStatusChanged(_ notification: Notification) {
    guard let track = notification.userInfo?["track"] as? Track else { return }
    trackLoveStatusChanged(track, isLoved: track.isFavorite)
}
```

Keep `deinit { NotificationCenter.default.removeObserver(self) }`; it remains harmless for any future observers.

- [ ] **Step 8: Remove favorite automation transport and intent**

In `Managers/Automation/AMTransport.swift`, update the file comment to:

```swift
// Playback transport commands (play/pause, navigation, seek, volume, shuffle,
// repeat) used by the transport App Intents. PlaybackManager has no
// standalone play()/pause(), so those are synthesized from togglePlayPause()
// guarded on isPlaying.
```

Remove:

```swift
@discardableResult
func toggleFavoriteCurrent() -> Bool {
    guard let track = playback?.currentTrack else { return false }
    playlist?.toggleFavorite(for: track)
    return true
}
```

In `Managers/Automation/AutomationIntents.swift`, remove the entire `ToggleFavoriteIntent` struct:

```swift
struct ToggleFavoriteIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Favorite for Current Track"
    static var description = IntentDescription("Favorites or unfavorites the current track in Petrichor.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AutomationManager.shared.toggleFavoriteCurrent()
        return .result()
    }
}
```

- [ ] **Step 9: Remove favorite shortcut**

In `Managers/Automation/AutomationShortcuts.swift`, update the file comment to:

```swift
// Zero-setup Siri/Spotlight phrases. Apple registers at most 10 App Shortcuts
// per app, so this is the curated voice surface: Play/Pause, Current Track,
// and the content pickers (artist, album, album artist, composer, genre,
// decade, playlist). Years are intentionally excluded from voice
// (numeric phrases collide); the full intent set is still available as manual
// actions in Shortcuts.app regardless of what's listed here.
```

Remove this shortcut:

```swift
AppShortcut(
    intent: ToggleFavoriteIntent(),
    phrases: [
        "Favorite this in \(.applicationName)",
        "Favorite the current track in \(.applicationName)"
    ],
    shortTitle: "Favorite",
    systemImageName: "heart.fill"
)
```

- [ ] **Step 10: Remove favorite from automation current-track entity**

In `Managers/Automation/AMQuery.swift`, change `nowPlayingSnapshot()` to:

```swift
return NowPlayingSnapshot(
    title: track.title,
    artist: track.displayArtist,
    album: track.displayAlbum,
    duration: track.duration,
    position: playback.actualCurrentTime,
    isPlaying: playback.isPlaying
)
```

Remove this property from `NowPlayingSnapshot`:

```swift
let isFavorite: Bool
```

In `Managers/Automation/AutomationEntities.swift`, remove:

```swift
@Property(title: "Is Favorite")
var isFavorite: Bool
```

Remove this assignment from `init(snapshot:)`:

```swift
self.isFavorite = snapshot.isFavorite
```

- [ ] **Step 11: Remove removed integration setting from diagnostics**

In `Utilities/DiagnosticSnapshot.swift`, remove:

```swift
"loveSyncEnabled": defaults.boolOrNull("loveSyncEnabled"),
```

- [ ] **Step 12: Run dependent-code verification**

Run:

```bash
if rg -n 'isFavorite|ToggleFavoriteIntent|loveSyncEnabled|trackLoveStatusChanged|setLoveStatus|trackFavoriteStatusChanged' Models/Core/SmartPlaylistField.swift Managers/Database/DMSmartPlaylistQueries.swift Managers/Playlist/PMSmartPlaylistEvaluator.swift Views/Settings/IntegrationsTabView.swift Managers/ScrobbleManager.swift Managers/Automation Utilities/DiagnosticSnapshot.swift; then
    exit 1
fi
```

Expected: no output and exit code 0.

- [ ] **Step 13: Commit dependent-code removal**

Run:

```bash
git add Models/Core/SmartPlaylistField.swift Managers/Database/DMSmartPlaylistQueries.swift Managers/Playlist/PMSmartPlaylistEvaluator.swift Views/Playlists/Sheets/SmartPlaylistEditorSheet.swift Views/Settings/IntegrationsTabView.swift Managers/ScrobbleManager.swift Managers/Automation/AMTransport.swift Managers/Automation/AutomationIntents.swift Managers/Automation/AutomationShortcuts.swift Managers/Automation/AMQuery.swift Managers/Automation/AutomationEntities.swift Utilities/DiagnosticSnapshot.swift
git commit -m "refactor: remove favorite dependent features"
```

### Task 6: Clean Favorite Localization and Documentation

**Files:**
- Modify: `Resources/Localizable.xcstrings`
- Modify: `README.md`
- Test: `Scripts/test-favorites-updates-removed.sh`
- Test: `Scripts/test-localization-format-specifiers.sh`

- [ ] **Step 1: Run favorite guard and verify remaining localization/docs failures**

Run:

```bash
Scripts/test-favorites-updates-removed.sh favorite
```

Expected: FAIL with `Favorite localization keys remain.` or `Favorite docs, previews, or runtime references remain.`

- [ ] **Step 2: Remove favorite localization keys**

Run this script once from the repository root:

```bash
python3 - <<'PY'
import json
from pathlib import Path

path = Path("Resources/Localizable.xcstrings")
data = json.loads(path.read_text())
for key in [
    "Add to Favorites",
    "Favorite",
    "Favorites",
    "Favorites or unfavorites the current track in Petrichor.",
    "Is Favorite",
    "Mark songs as favorites to see them here",
    "No Favorite Songs",
    "Remove from Favorites",
    "Sync favorites as Loved tracks",
    "Toggle Favorite for Current Track",
    "Tracks you favorite in Petrichor will be loved on Last.fm. Loved tracks on Last.fm won't sync back to Petrichor.",
]:
    data["strings"].pop(key, None)
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
```

- [ ] **Step 3: Remove favorite schema from README**

In `README.md`, remove this schema line from the tracks table:

```markdown
        BOOLEAN is_favorite "NOT NULL DEFAULT false"
```

Keep this prose because it is generic and not the removed feature:

```markdown
- Pin _anything_ (almost!) to the sidebar for quick access to your favorite music.
```

- [ ] **Step 4: Run docs/localization verification**

Run:

```bash
Scripts/test-favorites-updates-removed.sh favorite
Scripts/test-localization-format-specifiers.sh
plutil -lint Resources/Localizable.xcstrings
```

Expected:

```text
Favorites and update-checking removal checks passed (favorite)
Localization format specifier checks passed
Resources/Localizable.xcstrings: OK
```

- [ ] **Step 5: Commit docs and localization cleanup**

Run:

```bash
git add Resources/Localizable.xcstrings README.md
git commit -m "docs: remove favorite references"
```

### Task 7: Final Verification

**Files:**
- Verify full repository

- [ ] **Step 1: Run removal guard in all mode**

Run:

```bash
Scripts/test-favorites-updates-removed.sh all
```

Expected:

```text
Favorites and update-checking removal checks passed (all)
```

- [ ] **Step 2: Run existing project checks**

Run:

```bash
Scripts/test-file-backed-playlists-integration.sh
Scripts/test-localization-format-specifiers.sh
```

Expected:

```text
File-backed playlist integration checks passed
Localization format specifier checks passed
```

- [ ] **Step 3: Resolve Swift packages**

Run:

```bash
xcodebuild -resolvePackageDependencies -project Petrichor.xcodeproj -scheme Petrichor
```

Expected: output includes:

```text
resolved source packages:
```

and no Sparkle package in the resolved package list.

- [ ] **Step 4: Build the app**

Run:

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: output ends with:

```text
** BUILD SUCCEEDED **
```

- [ ] **Step 5: Inspect final references**

Run:

```bash
rg -n -i 'favorite|favorites|is_favorite|Sparkle|Check for Updates|automaticUpdatesEnabled|loveSyncEnabled' \
    Application Managers Models Views Utilities PetrichorApp.swift Configuration README.md ACKNOWLEDGEMENTS.md Resources/Localizable.xcstrings \
    -g '!Managers/Database/DatabaseMigration.swift'
```

Expected: only generic prose such as `favorite music`, non-feature words in historical docs outside the searched paths, or no output. If this command prints production feature hooks, remove them and rerun Task 7.

- [ ] **Step 6: Review git diff**

Run:

```bash
git status --short
git log --oneline -5
```

Expected:

```text
```

for `git status --short`, unless the user has unrelated uncommitted work. The recent log should include commits from Tasks 2, 3, 4, 5, and 6.
