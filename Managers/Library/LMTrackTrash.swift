import Foundation

extension LibraryManager {
    func removeTrackFromLibrary(_ track: Track) async throws {
        try await databaseManager.removeTrackFromLibrary(track)

        await MainActor.run {
            tracks.removeAll { existing in
                if let existingId = existing.trackId, let removedId = track.trackId {
                    return existingId == removedId
                }
                return existing.url == track.url
            }

            discoverTracks.removeAll { existing in
                if let existingId = existing.trackId, let removedId = track.trackId {
                    return existingId == removedId
                }
                return existing.url == track.url
            }

            updateSearchResults()
            refreshLibraryCategories()
            refreshEntities()
            NotificationCenter.default.post(name: .libraryDataDidChange, object: nil)
        }
    }
}
