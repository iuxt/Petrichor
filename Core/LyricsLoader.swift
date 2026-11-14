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
            return (external.lyrics, external.source, external.availableScripts, external.availableLanguages,
                    external.selectedLanguage, external.fileURL)
        }

        guard let fullTrack = try? await track.fullTrack(using: dbQueue),
              let raw = fullTrack.extendedMetadata?.lyrics, !raw.isEmpty else {
            return ([], .none, [.original], [.original], .original, nil)
        }
        let embedded = parseEmbedded(raw, script: script, languageTag: languageTag)
        let lines = segment.map { $0.lyrics(from: embedded.lyrics) } ?? embedded.lyrics
        return (lines, .embedded, embedded.availableScripts, embedded.availableLanguages, embedded.selectedLanguage, nil)
    }

    private static func parseEmbedded(_ text: String, script: LyricScript, languageTag: String?) -> LyricsSidecarLoader.Result {
        let raw = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        if raw.hasPrefix("<") {
            let parsed = TTMLLyricsParser.parse(Data(raw.utf8), script: script, languageTag: languageTag)
            if !parsed.lines.isEmpty {
                return .init(lyrics: parsed.lines, source: .embedded, availableScripts: parsed.availableScripts,
                             availableLanguages: parsed.availableLanguages, selectedLanguage: parsed.selectedLanguage)
            }
        }
        if raw.localizedCaseInsensitiveContains("karaoke.add") {
            let lines = LyricLine.parseKSC(from: raw)
            if !lines.isEmpty { return .init(lyrics: lines, source: .embedded) }
        }
        if raw.contains("-->") {
            let lines = LyricLine.parseSRT(from: raw)
            if !lines.isEmpty { return .init(lyrics: lines, source: .embedded) }
        }
        let timed = LyricLine.parseLRC(from: raw)
        if !timed.isEmpty { return .init(lyrics: timed, source: .embedded) }

        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricLine(text: $0, startTime: 0, endTime: nil) }
        return .init(lyrics: lines, source: .embedded)
    }
}
