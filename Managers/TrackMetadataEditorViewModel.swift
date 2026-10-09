import Combine
import Foundation
import ImageIO

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
    private struct OutstandingPlaybackRestoration {
        let target: TrackMetadataEditTarget
        let snapshot: PlaybackManager.MetadataEditPlaybackSnapshot
    }

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
    @Published private(set) var lyricsRemovalTargets: Set<TrackMetadataEditTarget> = []
    @Published private(set) var artworkRemovalTargets: Set<TrackMetadataEditTarget> = []
    @Published private(set) var pendingLyrics: [TrackMetadataEditTarget: String] = [:]
    @Published private(set) var pendingArtwork: [TrackMetadataEditTarget: Data] = [:]
    @Published private(set) var isImportingEmbeddedContent = false
    @Published var embeddedImportError: String?
    private(set) var appliedOnlineTagCandidate: OnlineTagCandidate?

    let tracks: [Track]

    private let fileService: any TrackMetadataFileServicing
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var retryPatch: TrackMetadataPatch?
    private var selectedSaveTargets: Set<TrackMetadataEditTarget> = []
    private var playbackRestorationErrorTarget: TrackMetadataEditTarget?

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
              !isImportingEmbeddedContent,
              snapshots.contains(where: \.isWritable),
              let form,
              (form.isDirty || hasEmbeddedChanges),
              validationError == nil,
              let patch = try? form.makePatch() else {
            return false
        }
        return !patch.isEmpty || hasEmbeddedChanges
    }

    private var hasEmbeddedChanges: Bool {
        !lyricsRemovalTargets.isEmpty || !artworkRemovalTargets.isEmpty ||
        !pendingLyrics.isEmpty || !pendingArtwork.isEmpty
    }

    func toggleLyricsRemoval(for target: TrackMetadataEditTarget) {
        guard phase == .editing, !isImportingEmbeddedContent,
              let snapshot = snapshots.first(where: { $0.target == target }),
              snapshot.isWritable else { return }
        let hadPending = pendingLyrics[target] != nil
        pendingLyrics.removeValue(forKey: target)
        guard snapshot.embeddedLyrics != nil else { return }
        if hadPending {
            lyricsRemovalTargets.insert(target)
            return
        }
        if !lyricsRemovalTargets.insert(target).inserted {
            lyricsRemovalTargets.remove(target)
        }
    }

    func toggleArtworkRemoval(for target: TrackMetadataEditTarget) {
        guard phase == .editing, !isImportingEmbeddedContent,
              let snapshot = snapshots.first(where: { $0.target == target }),
              snapshot.isWritable else { return }
        let hadPending = pendingArtwork[target] != nil
        pendingArtwork.removeValue(forKey: target)
        guard !snapshot.embeddedArtwork.isEmpty else { return }
        if hadPending {
            artworkRemovalTargets.insert(target)
            return
        }
        if !artworkRemovalTargets.insert(target).inserted {
            artworkRemovalTargets.remove(target)
        }
    }

    func stageLyrics(_ lyrics: String, for target: TrackMetadataEditTarget) {
        guard phase == .editing,
              snapshots.contains(where: { $0.target == target && $0.isWritable }) else { return }
        pendingLyrics[target] = lyrics
        lyricsRemovalTargets.remove(target)
    }

    func stageArtwork(_ artwork: Data, for target: TrackMetadataEditTarget) {
        guard phase == .editing,
              snapshots.contains(where: { $0.target == target && $0.isWritable }) else { return }
        pendingArtwork[target] = artwork
        artworkRemovalTargets.remove(target)
    }

    func undoEmbedding(for target: TrackMetadataEditTarget, artwork: Bool) {
        guard phase == .editing, !isImportingEmbeddedContent else { return }
        if artwork { pendingArtwork.removeValue(forKey: target) }
        else { pendingLyrics.removeValue(forKey: target) }
    }

    func importEmbeddedContent(from url: URL, for target: TrackMetadataEditTarget, artwork: Bool) async {
        guard phase == .editing, !isImportingEmbeddedContent,
              snapshots.contains(where: { $0.target == target && $0.isWritable }) else { return }
        isImportingEmbeddedContent = true
        defer { isImportingEmbeddedContent = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let limit = artwork ? 20 * 1_024 * 1_024 : 4 * 1_024 * 1_024
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= limit else { throw EmbeddedImportFailure.tooLarge }
                let data = try Data(contentsOf: url)
                guard data.count <= limit else { throw EmbeddedImportFailure.tooLarge }
                if artwork {
                    guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                          let type = CGImageSourceGetType(image) as String?,
                          ["public.jpeg", "public.png"].contains(type),
                          CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else {
                        throw EmbeddedImportFailure.invalidArtwork
                    }
                } else {
                    guard let text = String(data: data, encoding: .utf8),
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !text.contains("\0") else { throw EmbeddedImportFailure.invalidLyrics }
                }
                return data
            }.value
            if artwork { stageArtwork(data, for: target) }
            else if let lyrics = String(data: data, encoding: .utf8) { stageLyrics(lyrics, for: target) }
        } catch {
            embeddedImportError = error.localizedDescription
        }
    }

    private enum EmbeddedImportFailure: LocalizedError {
        case tooLarge, invalidArtwork, invalidLyrics

        var errorDescription: String? {
            switch self {
            case .tooLarge: String(appLocalized: "The selected file is too large. Artwork must be at most 20 MB and lyrics at most 4 MB.")
            case .invalidArtwork: String(appLocalized: "Choose a valid JPEG or PNG image.")
            case .invalidLyrics: String(appLocalized: "Choose a nonempty UTF-8 lyrics file.")
            }
        }
    }

    private func patch(_ base: TrackMetadataPatch, for target: TrackMetadataEditTarget) -> TrackMetadataPatch {
        var patch = base
        patch.removeEmbeddedLyrics = lyricsRemovalTargets.contains(target)
        patch.removeEmbeddedArtwork = artworkRemovalTargets.contains(target)
        patch.embeddedLyrics = pendingLyrics[target]
        patch.embeddedArtwork = pendingArtwork[target]
        return patch
    }

    var canLookUpTags: Bool {
        phase == .editing && tracks.count == 1 && snapshots.count == 1 && snapshots[0].isWritable
    }

    func applyOnlineTags(_ candidate: OnlineTagCandidate, fields: Set<TrackMetadataEditableField>) {
        guard canLookUpTags, !fields.isEmpty, var form else { return }
        candidate.apply(to: &form, fields: fields)
        self.form = form
        appliedOnlineTagCandidate = candidate
        recomputeValidationError()
    }

    var compilationValue: Bool? {
        form?.compilation.value
    }

    var validationMessage: String? {
        guard let validationError else { return nil }

        switch validationError.kind {
        case .positiveInteger:
            return String.localizedStringWithFormat(
                String(appLocalized: "%1$@ must be a positive integer."),
                Self.localizedName(for: validationError.field)
            )
        case .invalidReleaseDate:
            return String(appLocalized: "The release date must use YYYY or YYYY-MM-DD.")
        }
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
            self.appliedOnlineTagCandidate = nil
            self.validationError = nil
            self.playbackRestorationError = nil
            self.playbackRestorationErrorTarget = nil
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
            playbackRestorationError = nil
            playbackRestorationErrorTarget = nil
            let writableTargets = snapshots
                .filter { $0.isWritable && !self.patch(patch, for: $0.target).isEmpty }
                .map(\.target)
            selectedSaveTargets = Set(writableTargets)
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

    private static func localizedName(
        for field: TrackMetadataEditableField
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
        var outstandingPlaybackRestoration: OutstandingPlaybackRestoration?
        var shouldStop = false

        for target in targets {
            if Task.isCancelled {
                break
            }

            var writeAccess: PlaybackManager.MetadataWriteAccessToken?
            var updatedTrackForWriteAccess: Track?

            do {
                guard let track = track(matching: target) else {
                    throw TrackMetadataFileError.readFailed(target.url.path)
                }
                writeAccess = await playbackManager.beginMetadataWriteAccess(
                    for: track
                )
                try await fileService.preflightWrite(target: target)

                if let snapshot = await playbackManager
                    .prepareCurrentTrackForMetadataEdit(track) {
                    outstandingPlaybackRestoration = OutstandingPlaybackRestoration(
                        target: target,
                        snapshot: snapshot
                    )
                }
                try Task.checkCancellation()

                let verified = try await fileService.write(
                    target: target,
                    patch: self.patch(patch, for: target)
                )
                try Task.checkCancellation()
                let reindexed = try await libraryManager.databaseManager
                    .reindexEditedTrack(target: target, verified: verified)
                updatedTrackForWriteAccess = reindexed.track

                for affectedTrack in reindexed.affectedTracks {
                    libraryManager.applyMetadataEditResult(affectedTrack)
                    playlistManager.applyMetadataEditResult(affectedTrack)
                }

                if let pendingRestoration = outstandingPlaybackRestoration {
                    await restorePlayback(
                        pendingRestoration.snapshot,
                        target: pendingRestoration.target,
                        track: reindexed.track,
                        fullTrack: reindexed.fullTrack,
                        playbackManager: playbackManager
                    )
                    outstandingPlaybackRestoration = nil
                }

                verifiedByTarget[target] = verified
                results.append(
                    TrackMetadataBatchResult(target: target, outcome: .saved)
                )
            } catch let error as TrackMetadataFileError
            where error.isPreflightSkip {
                if let pendingRestoration = outstandingPlaybackRestoration {
                    await restorePlayback(
                        pendingRestoration.snapshot,
                        target: pendingRestoration.target,
                        track: nil,
                        fullTrack: nil,
                        playbackManager: playbackManager
                    )
                    outstandingPlaybackRestoration = nil
                }
                results.append(
                    TrackMetadataBatchResult(
                        target: target,
                        outcome: .skipped(error.localizedDescription)
                    )
                )
            } catch is CancellationError {
                results.append(
                    TrackMetadataBatchResult(
                        target: target,
                        outcome: .failed(CancellationError().localizedDescription)
                    )
                )
                shouldStop = true
            } catch {
                if let pendingRestoration = outstandingPlaybackRestoration {
                    await restorePlayback(
                        pendingRestoration.snapshot,
                        target: pendingRestoration.target,
                        track: nil,
                        fullTrack: nil,
                        playbackManager: playbackManager
                    )
                    outstandingPlaybackRestoration = nil
                }
                results.append(
                    TrackMetadataBatchResult(
                        target: target,
                        outcome: .failed(Self.localizedSaveFailure(error))
                    )
                )
            }

            if let writeAccess {
                await playbackManager.endMetadataWriteAccess(
                    writeAccess,
                    updatedTrack: updatedTrackForWriteAccess
                )
            }

            currentProgress += 1
            if shouldStop || Task.isCancelled {
                break
            }
        }

        if let pendingRestoration = outstandingPlaybackRestoration {
            await restorePlayback(
                pendingRestoration.snapshot,
                target: pendingRestoration.target,
                track: nil,
                fullTrack: nil,
                playbackManager: playbackManager
            )
            outstandingPlaybackRestoration = nil
        }

        if shouldStop || Task.isCancelled {
            let completedTargets = Set(results.map(\.target))
            let cancellationReason = CancellationError().localizedDescription
            for target in targets where !completedTargets.contains(target) {
                results.append(
                    TrackMetadataBatchResult(
                        target: target,
                        outcome: .failed(cancellationReason)
                    )
                )
            }
        }

        await libraryManager.finishMetadataEditRefresh()
        playlistManager.finishMetadataEditRefresh()

        snapshots = snapshots.map { snapshot in
            verifiedByTarget[snapshot.target] ?? snapshot
        }
        lyricsRemovalTargets.subtract(verifiedByTarget.keys)
        artworkRemovalTargets.subtract(verifiedByTarget.keys)
        for target in verifiedByTarget.keys {
            pendingLyrics.removeValue(forKey: target)
            pendingArtwork.removeValue(forKey: target)
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
        target: TrackMetadataEditTarget,
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

                    switch result {
                    case .success:
                        if self.playbackRestorationErrorTarget == target {
                            self.playbackRestorationError = nil
                            self.playbackRestorationErrorTarget = nil
                        }
                    case .failure(let error):
                        if self.playbackRestorationError == nil {
                            self.playbackRestorationError = error.localizedDescription
                            self.playbackRestorationErrorTarget = target
                        }
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
        let allTargetsSaved = unavailableResults.isEmpty
            && !selectedSaveTargets.isEmpty
            && selectedSaveTargets.allSatisfy { target in
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

    private static func localizedSaveFailure(_ error: Error) -> String {
        if error is TrackMetadataFileError {
            return error.localizedDescription
        }
        return String.localizedStringWithFormat(
            String(appLocalized: "Could not save tags: %1$@"),
            error.localizedDescription
        )
    }
}
