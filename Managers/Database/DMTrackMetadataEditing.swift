import Foundation
import GRDB

struct TrackMetadataReindexResult {
    let track: Track
    let fullTrack: FullTrack
}

extension DatabaseManager {
    func reindexEditedTrack(
        target: TrackMetadataEditTarget,
        verified: TrackMetadataSnapshot
    ) async throws -> TrackMetadataReindexResult {
        try await dbQueue.write { db in
            let request: QueryInterfaceRequest<FullTrack>
            if let trackID = target.trackID {
                request = FullTrack.filter(FullTrack.Columns.trackId == trackID)
            } else {
                request = FullTrack.filter(FullTrack.Columns.path == target.url.path)
            }

            guard var track = try request.fetchOne(db) else {
                throw DatabaseError.invalidTrackId
            }

            let oldDuplicateKey = track.duplicateKey
            let oldAlbumID = track.albumId
            let oldArtistIDs = try TrackArtist
                .filter(TrackArtist.Columns.trackId == track.trackId)
                .select(TrackArtist.Columns.artistId, as: Int64.self)
                .fetchSet(db)
            let oldGenreIDs = try TrackGenre
                .filter(TrackGenre.Columns.trackId == track.trackId)
                .select(TrackGenre.Columns.genreId, as: Int64.self)
                .fetchSet(db)

            applyVerifiedEditableTags(verified.tags, to: &track)
            track.albumId = nil
            if let values = try? target.url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ) {
                track.fileSize = values.fileSize.map(Int64.init)
                track.dateModified = values.contentModificationDate
            }

            try processUpdatedTrack(track, in: db)

            guard let trackID = track.trackId,
                  let updated = try FullTrack
                    .filter(FullTrack.Columns.trackId == trackID)
                    .fetchOne(db) else {
                throw DatabaseError.invalidTrackId
            }

            try refreshDuplicateGroups(
                keys: Set([oldDuplicateKey, updated.duplicateKey]),
                in: db
            )
            try pruneOrphanedMetadata(
                albumIDs: Set([oldAlbumID].compactMap { $0 }),
                artistIDs: oldArtistIDs,
                genreIDs: oldGenreIDs,
                in: db
            )

            guard let finalTrack = try Track
                    .select(Track.lightweightSelection)
                    .filter(Track.Columns.trackId == trackID)
                    .fetchOne(db),
                  let finalFullTrack = try FullTrack
                    .filter(FullTrack.Columns.trackId == trackID)
                    .fetchOne(db) else {
                throw DatabaseError.invalidTrackId
            }

            return TrackMetadataReindexResult(
                track: finalTrack,
                fullTrack: finalFullTrack
            )
        }
    }

    private func applyVerifiedEditableTags(
        _ tags: TrackEditableTags,
        to track: inout FullTrack
    ) {
        let values = tags.normalized()
        track.title = values.title ?? track.url.deletingPathExtension().lastPathComponent
        track.artist = values.artist ?? "Unknown Artist"
        track.album = values.album ?? "Unknown Album"
        track.albumArtist = values.albumArtist
        track.composer = values.composer ?? "Unknown Composer"
        track.genre = values.genre ?? "Unknown Genre"
        track.releaseDate = values.releaseDate
        track.year = values.releaseDate.flatMap(MetadataMapping.year(fromDateString:)) ?? ""
        track.trackNumber = values.trackNumber
        track.totalTracks = values.trackTotal
        track.discNumber = values.discNumber
        track.totalDiscs = values.discTotal
        track.bpm = values.bpm
        track.compilation = values.compilation

        var extended = track.extendedMetadata ?? ExtendedMetadata()
        extended.comment = values.comment
        track.extendedMetadata = extended
    }

    private func refreshDuplicateGroups(
        keys: Set<String>,
        in db: Database
    ) throws {
        guard !keys.isEmpty else { return }

        let allTracks = try Track
            .select(Track.lightweightSelection)
            .fetchAll(db)
        let affectedTracks = allTracks.filter { keys.contains($0.duplicateKey) }
        let affectedTrackIDs = affectedTracks.compactMap(\.trackId)

        guard !affectedTrackIDs.isEmpty else { return }

        try FullTrack
            .filter(affectedTrackIDs.contains(FullTrack.Columns.trackId))
            .updateAll(
                db,
                FullTrack.Columns.isDuplicate.set(to: false),
                FullTrack.Columns.primaryTrackId.set(to: nil),
                FullTrack.Columns.duplicateGroupId.set(to: nil)
            )

        let groups = Dictionary(grouping: affectedTracks, by: \.duplicateKey)
        let duplicateTrackIDs = groups.values
            .filter { $0.count > 1 }
            .flatMap { $0.compactMap(\.trackId) }

        guard !duplicateTrackIDs.isEmpty else { return }

        let fullTrackByID = try FullTrack
            .filter(duplicateTrackIDs.contains(FullTrack.Columns.trackId))
            .fetchAll(db)
            .reduce(into: [Int64: FullTrack]()) { result, track in
                if let trackID = track.trackId {
                    result[trackID] = track
                }
            }

        for group in groups.values where group.count > 1 {
            let sortedTracks = group
                .compactMap { lightweight -> FullTrack? in
                    guard let trackID = lightweight.trackId else { return nil }
                    return fullTrackByID[trackID]
                }
                .sorted { $0.qualityScore > $1.qualityScore }

            guard let primaryTrack = sortedTracks.first,
                  let primaryID = primaryTrack.trackId else {
                continue
            }

            let groupID = UUID().uuidString
            for track in sortedTracks {
                guard let trackID = track.trackId else { continue }

                if trackID == primaryID {
                    try FullTrack
                        .filter(FullTrack.Columns.trackId == trackID)
                        .updateAll(
                            db,
                            FullTrack.Columns.isDuplicate.set(to: false),
                            FullTrack.Columns.primaryTrackId.set(to: nil),
                            FullTrack.Columns.duplicateGroupId.set(to: groupID)
                        )
                } else {
                    try FullTrack
                        .filter(FullTrack.Columns.trackId == trackID)
                        .updateAll(
                            db,
                            FullTrack.Columns.isDuplicate.set(to: true),
                            FullTrack.Columns.primaryTrackId.set(to: primaryID),
                            FullTrack.Columns.duplicateGroupId.set(to: groupID)
                        )
                }
            }
        }
    }

    private func pruneOrphanedMetadata(
        albumIDs: Set<Int64>,
        artistIDs: Set<Int64>,
        genreIDs: Set<Int64>,
        in db: Database
    ) throws {
        if !albumIDs.isEmpty {
            let referencedAlbumIDs = try Track
                .filter(albumIDs.contains(Track.Columns.albumId))
                .select(Track.Columns.albumId, as: Int64?.self)
                .distinct()
                .fetchSet(db)
                .compactMap { $0 }
            let orphanedAlbumIDs = albumIDs.subtracting(referencedAlbumIDs)

            if !orphanedAlbumIDs.isEmpty {
                try Album
                    .filter(orphanedAlbumIDs.contains(Album.Columns.id))
                    .deleteAll(db)
            }
        }

        if !artistIDs.isEmpty {
            let artistIDsWithTracks = try TrackArtist
                .filter(artistIDs.contains(TrackArtist.Columns.artistId))
                .select(TrackArtist.Columns.artistId, as: Int64.self)
                .distinct()
                .fetchSet(db)
            let artistIDsWithAlbums = try AlbumArtist
                .filter(artistIDs.contains(AlbumArtist.Columns.artistId))
                .select(AlbumArtist.Columns.artistId, as: Int64.self)
                .distinct()
                .fetchSet(db)
            let referencedArtistIDs = artistIDsWithTracks.union(artistIDsWithAlbums)
            let orphanedArtistIDs = artistIDs.subtracting(referencedArtistIDs)

            if !orphanedArtistIDs.isEmpty {
                try Artist
                    .filter(orphanedArtistIDs.contains(Artist.Columns.id))
                    .deleteAll(db)
            }
        }

        if !genreIDs.isEmpty {
            let referencedGenreIDs = try TrackGenre
                .filter(genreIDs.contains(TrackGenre.Columns.genreId))
                .select(TrackGenre.Columns.genreId, as: Int64.self)
                .distinct()
                .fetchSet(db)
            let orphanedGenreIDs = genreIDs.subtracting(referencedGenreIDs)

            if !orphanedGenreIDs.isEmpty {
                try Genre
                    .filter(orphanedGenreIDs.contains(Genre.Columns.id))
                    .deleteAll(db)
            }
        }
    }
}
