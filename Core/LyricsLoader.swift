import Foundation
import GRDB

struct LyricsLoader {
    /// Load structured lyrics for a track
    /// - Parameters:
    ///   - track: The track to load lyrics for
    ///   - dbQueue: Database queue for fetching embedded lyrics
    /// - Returns: Tuple containing parsed lyrics lines and source type
    static func loadLyrics(
        for track: Track,
        using dbQueue: DatabaseQueue,
        script: LyricScript = .original,
        languageTag: String? = nil
    ) async throws -> (lyrics: [LyricLine], source: LyricsSource, availableScripts: [LyricScript],
                       availableLanguages: [LyricLanguage], selectedLanguage: LyricLanguage, fileURL: URL?) {
        var lines: [LyricLine]?
        var source: LyricsSource = .none
        var availableScripts: [LyricScript] = [.original]
        var availableLanguages: [LyricLanguage] = [.original]
        var selectedLanguage: LyricLanguage = .original

        // 1. External TTML/KSC/LRC/SRT files
        let audioURL = track.url
        let target = track.lyricsFileTarget
        let segment = track.cueSegment
        let external = await Task.detached(priority: .utility) { () -> LyricsSidecarLoader.Result? in
            if segment != nil, let specific = LyricsSidecarLoader.load(
                forAudioURL: target.lookupURL, script: script, languageTag: languageTag
            ) { return specific }
            return LyricsSidecarLoader.load(forAudioURL: audioURL, script: script, languageTag: languageTag,
                transform: { lines in segment.map { $0.lyrics(from: lines) } ?? lines })
        }.value
        if let external {
            lines = external.lyrics
            source = external.source
            availableScripts = external.availableScripts
            availableLanguages = external.availableLanguages
            selectedLanguage = external.selectedLanguage
        }

        // 2. Embedded lyrics from database
        let fullTrack = try? await track.fullTrack(using: dbQueue)
        if lines == nil,
           let fullTrack = fullTrack,
           let embeddedText = fullTrack.extendedMetadata?.lyrics,
           !embeddedText.isEmpty {
            let embedded = parseAnyLyrics(embeddedText)
            lines = segment.map { $0.lyrics(from: embedded) } ?? embedded
            source = .embedded
        }

        // Fallback to empty array
        return (lines ?? [], source, availableScripts, availableLanguages, selectedLanguage, external?.fileURL)
    }
    
    // MARK: - Helpers
    
    /// Try to parse as LRC first, then fallback to plain text lines
    private static func parseAnyLyrics(_ raw: String) -> [LyricLine] {
        // Attempt LRC parsing first, covering external and embedded timestamped lyrics.
        let lrcResult = LyricLine.parseLRC(from: raw)
        if !lrcResult.isEmpty {
            return lrcResult
        }
        
        // Plain text: split by newlines, each line with startTime=0
        let lines = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricLine(text: $0, startTime: 0, endTime: nil) }
        return lines
    }
}
