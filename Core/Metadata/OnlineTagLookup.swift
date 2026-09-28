import Foundation

enum OnlineTagProvider: String, CaseIterable, Identifiable, Sendable {
    case netease
    case qqMusic

    var id: Self { self }
}

struct OnlineTagCandidate: Identifiable, Equatable, Sendable {
    let provider: OnlineTagProvider
    let songID: String
    let title: String
    let artist: String
    let album: String
    let duration: Double?
    let trackNumber: Int?

    var id: String { "\(provider.rawValue):\(songID)" }

    // Missing provider values must never clear existing tags.
    var fields: [(field: TrackMetadataEditableField, value: String)] {
        var values: [(TrackMetadataEditableField, String)] = [
            (.title, title), (.artist, artist), (.album, album)
        ]
        if let trackNumber, trackNumber > 0 {
            values.append((.trackNumber, String(trackNumber)))
        }
        return values.filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func apply(to form: inout TrackMetadataEditForm, fields selected: Set<TrackMetadataEditableField>) {
        for entry in fields where selected.contains(entry.field) {
            form.setText(entry.value, for: entry.field)
        }
    }
}

enum OnlineTagLookupError: Error, Equatable {
    case emptyQuery
    case invalidResponse
    case serviceUnavailable
}

protocol OnlineTagSearching: Sendable {
    func search(provider: OnlineTagProvider, title: String, artist: String) async throws -> [OnlineTagCandidate]
}

/// Metadata-only, explicitly invoked lookup. No account, cookies, disk cache or audio upload.
actor OnlineTagLookupService: OnlineTagSearching {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
    }

    func search(provider: OnlineTagProvider, title: String, artist: String) async throws -> [OnlineTagCandidate] {
        let request = try Self.request(provider: provider, title: title, artist: artist)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw OnlineTagLookupError.serviceUnavailable
        }
        return try Self.parse(data, provider: provider)
    }

    static func request(provider: OnlineTagProvider, title: String, artist: String) throws -> URLRequest {
        let query = [artist, title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty else { throw OnlineTagLookupError.emptyQuery }

        var components: URLComponents
        let referer: String
        switch provider {
        case .netease:
            components = URLComponents(string: "https://music.163.com/api/search/get/")!
            components.queryItems = [
                URLQueryItem(name: "s", value: query),
                URLQueryItem(name: "limit", value: "30"),
                URLQueryItem(name: "type", value: "1"),
                URLQueryItem(name: "offset", value: "0")
            ]
            referer = "https://music.163.com/"
        case .qqMusic:
            components = URLComponents(string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp")!
            components.queryItems = [
                URLQueryItem(name: "w", value: query),
                URLQueryItem(name: "p", value: "1"),
                URLQueryItem(name: "n", value: "30"),
                URLQueryItem(name: "format", value: "json")
            ]
            referer = "https://y.qq.com/"
        }
        // A literal + must not be interpreted as a space by form-style query parsers.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw OnlineTagLookupError.emptyQuery }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        return request
    }

    static func parse(_ data: Data, provider: OnlineTagProvider) throws -> [OnlineTagCandidate] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = root["code"] as? Int else {
            throw OnlineTagLookupError.invalidResponse
        }
        guard code == (provider == .netease ? 200 : 0) else {
            throw OnlineTagLookupError.serviceUnavailable
        }

        let rows: [Any]
        switch provider {
        case .netease:
            guard let result = root["result"] as? [String: Any] else {
                throw OnlineTagLookupError.invalidResponse
            }
            if let songs = result["songs"] as? [Any] {
                rows = songs
            } else if (result["songCount"] as? Int) == 0 {
                rows = []
            } else {
                throw OnlineTagLookupError.invalidResponse
            }
        case .qqMusic:
            guard let result = root["data"] as? [String: Any],
                  let songs = result["song"] as? [String: Any],
                  let list = songs["list"] as? [Any] else {
                throw OnlineTagLookupError.invalidResponse
            }
            rows = list
        }

        var seen = Set<String>()
        let candidates = rows.compactMap { row -> OnlineTagCandidate? in
            guard let row = row as? [String: Any] else { return nil }
            let isNetease = provider == .netease
            let songID: String
            if isNetease, let number = row["id"] as? Int64, number > 0 {
                songID = String(number)
            } else if !isNetease, let mid = row["songmid"] as? String, !mid.isEmpty {
                songID = mid
            } else {
                return nil
            }
            let title = clean(row[isNetease ? "name" : "songname"])
            guard !title.isEmpty else { return nil }
            let artists = row[isNetease ? "artists" : "singer"] as? [[String: Any]] ?? []
            let artist = artists.map { clean($0["name"]) }.filter { !$0.isEmpty }.joined(separator: "; ")
            let album = isNetease ? clean((row["album"] as? [String: Any])?["name"]) : clean(row["albumname"])
            let rawDuration = (row[isNetease ? "duration" : "interval"] as? NSNumber)?.doubleValue
            let duration = rawDuration.flatMap { value -> Double? in
                let seconds = value / (isNetease ? 1000 : 1)
                // Keep malformed provider numbers out of duration formatters' Int conversions.
                return seconds.isFinite && seconds > 0 && seconds < Double(Int32.max) ? seconds : nil
            }
            let rawTrack = row[isNetease ? "position" : "cdIdx"] as? Int
            let candidate = OnlineTagCandidate(
                provider: provider, songID: songID, title: title, artist: artist, album: album,
                duration: duration, trackNumber: rawTrack.flatMap { $0 > 0 ? $0 : nil }
            )
            return seen.insert(candidate.id).inserted ? candidate : nil
        }
        guard rows.isEmpty || !candidates.isEmpty else { throw OnlineTagLookupError.invalidResponse }
        return Array(candidates.prefix(30))
    }

    private static func clean(_ value: Any?) -> String {
        // QQ's legacy search occasionally double-escapes quotation marks.
        (value as? String ?? "")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
