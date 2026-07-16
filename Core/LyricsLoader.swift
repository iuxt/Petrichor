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
        using dbQueue: DatabaseQueue
    ) async throws -> (lyrics: [LyricLine], source: LyricsSource) {
        var lines: [LyricLine]?
        var source: LyricsSource = .none
        
        // 1. External KSC/LRC/SRT files
        let audioURL = track.url
        let external = await Task.detached(priority: .utility) {
            LyricsSidecarLoader.load(forAudioURL: audioURL)
        }.value
        if let external {
            lines = external.lyrics
            source = external.source
        }
        
        // 2. Embedded lyrics from database
        let fullTrack = try? await track.fullTrack(using: dbQueue)
        if lines == nil,
           let fullTrack = fullTrack,
           let embeddedText = fullTrack.extendedMetadata?.lyrics,
           !embeddedText.isEmpty {
            lines = parseAnyLyrics(embeddedText)
            source = .embedded
        }
        
        // Fallback to empty array
        return (lines ?? [], source)
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
