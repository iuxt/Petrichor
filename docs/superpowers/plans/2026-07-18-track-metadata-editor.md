# Track Metadata Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a localized single-track and batch metadata editor that reads tags from audio files, writes only explicitly changed fields, verifies every write, refreshes Petrichor from the verified file values, and restores an edited current track to its exact playing or paused state.

**Architecture:** Keep editable tag values and batch-patch semantics in Foundation-only value types. Put SFBAudioEngine file access behind an actor, then pass verified snapshots through a narrow database reindex operation. A `@MainActor` view model owns the sequential batch transaction, coordinates playback suspension/restoration, and updates library and playlist caches. Present one SwiftUI sheet from the existing main-window notification route.

**Tech Stack:** Swift 5, SwiftUI, AppKit, SFBAudioEngine 0.13, GRDB, Bash source-regression checks, Xcode 16+

## Global Constraints

- Treat each audio file as the source of truth: load from the file, mutate the existing `AudioMetadata`, call `writeMetadata()`, reopen, and verify before changing SQLite.
- Support metadata writing only for `mp3`, `m4a`, `flac`, `wav`, `aiff`, `aif`, `ogg`, `oga`, `opus`, `spx`, `ape`, `mpc`, `wv`, `tta`, `dsf`, and `dff`.
- Keep raw `aac`, raw `alac`, `au`, `mod`, `it`, `s3m`, and `xm` visible but read-only in the editor.
- Never replace the entire SFBAudioEngine metadata object; doing so could erase artwork or advanced tags outside this feature's scope.
- An untouched mixed field produces `.unchanged`; a changed empty text/number/date/comment field produces `.remove`; compilation produces only `.unchanged` or `.set(Bool)`.
- Write files sequentially. If the current track is part of the writable batch, process it first and restore it immediately before continuing.
- Preserve current track identity, queue index, playback position, and playing/paused/stopped intent. A track that was paused must remain paused after the verified write.
- A failed file must not stop later files. Keep the result sheet open for skipped or failed items and retry failed items only.
- Do not rescan a folder. Reindex only the successfully verified track, normalized relations, affected duplicate groups, and in-memory consumers.
- All file-level smoke checks must use temporary fixtures or disposable copies, never a user's library file.
- Add every user-facing string to `Resources/Localizable.xcstrings` with English source text and Simplified Chinese translation.
- Do not edit `Petrichor.xcodeproj/project.pbxproj`; synchronized filesystem groups include the new Swift and shell files automatically.

---

### Task 1: Implement the Pure Batch Edit and Patch Model

**Files:**
- Create: `Core/Metadata/TrackMetadataEditModel.swift`
- Create: `Scripts/test-track-metadata-edit-model.sh`

**Interfaces:**
- Produces `MetadataPatchValue`, `TrackEditableTags`, `TrackMetadataSnapshot`, `TrackMetadataPatch`, `TrackMetadataEditForm`, and validation errors.
- Has no dependency on SwiftUI, AppKit, GRDB, SFBAudioEngine, `Track`, or `FullTrack`.
- Normalizes absent and empty stored strings to `nil`, but otherwise compares spelling, case, and whitespace exactly.

- [ ] **Step 1: Write the failing executable model test**

Create `Scripts/test-track-metadata-edit-model.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-metadata-model.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cp "$ROOT_DIR/Core/Metadata/TrackMetadataEditModel.swift" "$TMP_DIR/TrackMetadataEditModel.swift"

cat >"$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let first = TrackEditableTags(
    title: "One",
    artist: "Artist",
    album: nil,
    albumArtist: nil,
    composer: nil,
    genre: "Rock",
    releaseDate: "2025",
    trackNumber: 1,
    trackTotal: 10,
    discNumber: 1,
    discTotal: 1,
    bpm: 120,
    compilation: false,
    comment: nil
)
let second = TrackEditableTags(
    title: "Two",
    artist: "Artist",
    album: "",
    albumArtist: nil,
    composer: nil,
    genre: "Jazz",
    releaseDate: "2025",
    trackNumber: 2,
    trackTotal: 10,
    discNumber: 1,
    discTotal: 1,
    bpm: 120,
    compilation: true,
    comment: nil
)

var form = TrackMetadataEditForm(tags: [first, second])
expect(form.artist.text == "Artist", "common artist must be displayed")
expect(!form.artist.showsMixedPlaceholder, "common artist must not be mixed")
expect(form.title.text.isEmpty, "mixed title control must start empty")
expect(form.title.showsMixedPlaceholder, "mixed title must show the placeholder")
expect(form.album.text.isEmpty, "nil and empty album must aggregate as empty")
expect(!form.album.showsMixedPlaceholder, "nil and empty album must be equal")
expect(form.compilation.value == nil, "mixed compilation must be indeterminate")

let untouched = try form.makePatch()
expect(untouched.isEmpty, "untouched mixed values must produce no patch")

form.setText("Shared", for: .title)
form.setText("", for: .genre)
form.setText("2024-02-29", for: .releaseDate)
form.setCompilation(false)
let changed = try form.makePatch()
expect(changed.title == .set("Shared"), "typed title must apply to every file")
expect(changed.genre == .remove, "cleared dirty genre must remove the tag")
expect(changed.releaseDate == .set("2024-02-29"), "valid ISO date must be retained")
expect(changed.compilation == .set(false), "compilation off must be explicit")

let retryResults = [
    TrackMetadataBatchResult(target: .init(trackID: 1, url: URL(fileURLWithPath: "/tmp/one.flac")), outcome: .saved),
    TrackMetadataBatchResult(target: .init(trackID: 2, url: URL(fileURLWithPath: "/tmp/two.flac")), outcome: .failed("write")),
    TrackMetadataBatchResult(target: .init(trackID: 3, url: URL(fileURLWithPath: "/tmp/three.aac")), outcome: .skipped("read-only"))
]
expect(
    TrackMetadataBatchResult.retryTargets(from: retryResults).map(\.trackID) == [2],
    "retry must include failed writable targets only"
)

form.setText("2023-02-29", for: .releaseDate)
do {
    _ = try form.makePatch()
    expect(false, "invalid calendar date must fail validation")
} catch let error as TrackMetadataValidationError {
    expect(error.field == .releaseDate, "date error must identify release date")
}

form.setText("", for: .releaseDate)
form.setText("0", for: .bpm)
do {
    _ = try form.makePatch()
    expect(false, "zero BPM must fail validation")
} catch let error as TrackMetadataValidationError {
    expect(error.field == .bpm, "integer error must identify BPM")
}

var restoredMixed = TrackMetadataEditForm(tags: [first, second])
restoredMixed.setText("temporary", for: .title)
restoredMixed.setText("", for: .title)
expect(
    try restoredMixed.makePatch().title == .remove,
    "typing then clearing a mixed field must be an explicit removal"
)

print("Track metadata edit model checks passed")
SWIFT

xcrun swiftc \
    "$TMP_DIR/TrackMetadataEditModel.swift" \
    "$TMP_DIR/main.swift" \
    -o "$TMP_DIR/test-track-metadata-edit-model"
"$TMP_DIR/test-track-metadata-edit-model"
```

Make it executable:

```bash
chmod +x Scripts/test-track-metadata-edit-model.sh
```

- [ ] **Step 2: Run the test and verify the RED state**

Run:

```bash
Scripts/test-track-metadata-edit-model.sh
```

Expected: compilation fails because `Core/Metadata/TrackMetadataEditModel.swift` and its types do not exist.

- [ ] **Step 3: Add the domain types**

Create `Core/Metadata/TrackMetadataEditModel.swift` with these declarations:

```swift
import Foundation

enum MetadataPatchValue<Value: Equatable & Sendable>: Equatable, Sendable {
    case unchanged
    case set(Value)
    case remove
}

enum TrackMetadataEditableField: String, CaseIterable, Equatable, Sendable {
    case title
    case artist
    case album
    case albumArtist
    case composer
    case genre
    case releaseDate
    case trackNumber
    case trackTotal
    case discNumber
    case discTotal
    case bpm
    case compilation
    case comment
}

struct TrackMetadataEditTarget: Hashable, Sendable {
    let trackID: Int64?
    let url: URL

    var displayName: String {
        url.lastPathComponent
    }
}

struct TrackEditableTags: Equatable, Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var composer: String?
    var genre: String?
    var releaseDate: String?
    var trackNumber: Int?
    var trackTotal: Int?
    var discNumber: Int?
    var discTotal: Int?
    var bpm: Int?
    var compilation: Bool
    var comment: String?

    func normalized() -> Self {
        var copy = self
        copy.title = Self.normalizedString(title)
        copy.artist = Self.normalizedString(artist)
        copy.album = Self.normalizedString(album)
        copy.albumArtist = Self.normalizedString(albumArtist)
        copy.composer = Self.normalizedString(composer)
        copy.genre = Self.normalizedString(genre)
        copy.releaseDate = Self.normalizedString(releaseDate)
        copy.comment = Self.normalizedString(comment)
        return copy
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

struct TrackMetadataFileSummary: Equatable, Sendable {
    let filename: String
    let path: String
    let format: String
    let duration: Double?
    let fileSize: Int64?
}

struct TrackMetadataSnapshot: Equatable, Sendable {
    let target: TrackMetadataEditTarget
    let tags: TrackEditableTags
    let file: TrackMetadataFileSummary
    let isWritable: Bool
    let restrictionReason: String?
}

enum TrackMetadataLoadResult: Sendable {
    case loaded(TrackMetadataSnapshot)
    case unavailable(target: TrackMetadataEditTarget, reason: String)
}

enum TrackMetadataBatchOutcome: Equatable, Sendable {
    case saved
    case skipped(String)
    case failed(String)
}

struct TrackMetadataBatchResult: Identifiable, Equatable, Sendable {
    let target: TrackMetadataEditTarget
    let outcome: TrackMetadataBatchOutcome

    var id: TrackMetadataEditTarget { target }

    static func retryTargets(
        from results: [TrackMetadataBatchResult]
    ) -> [TrackMetadataEditTarget] {
        results.compactMap { result in
            if case .failed = result.outcome {
                return result.target
            }
            return nil
        }
    }
}

struct TrackMetadataValidationError: LocalizedError, Equatable {
    let field: TrackMetadataEditableField
    let message: String

    var errorDescription: String? {
        message
    }
}
```

Implement `TrackMetadataPatch` with one `MetadataPatchValue` property per editable tag, plus:

```swift
struct TrackMetadataPatch: Equatable, Sendable {
    var title: MetadataPatchValue<String> = .unchanged
    var artist: MetadataPatchValue<String> = .unchanged
    var album: MetadataPatchValue<String> = .unchanged
    var albumArtist: MetadataPatchValue<String> = .unchanged
    var composer: MetadataPatchValue<String> = .unchanged
    var genre: MetadataPatchValue<String> = .unchanged
    var releaseDate: MetadataPatchValue<String> = .unchanged
    var trackNumber: MetadataPatchValue<Int> = .unchanged
    var trackTotal: MetadataPatchValue<Int> = .unchanged
    var discNumber: MetadataPatchValue<Int> = .unchanged
    var discTotal: MetadataPatchValue<Int> = .unchanged
    var bpm: MetadataPatchValue<Int> = .unchanged
    var compilation: MetadataPatchValue<Bool> = .unchanged
    var comment: MetadataPatchValue<String> = .unchanged

    var isEmpty: Bool {
        [
            title.isUnchanged,
            artist.isUnchanged,
            album.isUnchanged,
            albumArtist.isUnchanged,
            composer.isUnchanged,
            genre.isUnchanged,
            releaseDate.isUnchanged,
            trackNumber.isUnchanged,
            trackTotal.isUnchanged,
            discNumber.isUnchanged,
            discTotal.isUnchanged,
            bpm.isUnchanged,
            compilation.isUnchanged,
            comment.isUnchanged
        ].allSatisfy { $0 }
    }

    func mismatchedFields(in actual: TrackEditableTags) -> [TrackMetadataEditableField] {
        var mismatches: [TrackMetadataEditableField] = []
        compare(title, actual.title, field: .title, into: &mismatches)
        compare(artist, actual.artist, field: .artist, into: &mismatches)
        compare(album, actual.album, field: .album, into: &mismatches)
        compare(albumArtist, actual.albumArtist, field: .albumArtist, into: &mismatches)
        compare(composer, actual.composer, field: .composer, into: &mismatches)
        compare(genre, actual.genre, field: .genre, into: &mismatches)
        compare(releaseDate, actual.releaseDate, field: .releaseDate, into: &mismatches)
        compare(trackNumber, actual.trackNumber, field: .trackNumber, into: &mismatches)
        compare(trackTotal, actual.trackTotal, field: .trackTotal, into: &mismatches)
        compare(discNumber, actual.discNumber, field: .discNumber, into: &mismatches)
        compare(discTotal, actual.discTotal, field: .discTotal, into: &mismatches)
        compare(bpm, actual.bpm, field: .bpm, into: &mismatches)
        compare(compilation, actual.compilation, field: .compilation, into: &mismatches)
        compare(comment, actual.comment, field: .comment, into: &mismatches)
        return mismatches
    }
}

private extension MetadataPatchValue {
    var isUnchanged: Bool {
        if case .unchanged = self { return true }
        return false
    }
}

private func compare<Value: Equatable>(
    _ patch: MetadataPatchValue<Value>,
    _ actual: Value?,
    field: TrackMetadataEditableField,
    into mismatches: inout [TrackMetadataEditableField]
) {
    let matches: Bool
    switch patch {
    case .unchanged:
        matches = true
    case .set(let expected):
        matches = actual == expected
    case .remove:
        matches = actual == nil
    }
    if !matches {
        mismatches.append(field)
    }
}
```

For compilation, call `compare(compilation, Optional(actual.compilation), ...)`; writers map a missing compilation tag to `false` when creating `TrackEditableTags`.

- [ ] **Step 4: Add aggregate field state and strict validation**

Implement:

```swift
struct BatchTextFieldState: Equatable, Sendable {
    private let initialText: String
    private let wasMixed: Bool
    private(set) var text: String
    private(set) var isDirty = false

    init(values: [String?]) {
        let normalized = values.map { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let first = normalized.first ?? nil
        wasMixed = normalized.dropFirst().contains { $0 != first }
        initialText = wasMixed ? "" : (first ?? "")
        text = initialText
    }

    var showsMixedPlaceholder: Bool {
        wasMixed && !isDirty && text.isEmpty
    }

    mutating func setText(_ newValue: String) {
        if wasMixed {
            isDirty = isDirty || newValue != text
        } else {
            isDirty = newValue != initialText
        }
        text = newValue
    }

    func stringPatch(multiline: Bool = false) -> MetadataPatchValue<String> {
        guard isDirty else { return .unchanged }
        let trimmed = text.trimmingCharacters(
            in: multiline ? .whitespacesAndNewlines : .whitespaces
        )
        return trimmed.isEmpty ? .remove : .set(trimmed)
    }
}

struct BatchCompilationState: Equatable, Sendable {
    private(set) var value: Bool?
    private(set) var isDirty = false

    init(values: [Bool]) {
        let first = values.first ?? false
        value = values.dropFirst().contains { $0 != first } ? nil : first
    }

    mutating func setValue(_ newValue: Bool) {
        value = newValue
        isDirty = true
    }

    var patch: MetadataPatchValue<Bool> {
        guard isDirty, let value else { return .unchanged }
        return .set(value)
    }
}
```

Implement `TrackMetadataEditForm` with a `BatchTextFieldState` for every field except compilation. Its initializer converts integer values to decimal text, `setText(_:for:)` switches over all text/number/date/comment fields, `setCompilation(_:)` updates the Boolean state, and `makePatch()`:

- trims single-line values with `.whitespaces`;
- trims only the outer whitespace/newlines of comments;
- accepts empty dirty numeric/date controls as `.remove`;
- parses integers with `Int`, requires values greater than zero, and returns `TrackMetadataValidationError` using the offending field;
- validates release date as exactly four ASCII digits or `yyyy-MM-dd`, with a POSIX `DateFormatter`, Gregorian calendar, UTC time zone, and `isLenient = false`;
- requires the formatted round trip to equal the input, so `2023-02-29` is rejected;
- emits the Boolean compilation patch directly.

Use this public surface:

```swift
struct TrackMetadataEditForm: Equatable, Sendable {
    var title: BatchTextFieldState
    var artist: BatchTextFieldState
    var album: BatchTextFieldState
    var albumArtist: BatchTextFieldState
    var composer: BatchTextFieldState
    var genre: BatchTextFieldState
    var releaseDate: BatchTextFieldState
    var trackNumber: BatchTextFieldState
    var trackTotal: BatchTextFieldState
    var discNumber: BatchTextFieldState
    var discTotal: BatchTextFieldState
    var bpm: BatchTextFieldState
    var compilation: BatchCompilationState
    var comment: BatchTextFieldState

    init(tags: [TrackEditableTags])
    mutating func setText(_ value: String, for field: TrackMetadataEditableField)
    mutating func setCompilation(_ value: Bool)
    func makePatch() throws -> TrackMetadataPatch
    var isDirty: Bool { get }
    func text(for field: TrackMetadataEditableField) -> String
    func showsMixedPlaceholder(for field: TrackMetadataEditableField) -> Bool
}
```

- [ ] **Step 5: Run the model test**

Run:

```bash
Scripts/test-track-metadata-edit-model.sh
```

Expected:

```text
Track metadata edit model checks passed
```

- [ ] **Step 6: Commit the model**

```bash
git add Core/Metadata/TrackMetadataEditModel.swift Scripts/test-track-metadata-edit-model.sh
git commit -m "feat(metadata): add batch edit patch model"
```

---

### Task 2: Read, Write, Reopen, and Verify Tags with SFBAudioEngine

**Files:**
- Create: `Core/Metadata/SFBTrackMetadataFileService.swift`
- Create: `Scripts/test-track-metadata-file-service.sh`

**Interfaces:**
- Produces actor `SFBTrackMetadataFileService`.
- `load(target:)` never mutates a file.
- `write(target:patch:)` rejects unsupported or non-writable files before mutation and returns only a reopened, verified snapshot.

- [ ] **Step 1: Write the failing source-regression check**

Create `Scripts/test-track-metadata-file-service.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="$ROOT_DIR/Core/Metadata/SFBTrackMetadataFileService.swift"

require_pattern() {
    local pattern="$1"
    local message="$2"
    if ! rg -n "$pattern" "$SERVICE" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

reject_pattern() {
    local pattern="$1"
    local message="$2"
    if rg -n "$pattern" "$SERVICE" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern 'actor SFBTrackMetadataFileService' 'Metadata file access must be actor-isolated.'
require_pattern 'static let writableExtensions: Set<String>' 'The writable extension allowlist is missing.'
require_pattern '"mp3".*"m4a".*"flac".*"wav"' 'The common writable formats are missing.'
require_pattern 'let metadata = audioFile.metadata' 'Writes must mutate the existing metadata object.'
require_pattern 'try audioFile.writeMetadata\\(\\)' 'The service must call SFBAudioEngine writeMetadata().'
require_pattern 'try loadSnapshot\\(target: target\\)' 'The service must reopen the file after writing.'
require_pattern 'patch.mismatchedFields\\(in: verified.tags\\)' 'The service must verify every dirty field.'
require_pattern 'func preflightWrite\\(' 'The service must preflight before playback is suspended.'
require_pattern 'startAccessingSecurityScopedResource' 'The service must honor sandbox security scope.'
require_pattern 'stopAccessingSecurityScopedResource' 'Security scope must be balanced.'
reject_pattern 'AudioMetadata\\(\\)' 'Replacing the whole metadata object can erase untouched tags.'

printf '%s\n' 'Track metadata file service checks passed'
```

Make it executable:

```bash
chmod +x Scripts/test-track-metadata-file-service.sh
```

- [ ] **Step 2: Run the check and verify the RED state**

Run:

```bash
Scripts/test-track-metadata-file-service.sh
```

Expected: exit 1 with `Metadata file access must be actor-isolated.`

- [ ] **Step 3: Add the actor, allowlist, and errors**

Create `Core/Metadata/SFBTrackMetadataFileService.swift`:

```swift
import Foundation
import SFBAudioEngine

enum TrackMetadataFileError: LocalizedError {
    case fileMissing(String)
    case unsupportedFormat(String)
    case fileNotWritable(String)
    case readFailed(String)
    case writeFailed(String)
    case verificationFailed([TrackMetadataEditableField])

    var errorDescription: String? {
        switch self {
        case .fileMissing(let name):
            return String(
                format: String(appLocalized: "The file “%1$@” no longer exists."),
                name
            )
        case .unsupportedFormat(let format):
            return String(
                format: String(appLocalized: "The %1$@ format is read-only."),
                format.uppercased()
            )
        case .fileNotWritable(let name):
            return String(
                format: String(appLocalized: "The file “%1$@” is not writable."),
                name
            )
        case .readFailed(let detail):
            return String(
                format: String(appLocalized: "Could not read tags: %1$@"),
                detail
            )
        case .writeFailed(let detail):
            return String(
                format: String(appLocalized: "Could not save tags: %1$@"),
                detail
            )
        case .verificationFailed(let fields):
            let names = fields.map(localizedMetadataFieldName).joined(separator: ", ")
            return String(
                format: String(appLocalized: "Saved tags could not be verified: %1$@"),
                names
            )
        }
    }

    var isPreflightSkip: Bool {
        switch self {
        case .fileMissing, .unsupportedFormat, .fileNotWritable:
            return true
        case .readFailed, .writeFailed, .verificationFailed:
            return false
        }
    }
}

private func localizedMetadataFieldName(
    _ field: TrackMetadataEditableField
) -> String {
    switch field {
    case .title: return String(appLocalized: "Title")
    case .artist: return String(appLocalized: "Artist")
    case .album: return String(appLocalized: "Album")
    case .albumArtist: return String(appLocalized: "Album Artist")
    case .composer: return String(appLocalized: "Composer")
    case .genre: return String(appLocalized: "Genre")
    case .releaseDate: return String(appLocalized: "Release Date")
    case .trackNumber: return String(appLocalized: "Track Number")
    case .trackTotal: return String(appLocalized: "Total Tracks")
    case .discNumber: return String(appLocalized: "Disc Number")
    case .discTotal: return String(appLocalized: "Total Discs")
    case .bpm: return String(appLocalized: "BPM")
    case .compilation: return String(appLocalized: "Compilation")
    case .comment: return String(appLocalized: "Comment")
    }
}

actor SFBTrackMetadataFileService {
    static let writableExtensions: Set<String> = [
        "mp3", "m4a", "flac", "wav", "aiff", "aif",
        "ogg", "oga", "opus", "spx", "ape", "mpc",
        "wv", "tta", "dsf", "dff"
    ]

    private let fileManager = FileManager.default

    func load(target: TrackMetadataEditTarget) -> TrackMetadataLoadResult {
        do {
            return .loaded(try loadSnapshot(target: target))
        } catch {
            return .unavailable(
                target: target,
                reason: error.localizedDescription
            )
        }
    }

    func preflightWrite(target: TrackMetadataEditTarget) throws {
        let didStartScope = target.url.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                target.url.stopAccessingSecurityScopedResource()
            }
        }
        try validateWritable(target)
        do {
            _ = try AudioFile(readingPropertiesAndMetadataFrom: target.url)
        } catch {
            throw TrackMetadataFileError.readFailed(error.localizedDescription)
        }
    }

    func write(
        target: TrackMetadataEditTarget,
        patch: TrackMetadataPatch
    ) throws -> TrackMetadataSnapshot {
        guard !patch.isEmpty else {
            return try loadSnapshot(target: target)
        }

        let didStartScope = target.url.startAccessingSecurityScopedResource()
        defer {
            if didStartScope {
                target.url.stopAccessingSecurityScopedResource()
            }
        }
        try validateWritable(target)

        let audioFile: AudioFile
        do {
            audioFile = try AudioFile(readingPropertiesAndMetadataFrom: target.url)
        } catch {
            throw TrackMetadataFileError.readFailed(error.localizedDescription)
        }

        let metadata = audioFile.metadata
        apply(patch.title, to: \.title, on: metadata)
        apply(patch.artist, to: \.artist, on: metadata)
        apply(patch.album, to: \.albumTitle, on: metadata)
        apply(patch.albumArtist, to: \.albumArtist, on: metadata)
        apply(patch.composer, to: \.composer, on: metadata)
        apply(patch.genre, to: \.genre, on: metadata)
        apply(patch.releaseDate, to: \.releaseDate, on: metadata)
        apply(patch.trackNumber, to: \.trackNumber, on: metadata)
        apply(patch.trackTotal, to: \.trackTotal, on: metadata)
        apply(patch.discNumber, to: \.discNumber, on: metadata)
        apply(patch.discTotal, to: \.discTotal, on: metadata)
        apply(patch.bpm, to: \.bpm, on: metadata)
        apply(patch.compilation, to: \.isCompilation, on: metadata)
        apply(patch.comment, to: \.comment, on: metadata)

        do {
            try audioFile.writeMetadata()
        } catch {
            throw TrackMetadataFileError.writeFailed(error.localizedDescription)
        }

        let verified = try loadSnapshot(target: target)
        let mismatches = patch.mismatchedFields(in: verified.tags)
        guard mismatches.isEmpty else {
            throw TrackMetadataFileError.verificationFailed(mismatches)
        }
        return verified
    }
}
```

Use a generic helper whose key path has type `ReferenceWritableKeyPath<AudioMetadata, Value?>`:

```swift
private func apply<Value>(
    _ patch: MetadataPatchValue<Value>,
    to keyPath: ReferenceWritableKeyPath<AudioMetadata, Value?>,
    on metadata: AudioMetadata
) {
    switch patch {
    case .unchanged:
        break
    case .set(let value):
        metadata[keyPath: keyPath] = value
    case .remove:
        metadata[keyPath: keyPath] = nil
    }
}
```

- [ ] **Step 4: Implement fresh snapshot loading**

`loadSnapshot(target:)` must:

1. check file existence;
2. balance `startAccessingSecurityScopedResource()` if it returns `true`;
3. open `AudioFile(readingPropertiesAndMetadataFrom:)`;
4. build `TrackEditableTags` directly from `audioFile.metadata`, mapping `isCompilation ?? false`;
5. build file info from the URL, extension, resource file size, and `audioFile.properties.duration`;
6. set `isWritable` only when the extension is allowlisted and `FileManager.isWritableFile(atPath:)` is true;
7. provide a read-only reason for unsupported or permission-denied files.

Use a single `validateWritable(_:)` before any mutation:

```swift
private func validateWritable(_ target: TrackMetadataEditTarget) throws {
    guard fileManager.fileExists(atPath: target.url.path) else {
        throw TrackMetadataFileError.fileMissing(target.displayName)
    }
    let format = target.url.pathExtension.lowercased()
    guard Self.writableExtensions.contains(format) else {
        throw TrackMetadataFileError.unsupportedFormat(format)
    }
    guard fileManager.isWritableFile(atPath: target.url.path) else {
        throw TrackMetadataFileError.fileNotWritable(target.displayName)
    }
}
```

Normalize all reopened string values with `TrackEditableTags.normalized()`. Do not normalize case or internal whitespace because verification must detect a writer changing a requested value.

- [ ] **Step 5: Run focused checks and build**

Run:

```bash
Scripts/test-track-metadata-edit-model.sh
Scripts/test-track-metadata-file-service.sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: both scripts print their pass messages and `xcodebuild` ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit the file service**

```bash
git add Core/Metadata/SFBTrackMetadataFileService.swift Scripts/test-track-metadata-file-service.sh
git commit -m "feat(metadata): write and verify audio tags"
```

---

### Task 3: Reindex a Verified File Without Rescanning Its Folder

**Files:**
- Create: `Managers/Database/DMTrackMetadataEditing.swift`
- Create: `Scripts/test-track-metadata-reindex.sh`
- Modify: `Managers/Database/DMTrackProcessing.swift:147`
- Modify: `Managers/Database/DMTrackProcessing.swift:332-359`

**Interfaces:**
- Produces `TrackMetadataReindexResult`.
- Consumes only a verified `TrackMetadataSnapshot`.
- Updates one track row, normalized album/artist/genre records, FTS through the existing trigger, and duplicate groups for the old and new duplicate keys.

- [ ] **Step 1: Write the failing source-regression check**

Create `Scripts/test-track-metadata-reindex.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REINDEX="$ROOT_DIR/Managers/Database/DMTrackMetadataEditing.swift"
PROCESSING="$ROOT_DIR/Managers/Database/DMTrackProcessing.swift"

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

require_pattern "$REINDEX" 'func reindexEditedTrack\\(' 'The verified-track reindex entry point is missing.'
require_pattern "$REINDEX" 'verified.tags' 'The database must consume verified file values.'
require_pattern "$REINDEX" 'track.albumId = nil' 'Old album association must be cleared before rebuilding.'
require_pattern "$REINDEX" 'try processUpdatedTrack\\(' 'Normalized relations must use the existing update path.'
require_pattern "$REINDEX" 'refreshDuplicateGroups\\(' 'Only affected duplicate groups must be refreshed.'
require_pattern "$REINDEX" 'pruneOrphanedMetadata\\(' 'Old normalized parents must be pruned.'
reject_pattern "$REINDEX" 'scan|processFilesInBatches|refreshFolder' 'Metadata saving must not rescan a folder.'
reject_pattern "$PROCESSING" 'processUpdatedTrack\\([^\\n]*metadata:' 'The unused metadata parameter must be removed.'

printf '%s\n' 'Track metadata reindex checks passed'
```

Make it executable:

```bash
chmod +x Scripts/test-track-metadata-reindex.sh
```

- [ ] **Step 2: Run the check and verify the RED state**

Run:

```bash
Scripts/test-track-metadata-reindex.sh
```

Expected: exit 1 with `The verified-track reindex entry point is missing.`

- [ ] **Step 3: Remove the unused scan-metadata parameter**

Change the scan caller to:

```swift
try self.processUpdatedTrack(track, in: db, cache: cache)
```

Change the helper declaration to internal extension scope:

```swift
func processUpdatedTrack(
    _ track: FullTrack,
    in db: Database,
    cache: ScanLookupCache? = nil
) throws {
```

Keep its existing album update, row update, junction deletion, and relation rebuild body unchanged.

- [ ] **Step 4: Add authoritative verified-value mapping**

Create `Managers/Database/DMTrackMetadataEditing.swift`:

```swift
import Foundation
import GRDB

struct TrackMetadataReindexResult {
    let track: Track
    let fullTrack: FullTrack
}

extension DatabaseManager {
    func reindexEditedTrack(
        target: TrackMetadataEditTarget,
        verified: TrackMetadataSnapshot
    ) async throws -> TrackMetadataReindexResult {
        try await dbQueue.write { db in
            let request: QueryInterfaceRequest<FullTrack>
            if let trackID = target.trackID {
                request = FullTrack.filter(FullTrack.Columns.trackId == trackID)
            } else {
                request = FullTrack.filter(FullTrack.Columns.path == target.url.path)
            }

            guard var track = try request.fetchOne(db) else {
                throw DatabaseError.invalidTrackId
            }

            let oldDuplicateKey = track.duplicateKey
            let oldAlbumID = track.albumId
            let oldArtistIDs = try Int64.fetchAll(
                db,
                TrackArtist
                    .filter(TrackArtist.Columns.trackId == track.trackId)
                    .select(TrackArtist.Columns.artistId)
            )
            let oldGenreIDs = try Int64.fetchAll(
                db,
                TrackGenre
                    .filter(TrackGenre.Columns.trackId == track.trackId)
                    .select(TrackGenre.Columns.genreId)
            )

            applyVerifiedEditableTags(verified.tags, to: &track)
            track.albumId = nil
            if let values = try? target.url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ) {
                track.fileSize = values.fileSize.map(Int64.init)
                track.dateModified = values.contentModificationDate
            }

            try processUpdatedTrack(track, in: db)
            guard let trackID = track.trackId,
                  let updated = try FullTrack
                    .filter(FullTrack.Columns.trackId == trackID)
                    .fetchOne(db),
                  let lightweight = try Track
                    .select(Track.lightweightSelection)
                    .filter(Track.Columns.trackId == trackID)
                    .fetchOne(db) else {
                throw DatabaseError.invalidTrackId
            }

            try refreshDuplicateGroups(
                keys: Set([oldDuplicateKey, updated.duplicateKey]),
                in: db
            )
            try pruneOrphanedMetadata(
                albumIDs: Set([oldAlbumID].compactMap { $0 }),
                artistIDs: Set(oldArtistIDs),
                genreIDs: Set(oldGenreIDs),
                in: db
            )

            let finalTrack = try Track
                .select(Track.lightweightSelection)
                .filter(Track.Columns.trackId == trackID)
                .fetchOne(db) ?? lightweight
            let finalFullTrack = try FullTrack
                .filter(FullTrack.Columns.trackId == trackID)
                .fetchOne(db) ?? updated
            return TrackMetadataReindexResult(
                track: finalTrack,
                fullTrack: finalFullTrack
            )
        }
    }
}
```

`applyVerifiedEditableTags` must assign every edited field authoritatively, including removals:

```swift
private func applyVerifiedEditableTags(
    _ tags: TrackEditableTags,
    to track: inout FullTrack
) {
    let values = tags.normalized()
    track.title = values.title ?? track.url.deletingPathExtension().lastPathComponent
    track.artist = values.artist ?? "Unknown Artist"
    track.album = values.album ?? "Unknown Album"
    track.albumArtist = values.albumArtist
    track.composer = values.composer ?? "Unknown Composer"
    track.genre = values.genre ?? "Unknown Genre"
    track.releaseDate = values.releaseDate
    track.year = values.releaseDate.flatMap(MetadataMapping.year(fromDateString:)) ?? ""
    track.trackNumber = values.trackNumber
    track.totalTracks = values.trackTotal
    track.discNumber = values.discNumber
    track.totalDiscs = values.discTotal
    track.bpm = values.bpm
    track.compilation = values.compilation
    var extended = track.extendedMetadata ?? ExtendedMetadata()
    extended.comment = values.comment
    track.extendedMetadata = extended
}
```

- [ ] **Step 5: Refresh only old/new duplicate groups and prune old parents**

Add private locked helpers in `DMTrackMetadataEditing.swift`:

- `refreshDuplicateGroups(keys: Set<String>, in db: Database)` fetches lightweight tracks once, filters to the supplied keys, clears duplicate flags for those members, batch-fetches their `FullTrack` rows, sorts each group by `qualityScore`, and reapplies the existing primary/group semantics only when a group contains more than one member.
- `pruneOrphanedMetadata(albumIDs:artistIDs:genreIDs:in:)` deletes only supplied IDs whose rows are no longer referenced by tracks or junction records. An artist must be retained if either `track_artists` or `album_artists` still references it.

Use GRDB expressions rather than string interpolation for IDs. All operations remain inside the same `dbQueue.write` transaction as the track update.

- [ ] **Step 6: Run focused checks and build**

Run:

```bash
Scripts/test-track-metadata-edit-model.sh
Scripts/test-track-metadata-file-service.sh
Scripts/test-track-metadata-reindex.sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: all scripts pass and the build succeeds.

- [ ] **Step 7: Commit the reindex path**

```bash
git add Managers/Database/DMTrackMetadataEditing.swift Managers/Database/DMTrackProcessing.swift Scripts/test-track-metadata-reindex.sh
git commit -m "feat(metadata): reindex verified tag edits"
```

---

### Task 4: Preserve Playback and Refresh Every In-Memory Track Consumer

**Files:**
- Create: `Managers/Library/LMTrackMetadataEditing.swift`
- Create: `Scripts/test-track-metadata-playback-restore.sh`
- Modify: `Managers/PlaybackManager.swift:75-95`
- Modify: `Managers/PlaybackManager.swift:319-380`
- Modify: `Managers/PlaybackManager.swift:663-701`
- Modify: `Managers/PlaybackManager.swift:1041-1072`
- Modify: `Managers/Playlist/PMTrackUpdate.swift:84-99`
- Modify: `Managers/Playlist/PMPlayback.swift:190-199`
- Modify: `Managers/Library/LMLibrary.swift:146-154`

**Interfaces:**
- Produces `MetadataEditPlaybackSnapshot`, `prepareCurrentTrackForMetadataEdit(_:)`, and `restoreCurrentTrackAfterMetadataEdit(_:track:fullTrack:)`.
- Replaces edited tracks in library arrays, queue entries, loaded playlists, current playback, and smart-playlist results.

- [ ] **Step 1: Write the failing playback and cache regression check**

Create `Scripts/test-track-metadata-playback-restore.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLAYBACK="$ROOT_DIR/Managers/PlaybackManager.swift"
PLAYLIST="$ROOT_DIR/Managers/Playlist/PMTrackUpdate.swift"
LIBRARY="$ROOT_DIR/Managers/Library/LMTrackMetadataEditing.swift"

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! rg -n "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern "$PLAYBACK" 'struct MetadataEditPlaybackSnapshot' 'Playback metadata snapshot is missing.'
require_pattern "$PLAYBACK" 'let queueIndex: Int' 'The snapshot must preserve queue position.'
require_pattern "$PLAYBACK" 'func prepareCurrentTrackForMetadataEdit' 'Playback preparation is missing.'
require_pattern "$PLAYBACK" 'func restoreCurrentTrackAfterMetadataEdit' 'Playback restoration is missing.'
require_pattern "$PLAYBACK" 'shouldResume: Bool' 'Deferred restoration must distinguish playing from paused.'
require_pattern "$PLAYBACK" 'if pending.shouldResume' 'Paused restoration must not resume.'
require_pattern "$PLAYBACK" 'seekToPosition > 0 \\|\\| !resumeAfterRestore' 'A paused track at zero must remain paused.'
require_pattern "$PLAYBACK" 'restoreQueueIndexAfterMetadataEdit\\(snapshot.queueIndex\\)' 'The queue index must be restored through PlaylistManager.'
require_pattern "$PLAYBACK" 'currentArtworkIdentity = nil' 'Album changes must invalidate current artwork identity.'
require_pattern "$PLAYBACK" 'metadataRestoreCompletion' 'Playback restoration must report its terminal result.'
require_pattern "$PLAYLIST" 'func applyMetadataEditResult' 'Queue and playlist cache replacement is missing.'
require_pattern "$PLAYLIST" 'playlists\\[playlistIndex\\]\\.tracks\\[trackIndex\\]\\.trackId' 'Loaded playlist tracks must be replaced by ID.'
require_pattern "$LIBRARY" 'func applyMetadataEditResult' 'Library cache replacement is missing.'
require_pattern "$LIBRARY" 'refreshLibraryCategories\\(\\)' 'Metadata categories must refresh.'
require_pattern "$LIBRARY" 'refreshEntities\\(\\)' 'Album and artist entities must refresh.'

printf '%s\n' 'Track metadata playback restore checks passed'
```

Make it executable:

```bash
chmod +x Scripts/test-track-metadata-playback-restore.sh
```

- [ ] **Step 2: Run the check and verify the RED state**

Run:

```bash
Scripts/test-track-metadata-playback-restore.sh
```

Expected: exit 1 with `Playback metadata snapshot is missing.`

- [ ] **Step 3: Generalize deferred seek restoration**

Replace `pendingRestoreResume` with:

```swift
private struct PendingPlaybackRestore {
    let entryId: AudioEntryId
    let position: Double
    let shouldResume: Bool
}

private var pendingPlaybackRestore: PendingPlaybackRestore?
```

Change `startPlayback` to accept an explicit restored-state intent:

```swift
private func startPlayback(
    of fullTrack: FullTrack,
    lightweightTrack: Track,
    resumeAfterRestore: Bool = true
) {
```

When `seekToPosition > 0 || !resumeAfterRestore`, start the engine paused and assign:

```swift
pendingPlaybackRestore = PendingPlaybackRestore(
    entryId: entryId,
    position: seekToPosition,
    shouldResume: resumeAfterRestore
)
```

In `audioPlayerStateChanged`, after a successful deferred seek:

```swift
if pending.shouldResume {
    self.wantsPlaybackActive = true
    self.audioPlayer.resume()
    Logger.info("Resumed restored playback from \(pending.position)s")
} else {
    self.wantsPlaybackActive = false
    self.updateNowPlayingInfo()
    Logger.info("Restored paused playback at \(pending.position)s")
}
```

On seek failure, restart from zero only when `shouldResume` is true; otherwise stay paused at zero. Rename all existing `pendingRestoreResume` resets and reads to `pendingPlaybackRestore`. Existing normal restoration calls use the default `resumeAfterRestore: true`.

This explicit `|| !resumeAfterRestore` branch is required for a track paused at exactly zero seconds; the old zero-position fast path starts playback and would violate the requested paused-state restoration.

- [ ] **Step 4: Add metadata-edit playback snapshot and restoration**

Inside `PlaybackManager`, add:

```swift
enum MetadataPlaybackRestoreError: LocalizedError {
    case missingTrackData
    case seekFailed
    case timedOut
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .missingTrackData:
            return String(appLocalized: "Playback could not be restored because track data is missing.")
        case .seekFailed:
            return String(appLocalized: "Playback resumed, but its saved position could not be restored.")
        case .timedOut:
            return String(appLocalized: "Playback restoration timed out.")
        case .engine(let detail):
            return String(
                format: String(appLocalized: "Playback could not be restored: %1$@"),
                detail
            )
        }
    }
}

struct MetadataEditPlaybackSnapshot {
    let track: Track
    let fullTrack: FullTrack?
    let position: Double
    let wasPlaying: Bool
    let wasEngineActive: Bool
    let queueIndex: Int
    let restoredPosition: Double
}
```

Implement `prepareCurrentTrackForMetadataEdit(_:)` using the safe-stop sequence from `prepareCurrentTrackForTrashMove`, but do not remove the track or advance the queue. Capture `playlistManager.currentQueueIndex`, clear gapless lookahead, stop the engine, retain the displayed track/time, and return `nil` when the target is not current.

Implement:

```swift
func restoreCurrentTrackAfterMetadataEdit(
    _ snapshot: MetadataEditPlaybackSnapshot?,
    track updatedTrack: Track?,
    fullTrack updatedFullTrack: FullTrack?,
    completion: @escaping (Result<Void, MetadataPlaybackRestoreError>) -> Void
) {
    guard let snapshot else {
        completion(.success(()))
        return
    }
    let track = updatedTrack ?? snapshot.track
    let fullTrack = updatedFullTrack ?? snapshot.fullTrack

    pendingPlaybackRestore = nil
    pendingNext = nil
    pendingNextWasSkipped = false
    trackForEntry.removeAll()
    currentEntryId = nil
    wantsPlaybackActive = false
    playlistManager.restoreQueueIndexAfterMetadataEdit(snapshot.queueIndex)
    currentArtworkIdentity = nil
    currentTrack = track
    currentFullTrack = fullTrack
    let duration = HelperUtils.sanitizedDuration(fullTrack?.duration ?? 0)
    let restoredTime = duration > 0
        ? min(max(snapshot.position, 0), duration)
        : max(snapshot.position, 0)
    currentTime = restoredTime
    resetProgressResolution(engineProgress: restoredTime)
    restoredPosition = restoredTime
    isPlaying = false
    stopStateSaveTimer()

    guard snapshot.wasEngineActive else {
        updateNowPlayingInfo()
        completion(.success(()))
        return
    }
    guard let fullTrack else {
        completion(.failure(.missingTrackData))
        return
    }

    metadataRestoreCompletion = completion
    startPlayback(
        of: fullTrack,
        lightweightTrack: track,
        resumeAfterRestore: snapshot.wasPlaying
    )
}
```

Capture `wasEngineActive = wasPlaying || audioPlayer.state == .paused`. For a stopped current track, do not open the engine. This preserves the design's stopped-state rule in addition to the requested playing/paused behavior.

Add a one-shot metadata-restoration completion handler to `PlaybackManager`:

```swift
private var metadataRestoreCompletion:
    ((Result<Void, MetadataPlaybackRestoreError>) -> Void)?
```

`restoreCurrentTrackAfterMetadataEdit` accepts a `completion` closure. Resolve it with success after the requested playing or paused state and seek have been observed; resolve stopped restoration immediately. Resolve it with failure from `audioPlayerUnexpectedError`, when an active snapshot has no readable `FullTrack`, or when a five-second `Task.sleep` timeout expires. Clear the stored closure before invoking it so an engine callback cannot complete twice.

The editor view model publishes a failure separately as `playbackRestorationError`; it must not relabel an already verified file write as failed. Track `isAwaitingPlaybackRestoration` and defer automatic all-success dismissal until both the file loop and this completion callback are terminal.

Keep `PlaylistManager` authoritative for its queue index by adding this narrow helper beside `advanceQueueIndex(to:)` in `PMPlayback.swift`:

```swift
func restoreQueueIndexAfterMetadataEdit(_ index: Int) {
    guard currentQueue.indices.contains(index) else { return }
    currentQueueIndex = index
}
```

- [ ] **Step 5: Add targeted library and playlist cache replacement**

Create `Managers/Library/LMTrackMetadataEditing.swift`:

```swift
import Foundation

extension LibraryManager {
    @MainActor
    func applyMetadataEditResult(_ track: Track) {
        tracks = Self.replacingTrack(track, in: tracks)
        discoverTracks = Self.replacingTrack(track, in: discoverTracks)
        searchResults = Self.replacingTrack(track, in: searchResults)
    }

    @MainActor
    func finishMetadataEditRefresh() {
        updateSearchResults()
        refreshLibraryCategories()
        refreshEntities(notify: false)
        NotificationCenter.default.post(name: .libraryDataDidChange, object: nil)
    }

    private static func replacingTrack(_ track: Track, in values: [Track]) -> [Track] {
        values.map { value in
            value.trackId == track.trackId ? track : value
        }
    }
}
```

Change the existing entity refresh signature in `LMLibrary.swift` without changing its current callers:

```swift
func refreshEntities(notify: Bool = true) {
    entitiesLoaded = false
    cachedArtistEntities = databaseManager.getArtistEntities()
    cachedAlbumEntities = databaseManager.getAlbumEntities()
    entitiesLoaded = true
    updateTotalCounts(notify: notify)
    Logger.info(
        "Refreshed entities: \(cachedArtistEntities.count) artists and \(cachedAlbumEntities.count) albums"
    )
    objectWillChange.send()
}
```

Replace `handleTrackPropertyUpdate` with a synchronous main-actor cache helper while retaining a compatibility wrapper if callers still need the old async name:

```swift
func applyMetadataEditResult(_ track: Track) {
    for index in currentQueue.indices where currentQueue[index].trackId == track.trackId {
        currentQueue[index] = track
    }
    for playlistIndex in playlists.indices {
        for trackIndex in playlists[playlistIndex].tracks.indices
        where playlists[playlistIndex].tracks[trackIndex].trackId == track.trackId {
            playlists[playlistIndex].tracks[trackIndex] = track
        }
    }
    if audioPlayer?.currentTrack?.trackId == track.trackId {
        audioPlayer?.currentTrack = track
    }
}

func finishMetadataEditRefresh() {
    updateSmartPlaylists()
}
```

Do not rewrite regular `.m3u` playlist files because metadata edits do not change membership or paths.

- [ ] **Step 6: Run focused checks and existing playback regressions**

Run:

```bash
Scripts/test-track-metadata-playback-restore.sh
for script in Scripts/test-*playback*.sh; do
    "$script"
done
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: the new check and all existing playback checks pass; build succeeds.

- [ ] **Step 7: Commit playback and cache integration**

```bash
git add Managers/PlaybackManager.swift Managers/Playlist/PMTrackUpdate.swift Managers/Playlist/PMPlayback.swift Managers/Library/LMTrackMetadataEditing.swift Managers/Library/LMLibrary.swift Scripts/test-track-metadata-playback-restore.sh
git commit -m "feat(metadata): preserve playback across tag writes"
```

---

### Task 5: Orchestrate Loading, Sequential Saving, Partial Failure, and Retry

**Files:**
- Create: `Managers/TrackMetadataEditorViewModel.swift`
- Create: `Scripts/test-track-metadata-editor-orchestration.sh`

**Interfaces:**
- Produces `TrackMetadataEditorRequest`, `TrackMetadataEditorViewModel`, load/save phases, progress, and per-file outcomes.
- Owns the only file-save loop.
- Processes the current track first, restores it immediately, and continues the remaining files.

- [ ] **Step 1: Write the failing orchestration check**

Create `Scripts/test-track-metadata-editor-orchestration.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="$ROOT_DIR/Managers/TrackMetadataEditorViewModel.swift"

require_pattern() {
    local pattern="$1"
    local message="$2"
    if ! rg -n "$pattern" "$MODEL" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern '@MainActor.*TrackMetadataEditorViewModel|@MainActor' 'The editor view model must be main-actor isolated.'
require_pattern 'case loading|case editing|case saving|case results' 'All editor phases must be explicit.'
require_pattern 'func load\\(\\)' 'Fresh file-tag loading is missing.'
require_pattern 'func save\\(' 'The save entry point is missing.'
require_pattern 'currentTrack.*sorted|prioritizedTargets' 'The current track must be processed first.'
require_pattern 'for .* in .*targets' 'File writes must be sequential.'
require_pattern 'prepareCurrentTrackForMetadataEdit' 'Current playback must be suspended before its write.'
require_pattern 'restoreCurrentTrackAfterMetadataEdit' 'Current playback must be restored after its write.'
require_pattern 'func retryFailed\\(' 'Failed-only retry is missing.'
require_pattern 'applyMetadataEditResult' 'Successful writes must update in-memory consumers.'
require_pattern 'finishMetadataEditRefresh' 'Batch cache refresh must be coalesced.'

printf '%s\n' 'Track metadata editor orchestration checks passed'
```

Make it executable:

```bash
chmod +x Scripts/test-track-metadata-editor-orchestration.sh
```

- [ ] **Step 2: Run the check and verify the RED state**

Run:

```bash
Scripts/test-track-metadata-editor-orchestration.sh
```

Expected: exit 1 with `The editor view model must be main-actor isolated.`

- [ ] **Step 3: Add request, phase, progress, and result types**

Create `Managers/TrackMetadataEditorViewModel.swift` with:

```swift
import Foundation

struct TrackMetadataEditorRequest: Identifiable {
    let id = UUID()
    let tracks: [Track]
}

enum TrackMetadataEditorPhase: Equatable {
    case loading
    case editing
    case saving
    case results
}

@MainActor
final class TrackMetadataEditorViewModel: ObservableObject {
    @Published private(set) var phase: TrackMetadataEditorPhase = .loading
    @Published private(set) var snapshots: [TrackMetadataSnapshot] = []
    @Published private(set) var unavailableResults: [TrackMetadataBatchResult] = []
    @Published private(set) var saveResults: [TrackMetadataBatchResult] = []
    @Published private(set) var currentProgress = 0
    @Published private(set) var totalProgress = 0
    @Published private(set) var validationError: TrackMetadataValidationError?
    @Published private(set) var playbackRestorationError: String?
    @Published private(set) var allSelectedItemsSaved = false
    @Published private(set) var form: TrackMetadataEditForm?

    let tracks: [Track]
    private let fileService: SFBTrackMetadataFileService

    init(
        tracks: [Track],
        fileService: SFBTrackMetadataFileService = SFBTrackMetadataFileService()
    ) {
        self.tracks = tracks
        self.fileService = fileService
    }
}
```

Expose `text(for:)`, `showsMixedPlaceholder(for:)`, `setText(_:for:)`, `compilationValue`, and `setCompilation(_:)` methods so SwiftUI never mutates `form` around the view model. Each edit recomputes and publishes `validationError`; `canSave` is true only in `.editing`, with a dirty valid form and at least one writable snapshot.

- [ ] **Step 4: Load every selected file directly**

`load()` starts one task, creates targets from the original `Track` array, calls `await fileService.load(target:)`, preserves selection order, separates loaded and unavailable results, builds `TrackMetadataEditForm` from all successfully loaded tag snapshots, and switches to `.editing`.

Do not initialize form fields from `Track` or `FullTrack`. Unsupported formats still return a loaded read-only snapshot, so their values participate in the visible aggregate while only writable snapshots enter the save loop.

- [ ] **Step 5: Add the sequential save transaction**

Use:

```swift
func save(
    libraryManager: LibraryManager,
    playlistManager: PlaylistManager,
    playbackManager: PlaybackManager
) {
    guard phase == .editing, let form else { return }
    do {
        let patch = try form.makePatch()
        validationError = nil
        let writable = snapshots.filter(\.isWritable)
        beginSave(
            targets: writable.map(\.target),
            patch: patch,
            libraryManager: libraryManager,
            playlistManager: playlistManager,
            playbackManager: playbackManager
        )
    } catch let error as TrackMetadataValidationError {
        validationError = error
    } catch {
        Logger.error("Unexpected metadata validation error: \(error)")
    }
}
```

`beginSave` launches a `Task`, moves the current track to the front with `prioritizedTargets`, then uses a normal `for target in targets` loop. For each target:

1. Call `try await fileService.preflightWrite(target:)`; classify a preflight skip and continue without touching playback.
2. If it is the current track, call `prepareCurrentTrackForMetadataEdit` immediately before writing.
3. Call `try await fileService.write(target:patch:)`, which repeats the preflight to close the time-of-check/time-of-use gap.
4. Call `try await libraryManager.databaseManager.reindexEditedTrack(target:verified:)`.
5. Apply the returned `Track` to `LibraryManager` and `PlaylistManager`.
6. If playback was suspended, restore immediately with the returned `Track` and `FullTrack`.
7. Append `.saved` and advance progress.
8. On a `TrackMetadataFileError` whose `isPreflightSkip` is true, restore the original playback snapshot only when one was already taken, append `.skipped(error.localizedDescription)`, and continue.
9. On any write, verification, or reindex error, restore the original playback snapshot, append `.failed(error.localizedDescription)`, and continue.

Use `defer` or an explicit post-loop guard so an unexpected task path cannot leave a current track suspended. After the loop, call each manager's `finishMetadataEditRefresh()` once. Merge preflight unavailable items as `.skipped`, switch to `.results` if anything was skipped/failed, and return to a clean `.editing` baseline or notify the sheet to dismiss when every selected item saved.

Pass the playback completion closure described in Task 4 on both the success and error restoration paths. It clears `isAwaitingPlaybackRestoration` and records any failure in `playbackRestorationError`, while leaving the file's saved/skipped/failed outcome unchanged. A shared `finalizeBatchIfPossible()` sets `allSelectedItemsSaved = true` only after the file loop and playback restoration are both terminal, every original target has a `.saved` outcome, and no playback restoration error was reported.

Do not run file writes in a task group.

- [ ] **Step 6: Add failed-only retry and clean baselines**

After a partial result:

- derive `retryTargets` with `TrackMetadataBatchResult.retryTargets(from:)`;
- replace successful snapshots with their reopened verified snapshots;
- rebuild `form` from the new snapshots so successful files are clean;
- keep the same patch separately as `retryPatch` for failed-only retry;
- `retryFailed(...)` invokes the same sequential save helper with `retryTargets` and `retryPatch`;
- never retry `.skipped` unsupported/missing/read-only entries automatically.

Expose these computed values:

```swift
var savedCount: Int { get }
var skippedCount: Int { get }
var failedCount: Int { get }
var hasFailuresToRetry: Bool { get }
var isBusy: Bool { phase == .loading || phase == .saving }
```

- [ ] **Step 7: Run focused checks and build**

Run:

```bash
Scripts/test-track-metadata-editor-orchestration.sh
Scripts/test-track-metadata-edit-model.sh
Scripts/test-track-metadata-playback-restore.sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: all checks pass and the build succeeds.

- [ ] **Step 8: Commit orchestration**

```bash
git add Managers/TrackMetadataEditorViewModel.swift Scripts/test-track-metadata-editor-orchestration.sh
git commit -m "feat(metadata): orchestrate batch tag editing"
```

---

### Task 6: Build the Compact macOS Metadata Editor Sheet

**Files:**
- Create: `Views/Library/Sheets/TrackMetadataEditorSheet.swift`
- Create: `Views/Components/MixedStateCheckbox.swift`
- Create: `Scripts/test-track-metadata-editor-ui.sh`

**Interfaces:**
- Consumes `TrackMetadataEditorViewModel`.
- Shows read-only file information, all first-release tag fields, mixed placeholders, validation, progress, and per-file results.
- Prevents dismissal during active writes.

- [ ] **Step 1: Write the failing UI source check**

Create `Scripts/test-track-metadata-editor-ui.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHEET="$ROOT_DIR/Views/Library/Sheets/TrackMetadataEditorSheet.swift"
CHECKBOX="$ROOT_DIR/Views/Components/MixedStateCheckbox.swift"

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! rg -n "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern "$SHEET" 'struct TrackMetadataEditorSheet: View' 'Metadata editor sheet is missing.'
require_pattern "$SHEET" '"File Information"' 'Read-only file information group is missing.'
require_pattern "$SHEET" '"Tag Information"' 'Editable tag information group is missing.'
for field in title artist album albumArtist composer genre releaseDate trackNumber trackTotal discNumber discTotal bpm comment; do
    require_pattern "$SHEET" "\\.$field" "The $field editor is missing."
done
require_pattern "$SHEET" '"Multiple Values"' 'Mixed-value placeholder is missing.'
require_pattern "$SHEET" 'interactiveDismissDisabled.*phase.*saving|interactiveDismissDisabled\\(model.isBusy\\)' 'Save-time dismissal must be disabled.'
require_pattern "$SHEET" 'ProgressView' 'Batch save progress is missing.'
require_pattern "$SHEET" 'retryFailed' 'Failed-only retry action is missing.'
require_pattern "$CHECKBOX" 'NSViewRepresentable' 'Compilation control must bridge an AppKit tri-state checkbox.'
require_pattern "$CHECKBOX" 'allowsMixedState = true' 'Compilation checkbox must allow a mixed state.'

printf '%s\n' 'Track metadata editor UI checks passed'
```

Make it executable:

```bash
chmod +x Scripts/test-track-metadata-editor-ui.sh
```

- [ ] **Step 2: Run the check and verify the RED state**

Run:

```bash
Scripts/test-track-metadata-editor-ui.sh
```

Expected: exit 1 with `Metadata editor sheet is missing.`

- [ ] **Step 3: Add the AppKit tri-state checkbox**

Create `Views/Components/MixedStateCheckbox.swift`:

```swift
import AppKit
import SwiftUI

struct MixedStateCheckbox: NSViewRepresentable {
    let title: String
    let value: Bool?
    let isEnabled: Bool
    let onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: title,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        button.allowsMixedState = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.isEnabled = isEnabled
        button.state = value.map { $0 ? .on : .off } ?? .mixed
        context.coordinator.onChange = onChange
    }

    final class Coordinator: NSObject {
        var onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
        }

        @objc func changed(_ sender: NSButton) {
            if sender.state == .mixed {
                sender.state = .on
            }
            onChange(sender.state == .on)
        }
    }
}
```

- [ ] **Step 4: Add the editor shell and phase presentation**

Create `Views/Library/Sheets/TrackMetadataEditorSheet.swift` with:

```swift
import SwiftUI

struct TrackMetadataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playlistManager: PlaylistManager
    @EnvironmentObject private var playbackManager: PlaybackManager
    @StateObject private var model: TrackMetadataEditorViewModel

    init(request: TrackMetadataEditorRequest) {
        _model = StateObject(
            wrappedValue: TrackMetadataEditorViewModel(tracks: request.tracks)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 660, idealWidth: 720, minHeight: 520, idealHeight: 620)
        .interactiveDismissDisabled(model.phase == .saving)
        .task {
            model.load()
        }
    }
}
```

The header title is localized `Track Info` for one file and a positional-format `Track Info (%1$lld Tracks)` for multiple files. The close control is disabled in `.saving`.

Switch `content` over the four phases:

- `.loading`: centered `ProgressView` and `Reading Tags...`;
- `.editing`: `ScrollView` containing `File Information` and `Tag Information`;
- `.saving`: the same form disabled, plus deterministic progress `currentProgress / totalProgress`;
- `.results`: summary counts and one compact row per skipped/failed file with filename and reason.

- [ ] **Step 5: Implement file information and all editable rows**

The file-information section shows:

- one file: filename, full path, uppercased format, duration, and file size;
- many files: selected count plus aggregated filename/path/format/duration/file size;
- a common value normally and differing values as localized `Multiple Values`;
- read-only reason rows for unavailable or read-only items.

The tag form uses a two-column `Grid` and a reusable row:

```swift
private func textRow(
    _ label: String,
    field: TrackMetadataEditableField,
    prompt: String? = nil
) -> some View {
    GridRow {
        Text(String(appLocalized: label))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
        TextField(
            "",
            text: Binding(
                get: { model.text(for: field) },
                set: { model.setText($0, for: field) }
            ),
            prompt: Text(
                model.showsMixedPlaceholder(for: field)
                    ? String(appLocalized: "Multiple Values")
                    : (prompt ?? "")
            )
        )
    }
}
```

Render title, artist, album, album artist, composer, genre, and release date. Put track number/total and disc number/total into paired `HStack` controls. Render BPM as a narrow numeric field. Render compilation with `MixedStateCheckbox`. Render comment with a multiline `TextEditor` whose binding calls `.comment`.

Mark only the currently invalid field with an error color and show `validationError.message` directly below the grid. Do not treat untouched mixed fields as errors.

- [ ] **Step 6: Implement footer behavior**

Editing footer:

- `Cancel` dismisses;
- `Save` calls `model.save(...)`;
- `Save` is disabled when `!model.canSave`.

Saving footer:

- show `Saving %1$lld of %2$lld`;
- disable close, cancel, and save.

Results footer:

- `Close` dismisses;
- `Retry Failed` appears only when `model.hasFailuresToRetry`;
- retry calls `model.retryFailed(...)`;
- skipped read-only files remain visible but are not retried.

If every selected item saves, show a success tray through `NotificationManager.shared` and dismiss. If anything is skipped or fails, keep the result sheet open.

- [ ] **Step 7: Run the UI check and build**

Run:

```bash
Scripts/test-track-metadata-editor-ui.sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected: the UI check passes and the app builds.

- [ ] **Step 8: Commit the sheet**

```bash
git add Views/Library/Sheets/TrackMetadataEditorSheet.swift Views/Components/MixedStateCheckbox.swift Scripts/test-track-metadata-editor-ui.sh
git commit -m "feat(metadata): add batch tag editor sheet"
```

---

### Task 7: Route Every Context Menu to the Sheet and Localize It

**Files:**
- Modify: `Views/Components/TrackContextMenu.swift:5-95`
- Modify: `Views/Main/ContentView.swift:50-230`
- Modify: `Views/Main/ContentView.swift:502-548`
- Modify: `Utilities/Constants.swift:245-265`
- Modify: `Resources/Localizable.xcstrings`
- Create: `Scripts/test-track-metadata-editor-entry-points.sh`

**Interfaces:**
- Posts one `[Track]` payload for single, multiple, and player menu entry points.
- Owns the active request in `ContentView` and presents one main-window sheet.

- [ ] **Step 1: Write the failing entry-point and localization check**

Create `Scripts/test-track-metadata-editor-entry-points.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MENU="$ROOT_DIR/Views/Components/TrackContextMenu.swift"
CONTENT="$ROOT_DIR/Views/Main/ContentView.swift"
CONSTANTS="$ROOT_DIR/Utilities/Constants.swift"
STRINGS="$ROOT_DIR/Resources/Localizable.xcstrings"

require_pattern() {
    local file="$1"
    local pattern="$2"
    local message="$3"
    if ! rg -n "$pattern" "$file" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern "$CONSTANTS" 'static let editTrackMetadata' 'Typed metadata editor notification is missing.'
require_pattern "$MENU" 'createEditInfoItem\\(for: \\[track\\]\\)' 'Single-track menus must expose Edit Track Info.'
require_pattern "$MENU" 'createEditInfoItem\\(for: tracks\\)' 'Multi-track menus must expose Edit Track Info.'
require_pattern "$MENU" '"Edit Track Info\\.\\.\\."' 'The localized menu action is missing.'
require_pattern "$CONTENT" 'TrackMetadataEditorRequest\\?' 'ContentView must own the active editor request.'
require_pattern "$CONTENT" 'sheet\\(item:.*trackMetadataEditorRequest' 'ContentView must present the editor sheet.'
require_pattern "$CONTENT" 'publisher\\(for: \\.editTrackMetadata\\)' 'ContentView must receive metadata edit requests.'
require_pattern "$STRINGS" '"Edit Track Info\\.\\.\\."' 'The Edit Track Info localization is missing.'
require_pattern "$STRINGS" '"Multiple Values"' 'The mixed-value localization is missing.'
require_pattern "$STRINGS" '"File Information"' 'The file-information localization is missing.'
require_pattern "$STRINGS" '"Tag Information"' 'The tag-information localization is missing.'

jq -e . "$STRINGS" >/dev/null
printf '%s\n' 'Track metadata editor entry point checks passed'
```

Make it executable:

```bash
chmod +x Scripts/test-track-metadata-editor-entry-points.sh
```

- [ ] **Step 2: Run the check and verify the RED state**

Run:

```bash
Scripts/test-track-metadata-editor-entry-points.sh
```

Expected: exit 1 with `Typed metadata editor notification is missing.`

- [ ] **Step 3: Add the typed notification and menu action**

In `Utilities/Constants.swift`, add:

```swift
static let editTrackMetadata = Notification.Name("EditTrackMetadata")
```

In `TrackContextMenu`, add:

```swift
private static func createEditInfoItem(for tracks: [Track]) -> ContextMenuItem {
    .button(
        title: String(appLocalized: "Edit Track Info..."),
        icon: "pencil"
    ) {
        NotificationCenter.default.post(
            name: .editTrackMetadata,
            object: nil,
            userInfo: ["tracks": tracks]
        )
    }
}
```

Insert `createEditInfoItem(for: [track])` after `Show Info` in single-track and player menus. Insert `createEditInfoItem(for: tracks)` in the multi-selection menu between playback actions and destructive actions, with dividers matching the existing compact layout.

- [ ] **Step 4: Present the request from `ContentView`**

Add state:

```swift
@State private var trackMetadataEditorRequest: TrackMetadataEditorRequest?
```

Extend `contentViewNotificationHandlers` with a binding and receiver:

```swift
.onReceive(NotificationCenter.default.publisher(for: .editTrackMetadata)) { notification in
    guard let tracks = notification.userInfo?["tracks"] as? [Track],
          !tracks.isEmpty else { return }
    trackMetadataEditorRequest.wrappedValue = TrackMetadataEditorRequest(tracks: tracks)
}
```

Present:

```swift
.sheet(item: $trackMetadataEditorRequest) { request in
    TrackMetadataEditorSheet(request: request)
        .environmentObject(libraryManager)
        .environmentObject(playlistManager)
        .environmentObject(playbackManager)
}
```

Pass the new binding into the view modifier from `ContentView.body`.

- [ ] **Step 5: Add English and Simplified Chinese strings**

Add at least these keys to `Resources/Localizable.xcstrings`:

| Source key | `zh-Hans` value |
|---|---|
| `Edit Track Info...` | `修改歌曲信息…` |
| `File Information` | `文件信息` |
| `Tag Information` | `标签信息` |
| `Multiple Values` | `多个值` |
| `Selected Tracks` | `已选歌曲` |
| `Track Info (%1$lld Tracks)` | `歌曲信息（%1$lld 首）` |
| `Reading Tags...` | `正在读取标签…` |
| `Release Date` | `发行日期` |
| `Total Tracks` | `总曲目数` |
| `Total Discs` | `总碟片数` |
| `Comment` | `备注` |
| `Saving %1$lld of %2$lld` | `正在保存第 %1$lld 首，共 %2$lld 首` |
| `Saved` | `已保存` |
| `Skipped` | `已跳过` |
| `Failed` | `失败` |
| `Retry Failed` | `重试失败项` |
| `The release date must use YYYY or YYYY-MM-DD.` | `发行日期必须使用 YYYY 或 YYYY-MM-DD 格式。` |
| `%1$@ must be a positive integer.` | `%1$@ 必须是正整数。` |
| `The %1$@ format is read-only.` | `%1$@ 格式为只读。` |
| `The file “%1$@” no longer exists.` | `文件“%1$@”已不存在。` |
| `The file “%1$@” is not writable.` | `文件“%1$@”不可写。` |
| `Could not read tags: %1$@` | `无法读取标签：%1$@` |
| `Could not save tags: %1$@` | `无法保存标签：%1$@` |
| `Saved tags could not be verified: %1$@` | `无法验证已保存的标签：%1$@` |
| `Playback could not be restored because track data is missing.` | `由于歌曲数据缺失，无法恢复播放。` |
| `Playback resumed, but its saved position could not be restored.` | `播放已恢复，但无法恢复到保存前的位置。` |
| `Playback restoration timed out.` | `恢复播放超时。` |
| `Playback could not be restored: %1$@` | `无法恢复播放：%1$@` |

Use positional specifiers in Swift source as well as the catalog for all formatted strings. Reuse existing keys such as `Title`, `Artist`, `Album`, `Album Artist`, `Composer`, `Genre`, `Track Number`, `Disc Number`, `BPM`, `Compilation`, `Cancel`, `Save`, and `Close`.

- [ ] **Step 6: Run entry-point and localization checks**

Run:

```bash
Scripts/test-track-metadata-editor-entry-points.sh
Scripts/test-localization-format-specifiers.sh
xcodebuild -project Petrichor.xcodeproj -scheme Petrichor -configuration Debug build
```

Expected:

```text
Track metadata editor entry point checks passed
Localization format specifier checks passed
```

and `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit entry points and localization**

```bash
git add Views/Components/TrackContextMenu.swift Views/Main/ContentView.swift Utilities/Constants.swift Resources/Localizable.xcstrings Scripts/test-track-metadata-editor-entry-points.sh
git commit -m "feat(metadata): expose localized tag editor"
```

---

### Task 8: Verify File Safety, Batch Semantics, and Playback Continuity End to End

**Files:**
- Modify only if a defect is found: files from Tasks 1-7
- Update if validation needs a stable fixture command: `Scripts/test-track-metadata-file-service.sh`

- [ ] **Step 1: Run every focused metadata-editor check**

Run:

```bash
Scripts/test-track-metadata-edit-model.sh
Scripts/test-track-metadata-file-service.sh
Scripts/test-track-metadata-reindex.sh
Scripts/test-track-metadata-playback-restore.sh
Scripts/test-track-metadata-editor-orchestration.sh
Scripts/test-track-metadata-editor-ui.sh
Scripts/test-track-metadata-editor-entry-points.sh
Scripts/test-localization-format-specifiers.sh
```

Expected: every script exits 0 and prints its pass message.

- [ ] **Step 2: Run all repository shell checks**

Run:

```bash
for script in Scripts/test-*.sh; do
    "$script"
done
```

Expected: all checks exit 0. If an unrelated pre-existing check fails, record its exact command and output before deciding whether it is in scope.

- [ ] **Step 3: Build in a clean derived-data directory**

Run:

```bash
xcodebuild \
    -project Petrichor.xcodeproj \
    -scheme Petrichor \
    -configuration Debug \
    -derivedDataPath /tmp/PetrichorMetadataEditorDerivedData \
    build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Create disposable format fixtures**

If `ffmpeg` is available, create a temporary fixture folder outside the user's library:

```bash
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-metadata-fixtures.XXXXXX")"
ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 3 \
    -metadata title="Original Title" \
    -metadata artist="Original Artist" \
    "$FIXTURE_DIR/editable.flac"
ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 3 \
    -metadata title="Other Title" \
    -metadata artist="Original Artist" \
    "$FIXTURE_DIR/mixed.mp3"
ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 3 \
    -metadata title="M4A Title" \
    "$FIXTURE_DIR/editable.m4a"
ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 3 \
    -metadata title="WAV Title" \
    "$FIXTURE_DIR/editable.wav"
ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 3 \
    -c:a libvorbis \
    -metadata title="Vorbis Title" \
    "$FIXTURE_DIR/editable.ogg"
ffmpeg -f lavfi -i anullsrc=r=48000:cl=stereo -t 3 \
    -c:a libopus \
    -metadata title="Opus Title" \
    "$FIXTURE_DIR/editable.opus"
cp "$FIXTURE_DIR/editable.flac" "$FIXTURE_DIR/read-only.flac"
chmod 444 "$FIXTURE_DIR/read-only.flac"
```

If an optional encoder such as `libvorbis` or `libopus` is unavailable, retain the other generated fixtures and record that format as untested in the final verification report. If `ffmpeg` itself is unavailable, use disposable copies of non-DRM files and explicitly note that automated fixture creation was unavailable. Never point this check at the user's only copy of a track.

- [ ] **Step 5: Perform manual single and batch acceptance checks**

Add only the disposable fixture folder to Petrichor and verify:

1. Single-track and player right-click menus show `Edit Track Info...`.
2. Opening shows tags from the file, not stale database values.
3. Editing every supported field persists after closing and reopening the sheet.
4. A two-file selection displays common artist, mixed title placeholder, and missing/equal values correctly.
5. Leaving a mixed title untouched preserves both titles.
6. Typing one title applies it to both writable files.
7. Typing then clearing title, numbers, release date, and comment removes those tags.
8. Compilation can be set on and off across the batch.
9. Unsupported, missing, and read-only files are shown and skipped with a reason.
10. A failure does not prevent later writable files from saving.
11. `Retry Failed` targets failed files only.
12. Search, artist/album/genre categories, detail sidebar, queue, and loaded playlists show verified values without a folder rescan.
13. Repeat representative set/remove/verify checks for MP3, FLAC, M4A, WAV, Ogg Vorbis, and Opus fixtures that the local `ffmpeg` build can generate; confirm an untouched embedded artwork or advanced tag survives where the fixture contains one.

- [ ] **Step 6: Verify playing and paused restoration**

With a disposable track in a queue:

1. Start playback, seek well away from zero, record queue index and approximate position, edit a tag, and save.
2. Confirm the same track and queue index remain selected, playback resumes, and the position is within normal backend seek tolerance.
3. Pause, record position, edit another tag, and save.
4. Confirm the same track and queue index remain selected, the position is restored, and the engine remains paused.
5. Stop without clearing the displayed track if the UI exposes that state, save, and confirm saving does not start playback.

- [ ] **Step 7: Inspect the final diff for scope and safety**

Run:

```bash
git status --short
git diff --check
git diff --stat
rg -n 'TODO|TBD|FIXME|AudioMetadata\\(\\)|TaskGroup|processFilesInBatches|refreshFolder' \
    Core/Metadata/TrackMetadataEditModel.swift \
    Core/Metadata/SFBTrackMetadataFileService.swift \
    Managers/Database/DMTrackMetadataEditing.swift \
    Managers/TrackMetadataEditorViewModel.swift \
    Views/Library/Sheets/TrackMetadataEditorSheet.swift
```

Expected:

- `git diff --check` is silent;
- there are no placeholder markers;
- no whole metadata replacement, parallel write group, or folder-rescan call appears in the feature;
- only feature-related files are modified.

- [ ] **Step 8: Commit any verification fixes**

If verification required changes:

```bash
git add Core Managers Views Utilities Resources Scripts
git commit -m "fix(metadata): harden tag editor verification"
```

If no changes were required, do not create an empty commit.
