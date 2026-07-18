import Combine
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

protocol TrackMetadataFileServicing: Sendable {
    func load(target: TrackMetadataEditTarget) async -> TrackMetadataLoadResult
    func preflightWrite(target: TrackMetadataEditTarget) async throws
    func write(
        target: TrackMetadataEditTarget,
        patch: TrackMetadataPatch
    ) async throws -> TrackMetadataSnapshot
}

extension SFBTrackMetadataFileService: TrackMetadataFileServicing {}

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
    @Published private(set) var isAwaitingPlaybackRestoration = false
    @Published private(set) var allSelectedItemsSaved = false
    @Published private(set) var form: TrackMetadataEditForm?

    let tracks: [Track]

    private let fileService: any TrackMetadataFileServicing
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var retryPatch: TrackMetadataPatch?

    init(
        tracks: [Track],
        fileService: any TrackMetadataFileServicing = SFBTrackMetadataFileService()
    ) {
        self.tracks = tracks
        self.fileService = fileService
    }

    var savedCount: Int {
        saveResults.count { result in
            if case .saved = result.outcome { return true }
            return false
        }
    }

    var skippedCount: Int {
        saveResults.count { result in
            if case .skipped = result.outcome { return true }
            return false
        }
    }

    var failedCount: Int {
        saveResults.count { result in
            if case .failed = result.outcome { return true }
            return false
        }
    }

    var hasFailuresToRetry: Bool {
        failedCount > 0 && retryPatch != nil && phase == .results
    }

    var isBusy: Bool {
        phase == .loading || phase == .saving
    }

    var canSave: Bool {
        guard phase == .editing,
              snapshots.contains(where: \.isWritable),
              let form,
              form.isDirty,
              validationError == nil,
              let patch = try? form.makePatch() else {
            return false
        }
        return !patch.isEmpty
    }

    var compilationValue: Bool? {
        form?.compilation.value
    }

    func text(for field: TrackMetadataEditableField) -> String {
        form?.text(for: field) ?? ""
    }

    func showsMixedPlaceholder(for field: TrackMetadataEditableField) -> Bool {
        form?.showsMixedPlaceholder(for: field) ?? false
    }

    func setText(_ value: String, for field: TrackMetadataEditableField) {
        guard var form else { return }
        form.setText(value, for: field)
        self.form = form
        recomputeValidationError()
    }

    func setCompilation(_ value: Bool) {
        guard var form else { return }
        form.setCompilation(value)
        self.form = form
        recomputeValidationError()
    }

    func load() {
        guard phase == .loading, loadTask == nil else { return }

        let targets = tracks.map(Self.target(for:))
        let fileService = fileService
        loadTask = Task { [weak self] in
            var loadedSnapshots: [TrackMetadataSnapshot] = []
            var unavailable: [TrackMetadataBatchResult] = []

            for target in targets {
                switch await fileService.load(target: target) {
                case .loaded(let snapshot):
                    loadedSnapshots.append(snapshot)
                    if !snapshot.isWritable {
                        unavailable.append(
                            TrackMetadataBatchResult(
                                target: target,
                                outcome: .skipped(
                                    snapshot.restrictionReason
                                        ?? String(appLocalized: "This file is read-only.")
                                )
                            )
                        )
                    }

                case .unavailable(let target, let reason):
                    unavailable.append(
                        TrackMetadataBatchResult(
                            target: target,
                            outcome: .skipped(reason)
                        )
                    )
                }
            }

            guard let self else { return }
            self.loadTask = nil
            self.snapshots = loadedSnapshots
            self.unavailableResults = unavailable
            self.saveResults = []
            self.form = TrackMetadataEditForm(tags: loadedSnapshots.map(\.tags))
            self.validationError = nil
            self.playbackRestorationError = nil
            self.allSelectedItemsSaved = false
            self.phase = .editing
        }
    }

    func save(
        libraryManager: LibraryManager,
        playlistManager: PlaylistManager,
        playbackManager: PlaybackManager
    ) {
        guard canSave, let form else { return }

        do {
            let patch = try form.makePatch()
            validationError = nil
            retryPatch = patch
            let writableTargets = snapshots
                .filter(\.isWritable)
                .map(\.target)
            beginSave(
                targets: writableTargets,
                patch: patch,
                retainedResults: unavailableResults,
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

    func retryFailed(
        libraryManager: LibraryManager,
        playlistManager: PlaylistManager,
        playbackManager: PlaybackManager
    ) {
        guard phase == .results, let retryPatch else { return }

        let retryTargets = TrackMetadataBatchResult.retryTargets(from: saveResults)
        guard !retryTargets.isEmpty else { return }

        let retryTargetSet = Set(retryTargets)
        let retainedResults = saveResults.filter {
            !retryTargetSet.contains($0.target)
        }
        beginSave(
            targets: retryTargets,
            patch: retryPatch,
            retainedResults: retainedResults,
            libraryManager: libraryManager,
            playlistManager: playlistManager,
            playbackManager: playbackManager
        )
    }

    private func recomputeValidationError() {
        guard let form else {
            validationError = nil
            return
        }

        do {
            _ = try form.makePatch()
            validationError = nil
        } catch let error as TrackMetadataValidationError {
            validationError = error
        } catch {
            validationError = nil
            Logger.error("Unexpected metadata validation error: \(error)")
        }
    }

    private func beginSave(
        targets: [TrackMetadataEditTarget],
        patch: TrackMetadataPatch,
        retainedResults: [TrackMetadataBatchResult],
        libraryManager: LibraryManager,
        playlistManager: PlaylistManager,
        playbackManager: PlaybackManager
    ) {
        guard saveTask == nil else { return }

        let targets = prioritizedTargets(
            targets,
            currentTrack: playbackManager.currentTrack
        )
        phase = .saving
        saveResults = retainedResults
        currentProgress = 0
        totalProgress = targets.count
        playbackRestorationError = nil
        isAwaitingPlaybackRestoration = false
        allSelectedItemsSaved = false

        saveTask = Task { [weak self] in
            guard let self else { return }
            await self.runSaveLoop(
                targets: targets,
                patch: patch,
                retainedResults: retainedResults,
                libraryManager: libraryManager,
                playlistManager: playlistManager,
                playbackManager: playbackManager
            )
        }
    }

    private func runSaveLoop(
        targets: [TrackMetadataEditTarget],
        patch: TrackMetadataPatch,
        retainedResults: [TrackMetadataBatchResult],
        libraryManager: LibraryManager,
        playlistManager: PlaylistManager,
        playbackManager: PlaybackManager
    ) async {
        var results = retainedResults
        var verifiedByTarget: [TrackMetadataEditTarget: TrackMetadataSnapshot] = [:]

        for target in targets {
            var playbackSnapshot: PlaybackManager.MetadataEditPlaybackSnapshot?

            do {
                try await fileService.preflightWrite(target: target)

                if let track = track(matching: target) {
                    playbackSnapshot = playbackManager
                        .prepareCurrentTrackForMetadataEdit(track)
                }

                let verified = try await fileService.write(
                    target: target,
                    patch: patch
                )
                let reindexed = try await libraryManager.databaseManager
                    .reindexEditedTrack(target: target, verified: verified)

                libraryManager.applyMetadataEditResult(reindexed.track)
                playlistManager.applyMetadataEditResult(reindexed.track)

                if let playbackSnapshot {
                    await restorePlayback(
                        playbackSnapshot,
                        track: reindexed.track,
                        fullTrack: reindexed.fullTrack,
                        playbackManager: playbackManager
                    )
                }

                verifiedByTarget[target] = verified
                results.append(
                    TrackMetadataBatchResult(target: target, outcome: .saved)
                )
            } catch let error as TrackMetadataFileError
            where error.isPreflightSkip {
                if let playbackSnapshot {
                    await restorePlayback(
                        playbackSnapshot,
                        track: nil,
                        fullTrack: nil,
                        playbackManager: playbackManager
                    )
                }
                results.append(
                    TrackMetadataBatchResult(
                        target: target,
                        outcome: .skipped(error.localizedDescription)
                    )
                )
            } catch {
                if let playbackSnapshot {
                    await restorePlayback(
                        playbackSnapshot,
                        track: nil,
                        fullTrack: nil,
                        playbackManager: playbackManager
                    )
                }
                results.append(
                    TrackMetadataBatchResult(
                        target: target,
                        outcome: .failed(error.localizedDescription)
                    )
                )
            }

            currentProgress += 1
        }

        libraryManager.finishMetadataEditRefresh()
        playlistManager.finishMetadataEditRefresh()

        snapshots = snapshots.map { snapshot in
            verifiedByTarget[snapshot.target] ?? snapshot
        }
        saveResults = results
        form = TrackMetadataEditForm(tags: snapshots.map(\.tags))
        validationError = nil
        saveTask = nil

        if failedCount == 0 {
            retryPatch = nil
        }
        finalizeBatchIfPossible()
    }

    private func restorePlayback(
        _ snapshot: PlaybackManager.MetadataEditPlaybackSnapshot,
        track: Track?,
        fullTrack: FullTrack?,
        playbackManager: PlaybackManager
    ) async {
        isAwaitingPlaybackRestoration = true

        await withCheckedContinuation { continuation in
            playbackManager.restoreCurrentTrackAfterMetadataEdit(
                snapshot,
                track: track,
                fullTrack: fullTrack
            ) { [weak self] result in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume()
                        return
                    }

                    if case .failure(let error) = result,
                       self.playbackRestorationError == nil {
                        self.playbackRestorationError = error.localizedDescription
                    }
                    self.isAwaitingPlaybackRestoration = false
                    continuation.resume()
                }
            }
        }
    }

    private func finalizeBatchIfPossible() {
        let outcomes = Dictionary(
            uniqueKeysWithValues: saveResults.map { ($0.target, $0.outcome) }
        )
        let allTargetsSaved = tracks
            .map(Self.target(for:))
            .allSatisfy { target in
                if case .saved? = outcomes[target] {
                    return true
                }
                return false
            }

        if allTargetsSaved,
           !isAwaitingPlaybackRestoration,
           playbackRestorationError == nil {
            allSelectedItemsSaved = true
            phase = .editing
        } else {
            allSelectedItemsSaved = false
            phase = .results
        }
    }

    private func prioritizedTargets(
        _ targets: [TrackMetadataEditTarget],
        currentTrack: Track?
    ) -> [TrackMetadataEditTarget] {
        guard let currentTrack,
              let currentIndex = targets.firstIndex(
                  where: { Self.matches($0, track: currentTrack) }
              ),
              currentIndex != targets.startIndex else {
            return targets
        }

        var prioritized = targets
        let currentTarget = prioritized.remove(at: currentIndex)
        prioritized.insert(currentTarget, at: prioritized.startIndex)
        return prioritized
    }

    private func track(matching target: TrackMetadataEditTarget) -> Track? {
        tracks.first { Self.matches(target, track: $0) }
    }

    private static func target(for track: Track) -> TrackMetadataEditTarget {
        TrackMetadataEditTarget(trackID: track.trackId, url: track.url)
    }

    private static func matches(
        _ target: TrackMetadataEditTarget,
        track: Track
    ) -> Bool {
        if let targetID = target.trackID, let trackID = track.trackId {
            return targetID == trackID
        }
        return target.url.standardizedFileURL == track.url.standardizedFileURL
    }
}
