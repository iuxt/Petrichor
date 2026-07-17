# Track Metadata Editor Design

## Goal

Add a localized macOS metadata editor that opens from track context menus, reads tags directly from the selected audio files, writes only fields the user explicitly changes, supports single-track and batch editing, and refreshes Petrichor's library state from the tags actually written.

## Confirmed Product Decisions

- The editor supports every imported format for which the bundled SFBAudioEngine 0.13.0 writer provides a real metadata-writing implementation.
- The first release edits common tags only: title, artist, album, album artist, composer, genre, release date, track number and total, disc number and total, BPM, compilation, and comment.
- Batch fields use three-state semantics: common value, mixed value, and explicit edit.
- An untouched mixed field preserves every file's original value. Entering a value applies it to every writable selected file. Explicitly clearing a dirty field removes that tag from every writable selected file.
- If the current track must be written, Petrichor preserves its queue position, playback position, and playing or paused state across the write.
- The file is the source of truth. Successful writes are read back and then applied authoritatively to the database.

## Entry Points and Presentation

Add a localized `Edit Track Info...` context-menu item to:

- library track tables;
- folder track tables;
- regular and smart playlist track tables;
- multi-track selections in those tables; and
- the current-track context menus in the player.

The existing `TrackContextMenu` factory already receives either one `Track` or the complete selected `[Track]`, so all entry points should route through one menu action carrying an array. A typed notification or equivalent top-level route presents the editor from `ContentView`.

The editor is a modal sheet owned by the main window. It does not replace or turn the existing read-only `TrackDetailView` sidebar into an editor. This keeps single-track and batch presentation consistent and prevents file-writing state from leaking into the detail view.

The sheet title is `Track Info` for one selection and `Track Info (N Tracks)` for multiple selections. Its body has two compact macOS form groups:

1. `File Information`, which is read-only.
2. `Tag Information`, which contains the editable fields.

For one file, the file-information group shows filename, path, format, and duration. For multiple files, it shows the selected count and aggregates common technical values; differing values display the localized `Multiple Values` placeholder. File information never becomes writable.

The tag-information group uses a compact two-column layout. Single-line fields use text fields, comment uses a multi-line text editor, compilation uses a three-state control, and the number/total pairs are presented together. The sheet is scrollable at smaller window heights.

The footer contains `Cancel` and `Save`. `Save` is disabled while tags are loading, while no field is dirty, when every selected file is unwritable, while a save is active, or when any dirty value is invalid. Closing and cancellation are disabled once file writes have started; the current batch runs to a terminal result so the user is never left uncertain about which files were modified.

## Editable Field Model

### Snapshots

Opening the sheet reads each selected file directly through SFBAudioEngine and produces an editable snapshot containing:

- the file URL and stable database track ID;
- the editable common tags;
- the read-only file summary;
- whether the format is supported for writing;
- whether the file exists and is writable; and
- a localized reason when the file cannot be edited.

Database values are not used to populate tag fields. They may be stale, and the user explicitly expects the editor to show the tags currently stored in the files.

### Batch Aggregation

Each editable field has:

- an initial aggregate: `common(value)` or `mixed`;
- a current UI value;
- a dirty flag; and
- validation state.

Aggregation compares tag values exactly after mapping missing values to the field's empty representation. A missing value and an empty stored value are therefore equivalent; two non-empty values that differ in spelling, case, or whitespace are mixed.

For text and numeric controls:

- a common value is displayed normally;
- a mixed value displays an empty control with `Multiple Values` as placeholder text;
- focusing or leaving a control without changing it does not mark it dirty;
- typing marks it dirty and applies the new value to the batch;
- after a dirty field has been cleared, its patch value is an explicit removal rather than `unchanged`.

Compilation aggregates to `on`, `off`, or `mixed`. An untouched mixed control produces no patch. Choosing on or off produces an explicit Boolean patch for the whole writable batch.

### Input Rules

- Title, artist, album, album artist, composer, and genre are single-line strings.
- Release date accepts `YYYY` or `YYYY-MM-DD`. The exact accepted forms are four ASCII digits, or an ISO calendar date that Foundation validates.
- Track number, total tracks, disc number, total discs, and BPM accept positive base-10 integers.
- An explicitly cleared number or release date removes that tag.
- Single-line strings are trimmed at both ends before writing. A whitespace-only dirty value removes the tag.
- Comment preserves internal whitespace and line breaks, trims whitespace and newlines at both ends, and removes the tag when the result is empty.
- A track number is not required to be less than or equal to the batch's total-tracks value because untouched per-file numbers may differ. The same rule applies to disc number and total discs.

## Format Support

The writer is a dedicated SFBAudioEngine adapter and is independent of the active playback or metadata-reading backend. Petrichor already bundles SFBAudioEngine and CXXTagLib, so this adds no dependency and no network behavior.

The writable allowlist is based on the concrete SFBAudioEngine file types whose `writeMetadata()` implementations call a real TagLib save path:

- MP3: `mp3`;
- MP4 audio: `m4a`;
- FLAC: `flac`;
- WAVE and AIFF: `wav`, `aiff`, `aif`;
- Ogg Vorbis, Ogg FLAC, Ogg Opus, and Ogg Speex: `ogg`, `oga`, `opus`, `spx`;
- Monkey's Audio, Musepack, WavPack, and True Audio: `ape`, `mpc`, `wv`, `tta`;
- DSF and DSDIFF: `dsf`, `dff`.

The adapter still asks SFBAudioEngine to inspect file content rather than trusting the extension alone. A URL on the allowlist can still be rejected when its contents are invalid, the concrete file type cannot be constructed, or the file is not writable.

Imported formats without a corresponding writer are read-only in this editor: raw `aac`, raw `alac`, `au`, `mod`, `it`, `s3m`, and `xm`. They remain playable and scannable. A mixed selection may contain read-only files; the sheet shows how many will be skipped and why. If all selected files are read-only, `Save` remains disabled.

## Metadata Writer

The writer exposes a small backend-neutral contract:

- read one editable snapshot from a URL;
- determine whether the concrete file can be written;
- apply a `TrackMetadataPatch` to a URL; and
- read the editable snapshot back for verification.

The SFBAudioEngine implementation opens `AudioFile(readingPropertiesAndMetadataFrom:)`, mutates only the metadata properties present in the patch, and calls `writeMetadata()`. It must not create a fresh empty metadata object, because doing so could remove embedded artwork or advanced tags that are outside the editor.

Patch operations distinguish:

- `unchanged`, which does not assign the corresponding `AudioMetadata` property;
- `set(value)`, which assigns a validated value; and
- `remove`, which assigns `nil`.

Release year is stored through SFBAudioEngine's release-date field. Petrichor's existing metadata mapping derives the lightweight library year from the value read back.

After a successful `writeMetadata()` call, the service reopens the file and compares every dirty field with the expected normalized value. Verification ignores fields that were not part of the patch. A mismatch is a per-file failure even when the underlying writer returned success.

Files are written sequentially on a non-main execution context. This avoids concurrent TagLib writes and produces deterministic progress and error ordering. No audio data, folder structure, sidecar lyrics, external artwork, embedded artwork, or file timestamps are intentionally changed beyond changes made by the metadata writer itself.

## Save Flow

When the user presses `Save`:

1. Validate every dirty form field.
2. Build one immutable patch shared by the writable batch.
3. Recheck each file's existence, concrete format, and write access.
4. Mark unsupported, missing, or read-only files as skipped with a reason.
5. If the current track is writable and receives a non-empty patch, snapshot playback and write that file first.
6. For each target, reread its current tags, apply only the patch, write, reopen, and verify.
7. After each verified write, authoritatively reindex that URL in the database.
8. Publish progress and collect success, skipped, and failed results.
9. Restore playback as soon as the current-track write and reindex finish; other files may continue saving afterward.
10. Refresh dependent in-memory state once at the end through existing debounced notifications.

A batch is not an all-or-nothing transaction. One file's failure neither stops later files nor rolls back earlier successes.

### Authoritative Targeted Reindex

The targeted database path reuses the existing metadata extraction and normalization rules but differs from the current "update only non-empty values" scan helper. Editing supports tag removal, so a successful reread must replace all file-derived editable columns, including `nil` and empty values.

The update preserves application-owned state such as:

- database track ID and folder ID;
- play count and last-played date;
- date added;
- playlist file membership.

It refreshes file-derived metadata and dependent records, including:

- the lightweight and full track rows;
- artist, album artist, composer, genre, album, and relationship records;
- FTS/search content;
- duplicate detection for the edited row and the affected old and new duplicate groups;
- cached library categories and entity counts;
- smart playlist evaluation;
- the current queue and current-track value; and
- artwork resolver/cache identity when metadata changes affect album association.

The targeted reindex updates only successfully written URLs. It does not hard-refresh an entire folder.

The filesystem watcher may independently observe the modification. Existing debouncing should coalesce the resulting library notification; the scan path must never write metadata back to the audio file.

## Playback Preservation

The playback manager snapshots the current track ID, queue position, sanitized playback time, and one of three states: playing, paused, or stopped.

Only a current file that will actually be written is stopped. Read-only or skipped current files do not disturb playback.

The current file is written and reindexed before the rest of the batch. Petrichor then updates the queue's track value, reopens the same URL, seeks to the saved time clamped to the reread duration, and restores state:

- playing resumes playing;
- paused remains paused at the saved position;
- stopped does not start automatically.

After the seek completes, the restored position should be within one second of the saved position unless it was clamped to the new duration.

If writing or verification fails, Petrichor reopens the unchanged or still-readable URL and restores the same state. Playback restoration is attempted independently of metadata-save success and is reported separately if it cannot be completed.

## Results and Error Handling

Loading failures appear inline before editing begins. Writable files can still be edited when other selected files fail to load, but the header shows the reduced writable count.

During save, the sheet displays `Saving X of N` and the current filename. Terminal results are grouped as:

- saved;
- skipped before write; and
- failed during open, write, verification, reindex, or playback restoration.

All-success closes the sheet and posts a localized completion notification.

When any file is skipped or fails, the sheet stays open and shows a localized summary plus per-file reasons. Successful files become the new clean baseline and are removed from the retry target. The existing patch remains dirty only for failed writable files, so `Retry Failed` never rewrites successful files. The user may also close the result sheet after the active write loop finishes.

Errors are logged without dumping tag contents. Paths may appear in local diagnostic logs as they already do in library scanning, but no information leaves the device.

## Concurrency and Sandbox Rules

- UI state and playback coordination are `@MainActor`.
- Tag reads, writes, and file verification do not run on the main thread.
- Database writes use the existing GRDB queue.
- The editor operates only on URLs inside user-selected library folders whose security-scoped bookmarks are retained by `LibraryManager`.
- The service performs a fresh access and writability check before each write and never broadens access outside the selected library.
- The feature is fully offline and introduces no analytics or external service.

## Localization

All user-visible strings, including menu labels, field labels, placeholders, progress, validation, skip reasons, and result summaries, are added to `Resources/Localizable.xcstrings`.

Count-bearing strings use positional format specifiers so translations may reorder arguments safely. The localization format-specifier regression check must pass.

## Testing

### Pure Model Checks

Add focused executable Swift checks for:

- common and mixed aggregation;
- missing and empty equivalence;
- untouched mixed fields producing `unchanged`;
- common and mixed fields producing `set` after edits;
- explicit text and numeric removal;
- compilation's on/off/mixed transitions;
- date and positive-integer validation; and
- retry targeting only failed writable files.

### Source and Integration Checks

Add focused repository checks that verify:

- every single- and multi-selection context-menu path includes the editor action;
- the writer mutates the existing `AudioMetadata` object and does not replace it;
- write is followed by reopen and verification;
- file work is not launched on the main actor;
- targeted reindex is authoritative for tag removal; and
- playback snapshot and restore wrap a current-track write.

File-level smoke tests operate only on temporary audio fixtures or disposable copies. They cover at least MP3, FLAC, M4A, WAV, Ogg Vorbis, and Opus when the local fixture tools are available. Each test writes representative text, number, Boolean, and removal patches, reopens the file, and verifies untouched tags and artwork remain present.

### Manual QA

- Open and cancel single-track editing without changing the file.
- Edit every supported field on a disposable single-track fixture.
- Batch-edit tracks whose fields are common, mixed, and missing.
- Explicitly clear text, numeric, date, Boolean, and comment tags.
- Mix writable, unsupported, missing, and read-only files in one selection.
- Save the current track while playing and while paused; verify track, queue position, state, and approximate playback time.
- Relaunch Petrichor and confirm file tags, library categories, search results, playlists, queue metadata, and track details remain consistent.

Before delivery, run the focused checks, `Scripts/test-localization-format-specifiers.sh`, every `Scripts/test-*.sh` check, and a Debug `xcodebuild`.

## Out of Scope

- Editing embedded or external artwork.
- Editing embedded or sidecar lyrics.
- Renaming or moving audio files.
- Automatic track or disc numbering.
- Editing sort tags, MusicBrainz identifiers, ISRC, ReplayGain, or arbitrary advanced tags.
- A batch-wide rollback or undo transaction.
- Adding a runtime network service or writing any metadata during ordinary library scanning.
