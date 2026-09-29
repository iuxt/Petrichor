import Foundation

struct DownloadedLyrics: Equatable, Sendable {
    let lrc: String
}

enum LyricsDownloadError: Error, Equatable {
    case unavailable
    case invalidResponse
    case noLyrics
    case existingFile
    case existingSidecar
    case unsafeDestination
}

protocol OnlineLyricsServing: OnlineTagSearching {
    func download(_ candidate: OnlineTagCandidate, includeTranslation: Bool) async throws -> DownloadedLyrics
}

actor OnlineLyricsService: OnlineLyricsServing {
    private let searchService: OnlineTagLookupService
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = session ?? URLSession(configuration: configuration)
        self.session = session
        searchService = OnlineTagLookupService(session: session)
    }

    func search(provider: OnlineTagProvider, title: String, artist: String) async throws -> [OnlineTagCandidate] {
        try await searchService.search(provider: provider, title: title, artist: artist)
    }

    func download(_ candidate: OnlineTagCandidate, includeTranslation: Bool) async throws -> DownloadedLyrics {
        if candidate.provider == .qqMusic {
            if let wordTimed = try? await downloadQQWordTimed(candidate, includeTranslation: includeTranslation) {
                return wordTimed
            }
            try Task.checkCancellation()
        }
        let (data, response) = try await session.data(for: Self.request(for: candidate))
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw LyricsDownloadError.unavailable
        }
        return try Self.parse(data, provider: candidate.provider, includeTranslation: includeTranslation)
    }

    private func downloadQQWordTimed(_ candidate: OnlineTagCandidate, includeTranslation: Bool) async throws -> DownloadedLyrics? {
        let (data, response) = try await session.data(for: Self.qqWordRequest(for: candidate))
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              data.count <= 2_000_000,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = json["req_0"] as? [String: Any], result["code"] as? Int == 0,
              let lyricData = result["data"] as? [String: Any],
              let encrypted = lyricData["lyric"] as? String,
              let xml = QQMusicQRCDecoder.decode(encrypted),
              let raw = Self.qrcContent(xml) else { return nil }
        let lines = WordTimedLyrics.qrc(raw)
        guard !lines.isEmpty else { return nil }

        var translations: [LyricLine] = []
        if includeTranslation,
           let (translationData, translationResponse) = try? await session.data(for: Self.request(for: candidate)),
           let translationResponse = translationResponse as? HTTPURLResponse,
           (200..<300).contains(translationResponse.statusCode),
           translationData.count <= 2_000_000,
           let lineJSON = (try? JSONSerialization.jsonObject(with: translationData)) as? [String: Any],
           let translation = lineJSON["trans"] as? String {
            translations = Self.timedLines(translation)
        }
        try Task.checkCancellation()
        return WordTimedLyrics.enhancedLRC(lines, translations: translations).map(DownloadedLyrics.init(lrc:))
    }

    private static func qrcContent(_ xml: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"LyricContent="([^"]*)""#),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return decodeEntities(String(xml[range]))
    }

    static func qqWordRequest(for candidate: OnlineTagCandidate) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
        request.httpMethod = "POST"
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "comm": ["ct": 19, "cv": 0, "tmeAppID": "qqmusiclight"],
            "req_0": ["module": "music.musichallSong.PlayLyricInfo", "method": "GetPlayLyricInfo",
                      "param": ["songMID": candidate.songID, "songID": 0, "platform": 0,
                                "needNew": 1, "crypt": 1, "qrc": 1, "trans": 1]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static func request(for candidate: OnlineTagCandidate) -> URLRequest {
        var components: URLComponents
        let referer: String
        switch candidate.provider {
        case .netease:
            components = URLComponents(string: "https://music.163.com/api/song/lyric/v1")!
            components.queryItems = [
                .init(name: "id", value: candidate.songID), .init(name: "cp", value: "false"),
                .init(name: "lv", value: "0"), .init(name: "tv", value: "0"),
                .init(name: "kv", value: "0"), .init(name: "yv", value: "0"),
                .init(name: "ytv", value: "0"), .init(name: "yrv", value: "0")
            ]
            referer = "https://music.163.com/"
        case .qqMusic:
            components = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
            components.queryItems = [
                .init(name: "songmid", value: candidate.songID), .init(name: "format", value: "json"),
                .init(name: "nobase64", value: "1")
            ]
            referer = "https://y.qq.com/"
        }
        var request = URLRequest(url: components.url!)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func parse(_ data: Data, provider: OnlineTagProvider, includeTranslation: Bool) throws -> DownloadedLyrics {
        guard data.count <= 2_000_000,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = json["code"] as? Int else { throw LyricsDownloadError.invalidResponse }
        guard code == (provider == .netease ? 200 : 0) else { throw LyricsDownloadError.unavailable }
        if json["nolyric"] as? Bool == true || json["pureMusic"] as? Bool == true {
            throw LyricsDownloadError.noLyrics
        }
        let raw: String?
        let translation: String?
        switch provider {
        case .netease:
            raw = (json["lrc"] as? [String: Any])?["lyric"] as? String
            translation = (json["tlyric"] as? [String: Any])?["lyric"] as? String
            if let yrc = (json["yrc"] as? [String: Any])?["lyric"] as? String,
               let enhanced = WordTimedLyrics.enhancedLRC(
                   WordTimedLyrics.yrc(yrc),
                   translations: includeTranslation ? timedLines(translation ?? "") : []
               ) {
                return DownloadedLyrics(lrc: enhanced)
            }
        case .qqMusic:
            raw = json["lyric"] as? String
            translation = json["trans"] as? String
        }
        guard let raw, !raw.isEmpty else { throw LyricsDownloadError.noLyrics }
        let original = timedLines(raw)
        guard original.contains(where: { !$0.text.isEmpty }) else { throw LyricsDownloadError.noLyrics }
        let translated = includeTranslation ? timedLines(translation ?? "") : []
        // Emit one timestamp per line; translations share their original's timestamp.
        // This avoids duplicate-timestamp lines fighting for the active highlight.
        var grouped: [Int: [String]] = [:]
        for line in original {
            let milliseconds = Int((line.startTime * 1000).rounded())
            var texts = grouped[milliseconds] ?? []
            if !texts.contains(line.text) { texts.append(line.text) }
            grouped[milliseconds] = texts
        }
        for line in translated where !line.text.isEmpty {
            let milliseconds = Int((line.startTime * 1000).rounded())
            guard let nearest = grouped.keys.min(by: { abs($0 - milliseconds) < abs($1 - milliseconds) }),
                  abs(nearest - milliseconds) <= 500,
                  grouped[nearest]?.contains(line.text) == false else { continue }
            grouped[nearest]?.append(line.text)
        }
        let lrc = grouped.keys.sorted().map { milliseconds in
            let text = grouped[milliseconds]!.filter { !$0.isEmpty }.joined(separator: " / ")
            return String(format: "[%02d:%02d.%03d]%@", milliseconds / 60_000, milliseconds / 1000 % 60, milliseconds % 1000, text)
        }.joined(separator: "\n") + "\n"
        return DownloadedLyrics(lrc: lrc)
    }

    private static func timedLines(_ text: String) -> [LyricLine] {
        let decoded = decodeEntities(text)
        // Respect an LRC's global offset while converting it to a normalized sidecar.
        let pattern = #"\[offset:\s*([+-]?\d+)\s*\]"#
        var offset = 0.0
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
           let range = Range(match.range(at: 1), in: decoded),
           let milliseconds = Double(decoded[range]), milliseconds.isFinite {
            offset = milliseconds / 1000
        }
        return LyricLine.parseLRC(from: decoded).compactMap { line in
            let time = line.startTime + offset
            guard time.isFinite, time >= 0, time < 86_400 else { return nil }
            return LyricLine(text: line.text, startTime: time)
        }
    }

    private static func decodeEntities(_ text: String) -> String {
        var text = text
        // QQ may entity-encode both timestamps and lyric text. Avoid an AppKit HTML parser.
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let full = Range(match.range, in: text), let valueRange = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[valueRange])
                let number = value.hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
                if let number, let scalar = UnicodeScalar(number) { text.replaceSubrange(full, with: String(scalar)) }
            }
        }
        for (entity, character) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }
}

/// Automatic downloads require agreement on title, artist and duration. Versions such
/// as live/remix are not stripped, and tied candidates from different albums are skipped.
struct LyricsMatchQuery: Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: Double

    var isComplete: Bool {
        !normalized(title).isEmpty && !normalized(artist).isEmpty &&
            artist != "Unknown Artist" && duration.isFinite && duration > 0
    }

    func automaticMatch(in candidates: [OnlineTagCandidate]) -> OnlineTagCandidate? {
        guard isComplete else { return nil }
        let matches = candidates.filter { candidate in
            guard normalized(candidate.title) == normalized(title),
                  artists(candidate.artist) == artists(artist),
                  let length = candidate.duration else { return false }
            return abs(length - duration) <= 3
        }
        let albumMatches = matches.filter { !album.isEmpty && normalized($0.album) == normalized(album) }
        let preferred = albumMatches.isEmpty ? matches : albumMatches
        guard let first = preferred.first else { return nil }
        if preferred.count > 1 {
            // Different recordings/albums are ambiguous even if the title matches.
            guard preferred.allSatisfy({ normalized($0.album) == normalized(first.album) }) else { return nil }
        }
        return preferred.min { abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration) }
    }

    private func artists(_ value: String) -> Set<String> {
        Set(value.components(separatedBy: CharacterSet(charactersIn: ";；/、")).map(normalized).filter { !$0.isEmpty })
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }
}
