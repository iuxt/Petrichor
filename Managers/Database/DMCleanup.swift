//
// DatabaseManager class extension
//
// This extension contains methods for cleaning up orphaned database entries
// on folder updates when tracks are removed or updated.
//

import Foundation
import GRDB

extension DatabaseManager {
    func removeTrackFromLibrary(_ track: Track) async throws {
        guard let trackId = track.trackId else {
            throw DatabaseError.invalidTrackId
        }

        // Delete the track and clean up the orphans it leaves behind in a single
        // transaction, so a crash between the two can't leave dangling
        // artists/albums/genres pointing at nothing.
        try await dbQueue.write { db in
            try deleteTracksAndCleanupLocked([trackId], in: db)
        }
    }

    /// Clean up all orphaned data in the database
    func cleanupOrphanedData() async throws {
        Logger.info("Starting comprehensive database cleanup...")
        
        try await dbQueue.write { db in
            var deletedCounts = [String: Int]()
            
            // 1. Clean up orphaned entries in junction tables first
            // Using raw SQL for these as GRDB doesn't have clean syntax for NOT IN subqueries
            
            // Remove track_artists entries where track no longer exists
            try db.execute(
                sql: """
                DELETE FROM track_artists
                WHERE track_id NOT IN (SELECT id FROM tracks)
                """
            )
            deletedCounts["track_artists"] = Int(db.changesCount)
            
            // Remove track_genres entries where track no longer exists
            try db.execute(
                sql: """
                DELETE FROM track_genres
                WHERE track_id NOT IN (SELECT id FROM tracks)
                """
            )
            deletedCounts["track_genres"] = Int(db.changesCount)
            
            // Remove album_artists entries where album no longer exists
            try db.execute(
                sql: """
                DELETE FROM album_artists
                WHERE album_id NOT IN (SELECT id FROM albums)
                """
            )
            deletedCounts["album_artists"] = Int(db.changesCount)
            
            // Remove playlist_tracks entries where track no longer exists
            try db.execute(
                sql: """
                DELETE FROM playlist_tracks
                WHERE track_id NOT IN (SELECT id FROM tracks)
                """
            )
            deletedCounts["playlist_tracks"] = Int(db.changesCount)
            
            // 2. Now clean up main tables using GRDB where possible
            
            // Get all artist IDs that are still referenced in track_artists OR album_artists.
            // Album-only artists (e.g. the canonical "Various Artists" used to anchor
            // compilations) have no track_artists rows but must not be considered orphaned.
            let artistsWithTracks = try TrackArtist
                .select(TrackArtist.Columns.artistId, as: Int64.self)
                .distinct()
                .fetchSet(db)

            let artistsWithAlbums = try AlbumArtist
                .select(AlbumArtist.Columns.artistId, as: Int64.self)
                .distinct()
                .fetchSet(db)

            let referencedArtists = artistsWithTracks.union(artistsWithAlbums)

            // Delete artists that have NO references in either junction
            let allArtistIds = try Artist.select(Artist.Columns.id, as: Int64.self).fetchSet(db)
            let artistsToDelete = allArtistIds.subtracting(referencedArtists)
            
            if !artistsToDelete.isEmpty {
                let orphanedArtists = try Artist
                    .filter(artistsToDelete.contains(Artist.Columns.id))
                    .deleteAll(db)
                deletedCounts["artists"] = orphanedArtists
            }
            
            // Delete orphaned albums (albums with no tracks)
            let albumsWithTracks = try Track
                .select(Track.Columns.albumId, as: Int64?.self)
                .filter(Track.Columns.albumId != nil)
                .distinct()
                .fetchSet(db)
                .compactMap { $0 }
            
            let allAlbumIds = try Album.select(Album.Columns.id, as: Int64.self).fetchSet(db)
            let albumsToDelete = allAlbumIds.subtracting(albumsWithTracks)
            
            if !albumsToDelete.isEmpty {
                let orphanedAlbums = try Album
                    .filter(albumsToDelete.contains(Album.Columns.id))
                    .deleteAll(db)
                deletedCounts["albums"] = orphanedAlbums
            }
            
            // Delete orphaned genres (genres with no tracks)
            let genresWithTracks = try TrackGenre
                .select(TrackGenre.Columns.genreId, as: Int64.self)
                .distinct()
                .fetchSet(db)
            
            let allGenreIds = try Genre.select(Genre.Columns.id, as: Int64.self).fetchSet(db)
            let genresToDelete = allGenreIds.subtracting(genresWithTracks)
            
            if !genresToDelete.isEmpty {
                let orphanedGenres = try Genre
                    .filter(genresToDelete.contains(Genre.Columns.id))
                    .deleteAll(db)
                deletedCounts["genres"] = orphanedGenres
            }
            
            // 3. Clean up other orphaned data using raw SQL

            // Delete orphaned pinned items
            try db.execute(
                sql: """
                DELETE FROM pinned_items
                WHERE (artist_id IS NOT NULL AND artist_id NOT IN (SELECT id FROM artists))
                   OR (album_id IS NOT NULL AND album_id NOT IN (SELECT id FROM albums))
                   OR (playlist_id IS NOT NULL AND playlist_id NOT IN (SELECT id FROM playlists))
                """
            )
            deletedCounts["pinned_items"] = Int(db.changesCount)
            
            // Log cleanup results
            var totalDeleted = 0
            for (table, count) in deletedCounts where count > 0 {
                Logger.info("Cleaned up \(count) orphaned entries from \(table)")
                totalDeleted += count
            }
            
            if totalDeleted > 0 {
                Logger.info("Database cleanup completed: \(totalDeleted) total orphaned entries removed")
            } else {
                Logger.info("Database cleanup completed: No orphaned entries found")
            }
        }
    }
    
    //// Clean up after removing specific tracks.
    ///
    /// Opens its own write transaction. The tracks must still be present (their
    /// junction rows are read to find affected parents before deletion). When you
    /// are deleting the tracks in your own write transaction, call
    /// `deleteTracksAndCleanupLocked(_:in:)` inside it instead so the delete +
    /// cleanup commit atomically.
    func cleanupAfterTrackRemoval(_ trackIds: [Int64]) async throws {
        guard !trackIds.isEmpty else { return }

        Logger.info("Cleaning up after removing \(trackIds.count) tracks...")

        try await dbQueue.write { db in
            try deleteTracksAndCleanupLocked(trackIds, in: db)
        }
    }

    /// Atomically delete `trackIds` and clean up the orphaned parents they leave
    /// behind, all within the caller's transaction. Captures affected
    /// artist/album/genre IDs *before* the cascade removes the junction rows, then
    /// deletes the tracks, then prunes the parents that no longer have any tracks.
    func deleteTracksAndCleanupLocked(_ trackIds: [Int64], in db: Database) throws {
        guard !trackIds.isEmpty else { return }

        // Capture affected parent IDs before the cascade clears the junction rows.
        let affectedArtistIds = try TrackArtist
            .filter(trackIds.contains(TrackArtist.Columns.trackId))
            .select(TrackArtist.Columns.artistId, as: Int64.self)
            .distinct()
            .fetchSet(db)

        let affectedAlbumIds = try Track
            .filter(trackIds.contains(Track.Columns.trackId))
            .filter(Track.Columns.albumId != nil)
            .select(Track.Columns.albumId, as: Int64?.self)
            .fetchSet(db)
            .compactMap { $0 }

        let affectedGenreIds = try TrackGenre
            .filter(trackIds.contains(TrackGenre.Columns.trackId))
            .select(TrackGenre.Columns.genreId, as: Int64.self)
            .distinct()
            .fetchSet(db)

        // Delete the tracks (cascades their junction rows).
        let deletedCount = try Track
            .filter(trackIds.contains(Track.Columns.trackId))
            .deleteAll(db)
        Logger.info("Deleted \(deletedCount) tracks and their junction rows")

        // Now prune the parents that no longer have any tracks.
        let artistsWithTracks = try TrackArtist
            .filter(affectedArtistIds.contains(TrackArtist.Columns.artistId))
            .select(TrackArtist.Columns.artistId, as: Int64.self)
            .distinct()
            .fetchSet(db)
        let artistsToDelete = Set(affectedArtistIds).subtracting(artistsWithTracks)
        if !artistsToDelete.isEmpty {
            let count = try Artist
                .filter(artistsToDelete.contains(Artist.Columns.id))
                .deleteAll(db)
            Logger.info("Removed \(count) orphaned artists")
        }

        let albumsWithTracks = try Track
            .filter(affectedAlbumIds.contains(Track.Columns.albumId))
            .select(Track.Columns.albumId, as: Int64?.self)
            .distinct()
            .fetchSet(db)
            .compactMap { $0 }
        let albumsToDelete = Set(affectedAlbumIds).subtracting(albumsWithTracks)
        if !albumsToDelete.isEmpty {
            let count = try Album
                .filter(albumsToDelete.contains(Album.Columns.id))
                .deleteAll(db)
            Logger.info("Removed \(count) orphaned albums")
        }

        let genresWithTracks = try TrackGenre
            .filter(affectedGenreIds.contains(TrackGenre.Columns.genreId))
            .select(TrackGenre.Columns.genreId, as: Int64.self)
            .distinct()
            .fetchSet(db)
        let genresToDelete = Set(affectedGenreIds).subtracting(genresWithTracks)
        if !genresToDelete.isEmpty {
            let count = try Genre
                .filter(genresToDelete.contains(Genre.Columns.id))
                .deleteAll(db)
            Logger.info("Removed \(count) orphaned genres")
        }
    }
}
