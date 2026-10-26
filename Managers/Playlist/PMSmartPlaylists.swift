//
// PlaylistManager class extension
//
// This extension contains methods for managing smart playlists: creation, editing,
// on-demand track loading, and refreshing on library changes. It uses DatabaseManager
// methods internally to evaluate criteria and persist frozen snapshots.
//

import Foundation

extension PlaylistManager {
    // MARK: - Editor Presentation

    /// Present the editor to create a new smart playlist.
    func showCreateSmartPlaylistModal() {
        smartPlaylistToEdit = nil
        showingSmartPlaylistEditor = true
    }

    /// Present the editor pre-filled to edit an existing smart playlist's rules.
    func showEditSmartPlaylistModal(_ playlist: Playlist) {
        guard playlist.type == .smart else { return }
        smartPlaylistToEdit = playlist
        showingSmartPlaylistEditor = true
    }

    // MARK: - Live Match Count

    /// Count how many library tracks match a criteria's rules (ignores any limit), for the
    /// editor's live "Matches N songs" footer.
    func countMatches(for criteria: SmartPlaylistCriteria) async -> Int {
        guard let dbManager = libraryManager?.databaseManager else { return 0 }
        return await dbManager.countMatchesForCriteria(criteria)
    }

    // MARK: - Create / Edit

    /// Create a new user smart playlist from editor criteria.
    @discardableResult
    func createSmartPlaylist(name: String, criteria: SmartPlaylistCriteria) -> Playlist {
        let newPlaylist = Playlist(name: name, criteria: criteria, isUserEditable: true)

        // Insert and keep the sidebar grouping (smart first, then regular) consistent.
        playlists.append(newPlaylist)
        playlists = sortPlaylists(
            smart: playlists.filter { $0.type == .smart },
            regular: playlists.filter { $0.type == .regular }
        )

        let persistence = scheduleSmartPlaylistPersistence(newPlaylist, criteria: criteria)
        Task {
            await persistence.value
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .navigateToPlaylists,
                    object: nil,
                    userInfo: ["playlistID": newPlaylist.id]
                )
            }
        }

        return newPlaylist
    }

    /// Update an existing smart playlist's name and criteria, then re-evaluate.
    func updateSmartPlaylistCriteria(playlistID: UUID, name: String, criteria: SmartPlaylistCriteria) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              playlists[index].type == .smart else { return }

        // Title-only change: the rules are unchanged, so skip the (expensive) re-evaluation
        // and snapshot rewrite and do a cheap metadata rename instead.
        if playlists[index].smartCriteria == criteria {
            if playlists[index].name != name {
                renamePlaylist(playlists[index], newName: name)
            }
            return
        }

        playlists[index].name = name
        playlists[index].smartCriteria = criteria
        playlists[index].dateModified = Date()
        // Invalidate cached tracks so the detail view reloads against the new rules.
        playlists[index].tracks = []

        let updated = playlists[index]
        scheduleSmartPlaylistPersistence(updated, criteria: criteria)
    }

    /// Keep record/snapshot writes ordered when a second edit arrives during an
    /// evaluation. Otherwise an older frozen snapshot can overwrite the new rules.
    @discardableResult
    private func scheduleSmartPlaylistPersistence(_ playlist: Playlist, criteria: SmartPlaylistCriteria) -> Task<Void, Never> {
        let previous = smartPlaylistPersistenceTasks[playlist.id]?.task
        let token = UUID()
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                if self.smartPlaylistPersistenceTasks[playlist.id]?.token == token {
                    self.smartPlaylistPersistenceTasks.removeValue(forKey: playlist.id)
                }
            }
            guard self.isCurrentSmartPlaylist(playlist) else { return }
            await self.persistSmartPlaylist(playlist, criteria: criteria)
        }
        smartPlaylistPersistenceTasks[playlist.id] = (token, task)
        return task
    }

    /// Persist a smart playlist record and (re)materialize its contents.
    ///
    /// For auto-updating playlists this just saves the record and loads tracks via criteria.
    /// For frozen playlists it evaluates the criteria once and stores the result as a snapshot
    /// in `playlist_tracks` so it never re-runs on library changes.
    private func persistSmartPlaylist(_ playlist: Playlist, criteria: SmartPlaylistCriteria) async {
        guard let dbManager = libraryManager?.databaseManager else { return }
        do {
            // Saves the record and clears any existing track associations (e.g. a stale
            // snapshot when switching a playlist from frozen back to auto-updating).
            try await dbManager.savePlaylistAsync(playlist)

            if !criteria.autoUpdate {
                let evaluated = try await dbManager.getTracksForSmartPlaylist(playlist)
                guard isCurrentSmartPlaylist(playlist) else { return }
                try await dbManager.saveSmartPlaylistSnapshot(playlistId: playlist.id, tracks: evaluated)
            }

            // Load contents into memory (criteria for auto, snapshot for frozen).
            await loadSmartPlaylistTracks(playlist, forceReload: true)
        } catch {
            Logger.error("Failed to persist smart playlist '\(playlist.name)': \(error)")
        }
    }

    // MARK: - Loading

    /// Load tracks for a single smart playlist on-demand.
    func loadSmartPlaylistTracks(_ playlist: Playlist, forceReload: Bool = false) async {
        guard playlist.type == .smart,
              let libraryManager,
              isCurrentSmartPlaylist(playlist) else { return }

        // Coalesce identical requests, but allow edited rules to supersede an old query.
        if !forceReload, let load = smartPlaylistLoads[playlist.id],
           load.criteria == playlist.smartCriteria { return }
        let token = UUID()
        smartPlaylistLoads[playlist.id] = (playlist.smartCriteria, token)
        defer {
            if smartPlaylistLoads[playlist.id]?.token == token {
                smartPlaylistLoads.removeValue(forKey: playlist.id)
            }
        }

        let tracks: [Track]
        if playlist.smartCriteria?.autoUpdate ?? true {
            do {
                tracks = try await libraryManager.databaseManager.getTracksForSmartPlaylist(playlist)
            } catch {
                Logger.error("Failed to load tracks for smart playlist '\(playlist.name)': \(error)")
                return
            }
        } else {
            tracks = libraryManager.databaseManager.loadTracksForPlaylist(playlist.id)
        }

        guard smartPlaylistLoads[playlist.id]?.token == token,
              isCurrentSmartPlaylist(playlist),
              let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].tracks = tracks
        playlists[index].trackCount = tracks.count
        Logger.info("Loaded \(tracks.count) tracks for smart playlist '\(playlist.name)'")
    }

    private func isCurrentSmartPlaylist(_ playlist: Playlist) -> Bool {
        playlists.contains {
            $0.id == playlist.id && $0.type == .smart && $0.smartCriteria == playlist.smartCriteria
        }
    }

    // MARK: - Library-Change Refresh

    /// Refresh smart playlists after the library changes.
    ///
    /// Scales to many playlists by avoiding eager track/artwork materialization:
    /// - Frozen playlists are skipped entirely (they never re-evaluate).
    /// - "Hot" playlists (already loaded because the user viewed them) get a full in-place
    ///   refresh so an open detail view stays current.
    /// - "Cold" playlists only get a cheap count update; their tracks reload lazily when next
    ///   viewed via `loadSmartPlaylistTracks`.
    func updateSmartPlaylists() {
        guard let dbManager = libraryManager?.databaseManager else { return }

        let autoSmart = playlists.filter { $0.type == .smart && ($0.smartCriteria?.autoUpdate ?? true) }
        guard !autoSmart.isEmpty else { return }

        // Cold playlists (not currently loaded) only need a cheap count; hot playlists
        // (already viewed this session) get a full in-place refresh so an open detail
        // view stays current. Frozen playlists are excluded entirely above.
        let cold = autoSmart.filter { $0.tracks.isEmpty }
        let hot = autoSmart.filter { !$0.tracks.isEmpty }

        Logger.info("Refreshing smart playlists after library change (\(cold.count) cold, \(hot.count) hot)")

        Task {
            // Cold: one batched read for all counts, no track/artwork materialization.
            if !cold.isEmpty {
                let counts = await dbManager.getSmartPlaylistTrackCounts(cold)
                await MainActor.run {
                    for (id, count) in counts {
                        if let original = cold.first(where: { $0.id == id }),
                           self.isCurrentSmartPlaylist(original),
                           let index = self.playlists.firstIndex(where: { $0.id == id }) {
                            self.playlists[index].trackCount = count
                        }
                    }
                }
            }

            // Hot: full refresh (each query only loads normalized tables if its rules need them).
            for playlist in hot {
                await loadSmartPlaylistTracks(playlist, forceReload: true)
            }
        }
    }

    /// Check if a smart playlist needs its tracks refreshed
    func smartPlaylistNeedsRefresh(_ playlist: Playlist) -> Bool {
        guard playlist.type == .smart else { return false }

        // If tracks array is empty, it needs refresh
        // (unless it's genuinely empty based on criteria)
        return playlist.tracks.isEmpty && playlist.dateModified != playlist.dateCreated
    }
}
