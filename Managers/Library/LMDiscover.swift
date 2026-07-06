import Foundation

extension LibraryManager {
    // MARK: - Constants
    private static let discoverTrackIdsKey = "discoverTrackIds"
    private static let discoverLastUpdatedKey = "discoverLastUpdated"
    private static let discoverUpdateIntervalKey = "discoverUpdateInterval"
    private static let discoverTrackCountKey = "discoverTrackCount"
    
    private var discoverUpdateInterval: DiscoverUpdateInterval {
        let rawValue = userDefaults.string(forKey: Self.discoverUpdateIntervalKey) ?? DiscoverUpdateInterval.weekly.rawValue
        return DiscoverUpdateInterval(rawValue: rawValue) ?? .weekly
    }
    
    private var discoverTrackCount: Int {
        let count = userDefaults.integer(forKey: Self.discoverTrackCountKey)
        return count > 0 ? count : 50
    }
    
    var discoverLastUpdated: Date? {
        userDefaults.object(forKey: Self.discoverLastUpdatedKey) as? Date
    }
    
    // MARK: - Methods
    
    func loadDiscoverTracks() {
        var tracks: [Track]
        
        if shouldRefreshDiscover() {
            tracks = loadFreshDiscoverTracks()
        } else {
            // Load from saved IDs
            if let savedIds = userDefaults.array(forKey: Self.discoverTrackIdsKey) as? [Int64] {
                let cappedSavedIds = Array(savedIds.prefix(discoverTrackCount))
                tracks = databaseManager.getTracks(byIds: cappedSavedIds)

                if tracks.count < min(savedIds.count, discoverTrackCount) {
                    Logger.info("Saved Discover tracks are stale, regenerating")
                    tracks = loadFreshDiscoverTracks()
                }
            } else {
                tracks = loadFreshDiscoverTracks()
            }
        }
        
        self.discoverTracks = tracks
        Logger.info("Discover tracks loaded")
    }
    
    /// Force refresh discover tracks (called when settings change)
    func refreshDiscoverTracks() {
        Logger.info("Force refreshing discover tracks")
        
        invalidateDiscoverTracks()
        
        // Reload tracks immediately
        loadDiscoverTracks()
        
        // Force UI update by triggering objectWillChange
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    func invalidateDiscoverTracks() {
        userDefaults.removeObject(forKey: Self.discoverTrackIdsKey)
        userDefaults.removeObject(forKey: Self.discoverLastUpdatedKey)
        discoverTracks = []
    }

    private func loadFreshDiscoverTracks() -> [Track] {
        let tracks = databaseManager.getDiscoverTracks(limit: discoverTrackCount)
        let trackIds = tracks.compactMap { $0.trackId }

        userDefaults.set(trackIds, forKey: Self.discoverTrackIdsKey)
        userDefaults.set(Date(), forKey: Self.discoverLastUpdatedKey)

        return tracks
    }
    
    /// Check if discover list needs refresh
    private func shouldRefreshDiscover() -> Bool {
        guard let lastUpdated = userDefaults.object(forKey: Self.discoverLastUpdatedKey) as? Date else {
            return true // Never updated
        }
        
        let timeElapsed = Date().timeIntervalSince(lastUpdated)
        return timeElapsed >= discoverUpdateInterval.timeInterval
    }
}
