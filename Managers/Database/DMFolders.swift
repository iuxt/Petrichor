//
// DatabaseManager class extension
//
// This extension contains all the folder management methods which allow mapping folders in the app
// and create corresponding records in `folders` table in the db, and scanning folders for tracks.
//

import Foundation
import GRDB

actor ScanState {
    var processedCount = 0
    var failedFiles: [(url: URL, error: Error)] = []
    var skippedFiles: [(url: URL, extension: String)] = []
    
    func incrementProcessed(by count: Int) {
        processedCount += count
    }
    
    func addFailedFiles(_ files: [(url: URL, error: Error)]) {
        failedFiles.append(contentsOf: files)
    }
    
    func addSkippedFiles(_ files: [(url: URL, extension: String)]) {
        skippedFiles.append(contentsOf: files)
    }
    
    func getProcessedCount() -> Int { processedCount }
    func getFailedFiles() -> [(url: URL, error: Error)] { failedFiles }
    func getSkippedFiles() -> [(url: URL, extension: String)] { skippedFiles }
}

struct GlobalScanProgress {
    let processed: Int
    let total: Int
    let added: Int
    let removed: Int
    let isInitial: Bool
}

actor GlobalScanState {
    var totalFiles: Int
    let isInitialScan: Bool
    var processedFiles = 0
    var tracksAdded = 0
    var tracksRemoved = 0

    init(totalFiles: Int, isInitialScan: Bool = false) {
        self.totalFiles = totalFiles
        self.isInitialScan = isInitialScan
    }

    /// Grow the total as each folder's real file count becomes known during
    /// enumeration, so we don't need a separate full-directory pre-count walk
    /// just to seed the progress bar.
    func addTotal(by count: Int) {
        totalFiles += count
    }

    func incrementProcessed(by count: Int) {
        processedFiles += count
    }
    
    func incrementTracksAdded(by count: Int) {
        tracksAdded += count
    }

    func incrementTracksRemoved(by count: Int) {
        tracksRemoved += count
    }

    func getProgress() -> GlobalScanProgress {
        GlobalScanProgress(
            processed: processedFiles,
            total: totalFiles,
            added: tracksAdded,
            removed: tracksRemoved,
            isInitial: isInitialScan
        )
    }
}

/// Result of a single-pass folder enumeration
struct FolderEnumerationResult {
    let musicFiles: [URL]
    let modificationDates: [URL: Date]  // audio file URL -> contentModificationDate (captured during enumeration)
    let unsupportedFiles: [(url: URL, extension: String)]
}

extension DatabaseManager {
    func addFolders(_ urls: [URL], bookmarkDataMap: [URL: Data], completion: @escaping (Result<[Folder], Error>) -> Void) {
        Task(priority: .utility) {
            do {
                let folders = try await addFoldersAsync(urls, bookmarkDataMap: bookmarkDataMap)
                await MainActor.run {
                    completion(.success(folders))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                    Logger.error("Failed to add folders: \(error)")
                    NotificationManager.shared.addMessage(.error, String(appLocalized: "Failed to add folders"))
                }
            }
        }
    }

    func addFoldersAsync(_ urls: [URL], bookmarkDataMap: [URL: Data]) async throws -> [Folder] {
        await MainActor.run {
            self.isScanning = true
            self.scanStatusMessage = "Adding folders..."
        }

        let addedFolders = try await dbQueue.write { db -> [Folder] in
            var folders: [Folder] = []

            for url in urls {
                let bookmarkData = bookmarkDataMap[url]
                var folder = Folder(url: url, bookmarkData: bookmarkData)

                // Get the file system modification date
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let fsModDate = attributes[.modificationDate] as? Date {
                    folder.dateUpdated = fsModDate
                }

                // Check if folder already exists
                if let existing = try Folder
                    .filter(Folder.Columns.path == url.path)
                    .fetchOne(db) {
                    // Update bookmark data if folder exists
                    var updatedFolder = existing
                    updatedFolder.bookmarkData = bookmarkData
                    try updatedFolder.update(db)
                    folders.append(updatedFolder)
                    Logger.info("Folder already exists: \(existing.name) with ID: \(existing.id ?? -1), updated bookmark")
                } else {
                    // Insert new folder
                    try folder.insert(db)

                    // Fetch the inserted folder to get the generated ID
                    if let insertedFolder = try Folder
                        .filter(Folder.Columns.path == url.path)
                        .fetchOne(db) {
                        folders.append(insertedFolder)
                        Logger.info("Added new folder: \(insertedFolder.name) with ID: \(insertedFolder.id ?? -1)")
                    }
                }
            }
            
            return folders
        }
        
        await MainActor.run {
            NotificationCenter.default.post(name: .foldersAddedToDatabase, object: addedFolders)
        }
        
        let existingTrackCount = try await dbQueue.read { db in
            try Track.fetchCount(db)
        }
        let isInitialScan = existingTrackCount == 0

        if !addedFolders.isEmpty {
            if isInitialScan {
                await MainActor.run {
                    NotificationCenter.default.post(name: .initialScanStarted, object: nil)
                }
            }
            
            try await scanFoldersForTracks(addedFolders, showActivityInTray: true, isInitialScan: isInitialScan)
        }

        await MainActor.run {
            self.isScanning = false
            self.scanStatusMessage = ""
            
            if isInitialScan {
                NotificationCenter.default.post(name: .initialScanCompleted, object: nil)
            }
        }
        
        // Wait for DB operations to finish before notifying scan completion
        try? await dbQueue.writeWithoutTransaction { _ in }
        if !isInitialScan {
            await MainActor.run {
                NotificationCenter.default.post(name: .libraryDataDidChange, object: nil)
            }
        }

        return addedFolders
    }

    func getAllFolders() -> [Folder] {
        do {
            return try dbQueue.read { db in
                try Folder
                    .order(Folder.Columns.name)
                    .fetchAll(db)
            }
        } catch {
            Logger.error("Failed to fetch folders: \(error)")
            return []
        }
    }

    func refreshFolder(
        _ folder: Folder,
        hardRefresh: Bool = false,
        manageActivityIndicator: Bool = true,
        globalScanState: GlobalScanState? = nil,
        precomputedHash: String? = nil,
        _ completion: @escaping (Result<Void, Error>) -> Void
    ) {
        Task {
            do {
                await MainActor.run {
                    self.isScanning = true
                    self.scanStatusMessage = String(appLocalized: "Refreshing \(folder.name)...")
                    if manageActivityIndicator {
                        NotificationManager.shared.startActivity(String(appLocalized: "Refreshing \(folder.name)..."))
                    }
                }

                // Log the current state
                let trackCountBefore = getTracksForFolder(folder.id ?? -1).count
                Logger.info("Starting refresh for folder \(folder.name) with \(trackCountBefore) tracks")

                ArtistParser.loadKnownArtists()
                // Balanced unload on every exit path (success or throw) so the retain count
                // can't leak or double-decrement a concurrent scan's data.
                defer { ArtistParser.unloadKnownArtists() }

                // Scan the folder - this will check for metadata updates.
                // finalizeScan (inside) updates the folder row and hash, so we no
                // longer re-call updateFolderMetadata here — that used to hash the
                // tree a second time on top of the refresh-check hash.
                try await scanSingleFolder(
                    folder,
                    supportedExtensions: AudioFormat.supportedExtensions,
                    hardRefresh: hardRefresh,
                    precomputedHash: precomputedHash,
                    globalScanState: globalScanState
                )

                // Log the result
                let trackCountAfter = getTracksForFolder(folder.id ?? -1).count
                Logger.info("Completed refresh for folder \(folder.name) with \(trackCountAfter) tracks (was \(trackCountBefore))")

                // Post-scan: normalize compilation albums, update stats, detect duplicates, and clean up
                try await normalizeCompilationAlbums()
                try await dbQueue.write { db in
                    try self.updateEntityStats(in: db)
                }
                await detectAndMarkDuplicates()
                try await cleanupOrphanedData()

                await MainActor.run {
                    self.isScanning = false
                    self.scanStatusMessage = ""
                    if manageActivityIndicator {
                        NotificationManager.shared.stopActivity()
                    }
                    completion(.success(()))
                }
            } catch {
                await MainActor.run {
                    self.isScanning = false
                    self.scanStatusMessage = ""
                    if manageActivityIndicator {
                        NotificationManager.shared.stopActivity()
                    }
                    completion(.failure(error))
                    Logger.error("Failed to refresh folder \(folder.name): \(error)")
                    NotificationManager.shared.addMessage(.error, String(appLocalized: "Failed to refresh folder \(folder.name)"))
                }
            }
        }
    }

    func removeFolder(_ folder: Folder, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            do {
                _ = try await dbQueue.write { db in
                    // Delete the folder (cascades to tracks and junction tables)
                    try folder.delete(db)
                }
                
                // Now run comprehensive cleanup for any orphaned data
                try await cleanupOrphanedData()
                
                Logger.info("Removed folder '\(folder.name)' and cleaned up orphaned data")
                
                await MainActor.run {
                    completion(.success(()))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                    Logger.error("Failed to remove folder '\(folder.name)': \(error)")
                    NotificationManager.shared.addMessage(.error, String(appLocalized: "Failed to remove folder '\(folder.name)'"))
                }
            }
        }
    }

    func updateFolderBookmark(_ folderId: Int64, bookmarkData: Data) async throws {
        _ = try await dbQueue.write { db in
            try Folder
                .filter(Folder.Columns.id == folderId)
                .updateAll(db, Folder.Columns.bookmarkData.set(to: bookmarkData))
        }
    }
    
    func updateFolderMetadata(_ folderId: Int64, precomputedHash: String? = nil) async throws {
        // First, get the folder and calculate hash outside the database transaction
        let folderData = try await dbQueue.read { db in
            try Folder.fetchOne(db, key: folderId)
        }

        guard let folder = folderData else { return }

        // Reuse the hash computed during the refresh-check when available; the scan
        // doesn't mutate files, so the pre-scan hash is still valid here. Otherwise
        // hash the tree now. (`??` can't host an `await` on its right side — it's an
        // autoclosure that doesn't support concurrency — so spell the fallback out.)
        let hash: String?
        if let precomputedHash {
            hash = precomputedHash
        } else {
            hash = await FilesystemUtils.computeFolderHash(for: folder.url)
        }
        
        try await dbQueue.write { db in
            guard var folder = try Folder.fetchOne(db, key: folderId) else { return }
            
            // Get and store the file system's modification date
            if let attributes = try? FileManager.default.attributesOfItem(atPath: folder.url.path),
               let fsModDate = attributes[.modificationDate] as? Date {
                folder.dateUpdated = fsModDate
            } else {
                // Fallback to current date if we can't get FS date
                folder.dateUpdated = Date()
            }
            
            // Store the calculated hash
            if let hash = hash {
                folder.shasumHash = hash
                Logger.info("Updated hash for folder \(folder.name)")
            } else {
                Logger.warning("Failed to calculate hash for folder \(folder.name)")
            }
            
            // Update track count
            let trackCount = try Track
                .filter(Track.Columns.folderId == folderId)
                .filter(Track.Columns.isDuplicate == false)
                .fetchCount(db)
            folder.trackCount = trackCount
            
            try folder.update(db)
        }
    }

    func getTracksInFolder(_ folder: Folder) -> [Track] {
        guard let folderId = folder.id else { return [] }
        return getTracksForFolder(folderId)
    }
    
    func scanFoldersForTracks(
        _ folders: [Folder],
        showActivityInTray: Bool = true,
        isInitialScan: Bool = false
    ) async throws {
        let supportedExtensions = AudioFormat.supportedExtensions
        let totalFolders = folders.count

        if showActivityInTray && totalFolders > 0 {
            await MainActor.run {
                let message = isInitialScan
                    ? String(appLocalized: "Scanning your music library...")
                    : String(appLocalized: "Scanning \(totalFolders) folders...")
                NotificationManager.shared.startActivity(message)
            }
        }

        // Total file count is grown per-folder as each is enumerated, so we skip the
        // separate full-directory pre-count walk the progress bar used to need.
        let globalScanState = GlobalScanState(totalFiles: 0, isInitialScan: isInitialScan)
        
        ArtistParser.loadKnownArtists()
        // Balanced unload on every exit path, including a throw from the post-scan steps below.
        defer { ArtistParser.unloadKnownArtists() }

        var processedFolders = 0

        for folder in folders {
            do {
                try await scanSingleFolder(
                    folder,
                    supportedExtensions: supportedExtensions,
                    globalScanState: globalScanState
                )
                processedFolders += 1
            } catch {
                Logger.error("Failed to scan folder \(folder.name): \(error)")
                Task.detached { @MainActor in
                    NotificationManager.shared.addMessage(.error, String(appLocalized: "Failed to scan folder '\(folder.name)'"))
                }
            }
            
            if processedFolders.isMultiple(of: 2) {
                await Task.yield()
            }
        }

        // Post-scan: normalize compilation albums, update stats, detect duplicates, and clean up once for all folders
        try await normalizeCompilationAlbums()
        try await dbQueue.write { db in
            try self.updateEntityStats(in: db)
        }
        await detectAndMarkDuplicates()
        try await cleanupOrphanedData()

        await MainActor.run {
            self.scanStatusMessage = String(appLocalized: "Scan complete")
            if showActivityInTray {
                NotificationManager.shared.stopActivity()
            }
            
            let completionMessage = isInitialScan
                ? String(appLocalized: "Library scan complete: \(self.getTotalTrackCount()) tracks found")
                : String(appLocalized: "Added \(totalFolders) folders to library")
            NotificationManager.shared.addMessage(.info, completionMessage)
        }
    }
    
    func updateFolderTrackCount(_ folder: Folder) async throws {
        try await dbQueue.write { db in
            let count = try Track
                .filter(Track.Columns.folderId == folder.id)
                .fetchCount(db)

            var updatedFolder = folder
            updatedFolder.trackCount = count
            updatedFolder.dateUpdated = Date()
            try updatedFolder.update(db)
        }
    }

    func scanSingleFolder(
        _ folder: Folder,
        supportedExtensions: [String],
        hardRefresh: Bool = false,
        precomputedHash: String? = nil,
        globalScanState: GlobalScanState? = nil
    ) async throws {
        guard let folderId = folder.id else {
            Logger.error("Folder has no ID")
            throw DatabaseError.invalidFolderId
        }

        let scanState = ScanState()

        // Single-pass enumeration: collect music files, unsupported files, and artwork
        let enumeration = try enumerateFolderContents(
            from: folder.url,
            supportedExtensions: supportedExtensions
        )
        let musicFiles = enumeration.musicFiles

        // Grow the progress total now that we know this folder's real file count,
        // instead of pre-counting via a second full directory walk.
        await globalScanState?.addTotal(by: musicFiles.count)

        await scanState.addSkippedFiles(enumeration.unsupportedFiles)

        // Pre-fetch the full records for every existing track in this folder in one
        // query, keyed by standardized path. The processing stage then compares and
        // updates entirely from this dictionary — no per-file DB reads on the
        // (serial) queue, which used to serialize the whole TaskGroup.
        let existingFullTracksByPath: [String: FullTrack] = try await dbQueue.read { db in
            let fullTracks = try FullTrack
                .filter(FullTrack.Columns.folderId == folderId)
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: fullTracks.map { ($0.url.standardizedFileURL.path, $0) })
        }

        // Remove tracks that no longer exist (skip on fresh scan when folder has no tracks)
        if !existingFullTracksByPath.isEmpty {
            try await removeDeletedTracks(
                folderId: folderId,
                foundPaths: Set(musicFiles),
                folderName: folder.name,
                hasRemainingFiles: !musicFiles.isEmpty,
                globalScanState: globalScanState
            )
        }

        // If no music files found, we're done
        if musicFiles.isEmpty {
            try await updateFolderTrackCount(folder)
            return
        }

        // Process music files in batches
        try await processMusicFilesInBatches(
            musicFiles: musicFiles,
            folderId: folderId,
            modificationDates: enumeration.modificationDates,
            folderName: folder.name,
            hardRefresh: hardRefresh,
            existingFullTracksByPath: existingFullTracksByPath,
            scanState: scanState,
            globalScanState: globalScanState
        )

        // Update metadata and report results
        try await finalizeScan(
            folderId: folderId,
            folder: folder,
            precomputedHash: precomputedHash,
            scanState: scanState
        )
    }
    // MARK: - Private Helpers

    /// Single-pass enumeration: collect music files (plus their prefetched mod
    /// dates), unsupported files, and folder artwork paths (decoded lazily later).
    private func enumerateFolderContents(
        from folderURL: URL,
        supportedExtensions: [String]
    ) throws -> FolderEnumerationResult {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw DatabaseError.scanFailed("Unable to enumerate folder contents")
        }

        var musicFiles: [URL] = []
        var modificationDates: [URL: Date] = [:]
        var unsupportedFiles: [(url: URL, extension: String)] = []
        // De-duplicate by resolved path so a symlinked file and its target (or two
        // symlinks pointing at the same file) are ingested exactly once.
        var seenResolvedPaths = Set<String>()

        while let fileURL = enumerator.nextObject() as? URL {
            let fileExtension = fileURL.pathExtension.lowercased()

            guard !fileExtension.isEmpty else { continue }

            // Resolve symlinks before storage/dedup so the DB holds the real file path
            // and metadata reads target the actual file. Without this, a symlink and its
            // target (or several links to one file) would be ingested as duplicates, and
            // self-referential symlink chains could loop the enumerator on some configs.
            let resolvedURL = (fileURL.resolvingSymlinksInPath()).standardizedFileURL
            let resolvedPath = resolvedURL.path
            guard seenResolvedPaths.insert(resolvedPath).inserted else {
                // Already ingested this exact file via another path/symlink.
                continue
            }

            if supportedExtensions.contains(fileExtension) {
                musicFiles.append(resolvedURL)
                // Reuse the modification date the enumerator already prefetched (via
                // includingPropertiesForKeys) so processing doesn't stat each file
                // again. Key by resolvedURL to match how musicFiles/lookups address it.
                if let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    modificationDates[resolvedURL] = modDate
                }
            } else if AudioFormat.isNotSupported(fileExtension) {
                unsupportedFiles.append((url: resolvedURL, extension: fileExtension))
                Logger.info("Skipped unsupported audio file: \(resolvedURL.lastPathComponent) (.\(fileExtension))")
            }
        }

        // Image files are intentionally not collected during enumeration. Artwork is
        // resolved on demand by ArtworkResolver at playback, so the scan never reads
        // or decodes any image bytes.

        return FolderEnumerationResult(
            musicFiles: musicFiles,
            modificationDates: modificationDates,
            unsupportedFiles: unsupportedFiles
        )
    }

    /// Remove tracks from database that no longer exist in the filesystem
    private func removeDeletedTracks(
        folderId: Int64,
        foundPaths: Set<URL>,
        folderName: String,
        hasRemainingFiles: Bool,
        globalScanState: GlobalScanState? = nil
    ) async throws {
        let existingTracks = getTracksForFolder(folderId)
        let foundPathStrings = Set(foundPaths.map { $0.standardizedFileURL.path })
        let tracksToRemove = existingTracks.filter { !foundPathStrings.contains($0.url.standardizedFileURL.path) }
        let trackIdsToRemove = tracksToRemove.compactMap { $0.trackId }
        
        guard !trackIdsToRemove.isEmpty else { return }
        
        let removedCount = trackIdsToRemove.count

        await globalScanState?.incrementTracksRemoved(by: removedCount)
        if let globalScanState {
            let progress = await globalScanState.getProgress()
            let detail = scanProgressDetail(progress)
            await MainActor.run {
                NotificationManager.shared.updateActivityProgress(
                    current: progress.processed,
                    total: progress.total > 0 ? progress.total : progress.processed,
                    detail: detail
                )
            }
        }
        
        // Remove tracks from database and clean up orphaned artists/albums/genres
        // in a single transaction, so a crash between the two can't leave dangling
        // parent rows pointing at nothing.
        try await dbQueue.write { db in
            try deleteTracksAndCleanupLocked(trackIdsToRemove, in: db)
            for track in tracksToRemove {
                Logger.info("Removed track that no longer exists: \(track.url.lastPathComponent)")
            }
        }

        // Report results to user
        await MainActor.run {
            if !hasRemainingFiles {
                NotificationManager.shared.addMessage(.info, String(appLocalized: "Folder '\(folderName)' is now empty, removed \(removedCount) tracks"))
            } else {
                let message = removedCount == 1
                    ? String(appLocalized: "Removed 1 missing track from '\(folderName)'")
                    : String(appLocalized: "Removed \(removedCount) missing tracks from '\(folderName)'")
                NotificationManager.shared.addMessage(.info, message)
            }
        }
    }

    func scanProgressDetail(_ progress: GlobalScanProgress) -> String {
        let base = progress.total > 0
            ? String(appLocalized: "\(progress.processed) of \(progress.total) files processed")
            : String(appLocalized: "\(progress.processed) files processed")

        var changes: [String] = []
        if progress.added > 0 {
            changes.append(progress.isInitial
                ? String(appLocalized: "\(progress.added) tracks found")
                : String(appLocalized: "\(progress.added) new tracks found"))
        }
        if progress.removed > 0 {
            changes.append(String(appLocalized: "\(progress.removed) tracks removed"))
        }

        guard !changes.isEmpty else { return base }
        return base + " • " + changes.joined(separator: " • ")
    }

    private func processMusicFilesInBatches(
        musicFiles: [URL],
        folderId: Int64,
        modificationDates: [URL: Date] = [:],
        folderName: String,
        hardRefresh: Bool = false,
        existingFullTracksByPath: [String: FullTrack],
        scanState: ScanState,
        globalScanState: GlobalScanState? = nil
    ) async throws {
        let totalFiles = musicFiles.count
        let batchSize = 500
        let fileBatches = musicFiles.chunked(into: batchSize)

        for batch in fileBatches {
            let batchWithFolderId = batch.map { url in (url: url, folderId: folderId) }

            do {
                try await processBatch(
                    batchWithFolderId,
                    hardRefresh: hardRefresh,
                    existingFullTracksByPath: existingFullTracksByPath,
                    modificationDates: modificationDates,
                    scanState: scanState,
                    folderName: folderName,
                    totalFilesInFolder: totalFiles,
                    globalScanState: globalScanState
                )
            } catch {
                let failures = batch.map { (url: $0, error: error) }
                await scanState.addFailedFiles(failures)
                Logger.error("Failed to process batch in folder \(folderName): \(error)")
            }
        }
    }

    /// Finalize the scan - update metadata, detect duplicates, and report results
    private func finalizeScan(
        folderId: Int64,
        folder: Folder,
        precomputedHash: String? = nil,
        scanState: ScanState
    ) async throws {
        // Update folder metadata
        try await updateFolderMetadata(folderId, precomputedHash: precomputedHash)
        
        // Get final counts
        let processedCount = await scanState.getProcessedCount()
        let failedFiles = await scanState.getFailedFiles()
        let skippedFiles = await scanState.getSkippedFiles()
        
        // Report failed files
        if !failedFiles.isEmpty {
            await MainActor.run {
                let message = failedFiles.count == 1
                    ? String(appLocalized: "Failed to process 1 file in '\(folder.name)'")
                    : String(appLocalized: "Failed to process \(failedFiles.count) files in '\(folder.name)'")
                NotificationManager.shared.addMessage(.warning, message)
            }
        }
        
        // Report skipped files
        if !skippedFiles.isEmpty {
            let extensionCounts = Dictionary(grouping: skippedFiles) { $0.extension }
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }
            
            let topExtensions = extensionCounts.prefix(3)
                .map { ".\($0.key.uppercased()) (\($0.value))" }
                .joined(separator: ", ")
            
            await MainActor.run {
                let message = skippedFiles.count == 1
                    ? String(appLocalized: "1 file skipped in '\(folder.name)' - unsupported format")
                    : String(appLocalized: "\(skippedFiles.count) files skipped in '\(folder.name)' - unsupported formats: \(topExtensions)")
                NotificationManager.shared.addMessage(.warning, message)
            }
        }
        
        Logger.info(
            """
            Completed scanning folder \(folder.name): \(processedCount) processed, \
            \(failedFiles.count) failed, \(skippedFiles.count) skipped
            """
        )
    }
}
