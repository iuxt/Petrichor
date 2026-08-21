# Artist List Table Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the Home sidebar's Artists category as a multi-column `Table` matching the Songs page presentation, replacing the artwork grid.

**Architecture:** A new `ArtistTableView` component owns the table columns, localized sorting, sort persistence, and the double-click primary action. `HomeView.artistsView` swaps `EntityView` (grid) for this table and drops its now-obsolete sort state. The albums page and grid code stay untouched.

**Tech Stack:** Swift, SwiftUI `Table` (macOS 15+), `KeyPathComparator`, UserDefaults persistence, repo-convention `rg` source-check scripts.

**Spec:** `docs/superpowers/specs/2026-08-21-artist-list-table-design.md`

**Key context for the implementer:**

- `Views/Components/TrackViews/TrackTableView.swift` is the presentation reference: `Table(sortedTracks, selection:sortOrder:)`, `.contextMenu(forSelectionType:primaryAction:)`, 13pt row fonts, `.scrollContentBackground(.hidden)`.
- The Xcode project uses filesystem-synchronized groups (objectVersion 77) — a new `.swift` file under `Views/Components/` is picked up automatically; **do not** edit `project.pbxproj`.
- `rg` is available on this machine; all repo check scripts use it.
- Builds must pass `CODE_SIGNING_ALLOWED=NO` (no signing certificate on this machine).
- `ArtistEntity` (`Models/Core/Entity.swift:66`) has `id`/`name`/`trackCount`/`displayName`; sorting uses raw `name`, display uses `displayName` (localizes the "Unknown" sentinel).
- Column header clicks produce non-localized `KeyPathComparator`s, so data is re-sorted by parsing the comparator description (same trick as `TrackSortField.detect` in `Views/Components/TrackViews/TrackTableOptionsDropdown.swift`) and applying `localizedCaseInsensitiveCompare` — preserving the previous grid's locale-aware ordering for Chinese names.

---

### Task 1: Source-check script (fail first)

**Files:**
- Create: `Scripts/test-artist-list-table.sh`

- [ ] **Step 1: Write the check script**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOME_VIEW="$ROOT_DIR/Views/Home/HomeView.swift"
ENTITY_TABLE="$ROOT_DIR/Views/Components/EntityTableView.swift"

if [ ! -f "$ENTITY_TABLE" ]; then
    printf 'ArtistTableView source file must exist.\n' >&2
    exit 1
fi

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"

    if ! rg -n "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

reject_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"

    if rg -n "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

# Artists page renders through the multi-column artist table.
require_pattern "$HOME_VIEW" 'ArtistTableView\(' \
    'HomeView artists page must render ArtistTableView.'
require_pattern "$HOME_VIEW" 'sortOrder: \$artistSortOrder' \
    'ArtistTableView must receive the artist sort order binding.'

# Only the albums page keeps the entity grid (exactly one EntityView usage).
grid_count="$(rg -c 'EntityView\(' "$HOME_VIEW" || true)"
if [ "${grid_count:-0}" != "1" ]; then
    printf 'HomeView must use EntityView only for albums (expected 1 usage, found %s).\n' \
        "${grid_count:-0}" >&2
    exit 1
fi

# Header sort toggle is gone; sorting lives in table column headers.
reject_pattern "$HOME_VIEW" 'entitySortAscending\.toggle' \
    'Artists header must not keep the asc/desc toggle button.'
reject_pattern "$HOME_VIEW" 'func sortArtistEntities' \
    'sortArtistEntities is obsolete after the table owns sorting.'
reject_pattern "$HOME_VIEW" 'func sortEntities\(' \
    'sortEntities helper is obsolete after the table owns sorting.'

# Table structure: columns, localized sort, selection-driven interactions.
require_pattern "$ENTITY_TABLE" 'struct ArtistTableView: View' \
    'ArtistTableView view must exist.'
require_pattern "$ENTITY_TABLE" 'Table\(sortedArtists, selection: \$selection, sortOrder: \$sortOrder\)' \
    'Artist table must use Table with selection and sort order.'
require_pattern "$ENTITY_TABLE" 'TableColumn\("Artist", value: \\.name\)' \
    'Artist table needs the Artist column.'
require_pattern "$ENTITY_TABLE" 'TableColumn\("Songs", value: \\.trackCount\)' \
    'Artist table needs the Songs column.'
require_pattern "$ENTITY_TABLE" 'localizedCaseInsensitiveCompare' \
    'Artist sorting must stay locale-aware.'
require_pattern "$ENTITY_TABLE" 'contextMenu\(forSelectionType: ArtistEntity\.ID\.self\)' \
    'Artist table must support the selection context menu.'
require_pattern "$ENTITY_TABLE" 'primaryAction' \
    'Artist table must open detail via the double-click primary action.'
require_pattern "$ENTITY_TABLE" '"artistTableSortOrder"' \
    'Artist sort order must persist across launches.'

printf 'Artist list table checks passed.\n'
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x Scripts/test-artist-list-table.sh && Scripts/test-artist-list-table.sh`
Expected: FAIL with `ArtistTableView source file must exist.` (exit 1)

- [ ] **Step 3: Commit**

```bash
git add Scripts/test-artist-list-table.sh
git commit -m "test(home): add artist list table checks"
```

---

### Task 2: Localize the Songs column header

**Files:**
- Modify: `Resources/Localizable.xcstrings` (insert before the `"Songs played 5 or more times will appear here"` entry around line 6914)

The table column titles are `LocalizedStringKey`s. `"Artist"` already exists in the catalog; `"Songs"` does not.

- [ ] **Step 1: Add the `Songs` key with zh-Hans translation**

Use Edit on `Resources/Localizable.xcstrings` with:

old_string:
```
    "Songs played 5 or more times will appear here": {
```

new_string:
```
    "Songs": {
      "comment": "Column header for the artist table's song count column.",
      "localizations": {
        "zh-Hans": {
          "stringUnit": {
            "state": "translated",
            "value": "歌曲数"
          }
        }
      }
    },
    "Songs played 5 or more times will appear here": {
```

- [ ] **Step 2: Verify the JSON still parses**

Run: `python3 -c "import json; d=json.load(open('Resources/Localizable.xcstrings')); print(d['strings']['Songs']['localizations']['zh-Hans']['stringUnit']['value'])"`
Expected: `歌曲数`

- [ ] **Step 3: Run the localization format check**

Run: `Scripts/test-localization-format-specifiers.sh`
Expected: PASS (exit 0)

- [ ] **Step 4: Commit**

```bash
git add Resources/Localizable.xcstrings
git commit -m "feat(home): localize artist table column headers"
```

---

### Task 3: ArtistTableView component

**Files:**
- Create: `Views/Components/EntityTableView.swift`
- Modify: `Models/Core/Entity.swift:66` (add `Equatable` conformance)

- [ ] **Step 1: Enable `Equatable` on ArtistEntity**

In `Models/Core/Entity.swift`, change:

```swift
struct ArtistEntity: Entity {
```

to:

```swift
struct ArtistEntity: Entity, Equatable {
```

(All stored properties are value types; `Track` is already `Equatable`. Synthesized `==` enables `onChange(of: artists)` in the table view.)

- [ ] **Step 2: Create the component file with full contents**

Write `Views/Components/EntityTableView.swift`:

```swift
import SwiftUI

// MARK: - Artist Sort Field

enum ArtistSortField: String, CaseIterable {
    case name
    case trackCount

    func getComparator(ascending: Bool) -> KeyPathComparator<ArtistEntity> {
        switch self {
        case .name:
            return KeyPathComparator(\ArtistEntity.name, order: ascending ? .forward : .reverse)
        case .trackCount:
            return KeyPathComparator(\ArtistEntity.trackCount, order: ascending ? .forward : .reverse)
        }
    }

    /// Detect the sort field from a comparator array by parsing its description,
    /// matching the TrackSortField approach.
    static func detect(from sortOrder: [KeyPathComparator<ArtistEntity>]) -> ArtistSortField {
        guard let firstSort = sortOrder.first else { return .name }
        return String(describing: firstSort).contains("trackCount") ? .trackCount : .name
    }

    /// Detect whether the sort order is ascending from a comparator array.
    static func isAscending(from sortOrder: [KeyPathComparator<ArtistEntity>]) -> Bool {
        guard let firstSort = sortOrder.first else { return true }
        return String(describing: firstSort).contains("forward")
    }
}

// MARK: - Artist Table View

/// Multi-column artist list mirroring the tracks table presentation.
struct ArtistTableView: View {
    let artists: [ArtistEntity]
    let onSelectArtist: (ArtistEntity) -> Void
    let contextMenuItems: (ArtistEntity) -> [ContextMenuItem]
    @Binding var sortOrder: [KeyPathComparator<ArtistEntity>]

    @State private var selection: Set<ArtistEntity.ID> = []
    @State private var sortedArtists: [ArtistEntity] = []

    private static let artistFont = Font.system(size: 13, weight: .regular)
    private static let sortOrderStorageKey = "artistTableSortOrder"

    var body: some View {
        Table(sortedArtists, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Artist", value: \.name) { artist in
                Text(artist.displayName)
                    .font(Self.artistFont)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 200)

            TableColumn("Songs", value: \.trackCount) { artist in
                Text("\(artist.trackCount)")
                    .font(Self.artistFont)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 40)
        }
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 28)
        .contextMenu(forSelectionType: ArtistEntity.ID.self) { selectedIDs in
            let targetID = selectedIDs.first ?? selection.first
            if let artist = sortedArtists.first(where: { $0.id == targetID }) {
                ForEach(contextMenuItems(artist), id: \.id) { item in
                    ContextMenuItemView(item: item)
                }
            }
        } primaryAction: { selectedIDs in
            let targetID = selectedIDs.first ?? selection.first
            if let artist = sortedArtists.first(where: { $0.id == targetID }) {
                onSelectArtist(artist)
            }
        }
        .onAppear {
            restorePersistedSortOrder()
            performLocalizedSort()
        }
        .onChange(of: sortOrder) { _, newValue in
            persistSortOrder(newValue)
            performLocalizedSort()
        }
        .onChange(of: artists) { _, _ in
            performLocalizedSort()
        }
    }

    // MARK: - Sorting

    /// Re-sort with localized comparison so Chinese and other locale-aware ordering
    /// matches the previous grid presentation. Column-header comparators are
    /// non-localized, so ordering is rebuilt from the detected field and direction.
    private func performLocalizedSort() {
        let field = ArtistSortField.detect(from: sortOrder)
        let ascending = ArtistSortField.isAscending(from: sortOrder)

        sortedArtists = artists.sorted { a, b in
            switch field {
            case .name:
                let result = a.name.localizedCaseInsensitiveCompare(b.name)
                return ascending ? result == .orderedAscending : result == .orderedDescending
            case .trackCount:
                if a.trackCount != b.trackCount {
                    return ascending ? a.trackCount < b.trackCount : a.trackCount > b.trackCount
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    // MARK: - Sort Persistence

    private func restorePersistedSortOrder() {
        if let savedSort = UserDefaults.standard.dictionary(forKey: Self.sortOrderStorageKey),
           let key = savedSort["key"] as? String,
           let ascending = savedSort["ascending"] as? Bool,
           let field = ArtistSortField(rawValue: key) {
            sortOrder = [field.getComparator(ascending: ascending)]
            return
        }

        sortOrder = [ArtistSortField.name.getComparator(ascending: true)]
    }

    private func persistSortOrder(_ newValue: [KeyPathComparator<ArtistEntity>]) {
        let storage: [String: Any] = [
            "key": ArtistSortField.detect(from: newValue).rawValue,
            "ascending": ArtistSortField.isAscending(from: newValue)
        ]
        UserDefaults.standard.set(storage, forKey: Self.sortOrderStorageKey)
    }
}

// MARK: - Preview

#Preview("Artist Table") {
    let artists = [
        ArtistEntity(name: "Beatles", trackCount: 25),
        ArtistEntity(name: "Coldplay", trackCount: 42),
        ArtistEntity(name: "周杰伦", trackCount: 68)
    ]

    @Previewable @State var sortOrder = [KeyPathComparator(\ArtistEntity.name)]

    ArtistTableView(
        artists: artists,
        sortOrder: $sortOrder,
        onSelectArtist: { artist in
            Logger.debugPrint("Selected: \(artist.name)")
        },
        contextMenuItems: { _ in [] }
    )
    .frame(width: 500, height: 300)
}
```

- [ ] **Step 3: Build to verify it compiles (component is not yet wired into any screen)**

Run: `xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` with no new warnings referencing `EntityTableView.swift`

- [ ] **Step 4: Commit**

```bash
git add Views/Components/EntityTableView.swift Models/Core/Entity.swift
git commit -m "feat(home): add ArtistTableView for track-style artist list"
```

---

### Task 4: Wire into HomeView

**Files:**
- Modify: `Views/Home/HomeView.swift`

- [ ] **Step 1: Replace artist sort state (lines 27-30)**

Change:

```swift
    @State private var sortedArtistEntities: [ArtistEntity] = []
    @State private var sortedAlbumEntities: [AlbumEntity] = []
    @State private var lastArtistCount: Int = 0
    @State private var lastAlbumCount: Int = 0
```

to:

```swift
    @State private var sortedAlbumEntities: [AlbumEntity] = []
    @State private var lastAlbumCount: Int = 0
    @State private var artistSortOrder = [KeyPathComparator(\ArtistEntity.name)]
```

- [ ] **Step 2: Drop the eager artist sort in the sidebar-change handler (around line 102-108)**

Change:

```swift
                        // Load appropriate data
                        switch type {
                        case .discover, .tracks:
                            isShowingEntities = false
                        case .artists:
                            sortArtistEntities()
                        case .albums:
                            sortAlbumEntities()
                        }
```

to:

```swift
                        // Load appropriate data
                        switch type {
                        case .discover, .tracks, .artists:
                            isShowingEntities = false
                        case .albums:
                            sortAlbumEntities()
                        }
```

- [ ] **Step 3: Replace the whole `artistsView` body (lines 256-303)**

Change:

```swift
    private var artistsView: some View {
        VStack(spacing: 0) {
            // Header
            TrackListHeader(
                title: String(appLocalized: "All Artists"),
                trackCount: libraryManager.artistEntities.count
            ) {
                Button(action: {
                    entitySortAscending.toggle()
                    sortEntities()
                }, label: {
                    Image(Icons.sortIcon(for: entitySortAscending))
                        .renderingMode(.template)
                        .scaleEffect(0.8)
                })
                .buttonStyle(.borderless)
                .hoverEffect(scale: 1.1)
                .help(entitySortAscending ? String(appLocalized: "Sort descending") : String(appLocalized: "Sort ascending"))
            }
            
            Divider()
            
            // Artists list
            if libraryManager.artistEntities.isEmpty {
                NoMusicEmptyStateView(context: .mainWindow)
            } else {
                EntityView(
                    entities: sortedArtistEntities,
                    onSelectEntity: { artist in
                        selectedArtistEntity = artist
                        selectedAlbumEntity = nil
                        isShowingEntityDetail = true
                    },
                    contextMenuItems: { artist in
                        libraryManager.contextMenuItems(for: artist)
                    }
                )
            }
        }
        .onAppear {
            if sortedArtistEntities.isEmpty {
                sortArtistEntities()
            }
        }
        .onReceive(libraryManager.$cachedArtistEntities) { _ in
            sortArtistEntities()
        }
    }
```

to:

```swift
    private var artistsView: some View {
        VStack(spacing: 0) {
            // Header
            TrackListHeader(
                title: String(appLocalized: "All Artists"),
                trackCount: libraryManager.artistEntities.count
            )
            
            Divider()
            
            // Artists list
            if libraryManager.artistEntities.isEmpty {
                NoMusicEmptyStateView(context: .mainWindow)
            } else {
                ArtistTableView(
                    artists: libraryManager.artistEntities,
                    sortOrder: $artistSortOrder,
                    onSelectArtist: { artist in
                        selectedArtistEntity = artist
                        selectedAlbumEntity = nil
                        isShowingEntityDetail = true
                    },
                    contextMenuItems: { artist in
                        libraryManager.contextMenuItems(for: artist)
                    }
                )
            }
        }
    }
```

- [ ] **Step 4: Delete the obsolete helpers `sortArtistEntities()` (around line 455) and `sortEntities()` (around line 512)**

Delete:

```swift
    private func sortArtistEntities() {
        sortedArtistEntities = entitySortAscending
        ? libraryManager.artistEntities.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        : libraryManager.artistEntities.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        lastArtistCount = sortedArtistEntities.count
    }
```

and:

```swift
    private func sortEntities() {
        sortArtistEntities()
        sortAlbumEntities()
    }
```

Keep `entitySortAscending` and `sortAlbumEntities()` — the albums page still uses them.

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` with no new warnings referencing `HomeView.swift`

- [ ] **Step 6: Commit**

```bash
git add Views/Home/HomeView.swift
git commit -m "feat(home): show artists in a track-style table list"
```

---

### Task 5: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Run the new source check**

Run: `Scripts/test-artist-list-table.sh`
Expected: `Artist list table checks passed.` (exit 0)

- [ ] **Step 2: Run related regression checks**

Run: `Scripts/test-localization-format-specifiers.sh && Scripts/test-artist-artwork-removed.sh`
Expected: both PASS (exit 0)

- [ ] **Step 3: Confirm the working tree is clean**

Run: `git status --short`
Expected: empty (all changes committed across Tasks 1-4)

- [ ] **Step 4: Manual smoke test (optional, if a GUI session is available)**

Launch the built app, open 首页 → 艺人: verify the table shows 艺人/歌曲数 columns, click column headers to sort (Chinese names sort by pinyin), double-click a row to open the detail overlay, right-click for Pin/Merge menu, relaunch to confirm the sort choice persisted.

---

## Self-Review Notes

- Spec coverage: table columns + localized sort (Task 3), double-click detail + context menu (Tasks 3-4), header toggle removal (Task 4), sort persistence (Task 3), albums grid untouched (no task — verified by Task 1's `EntityView` count of exactly 1), empty state unchanged (Task 4 keeps `NoMusicEmptyStateView`), source checks (Task 1), build with `CODE_SIGNING_ALLOWED=NO` (Tasks 3, 5).
- Known repo issue, not ours: `Scripts/test-static-track-file-details.sh` already fails on `main` before this change; ignore it.
- Type consistency: `ArtistSortField.getComparator/detect/isAscending` used in Task 3 only; `ArtistTableView(artists:sortOrder:onSelectArtist:contextMenuItems:)` signature matches Task 4's call site; `artistSortOrder` state name matches in Tasks 4 and the Task 1 script pattern.
