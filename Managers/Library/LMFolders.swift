//
// LibraryManager class extension
//
// This extension contains methods for folder management in the library,
// the methods internally also use DatabaseManager methods to work with database.
//

import Foundation
import AppKit

extension LibraryManager {
    func addFolder() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        openPanel.prompt = String(appLocalized: "Add Music Folder")
        openPanel.message = String(appLocalized: "Select folders containing your music files")

        guard let keyWindow = NSApp.keyWindow else {
            Logger.error("Cannot add folder: no key window available")
            return
        }

        openPanel.beginSheetModal(for: keyWindow) { [weak self] response in
            guard let self = self, response == .OK else { return }

            var urlsToAdd: [URL] = []
            var bookmarkDataMap: [URL: Data] = [:]

            for url in openPanel.urls {
                // Create security bookmark
                do {
                    let bookmarkData = try url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    urlsToAdd.append(url)
                    bookmarkDataMap[url] = bookmarkData
                    Logger.info("Created bookmark for folder - \(url.lastPathComponent) at \(url.path)")
                } catch {
                    Logger.error("Failed to create security bookmark for \(url.path): \(error)")
                }
            }

            // Add folders to database with their bookmarks
            if !urlsToAdd.isEmpty {
                self.databaseManager.addFolders(urlsToAdd, bookmarkDataMap: bookmarkDataMap) { result in
                    switch result {
                    case .success(let dbFolders):
                        Logger.info("Successfully added \(dbFolders.count) folders to database")
                        self.refreshDiscoverTracks()
                        self.scheduleLibraryReload()
                    case .failure(let error):
                        Logger.error("Failed to add folders to database: \(error)")
                    }
                }
            }
        }
    }

    func removeFolder(_ folder: Folder) {
        Logger.info("Removing folder: \(folder.name)")
        
        databaseManager.removeFolder(folder) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success:
                Logger.info("Successfully removed folder: \(folder.name)")
                // Remove from local array
                self.folders.removeAll { $0.id == folder.id }
                // Reload library immediately
                self.refreshLibraryCategories()
                self.loadMusicLibrary()
                self.refreshDiscoverTracks()
                // Stop the activity indicator
                Task { @MainActor in
                    NotificationManager.shared.stopActivity()
                }

            case .failure(let error):
                Logger.error("Failed to remove folder: \(error)")
                // Stop the activity indicator on failure too
                Task { @MainActor in
                    NotificationManager.shared.stopActivity()
                    // Show error message
                    NotificationManager.shared.addMessage(.error, String(appLocalized: "Failed to remove folder '\(folder.name)'"))
                }
            }
        }
    }

    func refreshFolder(_ folder: Folder, hardRefresh: Bool = false) {
        guard folderLocationsReady else {
            loadMusicLibrary()
            return
        }
        // First, ensure we have a valid bookmark
        Task { [weak self] in
            guard let self = self else { return }

            // Every successful start must be paired with a stop; track whether we took a ref.
            let startedAccess = folder.bookmarkData != nil
                && folder.url.startAccessingSecurityScopedResource()
            if !startedAccess {
                await self.refreshBookmarkForFolder(folder)
            }

            // Show the indicator before enumerating: enumerating a large folder can
            // take a moment, and refreshLibrary() starts activity before scanning too.
            await MainActor.run {
                NotificationManager.shared.startActivity(String(appLocalized: "Refreshing \(folder.name)..."))
            }

            // Total file count is grown during enumeration (see scanSingleFolder),
            // so start at 0 and let the progress bar show an indeterminate state
            // until the folder is enumerated — no separate pre-count walk.
            let globalScanState = GlobalScanState(totalFiles: 0)

            // startActivity() above cleared progress; set the initial state (the
            // first update always passes the throttle after a start).
            await MainActor.run {
                NotificationManager.shared.updateActivityProgress(
                    current: 0,
                    total: 0,
                    detail: String(appLocalized: "Preparing files...")
                )
            }

            // completion runs on the main actor (see DMFolders.refreshFolder)
            self.databaseManager.refreshFolder(
                folder,
                hardRefresh: hardRefresh,
                manageActivityIndicator: false,
                globalScanState: globalScanState
            ) { result in
                if startedAccess { folder.url.stopAccessingSecurityScopedResource() }
                Task { @MainActor in
                    NotificationManager.shared.stopActivity()
                }
                switch result {
                case .success:
                    Logger.info("Successfully refreshed folder \(folder.name)")
                    // Reload the library to reflect changes
                    self.refreshLibraryCategories()
                    self.loadMusicLibrary()
                    self.refreshDiscoverTracks()
                case .failure(let error):
                    Logger.error("Failed to refresh folder \(folder.name): \(error)")
                }
            }
        }
    }

    func optimizeDatabase(notifyUser: Bool = false) {
        // A missing path may be an unmounted disk, an offline share, or revoked access.
        // Only explicit folder removal may delete its tracks and listening history.
        let sizeBefore = databaseManager.getDatabaseSize() ?? 0
        performDatabaseOptimization(sizeBefore: sizeBefore, context: "optimization")
    }

    func refreshBookmarkForFolder(_ folder: Folder) async {
        // Only refresh if we can access the folder
        guard FileManager.default.fileExists(atPath: folder.url.path) else {
            Logger.warning("Folder no longer exists at \(folder.url.path)")
            return
        }

        // `bookmarkData(options: .withSecurityScope)` requires an active security-scoped
        // reference on the URL; without it the call silently fails on sandboxed volumes.
        // Take a balanced reference for the duration of the bookmark creation.
        let didStartAccess = folder.url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                folder.url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            // Create a fresh bookmark
            let newBookmarkData = try folder.url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            // Update the folder with new bookmark
            var updatedFolder = folder
            updatedFolder.bookmarkData = newBookmarkData

            guard let folderId = folder.id else {
                Logger.error("Failed to refresh bookmark for \(folder.name): folder has no database ID")
                return
            }

            // Save to database
            try await databaseManager.updateFolderBookmark(folderId, bookmarkData: newBookmarkData)

            Logger.info("Successfully refreshed bookmark for \(folder.name)")
        } catch {
            Logger.error("Failed to refresh bookmark for \(folder.name): \(error)")
        }
    }
    
    // MARK: - Private Helpers
    
    private func performDatabaseOptimization(sizeBefore: Int64, context: String) {
        Task {
            do {
                try await databaseManager.cleanupOrphanedData()
                try await databaseManager.vacuumDatabase()
                try await databaseManager.analyzeDatabase()
                
                // Get database size after optimization and calculate savings
                let sizeAfter = databaseManager.getDatabaseSize() ?? 0
                let spaceSaved = max(0, sizeBefore - sizeAfter)
                
                Logger.info("Database \(context) completed")
                
                await MainActor.run {
                    refreshEntities()
                    updateTotalCounts()
                    
                    if spaceSaved > 0 {
                        let savedMB = Double(spaceSaved) / (1024.0 * 1024.0)
                        NotificationManager.shared.addMessage(
                            .info,
                            String(appLocalized: "Database optimization completed - reclaimed \(String(format: "%.1f", savedMB)) MB")
                        )
                    } else {
                        NotificationManager.shared.addMessage(.info, String(appLocalized: "Database optimization completed"))
                    }
                }
            } catch {
                Logger.error("Database \(context) failed: \(error)")
                await MainActor.run {
                    NotificationManager.shared.addMessage(.error, String(appLocalized: "Database optimization failed"))
                }
            }
        }
    }
}
