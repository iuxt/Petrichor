import Foundation

struct AMLLTTMLCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
}

/// AMLL's public lyric API. Requests happen only from manual search/save or the
/// existing opt-in automatic lyric downloader, and contain no audio data.
enum AMLLTTMLService {
    private static let baseURL = "https://api.amll.dev/v1/lyrics/"
    private static let maximumResponseBytes = 2_000_000

    static func search(title: String, artist: String, session: URLSession) async throws -> [AMLLTTMLCandidate] {
        var query: [URLQueryItem] = []
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { query.append(.init(name: "musicName", value: title)) }
        if !artist.isEmpty { query.append(.init(name: "artistName", value: artist)) }
        guard !query.isEmpty else { return [] }
        query.append(.init(name: "pageSize", value: "30"))
        let data = try await fetch(path: "search", query: query, session: session)
        guard let payload = responseData(data),
              let items = payload["items"] as? [[String: Any]] else { throw LyricsDownloadError.invalidResponse }
        return items.compactMap { item in
            guard let id = item["id"] as? NSNumber,
                  let title = (item["musicNames"] as? [String])?.first,
                  !title.isEmpty else { return nil }
            return AMLLTTMLCandidate(
                id: id.stringValue,
                title: title,
                artist: (item["artistNames"] as? [String] ?? []).joined(separator: ", "),
                album: (item["albumNames"] as? [String])?.first ?? ""
            )
        }
    }

    static func download(_ candidate: AMLLTTMLCandidate, session: URLSession) async throws -> DownloadedLyrics {
        guard Int64(candidate.id) != nil else { throw LyricsDownloadError.invalidResponse }
        let data = try await fetch(path: "get", query: [.init(name: "id", value: candidate.id)], session: session)
        return try parseLyrics(data, expectedID: candidate.id)
    }

    static func download(for candidate: OnlineTagCandidate, session: URLSession) async throws -> DownloadedLyrics {
        let parameter = candidate.provider == .netease ? "ncmMusicId" : "qqMusicId"
        let data = try await fetch(path: "get", query: [.init(name: parameter, value: candidate.songID)], session: session)
        return try parseLyrics(data, expectedPlatform: (parameter + "s", candidate.songID))
    }

    private static func fetch(path: String, query: [URLQueryItem], session: URLSession) async throws -> Data {
        var components = URLComponents(string: baseURL + path)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { throw LyricsDownloadError.unavailable }
        guard data.count <= maximumResponseBytes else { throw LyricsDownloadError.invalidResponse }
        return data
    }

    private static func responseData(_ data: Data) -> [String: Any]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["status"] as? Int == 200 else { return nil }
        return json["data"] as? [String: Any]
    }

    private static func parseLyrics(
        _ data: Data,
        expectedID: String? = nil,
        expectedPlatform: (key: String, id: String)? = nil
    ) throws -> DownloadedLyrics {
        guard let payload = responseData(data),
              let source = payload["lyrics"] as? String,
              !TTMLLyricsParser.parse(Data(source.utf8)).isEmpty else { throw LyricsDownloadError.noLyrics }
        if let expectedID, (payload["id"] as? NSNumber)?.stringValue != expectedID {
            throw LyricsDownloadError.invalidResponse
        }
        if let expectedPlatform,
           (payload[expectedPlatform.key] as? [String])?.contains(expectedPlatform.id) != true {
            throw LyricsDownloadError.invalidResponse
        }
        return DownloadedLyrics(ttml: source)
    }
}
