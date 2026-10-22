import Foundation

extension LibraryManager {
    func removeTrackFromLibrary(_ track: Track) async throws {
        try await databaseManager.removeTrackFromLibrary(track)

        // Deletion can promote a previously hidden duplicate. Reload the visible
        // library so that survivor appears immediately, without a folder rescan.
        let database = databaseManager
        let remainingTracks = await Task.detached {
            database.getAllTracks()
        }.value

        await MainActor.run {
            tracks = remainingTracks

            discoverTracks.removeAll { existing in
                if let existingId = existing.trackId, let removedId = track.trackId {
                    return existingId == removedId
                }
                return existing.libraryPath == track.libraryPath
            }

            updateSearchResults()
            refreshLibraryCategories()
            refreshEntities()
            NotificationCenter.default.post(name: .libraryDataDidChange, object: nil)
        }
    }
}
