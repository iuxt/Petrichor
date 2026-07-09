import Foundation

enum TrackTrashManager {
    static func moveTrackToTrash(_ track: Track) async {
        guard let coordinator = AppCoordinator.shared else {
            await notify(.error, String(appLocalized: "Unable to access the library"))
            return
        }

        let result = await moveTrackCore(
            track,
            coordinator: coordinator,
            captureSnapshot: true,
            advanceAfterMove: true
        )

        await notifySingleResult(result)
    }

    static func moveTracksToTrash(_ tracks: [Track]) async {
        guard !tracks.isEmpty else { return }
        guard let coordinator = AppCoordinator.shared else {
            await notify(.error, String(appLocalized: "Unable to access the library"))
            return
        }

        // Cache the current playback id once, outside the loop. `currentTrack`
        // mutates as the loop advances playback, so re-querying would misidentify.
        let currentTrackId = await MainActor.run {
            coordinator.playbackManager.currentTrack?.trackId
        }

        // Process the currently-playing track last so playback only advances
        // once, to the next track outside the selection. This avoids the
        // play/stop churn that would happen if it were deleted in the middle.
        let sorted = sortTracksForBatchTrash(tracks, currentTrackId: currentTrackId)
        let lastIndex = sorted.count - 1

        var results: [TrashMoveResult] = []
        results.reserveCapacity(sorted.count)
        for (index, track) in sorted.enumerated() {
            let isLast = index == lastIndex
            let result = await moveTrackCore(
                track,
                coordinator: coordinator,
                captureSnapshot: isLast,
                advanceAfterMove: isLast
            )
            results.append(result)
        }

        await notifyBatchResult(results, coordinator: coordinator)
    }

    // MARK: - Core

    private struct TrashMoveResult {
        let track: Track
        let audioMoved: Bool
        let audioError: Error?
        let failedSidecars: [URL]
        let libraryRemoved: Bool
        let libraryError: Error?
        let fileMissing: Bool
    }

    @MainActor
    private static func moveTrackCore(
        _ track: Track,
        coordinator: AppCoordinator,
        captureSnapshot: Bool,
        advanceAfterMove: Bool
    ) async -> TrashMoveResult {
        let libraryManager = coordinator.libraryManager
        let fileManager = FileManager.default
        let audioURL = track.url
        let accessURL = libraryFolderAccessURL(containing: audioURL, folders: libraryManager.folders)
        let didStartAccess = withLibraryFolderAccess(accessURL)
        defer {
            if didStartAccess {
                accessURL?.stopAccessingSecurityScopedResource()
            }
        }

        guard fileManager.fileExists(atPath: audioURL.path) else {
            return TrashMoveResult(
                track: track,
                audioMoved: false,
                audioError: nil,
                failedSidecars: [],
                libraryRemoved: false,
                libraryError: nil,
                fileMissing: true
            )
        }

        let sidecars = TrackTrashSidecars.sidecarURLs(forAudioURL: audioURL)
        let snapshot = captureSnapshot
            ? coordinator.playbackManager.prepareCurrentTrackForTrashMove(track)
            : nil

        do {
            try moveItemToTrash(audioURL, fileManager: fileManager)
        } catch {
            Logger.error("Failed to move track to Trash: \(audioURL.path), error: \(error)")
            if captureSnapshot {
                coordinator.playbackManager.restoreCurrentTrackAfterFailedTrashMove(snapshot)
            }
            return TrashMoveResult(
                track: track,
                audioMoved: false,
                audioError: error,
                failedSidecars: [],
                libraryRemoved: false,
                libraryError: nil,
                fileMissing: false
            )
        }

        if advanceAfterMove {
            coordinator.playbackManager.handleTrackMovedToTrash(track)
        }

        var failedSidecars: [URL] = []
        for url in sidecars {
            do {
                try moveItemToTrash(url, fileManager: fileManager)
            } catch {
                failedSidecars.append(url)
                Logger.warning("Failed to move sidecar to Trash: \(url.path), error: \(error)")
            }
        }

        do {
            try await libraryManager.removeTrackFromLibrary(track)
            return TrashMoveResult(
                track: track,
                audioMoved: true,
                audioError: nil,
                failedSidecars: failedSidecars,
                libraryRemoved: true,
                libraryError: nil,
                fileMissing: false
            )
        } catch {
            Logger.error("Failed to remove trashed track from library: \(error)")
            return TrashMoveResult(
                track: track,
                audioMoved: true,
                audioError: nil,
                failedSidecars: failedSidecars,
                libraryRemoved: false,
                libraryError: error,
                fileMissing: false
            )
        }
    }

    private static func sortTracksForBatchTrash(
        _ tracks: [Track],
        currentTrackId: Int64?
    ) -> [Track] {
        guard let currentTrackId else { return tracks }
        let others = tracks.filter { $0.trackId != currentTrackId }
        let current = tracks.filter { $0.trackId == currentTrackId }
        return others + current
    }

    // MARK: - Notification Aggregation

    @MainActor
    private static func notifySingleResult(_ result: TrashMoveResult) {
        let track = result.track

        if result.fileMissing {
            notify(.error, String(appLocalized: "The file no longer exists"))
            return
        }

        if let error = result.audioError {
            notify(.error, String(appLocalized: "Failed to move '\(track.title)' to Trash: \(error.localizedDescription)"))
            return
        }

        if !result.libraryRemoved {
            notify(.error, String(appLocalized: "Moved file to Trash, but failed to update the library"))
            AppCoordinator.shared?.libraryManager.refreshLibrary()
            return
        }

        let message = result.failedSidecars.isEmpty
            ? String(appLocalized: "Moved '\(track.title)' to Trash")
            : String(appLocalized: "Moved '\(track.title)' to Trash, but some related files could not be moved")
        notify(result.failedSidecars.isEmpty ? .info : .warning, message)
    }

    @MainActor
    private static func notifyBatchResult(_ results: [TrashMoveResult], coordinator: AppCoordinator) {
        let total = results.count
        let audioMoved = results.filter(\.audioMoved)
        let audioSuccess = audioMoved.count
        let totalFailedSidecars = audioMoved.reduce(0) { $0 + $1.failedSidecars.count }
        let libraryFailures = audioMoved.filter { !$0.libraryRemoved }.count

        if audioSuccess == 0 {
            let allMissing = results.allSatisfy { $0.fileMissing }
            if allMissing {
                notify(.error, String(appLocalized: "The files no longer exist"))
            } else {
                notify(.error, String(appLocalized: "Failed to move \(total) items to Trash"))
            }
            return
        }

        if audioSuccess < total {
            let failed = total - audioSuccess
            notify(.warning, String(appLocalized: "Moved \(audioSuccess) of \(total) items to Trash; \(failed) could not be moved"))
        } else if totalFailedSidecars > 0 {
            notify(.warning, String(appLocalized: "Moved \(total) items to Trash, but some related files could not be moved"))
        } else {
            notify(.info, String(appLocalized: "Moved \(total) items to Trash"))
        }

        if libraryFailures > 0 {
            coordinator.libraryManager.refreshLibrary()
        }
    }

    private static func withLibraryFolderAccess(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.startAccessingSecurityScopedResource()
    }

    private static func libraryFolderAccessURL(containing fileURL: URL, folders: [Folder]) -> URL? {
        guard let folder = folders
            .filter({ contains(fileURL, in: $0.url) })
            .max(by: { $0.url.standardizedFileURL.path.count < $1.url.standardizedFileURL.path.count })
        else {
            return nil
        }

        guard let bookmarkData = folder.bookmarkData else {
            return folder.url
        }

        do {
            var isStale = false
            return try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            Logger.warning("Failed to resolve bookmark before moving track to Trash: \(error)")
            return folder.url
        }
    }

    private static func contains(_ fileURL: URL, in folderURL: URL) -> Bool {
        let filePath = fileURL.standardizedFileURL.path
        let folderPath = folderURL.standardizedFileURL.path
        return filePath == folderPath || filePath.hasPrefix(folderPath + "/")
    }

    private static func moveItemToTrash(_ url: URL, fileManager: FileManager) throws {
        var resultingURL: NSURL?

        do {
            try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        } catch {
            Logger.warning("System Trash failed for \(url.path), falling back to user Trash: \(error)")
            try moveItemToLocalTrashFallback(url, fileManager: fileManager)
            return
        }

        if let resultingURL {
            Logger.info("Moved item to Trash: \(url.path) -> \(resultingURL.path ?? "")")
        } else {
            Logger.warning("System Trash returned no destination for \(url.path), falling back to user Trash")
            try moveItemToLocalTrashFallback(url, fileManager: fileManager)
        }
    }

    private static func moveItemToLocalTrashFallback(_ url: URL, fileManager: FileManager) throws {
        let trashDirectory = try fileManager.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appTrashDirectory = trashDirectory.appendingPathComponent(TrackTrashFallback.appTrashFolderName, isDirectory: true)
        try fileManager.createDirectory(at: appTrashDirectory, withIntermediateDirectories: true)

        let destination = TrackTrashFallback.fallbackURL(for: url, trashDirectory: trashDirectory, fileManager: fileManager)
        try fileManager.moveItem(at: url, to: destination)
        Logger.info("Moved item to local Trash fallback: \(url.path) -> \(destination.path)")
    }

    @MainActor
    private static func notify(_ type: NotificationType, _ message: String) {
        NotificationManager.shared.addMessage(type, message)
    }
}
