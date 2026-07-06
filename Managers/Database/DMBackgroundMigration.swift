//
// DatabaseManager class extension
//
// This extension contains background migration logic for heavy one-time data transformations
// that run asynchronously after app launch without blocking the UI.
//

import Foundation
import GRDB

extension DatabaseManager {
    /// Returns true if at least one migration actually performed data work, so the
    /// caller can refresh category/sidebar caches that the migration may have changed.
    @discardableResult
    func runPendingBackgroundMigrations() async -> Bool {
        let pending: [(identifier: String, progress: String?)]
        do {
            pending = try await dbQueue.read { db -> [(String, String?)] in
                if try db.tableExists("background_migrations") {
                    let sql = """
                        SELECT identifier, progress FROM background_migrations \
                        WHERE completed_at IS NULL ORDER BY identifier
                        """
                    return try Row.fetchAll(db, sql: sql)
                        .map { ($0["identifier"], $0["progress"]) }
                }
                return []
            }
        } catch {
            Logger.error("Failed to read pending background migrations: \(error)")
            return false
        }
        if pending.isEmpty { return false }

        // Skip migrations on a fresh/empty database — nothing to migrate
        let trackCount = (try? await dbQueue.read { db in try Track.fetchCount(db) }) ?? 0
        if trackCount == 0 {
            for (identifier, _) in pending {
                completeBackgroundMigration(identifier)
            }
            Logger.info("Skipped \(pending.count) background migrations on empty database")
            return false
        }

        for (identifier, progress) in pending {
            switch identifier {
            case Self.knownArtistsMigrationIdentifier:
                await loadKnownArtistsAndRebuild(progress: progress)
            case Self.albumArtistBackfillIdentifier:
                await backfillAlbumArtists(progress: progress)
            default:
                Logger.warning("Unknown background migration: \(identifier)")
            }
        }
        return true
    }

    // MARK: - v9: Load Known Artists & Rebuild Artist Associations

    private static let knownArtistsMigrationIdentifier = "v9_background_rebuild_artist_associations"

    private struct KnownArtistsProgress: Codable {
        let offset: Int
    }

    private func loadKnownArtistsAndRebuild(progress: String?) async {
        await MainActor.run {
            NotificationManager.shared.startActivity(String(appLocalized: "Updating Artists..."))
        }

        var resumeOffset = 0
        if let progress = progress,
           let data = progress.data(using: .utf8),
           let state = try? JSONDecoder().decode(KnownArtistsProgress.self, from: data) {
            resumeOffset = state.offset
            Logger.info("Resuming known artists migration at offset \(resumeOffset)")
        }

        do {
            try await rebuildArtistAssociations(resumeOffset: resumeOffset)

            completeBackgroundMigration(Self.knownArtistsMigrationIdentifier)
            await MainActor.run {
                NotificationManager.shared.stopActivity()
                NotificationManager.shared.addMessage(.info, String(appLocalized: "Artists information updated successfully"))
            }
            Logger.info("Known artists migration completed")
        } catch {
            await MainActor.run {
                NotificationManager.shared.stopActivity()
                NotificationManager.shared.addMessage(.error, String(appLocalized: "Failed to update artists information"))
            }
            Logger.error("Known artists migration failed: \(error)")
        }
    }

    /// Rebuild all TrackArtist/AlbumArtist associations using updated parser
    private func rebuildArtistAssociations(resumeOffset: Int) async throws {
        let totalTracks = try await dbQueue.read { db in
            try FullTrack.filter(FullTrack.Columns.isDuplicate == false).fetchCount(db)
        }

        guard totalTracks > 0 else {
            Logger.info("No tracks to rebuild artist associations for")
            return
        }

        Logger.info("Rebuilding artist associations for \(totalTracks) tracks")

        try await Task.detached(priority: .utility) { [dbQueue, weak self] in
            guard let self = self else { return }

            // Snapshot pinned items before clearing associations
            let pinnedArtists = self.snapshotPinnedItems(idColumn: PinnedItem.Columns.artistId)
            let pinnedAlbums = self.snapshotPinnedItems(idColumn: PinnedItem.Columns.albumId)

            ArtistParser.loadKnownArtists()
            // Balanced unload even if a batch write below throws, so the retain count can't leak.
            defer { ArtistParser.unloadKnownArtists() }

            // Clear existing associations and reset stats
            _ = try dbQueue.write { db in
                try TrackArtist.deleteAll(db)
                try AlbumArtist.deleteAll(db)
                try Artist.updateAll(db, Artist.Columns.totalTracks.set(to: 0), Artist.Columns.totalAlbums.set(to: 0))
                try Album.updateAll(db, Album.Columns.totalTracks.set(to: 0))
            }

            Logger.info("Cleared existing artist/album associations")

            // Rebuild in batches
            let batchSize = 500
            var offset = resumeOffset

            while offset < totalTracks {
                let tracks = try dbQueue.read { db in
                    try FullTrack
                        .filter(FullTrack.Columns.isDuplicate == false)
                        .order(FullTrack.Columns.trackId)
                        .limit(batchSize, offset: offset)
                        .fetchAll(db)
                }

                if tracks.isEmpty { break }

                _ = try dbQueue.write { db in
                    for var track in tracks {
                        try self.processTrackArtists(track, in: db)
                        try self.processTrackAlbum(&track, in: db)
                    }
                }

                offset += tracks.count
                Task { @MainActor in
                    NotificationManager.shared.updateActivityProgress(current: offset, total: totalTracks)
                }
                self.saveProgress(offset: offset)
            }

            // Update stats
            try dbQueue.write { db in
                try self.updateEntityStats(in: db)
            }

            // Re-link pinned items by name
            self.relinkPinnedArtists(pinnedArtists)
            self.relinkPinnedAlbums(pinnedAlbums)

            Logger.info("Artist associations rebuild completed")
        }.value

        // Clean up orphaned entities (runs in its own dbQueue.write)
        try await cleanupOrphanedData()
    }

    // MARK: - v9 Helpers

    private func saveProgress(offset: Int) {
        if let data = try? JSONEncoder().encode(KnownArtistsProgress(offset: offset)),
           let json = String(data: data, encoding: .utf8) {
            updateMigrationProgress(Self.knownArtistsMigrationIdentifier, progress: json)
        }
    }

    private func snapshotPinnedItems(idColumn: Column) -> [(id: Int64, name: String)] {
        (try? dbQueue.read { db in
            try PinnedItem
                .filter(idColumn != nil)
                .filter(PinnedItem.Columns.filterValue != nil)
                .select(PinnedItem.Columns.id, PinnedItem.Columns.filterValue)
                .asRequest(of: Row.self)
                .fetchAll(db)
                .compactMap { row -> (Int64, String)? in
                    guard let id: Int64 = row[PinnedItem.Columns.id],
                          let name: String = row[PinnedItem.Columns.filterValue] else { return nil }
                    return (id, name)
                }
        }) ?? []
    }

    private func relinkPinnedArtists(_ pinnedArtists: [(id: Int64, name: String)]) {
        guard !pinnedArtists.isEmpty else { return }
        do {
            _ = try dbQueue.write { db in
                for (pinnedId, artistName) in pinnedArtists {
                    let normalized = ArtistParser.normalizeArtistName(artistName)
                    if let artist = try Artist.filter(Artist.Columns.normalizedName == normalized).fetchOne(db),
                       let newId = artist.id {
                        try PinnedItem.filter(PinnedItem.Columns.id == pinnedId)
                            .updateAll(db, PinnedItem.Columns.artistId.set(to: newId))
                    }
                }
            }
            Logger.info("Re-linked \(pinnedArtists.count) pinned artist items")
        } catch {
            Logger.error("Failed to re-link pinned artists: \(error)")
        }
    }

    private func relinkPinnedAlbums(_ pinnedAlbums: [(id: Int64, name: String)]) {
        guard !pinnedAlbums.isEmpty else { return }
        do {
            _ = try dbQueue.write { db in
                for (pinnedId, albumName) in pinnedAlbums {
                    let normalizedTitle = Album.normalizeTitle(albumName)
                    if let album = try Album.filter(Album.Columns.normalizedTitle == normalizedTitle).fetchOne(db),
                       let newId = album.id {
                        try PinnedItem.filter(PinnedItem.Columns.id == pinnedId)
                            .updateAll(db, PinnedItem.Columns.albumId.set(to: newId))
                    }
                }
            }
            Logger.info("Re-linked \(pinnedAlbums.count) pinned album items")
        } catch {
            Logger.error("Failed to re-link pinned albums: \(error)")
        }
    }

    // MARK: - Migration State

    func isActiveBackgroundMigrationResumable() -> Bool {
        do {
            return try dbQueue.read { db -> Bool in
                if try db.tableExists("background_migrations") {
                    return try Bool.fetchOne(
                        db,
                        sql: "SELECT resumable FROM background_migrations WHERE completed_at IS NULL LIMIT 1"
                    ) ?? true
                }
                return true
            }
        } catch {
            return true
        }
    }

    // MARK: - v12: Backfill album-artist associations

    private static let albumArtistBackfillIdentifier = "v12_background_backfill_album_artists"

    private struct AlbumArtistBackfillProgress: Codable {
        let offset: Int
    }

    private func backfillAlbumArtists(progress: String?) async {
        await MainActor.run {
            NotificationManager.shared.startActivity(String(appLocalized: "Updating album artists..."))
        }

        var resumeOffset = 0
        if let progress = progress,
           let data = progress.data(using: .utf8),
           let state = try? JSONDecoder().decode(AlbumArtistBackfillProgress.self, from: data) {
            resumeOffset = state.offset
            Logger.info("Resuming album-artist backfill at offset \(resumeOffset)")
        }

        do {
            try await performAlbumArtistBackfill(resumeOffset: resumeOffset)
            completeBackgroundMigration(Self.albumArtistBackfillIdentifier)
            await MainActor.run {
                NotificationManager.shared.stopActivity()
            }
            Logger.info("Album-artist backfill completed")
        } catch {
            // Leave the migration unfinished (completed_at stays NULL) so it resumes
            // from the saved offset on next launch. Never rethrow - don't crash launch.
            await MainActor.run {
                NotificationManager.shared.stopActivity()
            }
            Logger.error("Album-artist backfill failed (will resume next launch): \(error)")
        }
    }

    /// Backfills a `role='album_artist'` junction row (falling back to the track
    /// artist) for tracks that have none. Resumable (saved offset) and idempotent
    /// (per-track existence check); append-only, never clearing existing rows.
    private func performAlbumArtistBackfill(resumeOffset: Int) async throws {
        let totalTracks = try await dbQueue.read { db in try Track.fetchCount(db) }
        guard totalTracks > 0 else { return }

        Logger.info("Backfilling album artists across \(totalTracks) tracks")

        try await Task.detached(priority: .utility) { [dbQueue, weak self] in
            guard let self = self else { return }

            let batchSize = 500
            var offset = resumeOffset

            while offset < totalTracks {
                let tracks = try dbQueue.read { db in
                    try FullTrack
                        .order(FullTrack.Columns.trackId)
                        .limit(batchSize, offset: offset)
                        .fetchAll(db)
                }
                if tracks.isEmpty { break }

                try dbQueue.write { db in
                    for track in tracks {
                        guard let trackId = track.trackId else { continue }

                        // Skip tracks that already have an album-artist relationship
                        // (a real tag, or a prior backfill run). Makes resume safe.
                        let alreadyLinked = try TrackArtist
                            .filter(TrackArtist.Columns.trackId == trackId)
                            .filter(TrackArtist.Columns.role == TrackArtist.Role.albumArtist)
                            .fetchCount(db) > 0
                        if alreadyLinked { continue }

                        guard let field = self.resolvedAlbumArtistField(for: track) else { continue }
                        try self.processArtistsForField(field, trackId: trackId, role: TrackArtist.Role.albumArtist, in: db)
                    }
                }

                offset += tracks.count
                Task { @MainActor in
                    NotificationManager.shared.updateActivityProgress(current: offset, total: totalTracks)
                }
                if let data = try? JSONEncoder().encode(AlbumArtistBackfillProgress(offset: offset)),
                   let json = String(data: data, encoding: .utf8) {
                    self.updateMigrationProgress(Self.albumArtistBackfillIdentifier, progress: json)
                }
            }
        }.value
    }

    // MARK: - Helpers

    func updateMigrationProgress(_ identifier: String, progress: String) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE background_migrations SET progress = ? WHERE identifier = ?",
                    arguments: [progress, identifier]
                )
            }
        } catch {
            Logger.error("Failed to update migration progress for \(identifier): \(error)")
        }
    }

    func completeBackgroundMigration(_ identifier: String) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE background_migrations SET completed_at = ?, progress = NULL WHERE identifier = ?",
                    arguments: [Date(), identifier]
                )
            }
        } catch {
            Logger.error("Failed to mark migration \(identifier) as completed: \(error)")
        }
    }
}
