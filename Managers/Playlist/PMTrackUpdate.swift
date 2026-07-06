//
// PlaylistManager class extension
//
// This extension contains methods for updating individual tracks based on user
// interaction events like play count and last played date.
// The methods internally also use DatabaseManager methods to work with database.
//

import Foundation
import GRDB

extension PlaylistManager {
    /// Add or remove a track from any playlist (handles both regular and smart playlists)
    func updateTrackInPlaylist(track: Track, playlist: Playlist, add: Bool) {
        Task {
            do {
                guard libraryManager?.databaseManager != nil else { return }

                if playlist.type == .smart {
                    return
                }

                // For regular playlists, add/remove from playlist
                if add {
                    await addTrackToRegularPlaylist(track: track, playlistID: playlist.id)
                } else {
                    await removeTrackFromRegularPlaylist(track: track, playlistID: playlist.id)
                }
            }
        }
    }

    /// Update play count for a track
    func incrementPlayCount(for track: Track) {
        Task { [weak self] in
            guard let self else { return }

            guard let trackId = track.trackId else {
                Logger.error("Cannot update play count - track has no database ID")
                return
            }
            
            guard let dbManager = libraryManager?.databaseManager else {
                Logger.error("Cannot update play count - no database manager")
                return
            }

            do {
                let currentPlayCount = try await dbManager.getTrackPlayCount(trackId: trackId) ?? track.playCount
                let newPlayCount = currentPlayCount + 1
                let lastPlayedDate = Date()

                try await dbManager.updatePlayingTrackMetadata(
                    trackId: trackId,
                    playCount: newPlayCount,
                    lastPlayedDate: lastPlayedDate
                )

                Logger.info("Incremented play count for track: \(track.title) (now: \(newPlayCount))")
                
                updateSmartPlaylistCounts()
                
                // Refresh smart playlists affected by play count/last played changes
                Task.detached(priority: .background) { [weak self] in
                    guard let self = self else { return }

                    // Snapshot the (value-type) playlists array on the main actor before
                    // iterating, since `self.playlists` is main-actor-isolated.
                    let playlists = await MainActor.run { self.playlists }
                    for playlist in playlists where playlist.type == .smart && !playlist.isUserEditable {
                        if playlist.name == DefaultPlaylists.mostPlayed ||
                           playlist.name == DefaultPlaylists.recentlyPlayed {
                            await self.loadSmartPlaylistTracks(playlist)
                        }
                    }
                }
            } catch {
                Logger.error("Failed to update play count: \(error)")
            }
        }
    }

    /// Handle track property updates to refresh smart playlists and other dependent data
    internal func handleTrackPropertyUpdate(_ track: Track) async {
        // Update current queue if the track is in it
        await MainActor.run {
            if let queueIndex = self.currentQueue.firstIndex(where: { $0.trackId == track.trackId }) {
                self.currentQueue[queueIndex] = track
            }
        }

        // Update current track if it's the one being updated
        if let currentTrack = audioPlayer?.currentTrack, currentTrack.trackId == track.trackId {
            await MainActor.run {
                self.audioPlayer?.currentTrack = track
            }
        }
    }
}
