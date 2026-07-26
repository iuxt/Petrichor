//
// DatabaseManager class extension
//
// This extension contains methods for track processing as found from folders added.
//

import Foundation
import GRDB

extension DatabaseManager {
    func processBatch(
        _ batch: [(url: URL, folderId: Int64)],
        hardRefresh: Bool = false,
        existingFullTracksByPath: [String: FullTrack] = [:],
        modificationDates: [URL: Date] = [:],
        scanState: ScanState? = nil,
        folderName: String? = nil,
        totalFilesInFolder: Int? = nil,
        globalScanState: GlobalScanState? = nil
    ) async throws {
        let chunkSize = 100  // DB-write batch + progress cadence
        // Bound concurrent parses to the available cores.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let maxConcurrent = max(4, cores)

        Logger.info("Processing batch of \(batch.count) files in chunks of \(chunkSize), up to \(maxConcurrent) concurrent")

        let chunks = batch.chunked(into: chunkSize)

        for chunk in chunks {
            let results = try await withThrowingTaskGroup(of: (URL, TrackProcessResult).self) { group in
                var chunkResults: [(URL, TrackProcessResult)] = []
                chunkResults.reserveCapacity(chunk.count)

                var iterator = chunk.makeIterator()

                func addTask(for item: (url: URL, folderId: Int64)) {
                    group.addTask { [weak self] in
                        guard let self = self else { return (item.url, .skipped) }
                        return await self.processFile(
                            item.url,
                            folderId: item.folderId,
                            hardRefresh: hardRefresh,
                            existingFullTracksByPath: existingFullTracksByPath,
                            modificationDates: modificationDates
                        )
                    }
                }

                // Keep at most `maxConcurrent` parses in flight: prime, then refill
                // on each completion.
                for _ in 0..<maxConcurrent {
                    guard let item = iterator.next() else { break }
                    addTask(for: item)
                }
                while let result = try await group.next() {
                    chunkResults.append(result)
                    if let item = iterator.next() {
                        addTask(for: item)
                    }
                }
                return chunkResults
            }
            
            var processResults = (
                new: [(FullTrack, TrackMetadata)](),
                update: [(FullTrack, TrackMetadata)](),
                skipped: 0
            )
            
            for (_, trackResult) in results {
                switch trackResult {
                case let .new(track, metadata):
                    processResults.new.append((track, metadata))
                case let .update(track, metadata):
                    processResults.update.append((track, metadata))
                case .skipped:
                    processResults.skipped += 1
                }
            }
            
            try await dbQueue.write { [processResults] db in
                let cache = ScanLookupCache()

                for (track, metadata) in processResults.new {
                    do {
                        try self.processNewTrack(track, metadata: metadata, in: db, cache: cache)
                    } catch {
                        Logger.error("Failed to add new track \(track.title): \(error)")
                    }
                }

                for (track, _) in processResults.update {
                    do {
                        try self.processUpdatedTrack(track, in: db, cache: cache)
                    } catch {
                        Logger.error("Failed to update track \(track.title): \(error)")
                    }
                }
            }
            
            // Update progress after each chunk
            let chunkProcessed = processResults.new.count + processResults.update.count + processResults.skipped
            let newTracksCount = processResults.new.count

            if let scanState = scanState, let folderName = folderName {
                await scanState.incrementProcessed(by: chunkProcessed)
                
                if let globalState = globalScanState {
                    await globalState.incrementProcessed(by: chunkProcessed)
                    await globalState.incrementTracksAdded(by: newTracksCount)
                    let progress = await globalState.getProgress()
                    
                    if progress.total > 0 {
                        updateScanStatus("Processing: \(progress.processed)/\(progress.total) files")
                    } else {
                        updateScanStatus("Processing: \(progress.processed) files")
                    }

                    await MainActor.run {
                        // Update NotificationManager with progress
                        let detail = self.scanProgressDetail(progress)
                        NotificationManager.shared.updateActivityProgress(
                            current: progress.processed,
                            total: progress.total > 0 ? progress.total : progress.processed,
                            detail: detail
                        )
                        
                        // Check threshold during initial scan
                        if progress.isInitial {
                            NotificationCenter.default.post(name: .checkInitialScanThreshold, object: nil)
                        }
                    }
                } else if let totalFiles = totalFilesInFolder {
                    // Single folder progress
                    let currentProcessed = await scanState.getProcessedCount()
                    
                    await MainActor.run {
                        self.scanStatusMessage = "Processing: \(currentProcessed)/\(totalFiles) files in \(folderName)"
                    }
                }
            }
        }
        
        Logger.info("Batch processing complete")
    }

    // MARK: - Track Processing

    /// Process a single file
    private func processFile(
        _ fileURL: URL,
        folderId: Int64,
        hardRefresh: Bool = false,
        existingFullTracksByPath: [String: FullTrack] = [:],
        modificationDates: [URL: Date] = [:]
    ) async -> (URL, TrackProcessResult) {
        do {
            // Look up the prefetched FullTrack directly — no per-file DB read. The
            // previous code fetched a lightweight `Track` here then re-queried the
            // (serial) DB queue for its `FullTrack` on every already-known file,
            // which serialized the whole TaskGroup during incremental scans.
            // Standardize the lookup key to match how the dictionary is built (and how
            // the scan enumerates files), so symlink-resolved / un-trailing-slashed
            // paths don't cause a false miss and a duplicate insert.
            if let existingFullTrack = existingFullTracksByPath[fileURL.standardizedFileURL.path] {
                // Re-extract complete metadata on hardRefresh
                if hardRefresh {
                    let metadata = await MetadataEngine.extractMetadata(from: fileURL)

                    var updatedTrack = existingFullTrack
                    _ = updateTrackIfNeeded(&updatedTrack, with: metadata, at: fileURL)

                    // Always return as update during hard refresh
                    return (fileURL, .update(updatedTrack, metadata))
                }

                // Check if file has been modified. Prefer the modification date
                // captured during enumeration (the enumerator already stated every
                // file) instead of stating the file a second time.
                let modDate: Date?
                if let cached = modificationDates[fileURL] {
                    modDate = cached
                } else if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
                    modDate = attributes[.modificationDate] as? Date
                } else {
                    modDate = nil
                }
                if let modDate, let storedModDate = existingFullTrack.dateModified {
                    let timeDifference = abs(modDate.timeIntervalSince(storedModDate))

                    if timeDifference > 1.0 {
                        // File modified, extract fresh metadata
                        let metadata = await MetadataEngine.extractMetadata(from: fileURL)

                        var updatedTrack = existingFullTrack
                        let hasChanges = updateTrackIfNeeded(&updatedTrack, with: metadata, at: fileURL)

                        if hasChanges {
                            return (fileURL, .update(updatedTrack, metadata))
                        } else {
                            return (fileURL, .skipped)
                        }
                    }
                }

                // File not modified, skip
                return (fileURL, .skipped)
            }
            
            // New track - extract metadata
            let metadata = await MetadataEngine.extractMetadata(from: fileURL)
            
            var fullTrack = FullTrack(url: fileURL)
            fullTrack.folderId = folderId
            applyMetadataToTrack(&fullTrack, from: metadata, at: fileURL)
            
            return (fileURL, .new(fullTrack, metadata))
        } catch {
            Logger.error("Error processing file \(fileURL.lastPathComponent): \(error)")
            return (fileURL, .skipped)
        }
    }
    
    /// Process a new track with normalized data
    private func processNewTrack(_ track: FullTrack, metadata: TrackMetadata, in db: Database, cache: ScanLookupCache? = nil) throws {
        var mutableTrack = track

        // Process album first (so we can link the track to it)
        try processTrackAlbum(&mutableTrack, in: db, cache: cache)

        // Insert the track
        try mutableTrack.insert(db)

        // Ensure we have a valid track ID (fallback to lastInsertedRowID if needed)
        if mutableTrack.trackId == nil {
            mutableTrack.trackId = db.lastInsertedRowID
        }

        guard let trackId = mutableTrack.trackId else {
            throw DatabaseError.invalidTrackId
        }

        Logger.info("Added new track: \(mutableTrack.title) (ID: \(trackId))")

        // Process normalized relationships
        try processTrackArtists(mutableTrack, in: db, cache: cache)
        try processTrackGenres(mutableTrack, in: db, cache: cache)
        
        // Log interesting metadata
        #if DEBUG
        logTrackMetadata(mutableTrack)
        #endif
    }
    
    /// Process an updated track with normalized data
    func processUpdatedTrack(
        _ track: FullTrack,
        in db: Database,
        cache: ScanLookupCache? = nil
    ) throws {
        var mutableTrack = track

        // Update album association
        try processTrackAlbum(&mutableTrack, in: db, cache: cache)

        // Update the track
        try mutableTrack.update(db)

        guard let trackId = mutableTrack.trackId else {
            throw DatabaseError.invalidTrackId
        }

        Logger.info("Updated track: \(mutableTrack.title) (ID: \(trackId))")

        // Clear existing relationships
        try TrackArtist
            .filter(TrackArtist.Columns.trackId == trackId)
            .deleteAll(db)

        try TrackGenre
            .filter(TrackGenre.Columns.trackId == trackId)
            .deleteAll(db)

        // Re-process normalized relationships
        try processTrackArtists(mutableTrack, in: db, cache: cache)
        try processTrackGenres(mutableTrack, in: db, cache: cache)
        
    }
    
    // MARK: - Metadata Logging
    
    private func logTrackMetadata(_ track: FullTrack) {
        // Log interesting metadata for debugging
        if let extendedMetadata = track.extendedMetadata {
            var interestingFields: [String] = []
            
            if let isrc = extendedMetadata.isrc { interestingFields.append("ISRC: \(isrc)") }
            if let label = extendedMetadata.label { interestingFields.append("Label: \(label)") }
            if let conductor = extendedMetadata.conductor { interestingFields.append("Conductor: \(conductor)") }
            if let producer = extendedMetadata.producer { interestingFields.append("Producer: \(producer)") }
            
            if !interestingFields.isEmpty {
                Logger.info("Extended metadata: \(interestingFields.joined(separator: ", "))")
            }
        }
        
        // Log multi-artist info
        if track.artist.contains(";") || track.artist.contains(",") || track.artist.contains("&") {
            Logger.info("Multi-artist track: \(track.artist)")
        }
        
        // Log album artist if different from artist
        if let albumArtist = track.albumArtist, albumArtist != track.artist {
            Logger.info("Album artist differs: \(albumArtist)")
        }
    }
    
    // MARK: - Duplicates Matching
    /// Detect and mark duplicate tracks in the library
    func detectAndMarkDuplicates() async {
        do {
            try await dbQueue.write { db in
                // First, reset all duplicate flags using FullTrack
                try FullTrack.updateAll(
                    db,
                    FullTrack.Columns.isDuplicate.set(to: false),
                    FullTrack.Columns.primaryTrackId.set(to: nil),
                    FullTrack.Columns.duplicateGroupId.set(to: nil)
                )
                
                // Get all tracks (use lightweight Track for efficiency)
                let allTracks = try Track
                    .select(Track.lightweightSelection)
                    .fetchAll(db)
                
                // Group tracks by duplicate key
                var duplicateGroups: [String: [Track]] = [:]
                
                for track in allTracks {
                    let key = track.duplicateKey
                    if duplicateGroups[key] == nil {
                        duplicateGroups[key] = []
                    }
                    duplicateGroups[key]?.append(track)
                }
                
                // Batch-fetch every FullTrack needed for quality scoring in one query
                // (avoids an N+1 of `fetchOne` per duplicate member inside the loop).
                let duplicateMemberIds = duplicateGroups
                    .values
                    .filter { $0.count > 1 }
                    .flatMap { $0.compactMap { $0.trackId } }
                let fullTrackById: [Int64: FullTrack] = duplicateMemberIds.isEmpty
                    ? [:]
                    : try FullTrack
                        .filter(duplicateMemberIds.contains(FullTrack.Columns.trackId))
                        .fetchAll(db)
                        .reduce(into: [:]) { dict, track in
                            if let id = track.trackId { dict[id] = track }
                        }

                // Process each group that has duplicates
                for (_, tracks) in duplicateGroups where tracks.count > 1 {
                    // Look up the pre-fetched FullTracks for this group's members
                    let fullTracks = tracks.compactMap { track -> FullTrack? in
                        guard let trackId = track.trackId else { return nil }
                        return fullTrackById[trackId]
                    }

                    // Sort by quality score (highest first)
                    let sortedTracks = fullTracks.sorted { $0.qualityScore > $1.qualityScore }
                    
                    // The first track is the primary (highest quality)
                    guard let primaryTrack = sortedTracks.first,
                          let primaryId = primaryTrack.trackId else { continue }
                    
                    // Generate a unique group ID
                    let groupId = UUID().uuidString
                    
                    // Update all tracks in the group
                    for fullTrack in sortedTracks {
                        guard let trackId = fullTrack.trackId else { continue }
                        
                        if trackId == primaryId {
                            // This is the primary track
                            try FullTrack
                                .filter(FullTrack.Columns.trackId == trackId)
                                .updateAll(
                                    db,
                                    FullTrack.Columns.isDuplicate.set(to: false),
                                    FullTrack.Columns.primaryTrackId.set(to: nil),
                                    FullTrack.Columns.duplicateGroupId.set(to: groupId)
                                )
                        } else {
                            // This is a duplicate
                            try FullTrack
                                .filter(FullTrack.Columns.trackId == trackId)
                                .updateAll(
                                    db,
                                    FullTrack.Columns.isDuplicate.set(to: true),
                                    FullTrack.Columns.primaryTrackId.set(to: primaryId),
                                    FullTrack.Columns.duplicateGroupId.set(to: groupId)
                                )
                        }
                    }
                }
                
                // Log results
                let duplicateCount = try Track.filter(Track.Columns.isDuplicate == true).fetchCount(db)
                let groupCount = try Track
                    .select(Column("duplicate_group_id"), as: String?.self)
                    .distinct()
                    .filter(Column("duplicate_group_id") != nil)
                    .fetchCount(db)
                
                Logger.info("Duplicate detection complete: \(duplicateCount) duplicates found in \(groupCount) groups")
            }
        } catch {
            Logger.error("Failed to detect duplicates: \(error)")
        }
    }
    
    /// Get tracks respecting the hide duplicates setting
    func getTracksRespectingDuplicates(hideDuplicates: Bool) -> [Track] {
        do {
            return try dbQueue.read { db in
                if hideDuplicates {
                    return try Track
                        .filter(Track.Columns.isDuplicate == false)
                        .fetchAll(db)
                } else {
                    return try Track.fetchAll(db)
                }
            }
        } catch {
            Logger.error("Failed to fetch tracks: \(error)")
            return []
        }
    }
}
