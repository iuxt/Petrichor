//
// PlaylistManager class extension
//
// This extension contains methods for doing CRUD operations on regular playlists,
// the methods internally also use DatabaseManager methods to work with database.
//

import Foundation

extension PlaylistManager {
    // MARK: - Editor Presentation

    /// Present the name-only dialog (used by the track context menu's "New Playlist...").
    func showCreatePlaylistModal(with tracks: [Track] = []) {
        tracksToAddToNewPlaylist = tracks
        newPlaylistName = ""
        showingCreatePlaylistModal = true
    }

    /// Present the unified editor (name + song selection) to create a new playlist.
    func showCreateRegularPlaylistModal() {
        regularPlaylistToEdit = nil
        showingRegularPlaylistEditor = true
    }

    /// Present the unified editor pre-filled to edit an existing regular playlist.
    func showEditRegularPlaylistModal(_ playlist: Playlist) {
        guard playlist.type == .regular, playlist.isUserEditable else { return }
        regularPlaylistToEdit = playlist
        showingRegularPlaylistEditor = true
    }

    // MARK: - Create

    /// Create a new playlist with an optional set of tracks and navigate to it. Shared by
    /// both creation flows (the name-only dialog and the unified editor) so they stay in sync.
    @discardableResult
    func createRegularPlaylist(name: String, tracks: [Track] = []) -> Playlist {
        let newPlaylist = createPlaylist(name: name, tracks: tracks)

        NotificationCenter.default.post(
            name: .navigateToPlaylists,
            object: nil,
            userInfo: ["playlistID": newPlaylist.id]
        )

        return newPlaylist
    }

    func createPlaylistFromModal() {
        guard !newPlaylistName.isEmpty else { return }

        createRegularPlaylist(name: newPlaylistName, tracks: tracksToAddToNewPlaylist)

        // Reset modal state
        newPlaylistName = ""
        tracksToAddToNewPlaylist = []
        showingCreatePlaylistModal = false
    }

    /// Create a new basic playlist backed by an M3U file in the first music folder.
    func createPlaylist(name: String, tracks: [Track] = []) -> Playlist {
        guard let defaultFolder = libraryManager?.folders.first else {
            Task { @MainActor in
                NotificationManager.shared.addMessage(.error, PlaylistFileStoreError.missingDefaultMusicFolder.localizedDescription)
            }
            return Playlist(name: name, tracks: tracks)
        }

        do {
            let newPlaylist = try playlistFileStore.createPlaylist(named: name, tracks: tracks, in: defaultFolder)
            playlists.append(newPlaylist)
            playlists = sortPlaylists(
                smart: playlists.filter { $0.type == .smart },
                regular: playlists.filter { $0.type == .regular }
            )
            return newPlaylist
        } catch {
            Logger.error("Failed to create playlist file: \(error)")
            Task { @MainActor in
                NotificationManager.shared.addMessage(.error, error.localizedDescription)
            }
            return Playlist(name: name, tracks: tracks)
        }
    }
    
    /// Delete a playlist
    func deletePlaylist(_ playlist: Playlist) {
        guard playlist.isUserEditable else {
            Logger.warning("Cannot delete system playlist: \(playlist.name)")
            return
        }

        do {
            try playlistFileStore.delete(playlist)
            playlists.removeAll { $0.id == playlist.id }
            Task { await handlePlaylistDeletionForPinnedItems(playlist.id) }
        } catch {
            Logger.error("Failed to delete playlist file: \(error)")
            Task { @MainActor in
                NotificationManager.shared.addMessage(.error, error.localizedDescription)
            }
            reloadFileBackedPlaylists()
        }
    }
    
    /// Rename a playlist
    func renamePlaylist(_ playlist: Playlist, newName: String) {
        guard playlist.isUserEditable else {
            Logger.warning("Cannot rename system playlist: \(playlist.name)")
            return
        }
        
        do {
            let updatedPlaylist = try playlistFileStore.rename(playlist, to: newName)
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[index] = updatedPlaylist
            }
        } catch {
            Logger.error("Failed to rename playlist file: \(error)")
            Task { @MainActor in
                NotificationManager.shared.addMessage(.error, error.localizedDescription)
            }
            reloadFileBackedPlaylists()
        }
    }
    
    internal func addTrackToRegularPlaylist(track: Track, playlistID: UUID) async {
        await addTracksToPlaylist(tracks: [track], playlistID: playlistID)
    }
    
    internal func removeTrackFromRegularPlaylist(track: Track, playlistID: UUID) async {
        await removeTracksFromPlaylist(tracks: [track], playlistID: playlistID)
    }

    private func persistRegularPlaylistTracks(playlistID: UUID, tracks: [Track]) async {
        guard let index = await MainActor.run(body: {
            playlists.firstIndex(where: { $0.id == playlistID })
        }) else {
            return
        }

        let playlist = await MainActor.run { playlists[index] }

        do {
            let updated = try playlistFileStore.write(tracks: tracks, for: playlist)
            await MainActor.run {
                if let currentIndex = self.playlists.firstIndex(where: { $0.id == playlistID }) {
                    self.playlists[currentIndex] = updated
                }
            }
        } catch {
            Logger.error("Failed to write playlist file: \(error)")
            await MainActor.run {
                NotificationManager.shared.addMessage(.error, error.localizedDescription)
                self.reloadFileBackedPlaylists()
            }
        }
    }

    /// Add multiple tracks to a playlist
    func addTracksToPlaylist(tracks: [Track], playlistID: UUID) async {
        guard let playlist = await MainActor.run(body: {
            playlists.first(where: { $0.id == playlistID && $0.type == .regular && $0.isContentEditable })
        }) else {
            Logger.warning("Cannot add tracks to this playlist")
            return
        }

        let existingIDs = Set(playlist.tracks.compactMap { $0.trackId })
        let now = Date()
        let newTracks = tracks
            .filter { track in track.trackId.map { !existingIDs.contains($0) } ?? false }
            .map { track -> Track in
                var copy = track
                copy.dateAdded = now
                return copy
            }

        guard !newTracks.isEmpty else { return }

        await persistRegularPlaylistTracks(playlistID: playlistID, tracks: playlist.tracks + newTracks)
    }
    
    /// Remove multiple tracks from a playlist efficiently
    func removeTracksFromPlaylist(tracks: [Track], playlistID: UUID) async {
        guard let playlist = await MainActor.run(body: {
            playlists.first(where: { $0.id == playlistID && $0.type == .regular && $0.isContentEditable })
        }) else {
            Logger.warning("Cannot remove tracks from this playlist")
            return
        }

        let idsToRemove = Set(tracks.compactMap { $0.trackId })
        let remaining = playlist.tracks.filter { track in
            track.trackId.map { !idsToRemove.contains($0) } ?? true
        }

        await persistRegularPlaylistTracks(playlistID: playlistID, tracks: remaining)
    }
    
    /// Apply a new track order to a playlist by ID and persist it to the backing M3U file.
    func applyPlaylistTrackOrder(playlistID: UUID, orderedTrackIds: [Int64]) async {
        guard let playlist = await MainActor.run(body: {
            playlists.first(where: { $0.id == playlistID && $0.type == .regular && $0.isContentEditable })
        }) else {
            return
        }

        let byId = Dictionary(
            playlist.tracks.compactMap { track in track.trackId.map { ($0, track) } }
        ) { first, _ in first }
        let reordered = orderedTrackIds.compactMap { byId[$0] }

        guard reordered.count == playlist.tracks.count else { return }

        await persistRegularPlaylistTracks(playlistID: playlistID, tracks: reordered)
    }
}
