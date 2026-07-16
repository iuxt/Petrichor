import Foundation
import GRDB

/// Single-flight, single-entry lyrics cache shared by every `TrackLyricsContent`
/// instance (main window, mini player, immersive mode).
@MainActor
final class LyricsStore {
    static let shared = LyricsStore()
    private init() {}

    struct Lyrics {
        let trackId: UUID
        let lines: [LyricLine]
        let hasTimed: Bool
        let isKaraoke: Bool
    }

    private var cached: Lyrics?
    private var inFlight: [UUID: Task<Lyrics, Error>] = [:]

    func cachedLyrics(for trackId: UUID) -> Lyrics? {
        guard let cached, cached.trackId == trackId else { return nil }
        return cached
    }

    func lyrics(
        for track: Track,
        using dbQueue: DatabaseQueue,
        forceReload: Bool = false
    ) async throws -> Lyrics {
        if !forceReload, let cached, cached.trackId == track.id {
            return cached
        }

        // Join an in-progress load for the same track rather than starting another.
        if !forceReload, let existing = inFlight[track.id] {
            return try await existing.value
        }

        let trackId = track.id
        // Run the lyrics load on a background executor so file IO (`Data(contentsOf:)`)
        // and the DB read don't block the main actor. `Task.detached` inherits no actor,
        // so the work runs off-main even though `LyricsStore` itself is `@MainActor`.
        let task = Task.detached(priority: .userInitiated) { () throws -> Lyrics in
            let result = try await LyricsLoader.loadLyrics(
                for: track,
                using: dbQueue
            )
            let hasTimed = result.lyrics.contains { $0.startTime > 0 || $0.endTime != nil }
            return Lyrics(
                trackId: trackId,
                lines: result.lyrics,
                hasTimed: hasTimed,
                isKaraoke: result.source == .ksc
            )
        }
        inFlight[trackId] = task
        defer { inFlight[trackId] = nil }

        let result = try await task.value
        cached = result
        return result
    }

    /// Drop the in-flight load for `trackId`, cancelling the underlying task so the
    /// file/DB work stops when the caller no longer cares about the result.
    func cancelInFlightLoad(for trackId: UUID) {
        if let task = inFlight[trackId] {
            task.cancel()
            inFlight[trackId] = nil
        }
    }
}
