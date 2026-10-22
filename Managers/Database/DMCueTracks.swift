import Foundation
import GRDB

extension DatabaseManager {
    /// Prepare a whole sheet before changing the database. An invalid or missing
    /// source leaves ordinary audio import available instead of hiding the rip.
    func prepareCueTracks(
        sheets: [URL], audioURLs: [URL], folderId: Int64,
        existing: [String: FullTrack]
    ) async -> [(FullTrack, TrackMetadata)] {
        var result: [(FullTrack, TrackMetadata)] = []
        var claimedSources = Set<String>()
        var metadataByPath: [String: TrackMetadata] = [:]
        for sheetURL in sheets.sorted(by: { $0.path < $1.path }) {
            do {
                let sheet = try CueSheet.read(from: sheetURL)
                let sources = try sheet.resolveSources(relativeTo: sheetURL, audioURLs: audioURLs)
                guard claimedSources.isDisjoint(with: sources.map(\.path)) else {
                    throw CueSheet.ParseError.invalidSheet
                }
                for source in Set(sources) where metadataByPath[source.path] == nil {
                    metadataByPath[source.path] = await MetadataEngine.extractMetadata(from: source)
                }
                var prepared: [(FullTrack, TrackMetadata)] = []
                // Use one album artist for the whole sheet, including compilations.
                let albumArtist = sheet.performer ?? metadataByPath[sources[0].path]?.albumArtist
                    ?? metadataByPath[sources[0].path]?.artist ?? "Unknown Artist"
                let albumTitle = sheet.title ?? sheetURL.deletingPathExtension().lastPathComponent
                for (index, entry) in sheet.entries.enumerated() {
                    let source = sources[index]
                    guard let metadata = metadataByPath[source.path], let start = entry.start,
                          metadata.duration.isFinite, metadata.duration > start else {
                        throw CueSheet.ParseError.invalidSheet
                    }
                    let nextIndex = sources.indices.dropFirst(index + 1).first { sources[$0] == source }
                    let end = nextIndex.flatMap { sheet.entries[$0].start } ?? metadata.duration
                    guard end > start, end <= metadata.duration + 1.0 / 75 else {
                        throw CueSheet.ParseError.invalidSheet
                    }
                    let segment = CueTrackSegment(sheetPath: sheetURL.path, sourcePath: source.path,
                                                  number: entry.number, start: start, end: min(end, metadata.duration), albumSourcePath: sources[0].path)
                    // Reuse IDs, date-added and listening history across CUE edits.
                    var track = existing[segment.libraryPath] ?? FullTrack(url: source)
                    // A changed FILE can keep its virtual ID but needs the new source URL.
                    if track.url != source {
                        let previous = track
                        track = FullTrack(url: source)
                        track.trackId = previous.trackId
                        track.dateAdded = previous.dateAdded
                        track.playCount = previous.playCount
                        track.lastPlayedDate = previous.lastPlayedDate
                    }
                    track.folderId = folderId
                    applyMetadataToTrack(&track, from: metadata, at: source)
                    track.cueSegment = segment
                    track.title = entry.title ?? String(format: "%02d", entry.number)
                    track.artist = entry.performer ?? sheet.performer ?? albumArtist
                    track.album = albumTitle
                    track.albumArtist = albumArtist
                    track.composer = entry.songwriter ?? sheet.songwriter ?? track.composer
                    track.genre = sheet.genre ?? track.genre
                    track.year = sheet.year ?? track.year
                    track.discNumber = sheet.discNumber ?? track.discNumber
                    track.trackNumber = entry.number
                    track.totalTracks = sheet.entries.count
                    track.duration = segment.duration
                    // File-level sort tags describe the entire image.
                    track.sortTitle = nil
                    track.sortArtist = nil
                    track.sortAlbum = nil
                    track.sortAlbumArtist = nil
                    prepared.append((track, metadata))
                }
                result += prepared
                claimedSources.formUnion(sources.map(\.path))
            } catch {
                Logger.warning("Ignoring unusable CUE sheet \(sheetURL.lastPathComponent): \(error)")
            }
        }
        return result
    }

    func saveCueTracks(_ tracks: [(FullTrack, TrackMetadata)]) async throws {
        try await dbQueue.write { db in
            let cache = ScanLookupCache()
            for (track, metadata) in tracks {
                if track.trackId == nil {
                    try self.processNewTrack(track, metadata: metadata, in: db, cache: cache)
                } else {
                    try self.processUpdatedTrack(track, in: db, cache: cache)
                }
            }
        }
    }
}
