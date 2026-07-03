import Foundation

enum TrackTrashManager {
    static func moveTrackToTrash(_ track: Track) async {
        guard let coordinator = AppCoordinator.shared else {
            await notify(.error, String(appLocalized: "Unable to access the library"))
            return
        }

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
            await notify(.error, String(appLocalized: "The file no longer exists"))
            return
        }

        let sidecars = TrackTrashSidecars.sidecarURLs(forAudioURL: audioURL)
        let playbackSnapshot = await coordinator.playbackManager.prepareCurrentTrackForTrashMove(track)

        do {
            try moveItemToTrash(audioURL, fileManager: fileManager)
        } catch {
            Logger.error("Failed to move track to Trash: \(audioURL.path), error: \(error)")
            await coordinator.playbackManager.restoreCurrentTrackAfterFailedTrashMove(playbackSnapshot)
            await notify(.error, String(appLocalized: "Failed to move '\(track.title)' to Trash: \(error.localizedDescription)"))
            return
        }

        await coordinator.playbackManager.handleTrackMovedToTrash(track)

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
            let message = failedSidecars.isEmpty
                ? String(appLocalized: "Moved '\(track.title)' to Trash")
                : String(appLocalized: "Moved '\(track.title)' to Trash, but some related files could not be moved")
            await notify(failedSidecars.isEmpty ? .info : .warning, message)
        } catch {
            Logger.error("Failed to remove trashed track from library: \(error)")
            await notify(.error, String(appLocalized: "Moved file to Trash, but failed to update the library"))
            await MainActor.run {
                libraryManager.refreshLibrary()
            }
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
