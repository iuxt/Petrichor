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
