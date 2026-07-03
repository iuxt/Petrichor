# Filename Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make library search and playlist-add search match each track's original filename without the file extension.

**Architecture:** Add a deterministic filename-stem helper, persist the stem in `tracks.filename_stem`, and index it in `tracks_fts.filename_stem`. Existing search methods keep using the FTS table, so global search and playlist-add search share the same behavior.

**Tech Stack:** Swift, GRDB, SQLite FTS5, Xcode file-system-synchronized groups.

---

## File Structure

- Create: `Core/FilenameStem.swift`
  - Owns the pure filename-to-stem derivation.
  - Has no app or database dependencies so it can be verified with a temporary Swift harness.
- Modify: `Models/Core/Track.swift`
  - Adds `Track.Columns.filenameStem`.
  - Persists `filename` and `filename_stem` from the track URL during `Track.encode`.
- Modify: `Models/Core/FullTrack.swift`
  - Adds `FullTrack.Columns.filenameStem`.
  - Persists `filename_stem` during inserts and full-track updates.
- Modify: `Managers/Database/DMSetup.swift`
  - Adds `filename_stem` to fresh `tracks` schema.
  - Adds `filename_stem` to fresh `tracks_fts` schema, triggers, and FTS backfill.
- Modify: `Managers/Database/DatabaseMigration.swift`
  - Adds `v13_add_filename_stem_search`.
  - Adds and backfills `tracks.filename_stem`.
  - Rebuilds `tracks_fts` so existing libraries search filename stems.

## Task 1: Filename Stem Helper

**Files:**
- Create: `Core/FilenameStem.swift`

- [ ] **Step 1: Write the failing helper verification**

Run this before creating `Core/FilenameStem.swift`:

```bash
cat > /tmp/main.swift <<'SWIFT'
import Foundation

let cases: [(String, String)] = [
    ("01 - Intro.flac", "01 - Intro"),
    ("song.demo.v2.mp3", "song.demo.v2"),
    ("README", "README"),
    (".hidden", ".hidden"),
    (".hidden.flac", ".hidden"),
    ("track.", "track")
]

for (input, expected) in cases {
    let actual = FilenameStem.fromFilename(input)
    guard actual == expected else {
        fatalError("\(input) produced \(actual), expected \(expected)")
    }
}
SWIFT
swiftc Core/FilenameStem.swift /tmp/main.swift -o /tmp/filename_stem_test
```

Expected: FAIL because `Core/FilenameStem.swift` does not exist.

- [ ] **Step 2: Add the helper**

Create `Core/FilenameStem.swift`:

```swift
import Foundation

enum FilenameStem {
    static func fromURL(_ url: URL) -> String {
        fromFilename(url.lastPathComponent)
    }

    static func fromFilename(_ filename: String) -> String {
        guard let dotIndex = filename.lastIndex(of: "."),
              dotIndex != filename.startIndex else {
            return filename
        }

        return String(filename[..<dotIndex])
    }
}
```

- [ ] **Step 3: Run the helper verification**

```bash
swiftc Core/FilenameStem.swift /tmp/main.swift -o /tmp/filename_stem_test
/tmp/filename_stem_test
```

Expected: PASS with no output.

- [ ] **Step 4: Commit the helper**

```bash
git add Core/FilenameStem.swift
git commit -m "feat: add filename stem helper"
```

## Task 2: Persist Filename Stems On Tracks

**Files:**
- Modify: `Models/Core/Track.swift`
- Modify: `Models/Core/FullTrack.swift`

- [ ] **Step 1: Write the failing compile check**

Run this before model changes:

```bash
rg -n 'filenameStem|filename_stem' Models/Core/Track.swift Models/Core/FullTrack.swift
```

Expected: FAIL with no model-column matches before this task.

- [ ] **Step 2: Update `Track.Columns` and `Track.encode`**

In `Models/Core/Track.swift`, add this column next to `filename`:

```swift
static let filenameStem = Column("filename_stem")
```

Update `Track.encode(to:)` so the file-property persistence block is:

```swift
container[Columns.trackId] = trackId
container[Columns.folderId] = folderId
container[Columns.path] = url.path
container[Columns.filename] = url.lastPathComponent
container[Columns.filenameStem] = FilenameStem.fromURL(url)
container[Columns.title] = title
```

- [ ] **Step 3: Update `FullTrack.Columns` and `FullTrack.encode`**

In `Models/Core/FullTrack.swift`, add this column next to `filename`:

```swift
static let filenameStem = Column("filename_stem")
```

Update `FullTrack.encode(to:)` so the file-property persistence block is:

```swift
container[Columns.trackId] = trackId
container[Columns.folderId] = folderId
container[Columns.path] = url.path
container[Columns.filename] = url.lastPathComponent
container[Columns.filenameStem] = FilenameStem.fromURL(url)
container[Columns.title] = title
```

- [ ] **Step 4: Build-check model changes**

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug -destination 'platform=macOS' build
```

Expected: PASS, or the known local Xcode/CoreSimulator environment warning appears without Swift compile errors from these model changes.

- [ ] **Step 5: Commit model persistence**

```bash
git add Models/Core/Track.swift Models/Core/FullTrack.swift
git commit -m "feat: persist filename stems for tracks"
```

## Task 3: Fresh Schema And FTS Synchronization

**Files:**
- Modify: `Managers/Database/DMSetup.swift`

- [ ] **Step 1: Write the failing static check**

```bash
rg -n 'filename_stem' Managers/Database/DMSetup.swift
```

Expected: FAIL with no matches before this task.

- [ ] **Step 2: Add `filename_stem` to fresh `tracks` schema**

In `createTracksTable(in:)`, add this column immediately after `filename`:

```swift
t.column("filename_stem", .text).notNull().defaults(to: "")
```

- [ ] **Step 3: Add `filename_stem` to fresh FTS schema**

In `createFTSTable(in:)`, add this FTS column immediately after `title`:

```swift
t.column("filename_stem")
```

- [ ] **Step 4: Update FTS insert trigger**

Replace the insert trigger's column list and values with:

```sql
INSERT INTO tracks_fts(
    rowid, track_id, title, filename_stem, artist, album, album_artist, composer, genre, year
) VALUES (
    NEW.id, NEW.id, NEW.title, NEW.filename_stem, NEW.artist, NEW.album, NEW.album_artist, NEW.composer, NEW.genre, NEW.year
);
```

- [ ] **Step 5: Update FTS update trigger**

Add this assignment after `title = NEW.title,`:

```sql
filename_stem = NEW.filename_stem,
```

- [ ] **Step 6: Update fresh FTS population**

Replace the FTS population insert column list and select list with:

```sql
INSERT INTO tracks_fts(
    rowid, track_id, title, filename_stem, artist, album, album_artist, composer, genre, year
)
SELECT
    id, id, title, filename_stem, artist, album, album_artist, composer, genre, year
FROM tracks
```

- [ ] **Step 7: Run the static check**

```bash
rg -n 'filename_stem' Managers/Database/DMSetup.swift
```

Expected: PASS with matches in the tracks schema, FTS schema, insert trigger, update trigger, and population query.

- [ ] **Step 8: Commit fresh schema and trigger changes**

```bash
git add Managers/Database/DMSetup.swift
git commit -m "feat: index filename stems in fresh search schema"
```

## Task 4: Existing Database Migration

**Files:**
- Modify: `Managers/Database/DatabaseMigration.swift`

- [ ] **Step 1: Write the failing migration static check**

```bash
rg -n 'v13_add_filename_stem_search|filename_stem' Managers/Database/DatabaseMigration.swift
```

Expected: FAIL with no matches for `v13_add_filename_stem_search`.

- [ ] **Step 2: Add migration after `v12_backfill_album_artists`**

Insert this migration before the future migrations marker:

```swift
migrator.registerMigration("v13_add_filename_stem_search") { db in
    try db.addColumnIfNotExists(
        table: "tracks",
        column: "filename_stem",
        type: .text,
        defaultValue: "",
        notNull: true
    )

    let rows = try Row.fetchAll(
        db,
        sql: "SELECT id, filename FROM tracks"
    )
    for row in rows {
        let id: Int64 = row["id"]
        let filename: String = row["filename"]
        try db.execute(
            sql: "UPDATE tracks SET filename_stem = ? WHERE id = ?",
            arguments: [FilenameStem.fromFilename(filename), id]
        )
    }

    try db.execute(sql: "DROP TRIGGER IF EXISTS tracks_fts_insert")
    try db.execute(sql: "DROP TRIGGER IF EXISTS tracks_fts_update")
    try db.execute(sql: "DROP TRIGGER IF EXISTS tracks_fts_delete")
    try db.execute(sql: "DROP TABLE IF EXISTS tracks_fts")
    try DatabaseManager.createFTSTable(in: db)

    Logger.info("v13_add_filename_stem_search migration completed")
}
```

- [ ] **Step 3: Run the migration static check**

```bash
rg -n 'v13_add_filename_stem_search|filename_stem|FilenameStem.fromFilename' Managers/Database/DatabaseMigration.swift
```

Expected: PASS with matches for the migration name, column name, and Swift backfill helper call.

- [ ] **Step 4: Commit migration**

```bash
git add Managers/Database/DatabaseMigration.swift
git commit -m "feat: migrate filename stems into search index"
```

## Task 5: End-To-End Verification

**Files:**
- Read: `Managers/Database/DMSearchQueries.swift`
- Read: `Managers/Database/DMSetup.swift`
- Read: `Managers/Database/DatabaseMigration.swift`
- Read: `Models/Core/Track.swift`
- Read: `Models/Core/FullTrack.swift`

- [ ] **Step 1: Verify no search fallback was added**

```bash
git diff --exit-code -- Managers/Database/DMSearchQueries.swift
```

Expected: PASS with no output, proving both search entry points still use the shared FTS path.

- [ ] **Step 2: Verify helper behavior one final time**

```bash
swiftc Core/FilenameStem.swift /tmp/main.swift -o /tmp/filename_stem_test
/tmp/filename_stem_test
```

Expected: PASS with no output.

- [ ] **Step 3: Build the macOS app**

```bash
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug -destination 'platform=macOS' build
```

Expected: PASS. A local Xcode/CoreSimulator mismatch is an environment failure; Swift compile errors in changed files are implementation failures and must be fixed.

- [ ] **Step 4: Review git status**

```bash
git status --short
```

Expected: only the pre-existing `Resources/Localizable.xcstrings` modification remains, unless the user explicitly asks to stage it.
