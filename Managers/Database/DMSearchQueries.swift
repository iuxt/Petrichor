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
        if needsLikeFallback(searchText) {
            return searchTracksUsingLike(searchText, excludingTrackIds: [], limit: nil)
        }

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

        if needsLikeFallback(searchText) {
            return searchTracksUsingLike(searchText, excludingTrackIds: excludingTrackIds, limit: limit)
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

    /// trigram tokenizer requires ≥3 characters per token to generate any 3-gram.
    /// Shorter tokens (e.g. "97", "林") can't be matched via FTS and must use LIKE.
    private func needsLikeFallback(_ searchText: String) -> Bool {
        let tokens = searchText.split(separator: " ").map { String($0) }
        return tokens.contains { $0.count < 3 }
    }

    /// LIKE-based substring fallback used when FTS can't handle the query (tokens < 3 chars).
    /// Matches any of the indexed text columns; does not honor token-AND semantics —
    /// the whole trimmed query is treated as one substring.
    private func searchTracksUsingLike(_ searchText: String, excludingTrackIds: Set<Int64>, limit: Int?) -> [Track] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"

        let searchableColumns = [
            "title", "filename_stem", "artist", "album",
            "album_artist", "composer", "genre", "year"
        ]
        let orClause = searchableColumns
            .map { "\(($0)) LIKE ? ESCAPE '\\'" }
            .joined(separator: " OR ")

        let duplicateClause = UserDefaults.standard.bool(forKey: "hideDuplicateTracks") ? " AND t.is_duplicate = 0" : ""

        let excludeClause: String
        let excludeArgs: [Int64]
        if excludingTrackIds.isEmpty {
            excludeClause = ""
            excludeArgs = []
        } else {
            let excludedIds = Array(excludingTrackIds)
            let placeholders = databaseQuestionMarks(count: excludedIds.count)
            excludeClause = " AND t.id NOT IN (\(placeholders))"
            excludeArgs = excludedIds
        }

        let limitClause = limit.map { " LIMIT \($0)" } ?? ""

        do {
            return try dbQueue.read { db in
                var args: [DatabaseValueConvertible] = Array(repeating: pattern, count: searchableColumns.count)
                args.append(contentsOf: excludeArgs)

                return try Track.fetchAll(
                    db,
                    sql: """
                    SELECT t.* FROM tracks t
                    WHERE (\(orClause))\(duplicateClause)\(excludeClause)\(limitClause)
                    """,
                    arguments: StatementArguments(args)
                )
            }
        } catch {
            Logger.error("LIKE search failed: \(error)")
            return []
        }
    }

    // MARK: - Helper Methods

    /// Builds an FTS5 query expression for the trigram tokenizer. Each whitespace-split
    /// token is wrapped as a phrase (so any FTS5 special chars inside are literalized)
    /// and AND'ed together. trigram handles substring matching for tokens ≥3 chars;
    /// shorter tokens are routed to LIKE by callers before this is reached.
    private func buildFTS5Query(_ searchText: String) -> String {
        let tokens = searchText.split(separator: " ")
            .map { String($0) }
            .filter { !$0.isEmpty }

        return tokens
            .map { quotedFTSToken($0) }
            .joined(separator: " AND ")
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
