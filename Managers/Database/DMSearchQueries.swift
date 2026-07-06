//
// DatabaseManager class extension
//
// This extension contains all search-related query methods using FTS5.
//

import Foundation
import GRDB

extension DatabaseManager {
    /// Search tracks using FTS5 with language-aware query strategy
    func searchTracksUsingFTS(_ searchText: String) -> [Track] {
        do {
            return try dbQueue.read { db in
                let ftsQuery = buildFTS5Query(searchText)
                let duplicateClause = UserDefaults.standard.bool(forKey: "hideDuplicateTracks") ? " AND t.is_duplicate = 0" : ""

                return try Track.fetchAll(
                    db,
                    sql: """
                        SELECT t.*
                        FROM tracks t
                        JOIN tracks_fts fts ON t.id = fts.track_id
                        WHERE tracks_fts MATCH ?
                        \(duplicateClause)
                        ORDER BY rank
                        """,
                    arguments: [ftsQuery]
                )
            }
        } catch {
            Logger.error("FTS search failed: \(error)")
            return []
        }
    }

    /// Search tracks for playlist addition with exclusions
    /// - Parameter limit: Cap on the number of results. Defaults to 200 to keep the
    ///   picker responsive on very large libraries; pass `nil` for an unbounded query.
    func searchTracksForPlaylist(_ searchText: String, excludingTrackIds: Set<Int64> = [], limit: Int? = 200) -> [Track] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        do {
            return try dbQueue.read { db in
                let prefixQuery = buildFTS5Query(searchText)

                // Respect the "hide duplicate songs" setting so playlist search results
                // match what the rest of the library shows.
                let duplicateClause = UserDefaults.standard.bool(forKey: "hideDuplicateTracks") ? " AND t.is_duplicate = 0" : ""

                // Build the WHERE clause based on exclusions
                let whereClause: String
                let arguments: StatementArguments

                if excludingTrackIds.isEmpty {
                    whereClause = "WHERE tracks_fts MATCH ?\(duplicateClause)"
                    arguments = [prefixQuery]
                } else {
                    let excludedIds = Array(excludingTrackIds)
                    let placeholders = databaseQuestionMarks(count: excludedIds.count)
                    whereClause = "WHERE tracks_fts MATCH ? AND t.id NOT IN (\(placeholders))\(duplicateClause)"

                    var args: [DatabaseValueConvertible] = [prefixQuery]
                    args.append(contentsOf: excludedIds)
                    arguments = StatementArguments(args)
                }

                let limitClause = limit.map { "LIMIT \($0)" } ?? ""

                return try Track.fetchAll(
                    db,
                    sql: """
                    SELECT t.*
                    FROM tracks t
                    JOIN tracks_fts fts ON t.id = fts.track_id
                    \(whereClause)
                    ORDER BY rank
                    \(limitClause)
                    """,
                    arguments: arguments
                )
            }
        } catch {
            Logger.error("FTS playlist search failed: \(error)")
            return []
        }
    }

    // MARK: - Helper Methods
    
    /// FTS query builder with support for handling special characters
    private func buildFTS5Query(_ searchText: String) -> String {
        let tokens = searchText.split(separator: " ").map { String($0) }
        
        let processedTokens = tokens.map { token -> String in
            let tokenStr = String(token)

            if isPlainFTSToken(tokenStr) {
                return "\(tokenStr)*"
            }

            return quotedFTSToken(tokenStr)
        }
        
        return processedTokens.joined(separator: " AND ")
    }

    private func isPlainFTSToken(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
    }

    private func quotedFTSToken(_ token: String) -> String {
        let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
    
    /// Generate SQL placeholders for IN clause
    func databaseQuestionMarks(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}
