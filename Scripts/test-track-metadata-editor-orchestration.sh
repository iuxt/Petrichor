#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL="$ROOT_DIR/Managers/TrackMetadataEditorViewModel.swift"
PLAYBACK="$ROOT_DIR/Managers/PlaybackManager.swift"

require_pattern() {
    local pattern="$1"
    local message="$2"
    if ! rg -n -U "$pattern" "$MODEL" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

reject_pattern() {
    local pattern="$1"
    local message="$2"
    if rg -n -U "$pattern" "$MODEL" >/dev/null 2>&1; then
        printf '%s\n' "$message" >&2
        exit 1
    fi
}

require_pattern '@MainActor\s+final class TrackMetadataEditorViewModel' \
    'The editor view model must be main-actor isolated.'
require_pattern 'case loading\s+case editing\s+case saving\s+case results' \
    'All editor phases must be explicit.'
require_pattern 'func load\(\)' 'Fresh file-tag loading is missing.'
require_pattern 'func save\(' 'The save entry point is missing.'
require_pattern 'prioritizedTargets' 'The current track must be processed first.'
require_pattern 'for target in targets' 'File writes must be sequential.'
require_pattern 'preflightWrite\(target:' 'Preflight must happen before playback suspension.'
require_pattern 'prepareCurrentTrackForMetadataEdit' \
    'Current playback must be suspended before its write.'
require_pattern 'restoreCurrentTrackAfterMetadataEdit' \
    'Current playback must be restored after its write.'
require_pattern 'func retryFailed\(' 'Failed-only retry is missing.'
require_pattern 'TrackMetadataBatchResult\.retryTargets' \
    'Retry targets must be derived from failed outcomes.'
require_pattern 'applyMetadataEditResult' \
    'Successful writes must update in-memory consumers.'
require_pattern 'for affectedTrack in reindexed\.affectedTracks' \
    'Every duplicate peer changed by reindexing must reach playlist and playback caches.'
require_pattern 'finishMetadataEditRefresh' \
    'Batch cache refresh must be coalesced.'
require_pattern 'await libraryManager\.finishMetadataEditRefresh\(\)' \
    'Completion must await duplicate-filtered library membership reload.'
require_pattern 'finalizeBatchIfPossible' \
    'Completion must wait for playback restoration.'
require_pattern 'var validationMessage: String\?' \
    'The app-facing view model must expose a localized validation message.'
require_pattern 'String\(appLocalized: "%1\$@ must be a positive integer\."\)' \
    'Positive-integer validation must follow the selected app language.'
require_pattern 'String\(appLocalized: "The release date must use YYYY or YYYY-MM-DD\."\)' \
    'Release-date validation must follow the selected app language.'
reject_pattern 'withTaskGroup|TaskGroup|async let' \
    'Audio files must not be written concurrently.'
if ! rg -n 'let suspensionGeneration: UInt64' "$PLAYBACK" >/dev/null 2>&1; then
    printf '%s\n' \
        'The editor restoration contract must carry its metadata-write suspension generation.' >&2
    exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/petrichor-metadata-orchestration.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cp "$ROOT_DIR/Core/Metadata/TrackMetadataEditModel.swift" \
    "$TMP_DIR/TrackMetadataEditModel.swift"
cp "$MODEL" "$TMP_DIR/TrackMetadataEditorViewModel.swift"

cat >"$TMP_DIR/TestDoubles.swift" <<'SWIFT'
import Combine
import Foundation

extension String {
    init(appLocalized key: String) {
        self = key
    }
}

struct Track: Equatable, Sendable {
    let trackId: Int64?
    let url: URL
    var title: String

    init(id: Int64, name: String) {
        trackId = id
        url = URL(fileURLWithPath: "/tmp/\(name).flac")
        title = name
    }
}

struct FullTrack: Equatable, Sendable {
    let trackId: Int64
}

struct TrackMetadataReindexResult: Sendable {
    let track: Track
    let fullTrack: FullTrack
    let affectedTracks: [Track]

    init(
        track: Track,
        fullTrack: FullTrack,
        affectedTracks: [Track]? = nil
    ) {
        self.track = track
        self.fullTrack = fullTrack
        self.affectedTracks = affectedTracks ?? [track]
    }
}

enum HarnessError: LocalizedError {
    case write(Int64)
    case reindex(Int64)

    var errorDescription: String? {
        switch self {
        case .write(let id): "write \(id)"
        case .reindex(let id): "reindex \(id)"
        }
    }
}

enum TrackMetadataFileError: LocalizedError {
    case fileMissing(String)
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileMissing(let name): "missing \(name)"
        case .readFailed(let detail): "read \(detail)"
        }
    }

    var isPreflightSkip: Bool {
        switch self {
        case .fileMissing: true
        case .readFailed: false
        }
    }
}

enum Logger {
    static func error(_ message: String) {}
}

@MainActor
final class EventRecorder {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func reset() {
        events = []
    }
}

actor SFBTrackMetadataFileService {
    func load(target: TrackMetadataEditTarget) async -> TrackMetadataLoadResult {
        fatalError("The default service is not used by this harness")
    }

    func preflightWrite(target: TrackMetadataEditTarget) async throws {
        fatalError("The default service is not used by this harness")
    }

    func write(
        target: TrackMetadataEditTarget,
        patch: TrackMetadataPatch
    ) async throws -> TrackMetadataSnapshot {
        fatalError("The default service is not used by this harness")
    }
}

@MainActor
final class DatabaseManager {
    let recorder: EventRecorder
    var results: [Int64: TrackMetadataReindexResult] = [:]
    var failingIDs: Set<Int64> = []

    init(recorder: EventRecorder) {
        self.recorder = recorder
    }

    func reindexEditedTrack(
        target: TrackMetadataEditTarget,
        verified: TrackMetadataSnapshot
    ) async throws -> TrackMetadataReindexResult {
        let id = target.trackID!
        recorder.append("reindex:\(id)")
        if failingIDs.contains(id) {
            throw HarnessError.reindex(id)
        }
        return results[id]!
    }
}

@MainActor
final class LibraryManager {
    let databaseManager: DatabaseManager
    let recorder: EventRecorder

    init(databaseManager: DatabaseManager, recorder: EventRecorder) {
        self.databaseManager = databaseManager
        self.recorder = recorder
    }

    func applyMetadataEditResult(_ track: Track) {
        recorder.append("library:\(track.trackId!)")
    }

    func finishMetadataEditRefresh() async {
        recorder.append("libraryFinish")
    }
}

@MainActor
final class PlaylistManager {
    let recorder: EventRecorder

    init(recorder: EventRecorder) {
        self.recorder = recorder
    }

    func applyMetadataEditResult(_ track: Track) {
        recorder.append("playlist:\(track.trackId!)")
    }

    func finishMetadataEditRefresh() {
        recorder.append("playlistFinish")
    }
}

@MainActor
final class PlaybackManager {
    enum MetadataPlaybackRestoreError: LocalizedError {
        case engine(String)

        var errorDescription: String? {
            switch self {
            case .engine(let detail): detail
            }
        }
    }

    struct MetadataEditPlaybackSnapshot {
        let track: Track
        let suspensionGeneration: UInt64
    }

    var currentTrack: Track?
    var failRestoration = false
    private(set) var activeSuspensionGeneration: UInt64?
    private(set) var prepareCount = 0
    private(set) var restoreCount = 0
    private var nextSuspensionGeneration: UInt64 = 0
    let recorder: EventRecorder

    init(currentTrack: Track?, recorder: EventRecorder) {
        self.currentTrack = currentTrack
        self.recorder = recorder
    }

    func prepareCurrentTrackForMetadataEdit(
        _ track: Track
    ) -> MetadataEditPlaybackSnapshot? {
        guard currentTrack?.trackId == track.trackId else { return nil }
        precondition(
            activeSuspensionGeneration == nil,
            "a new metadata suspension must not replace an unconsumed token"
        )
        nextSuspensionGeneration &+= 1
        activeSuspensionGeneration = nextSuspensionGeneration
        prepareCount += 1
        recorder.append("prepare:\(track.trackId!)")
        return MetadataEditPlaybackSnapshot(
            track: track,
            suspensionGeneration: nextSuspensionGeneration
        )
    }

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
        precondition(
            activeSuspensionGeneration == snapshot.suspensionGeneration,
            "restore must consume the generation created by prepare"
        )
        activeSuspensionGeneration = nil
        restoreCount += 1
        let id = snapshot.track.trackId!
        recorder.append("restoreBegin:\(id):\(updatedTrack == nil ? "original" : "updated")")
        Task { @MainActor in
            await Task.yield()
            self.recorder.append("restoreEnd:\(id)")
            if self.failRestoration {
                completion(.failure(.engine("restore \(id)")))
            } else {
                self.currentTrack = updatedTrack ?? snapshot.track
                completion(.success(()))
            }
        }
    }
}
SWIFT

cat >"$TMP_DIR/Harness.swift" <<'SWIFT'
import Foundation

actor ScriptedFileService: TrackMetadataFileServicing {
    private let recorder: EventRecorder
    private var loads: [Int64: TrackMetadataLoadResult]
    private var writes: [Int64: TrackMetadataSnapshot]
    private var preflightFailures: [Int64: TrackMetadataFileError]
    private var writeFailuresRemaining: [Int64: Int]
    private var cancellingWriteIDs: Set<Int64>
    private var receivedTitlePatches: [Int64: [MetadataPatchValue<String>]] = [:]

    init(
        recorder: EventRecorder,
        loads: [Int64: TrackMetadataLoadResult],
        writes: [Int64: TrackMetadataSnapshot] = [:],
        preflightFailures: [Int64: TrackMetadataFileError] = [:],
        writeFailuresRemaining: [Int64: Int] = [:],
        cancellingWriteIDs: Set<Int64> = []
    ) {
        self.recorder = recorder
        self.loads = loads
        self.writes = writes
        self.preflightFailures = preflightFailures
        self.writeFailuresRemaining = writeFailuresRemaining
        self.cancellingWriteIDs = cancellingWriteIDs
    }

    func load(target: TrackMetadataEditTarget) async -> TrackMetadataLoadResult {
        let id = target.trackID!
        await recorder.append("load:\(id)")
        return loads[id]!
    }

    func preflightWrite(target: TrackMetadataEditTarget) async throws {
        let id = target.trackID!
        await recorder.append("preflight:\(id)")
        if let error = preflightFailures[id] {
            throw error
        }
    }

    func write(
        target: TrackMetadataEditTarget,
        patch: TrackMetadataPatch
    ) async throws -> TrackMetadataSnapshot {
        let id = target.trackID!
        await recorder.append("write:\(id)")
        receivedTitlePatches[id, default: []].append(patch.title)
        if cancellingWriteIDs.remove(id) != nil {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            throw CancellationError()
        }
        if let remaining = writeFailuresRemaining[id], remaining > 0 {
            writeFailuresRemaining[id] = remaining - 1
            throw HarnessError.write(id)
        }
        return writes[id]!
    }

    func writtenTitles(for id: Int64) -> [MetadataPatchValue<String>] {
        receivedTitlePatches[id] ?? []
    }
}

func tags(_ title: String) -> TrackEditableTags {
    TrackEditableTags(
        title: title,
        artist: "Artist",
        album: "Album",
        albumArtist: nil,
        composer: nil,
        genre: nil,
        releaseDate: nil,
        trackNumber: nil,
        trackTotal: nil,
        discNumber: nil,
        discTotal: nil,
        bpm: nil,
        compilation: false,
        comment: nil
    )
}

func snapshot(
    _ track: Track,
    title: String,
    writable: Bool = true,
    reason: String? = nil
) -> TrackMetadataSnapshot {
    TrackMetadataSnapshot(
        target: .init(trackID: track.trackId, url: track.url),
        tags: tags(title),
        file: .init(
            filename: track.url.lastPathComponent,
            path: track.url.path,
            format: "flac",
            duration: 30,
            fileSize: 100
        ),
        isWritable: writable,
        restrictionReason: reason
    )
}

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@MainActor
func waitUntil(
    _ message: String,
    condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<1_000 {
        if condition() {
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    fputs("FAIL: timed out waiting for \(message)\n", stderr)
    exit(1)
}

@MainActor
func makeManagers(
    recorder: EventRecorder,
    currentTrack: Track?
) -> (LibraryManager, PlaylistManager, PlaybackManager, DatabaseManager) {
    let database = DatabaseManager(recorder: recorder)
    return (
        LibraryManager(databaseManager: database, recorder: recorder),
        PlaylistManager(recorder: recorder),
        PlaybackManager(currentTrack: currentTrack, recorder: recorder),
        database
    )
}

@main
struct Harness {
    @MainActor
    static func main() async {
        await testFreshLoadAggregation()
        await testSequentialSaveAndFailedOnlyRetry()
        await testCurrentPreflightSkipDoesNotSuspend()
        await testCurrentFailureRestoresBeforeContinuing()
        await testPlaybackRestoreFailureBlocksDismissal()
        await testCancellationRestoresCurrentBeforeStopping()
        print("Track metadata editor orchestration checks passed")
    }

    @MainActor
    private static func testFreshLoadAggregation() async {
        let recorder = EventRecorder()
        let one = Track(id: 1, name: "one")
        let two = Track(id: 2, name: "two")
        let three = Track(id: 3, name: "three")
        let service = ScriptedFileService(
            recorder: recorder,
            loads: [
                1: .loaded(snapshot(one, title: "One")),
                2: .loaded(snapshot(two, title: "Two", writable: false, reason: "read only")),
                3: .unavailable(
                    target: .init(trackID: three.trackId, url: three.url),
                    reason: "missing"
                )
            ]
        )
        let viewModel = TrackMetadataEditorViewModel(
            tracks: [one, two, three],
            fileService: service
        )

        viewModel.load()
        await waitUntil("fresh load") { viewModel.phase == .editing }

        expect(recorder.events == ["load:1", "load:2", "load:3"], "load order must match selection")
        expect(viewModel.snapshots.map(\.target.trackID) == [1, 2], "loaded snapshots must preserve order")
        expect(viewModel.unavailableResults.count == 2, "read-only and unavailable targets must be skipped")
        expect(viewModel.form?.showsMixedPlaceholder(for: .title) == true, "read-only tags must participate in aggregation")
        expect(!viewModel.canSave, "an untouched form must not be saveable")
        viewModel.setText("Shared", for: .title)
        expect(viewModel.canSave, "a valid dirty form with a writable target must be saveable")
    }

    @MainActor
    private static func testSequentialSaveAndFailedOnlyRetry() async {
        let recorder = EventRecorder()
        let first = Track(id: 10, name: "first")
        let current = Track(id: 20, name: "current")
        let failed = Track(id: 30, name: "failed")
        let initial = [first, current, failed]
        let verified = Dictionary(
            uniqueKeysWithValues: initial.map { ($0.trackId!, snapshot($0, title: "Shared")) }
        )
        let service = ScriptedFileService(
            recorder: recorder,
            loads: Dictionary(
                uniqueKeysWithValues: initial.map { ($0.trackId!, .loaded(snapshot($0, title: $0.title))) }
            ),
            writes: verified,
            writeFailuresRemaining: [30: 1]
        )
        let (library, playlist, playback, database) = makeManagers(
            recorder: recorder,
            currentTrack: current
        )
        for track in initial {
            var updated = track
            updated.title = "Shared"
            database.results[track.trackId!] = .init(
                track: updated,
                fullTrack: .init(trackId: track.trackId!)
            )
        }
        let duplicatePeer = Track(id: 99, name: "duplicate-peer")
        if let currentResult = database.results[current.trackId!] {
            database.results[current.trackId!] = .init(
                track: currentResult.track,
                fullTrack: currentResult.fullTrack,
                affectedTracks: [currentResult.track, duplicatePeer]
            )
        }
        let viewModel = TrackMetadataEditorViewModel(tracks: initial, fileService: service)
        viewModel.load()
        await waitUntil("load before save") { viewModel.phase == .editing }
        viewModel.setText("Shared", for: .title)
        recorder.reset()

        viewModel.save(
            libraryManager: library,
            playlistManager: playlist,
            playbackManager: playback
        )
        await waitUntil("partial save") { viewModel.phase == .results }

        let firstPreflight = recorder.events.firstIndex(of: "preflight:10")!
        let currentPreflight = recorder.events.firstIndex(of: "preflight:20")!
        let restoreEnd = recorder.events.firstIndex(of: "restoreEnd:20")!
        expect(currentPreflight < firstPreflight, "the current track must be processed first")
        expect(
            restoreEnd < firstPreflight,
            "the current track restore must reach a terminal callback before the next write"
        )
        expect(
            recorder.events.contains("playlist:99"),
            "duplicate peers returned by reindexing must refresh playlist caches"
        )
        expect(
            recorder.events.filter { $0 == "libraryFinish" }.count == 1 &&
                recorder.events.filter { $0 == "playlistFinish" }.count == 1,
            "each manager must finish-refresh once per batch"
        )
        expect(viewModel.savedCount == 2, "two files should save")
        expect(viewModel.failedCount == 1, "one file should fail without stopping the loop")
        expect(viewModel.hasFailuresToRetry, "failed files must be retryable")
        expect(viewModel.form?.isDirty == false, "partial results must rebuild a clean baseline")
        expect(!viewModel.allSelectedItemsSaved, "partial results must stay open")
        expect(
            playback.prepareCount == 1 &&
                playback.restoreCount == 1 &&
                playback.activeSuspensionGeneration == nil,
            "successful current-track work must consume its suspension exactly once"
        )

        viewModel.setText("Do not retry this newer form value", for: .title)
        recorder.reset()
        viewModel.retryFailed(
            libraryManager: library,
            playlistManager: playlist,
            playbackManager: playback
        )
        await waitUntil("failed-only retry") { viewModel.allSelectedItemsSaved }

        expect(
            recorder.events.filter { $0.hasPrefix("preflight:") } == ["preflight:30"],
            "retry must preflight failed files only"
        )
        expect(
            recorder.events.filter { $0.hasPrefix("write:") } == ["write:30"],
            "retry must write failed files only"
        )
        let retriedTitles = await service.writtenTitles(for: 30)
        expect(
            retriedTitles == [.set("Shared"), .set("Shared")],
            "retry must reuse the original immutable patch"
        )
        expect(viewModel.phase == .editing, "an all-success batch must return to clean editing")
        expect(viewModel.savedCount == 3 && viewModel.failedCount == 0, "retry must merge outcomes")
        expect(viewModel.form?.isDirty == false, "retry success must leave a clean baseline")
    }

    @MainActor
    private static func testCurrentPreflightSkipDoesNotSuspend() async {
        let recorder = EventRecorder()
        let current = Track(id: 40, name: "vanished")
        let service = ScriptedFileService(
            recorder: recorder,
            loads: [40: .loaded(snapshot(current, title: "Old"))],
            preflightFailures: [40: .fileMissing(current.url.lastPathComponent)]
        )
        let (library, playlist, playback, _) = makeManagers(
            recorder: recorder,
            currentTrack: current
        )
        let viewModel = TrackMetadataEditorViewModel(tracks: [current], fileService: service)
        viewModel.load()
        await waitUntil("load vanished track") { viewModel.phase == .editing }
        viewModel.setText("New", for: .title)
        recorder.reset()
        viewModel.save(
            libraryManager: library,
            playlistManager: playlist,
            playbackManager: playback
        )
        await waitUntil("preflight skip") { viewModel.phase == .results }

        expect(viewModel.skippedCount == 1, "a missing preflight target must be skipped")
        expect(!recorder.events.contains(where: { $0.hasPrefix("prepare:") }), "preflight skip must not suspend playback")
        expect(!recorder.events.contains(where: { $0.hasPrefix("restoreBegin:") }), "preflight skip must not restore playback")
        expect(
            playback.prepareCount == 0 &&
                playback.restoreCount == 0 &&
                playback.activeSuspensionGeneration == nil,
            "preflight skips must not create a suspension token"
        )
    }

    @MainActor
    private static func testCurrentFailureRestoresBeforeContinuing() async {
        let recorder = EventRecorder()
        let other = Track(id: 60, name: "other")
        let current = Track(id: 50, name: "current-fails")
        let tracks = [other, current]
        let service = ScriptedFileService(
            recorder: recorder,
            loads: [
                60: .loaded(snapshot(other, title: "Other")),
                50: .loaded(snapshot(current, title: "Current"))
            ],
            writes: [
                60: snapshot(other, title: "Shared"),
                50: snapshot(current, title: "Shared")
            ]
        )
        let (library, playlist, playback, database) = makeManagers(
            recorder: recorder,
            currentTrack: current
        )
        database.failingIDs = [50]
        var updatedOther = other
        updatedOther.title = "Shared"
        database.results[60] = .init(track: updatedOther, fullTrack: .init(trackId: 60))
        let viewModel = TrackMetadataEditorViewModel(tracks: tracks, fileService: service)
        viewModel.load()
        await waitUntil("load reindex failure case") { viewModel.phase == .editing }
        viewModel.setText("Shared", for: .title)
        recorder.reset()
        viewModel.save(
            libraryManager: library,
            playlistManager: playlist,
            playbackManager: playback
        )
        await waitUntil("reindex failure batch") { viewModel.phase == .results }

        let restoreOriginal = recorder.events.firstIndex(of: "restoreBegin:50:original")!
        let restoreEnd = recorder.events.firstIndex(of: "restoreEnd:50")!
        let nextPreflight = recorder.events.firstIndex(of: "preflight:60")!
        expect(restoreOriginal < restoreEnd && restoreEnd < nextPreflight, "failed current write must restore before continuing")
        expect(viewModel.failedCount == 1 && viewModel.savedCount == 1, "a current failure must not block later files")
        expect(
            playback.prepareCount == 1 &&
                playback.restoreCount == 1 &&
                playback.activeSuspensionGeneration == nil,
            "reindex failure cleanup must consume its suspension exactly once"
        )
    }

    @MainActor
    private static func testPlaybackRestoreFailureBlocksDismissal() async {
        let recorder = EventRecorder()
        let current = Track(id: 70, name: "restore-fails")
        let unrelated = Track(id: 71, name: "unrelated-fails")
        let service = ScriptedFileService(
            recorder: recorder,
            loads: [
                70: .loaded(snapshot(current, title: "Old")),
                71: .loaded(snapshot(unrelated, title: "Old"))
            ],
            writes: [
                70: snapshot(current, title: "New"),
                71: snapshot(unrelated, title: "New")
            ],
            writeFailuresRemaining: [71: 1]
        )
        let (library, playlist, playback, database) = makeManagers(
            recorder: recorder,
            currentTrack: current
        )
        for track in [current, unrelated] {
            var updated = track
            updated.title = "New"
            database.results[track.trackId!] = .init(
                track: updated,
                fullTrack: .init(trackId: track.trackId!)
            )
        }
        playback.failRestoration = true
        let viewModel = TrackMetadataEditorViewModel(
            tracks: [unrelated, current],
            fileService: service
        )
        viewModel.load()
        await waitUntil("load playback failure case") { viewModel.phase == .editing }
        viewModel.setText("New", for: .title)
        viewModel.save(
            libraryManager: library,
            playlistManager: playlist,
            playbackManager: playback
        )
        await waitUntil("playback failure result") {
            viewModel.phase == .results && !viewModel.isAwaitingPlaybackRestoration
        }

        expect(viewModel.savedCount == 1, "playback failure must not rewrite the file outcome")
        expect(viewModel.failedCount == 1, "the unrelated file failure must remain retryable")
        expect(viewModel.playbackRestorationError != nil, "playback failure must be presented")
        expect(!viewModel.allSelectedItemsSaved, "playback failure must block automatic dismissal")
        expect(
            playback.prepareCount == 1 &&
                playback.restoreCount == 1 &&
                playback.activeSuspensionGeneration == nil,
            "a failed engine restoration must still consume the write suspension exactly once"
        )

        playback.failRestoration = false
        recorder.reset()
        viewModel.retryFailed(
            libraryManager: library,
            playlistManager: playlist,
            playbackManager: playback
        )
        await waitUntil("unrelated retry after playback failure") { !viewModel.isBusy }

        expect(
            viewModel.playbackRestorationError != nil,
            "an unrelated retry must preserve the unresolved playback restoration error"
        )
        expect(
            !viewModel.allSelectedItemsSaved && viewModel.phase == .results,
            "an unrelated retry must not auto-dismiss after an unresolved playback error"
        )
        expect(
            !recorder.events.contains(where: { $0.hasPrefix("restoreBegin:") }),
            "an unrelated retry must not claim a replacement playback restoration"
        )
    }

    @MainActor
    private static func testCancellationRestoresCurrentBeforeStopping() async {
        let recorder = EventRecorder()
        let current = Track(id: 80, name: "cancel-current")
        let later = Track(id: 81, name: "must-not-write")
        let service = ScriptedFileService(
            recorder: recorder,
            loads: [
                80: .loaded(snapshot(current, title: "Old")),
                81: .loaded(snapshot(later, title: "Old"))
            ],
            writes: [
                80: snapshot(current, title: "New"),
                81: snapshot(later, title: "New")
            ],
            cancellingWriteIDs: [80]
        )
        let (library, playlist, playback, database) = makeManagers(
            recorder: recorder,
            currentTrack: current
        )
        var updatedLater = later
        updatedLater.title = "New"
        database.results[81] = .init(
            track: updatedLater,
            fullTrack: .init(trackId: 81)
        )
        let viewModel = TrackMetadataEditorViewModel(
            tracks: [later, current],
            fileService: service
        )
        viewModel.load()
        await waitUntil("load cancellation case") { viewModel.phase == .editing }
        viewModel.setText("New", for: .title)
        recorder.reset()
        viewModel.save(
            libraryManager: library,
            playlistManager: playlist,
            playbackManager: playback
        )
        await waitUntil("cancelled save cleanup") { !viewModel.isBusy }

        expect(
            !recorder.events.contains("preflight:81"),
            "cancellation must stop before writing later targets"
        )
        expect(
            recorder.events.filter { $0 == "restoreBegin:80:original" }.count == 1 &&
                recorder.events.filter { $0 == "restoreEnd:80" }.count == 1,
            "cancelled current-track work must restore exactly once"
        )
        expect(
            !viewModel.isAwaitingPlaybackRestoration,
            "cancelled cleanup must reach a terminal playback state"
        )
        expect(
            playback.prepareCount == 1 &&
                playback.restoreCount == 1 &&
                playback.activeSuspensionGeneration == nil,
            "cancellation cleanup must consume its suspension exactly once"
        )
        expect(
            viewModel.saveResults.compactMap { result -> Int64? in
                if case .failed = result.outcome {
                    return result.target.trackID
                }
                return nil
            }.sorted() == [80, 81],
            "cancelled and unprocessed targets must remain available for retry"
        )
    }
}
SWIFT

xcrun swiftc \
    -parse-as-library \
    "$TMP_DIR/TrackMetadataEditModel.swift" \
    "$TMP_DIR/TestDoubles.swift" \
    "$TMP_DIR/TrackMetadataEditorViewModel.swift" \
    "$TMP_DIR/Harness.swift" \
    -o "$TMP_DIR/test-track-metadata-editor-orchestration"
"$TMP_DIR/test-track-metadata-editor-orchestration"
