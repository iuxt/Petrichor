import Foundation
import GRDB

/// Single-flight, single-entry lyrics cache shared by the main window, mini
/// player, immersive mode, and desktop lyrics.
@MainActor
final class LyricsStore {
    static let shared = LyricsStore()
    private var scriptObserver: NSObjectProtocol?

    struct Lyrics {
        let trackId: UUID
        let lines: [LyricLine]
        let source: LyricsSource
        let hasTimed: Bool
        let isKaraoke: Bool
        let availableScripts: [LyricScript]
        let availableLanguages: [LyricLanguage]
        let selectedLanguage: LyricLanguage
    }

    /// Writing script loads parse with; injectable so tests can pin it.
    var scriptResolver: () -> LyricScript = { LyricsScriptSettings.shared.effectiveScript }
    var languageResolver: () -> String? = { LyricsScriptSettings.shared.languageTag }

    private struct Selection: Equatable {
        let script: LyricScript
        let languageTag: String?
    }

    private var currentSelection: Selection {
        Selection(script: scriptResolver(), languageTag: languageResolver())
    }

    private var cached: Lyrics?
    private var cachedURL: URL?
    private var cachedSelection: Selection?
    private var inFlight: [UUID: Task<Lyrics, Error>] = [:]
    private var loadIDs: [UUID: UUID] = [:]
    private var loadURLs: [UUID: URL] = [:]
    private var loadSelections: [UUID: Selection] = [:]

    private init() {
        // Cached lines belong to one language selection. Drop cached and pending
        // work on changes; cache lookups also check the selection so observer
        // ordering cannot expose the previous language to a reloading view.
        scriptObserver = NotificationCenter.default.addObserver(
            forName: .lyricsScriptPreferenceDidChange, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                LyricsStore.shared.invalidateAll()
            }
        }
    }

    deinit {
        if let scriptObserver {
            NotificationCenter.default.removeObserver(scriptObserver)
        }
    }

    /// Clear old data before notifying every lyrics surface. Consumers use a
    /// normal load so they all join the same fresh read.
    func reload(for audioURL: URL) {
        invalidate(for: audioURL)
        NotificationCenter.default.post(name: .downloadedLyricsDidChange, object: audioURL)
    }

    func invalidate(for audioURL: URL) {
        let url = audioURL.standardizedFileURL
        if cachedURL == url {
            cached = nil
            cachedURL = nil
            cachedSelection = nil
        }
        for trackID in loadURLs.filter({ $0.value == url }).map(\.key) {
            cancelInFlightLoad(for: trackID)
        }
    }

    func invalidateAll() {
        cached = nil
        cachedURL = nil
        cachedSelection = nil
        for trackID in Array(loadIDs.keys) {
            cancelInFlightLoad(for: trackID)
        }
    }

    func cachedLyrics(for trackId: UUID) -> Lyrics? {
        guard let cached, cached.trackId == trackId, cachedSelection == currentSelection else { return nil }
        return cached
    }

    func lyrics(
        for track: Track,
        using dbQueue: DatabaseQueue,
        forceReload: Bool = false
    ) async throws -> Lyrics {
        let selection = currentSelection
        if !forceReload, let cached = cachedLyrics(for: track.id) {
            return cached
        }

        // Join an in-progress load for the same track rather than starting another.
        if !forceReload, loadSelections[track.id] == selection, let existing = inFlight[track.id] {
            let result = try await existing.value
            guard !existing.isCancelled, currentSelection == selection else { throw CancellationError() }
            return result
        }

        cancelInFlightLoad(for: track.id)

        let trackId = track.id
        let loadID = UUID()
        // Run the lyrics load on a background executor so file IO (`Data(contentsOf:)`)
        // and the DB read don't block the main actor. `Task.detached` inherits no actor,
        // so the work runs off-main even though `LyricsStore` itself is `@MainActor`.
        let task = Task.detached(priority: .userInitiated) { () throws -> Lyrics in
            let result = try await LyricsLoader.loadLyrics(
                for: track,
                using: dbQueue,
                script: selection.script,
                languageTag: selection.languageTag
            )
            let hasTimed = result.source.sidecarURL(for: track.url) != nil
                || result.lyrics.contains { $0.startTime > 0 || $0.endTime != nil }
            return Lyrics(
                trackId: trackId,
                lines: result.lyrics,
                source: result.source,
                hasTimed: hasTimed,
                isKaraoke: result.lyrics.contains { $0.timingSegments?.isEmpty == false },
                availableScripts: result.availableScripts,
                availableLanguages: result.availableLanguages,
                selectedLanguage: result.selectedLanguage
            )
        }
        inFlight[trackId] = task
        loadIDs[trackId] = loadID
        loadURLs[trackId] = track.url.standardizedFileURL
        loadSelections[trackId] = selection
        defer {
            if loadIDs[trackId] == loadID {
                inFlight[trackId] = nil
                loadIDs[trackId] = nil
                loadURLs[trackId] = nil
                loadSelections[trackId] = nil
            }
        }

        let result = try await task.value
        guard loadIDs[trackId] == loadID, currentSelection == selection else { throw CancellationError() }
        cached = result
        cachedURL = track.url.standardizedFileURL
        cachedSelection = selection
        return result
    }

    /// Drop the in-flight load for `trackId`, cancelling the underlying task so the
    /// file/DB work stops when the caller no longer cares about the result.
    func cancelInFlightLoad(for trackId: UUID) {
        if let task = inFlight[trackId] {
            task.cancel()
            inFlight[trackId] = nil
            loadIDs[trackId] = nil
            loadURLs[trackId] = nil
            loadSelections[trackId] = nil
        }
    }
}
