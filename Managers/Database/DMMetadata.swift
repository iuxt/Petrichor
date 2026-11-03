//
// DatabaseManager class extension
//
// This extension contains track metadata management methods which allow for setting up parsed
// track information into track table.
//

import Foundation
import GRDB

extension DatabaseManager {
    func applyMetadataToTrack(_ track: inout FullTrack, from metadata: TrackMetadata, at fileURL: URL) {
        // Core fields
        track.title = metadata.title?.nilIfEmpty ?? fileURL.deletingPathExtension().lastPathComponent
        track.artist = metadata.artist?.nilIfEmpty ?? "Unknown Artist"
        track.album = metadata.album?.nilIfEmpty ?? "Unknown Album"
        track.genre = metadata.genre?.nilIfEmpty ?? "Unknown Genre"
        track.composer = metadata.composer?.nilIfEmpty ?? "Unknown Composer"
        track.year = metadata.year?.nilIfEmpty ?? ""
        track.duration = HelperUtils.sanitizedDuration(metadata.duration)
        
        // Artwork is resolved on demand by ArtworkResolver at playback and is not stored in SQLite.

        // Additional metadata
        track.albumArtist = metadata.albumArtist
        track.trackNumber = metadata.trackNumber
        track.totalTracks = metadata.totalTracks
        track.discNumber = metadata.discNumber
        track.totalDiscs = metadata.totalDiscs
        track.rating = metadata.rating
        track.compilation = metadata.compilation
        track.releaseDate = metadata.releaseDate
        track.originalReleaseDate = metadata.originalReleaseDate
        track.bpm = metadata.bpm
        track.mediaType = metadata.mediaType

        // Sort fields
        track.sortTitle = metadata.sortTitle
        track.sortArtist = metadata.sortArtist
        track.sortAlbum = metadata.sortAlbum
        track.sortAlbumArtist = metadata.sortAlbumArtist

        // Audio properties
        track.bitrate = metadata.bitrate
        track.sampleRate = metadata.sampleRate
        track.channels = metadata.channels
        track.codec = metadata.codec
        track.bitDepth = metadata.bitDepth
        track.lossless = metadata.lossless

        // File properties
        if let attributes = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            track.fileSize = attributes.fileSize.map { Int64($0) }
            track.dateModified = attributes.contentModificationDate
        }

        // Extended metadata
        track.extendedMetadata = metadata.extended
    }

    func updateTrackIfNeeded(_ track: inout FullTrack, with metadata: TrackMetadata, at fileURL: URL) -> Bool {
        guard metadata.readSucceeded else { return false }
        // A successful read is authoritative, including removed tags. Preserve a
        // known duration if a backend could read tags but not the audio length.
        let previousDuration = track.duration
        applyMetadataToTrack(&track, from: metadata, at: fileURL)
        if track.duration <= 0 { track.duration = previousDuration }
        return true
    }

    // MARK: - Artist Info Lookup

    func getArtistBio(for artistName: String) -> String? {
        do {
            return try dbQueue.read { db in
                try Artist
                    .filter(Artist.Columns.name == artistName)
                    .fetchOne(db)?
                    .bio
            }
        } catch {
            Logger.error("Failed to get artist bio: \(error)")
            return nil
        }
    }
}
