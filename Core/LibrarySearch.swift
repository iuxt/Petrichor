import Foundation

enum LibrarySearch {
    // MARK: - Track Search

    /// Searches tracks based on a query string using FTS5
    /// - Parameters:
    ///   - tracks: The tracks to search through (used as fallback if FTS fails)
    ///   - query: The search query string
    /// - Returns: Filtered tracks that match the query
    static func searchTracks(_ tracks: [Track], with query: String) -> [Track] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return tracks }
        
        guard isSearchableQuery(trimmedQuery) else { return [] }

        // Use FTS5 search from database
        if let coordinator = AppCoordinator.shared {
            let ftsResults = coordinator.libraryManager.databaseManager.searchTracksUsingFTS(trimmedQuery)
            
            // Return FTS results if we got any
            if !ftsResults.isEmpty {
                return ftsResults
            }
            
            // If FTS returned empty but query exists, it means no matches found
            // Return empty array rather than falling back to in-memory search
            return []
        }

        // If no coordinator available (shouldn't happen in normal app flow)
        // Return empty results
        Logger.warning("AppCoordinator not available for search")
        return []
    }

    static func isSearchableQuery(_ query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return false }

        if trimmedQuery.count >= 2 {
            return true
        }

        return trimmedQuery.unicodeScalars.contains(where: isCJKSearchScalar)
    }

    private static func isCJKSearchScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, // Hangul Jamo
             0x3040...0x30FF, // Hiragana and Katakana
             0x3100...0x312F, // Bopomofo
             0x3400...0x4DBF, // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xAC00...0xD7AF, // Hangul Syllables
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0x20000...0x2EBEF: // CJK Unified Ideographs Extensions
            return true
        default:
            return false
        }
    }
}
