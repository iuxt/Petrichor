//
// LibraryManager class extension
//
// This extension contains methods querying tracks across Library,
// the methods internally use DatabaseManager methods to work with database.
//

import Foundation

extension LibraryManager {
    func getTracksInFolder(_ folder: Folder) -> [Track] {
        guard let folderId = folder.id else {
            Logger.error("Folder has no ID")
            return []
        }

        return databaseManager.getTracksForFolder(folderId)
    }

    func getTracksBy(filterType: LibraryFilterType, value: String, albumId: Int64? = nil) -> [Track] {
        if filterType.usesMultiArtistParsing && value != filterType.unknownPlaceholder {
            return databaseManager.getTracksByFilterTypeContaining(filterType, value: value)
        } else {
            return databaseManager.getTracksByFilterType(filterType, value: value, albumId: albumId)
        }
    }

    func getLibraryFilterItems(for filterType: LibraryFilterType) -> [LibraryFilterItem] {
        if let cachedItems = cachedLibraryCategories[filterType] {
            Logger.info("Returning cached library filter items for \(filterType)")
            return cachedItems
        }

        let items = getLibraryFilterItemsFromDatabase(for: filterType)
        cachedLibraryCategories[filterType] = items

        return items
    }

    func libraryFilterTrackCount(for filterType: LibraryFilterType, value: String, albumId: Int64? = nil) -> Int {
        let items = getLibraryFilterItems(for: filterType)
        if filterType == .albums, let albumId {
            return items.first { $0.albumId == albumId }?.count ?? 0
        }
        return items.first { $0.name == value }?.count ?? 0
    }

    func getTrackCountsByFolderPath() -> [String: Int] {
        databaseManager.getTrackCountsByFolderPath()
    }

    func updateSearchResults() {
        // Library mutations and text bindings enter here on the main thread.
        // Debounce the database work itself, with one owner for the whole UI.
        MainActor.assumeIsolated {
            searchUpdateTask?.cancel()
            searchUpdateTask = nil
            let query = globalSearchText
            searchResults = []
            isSearching = LibrarySearch.isSearchableQuery(query)
            guard isSearching else { return }

            let database = databaseManager
            searchUpdateTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: TimeConstants.searchDebounceDuration)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }

                let results = await Task.detached(priority: .userInitiated) {
                    database.searchTracksUsingFTS(query)
                }.value

                // Cancellation also distinguishes A → B → A and library refreshes
                // with unchanged text, where comparing the query alone is insufficient.
                guard !Task.isCancelled, let self,
                      self.globalSearchText == query else { return }
                self.searchResults = results
                self.isSearching = false
                self.searchUpdateTask = nil
            }
        }
    }
}
