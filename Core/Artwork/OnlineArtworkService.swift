import Foundation

enum ArtworkDownloadError: Error {
    case invalidResponse
    case unavailable
    case unsafeDestination
    case existingArtwork
}

protocol OnlineArtworkServing: Sendable {
    func download(for candidate: OnlineTagCandidate) async throws -> Data
}

/// Uses the song-detail cover endpoints used by MusicPlayer2. Only a confident
/// match from the user's selected music provider is passed to this service.
actor OnlineArtworkService: OnlineArtworkServing {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
    }

    func download(for candidate: OnlineTagCandidate) async throws -> Data {
        let detailURL = try Self.detailURL(for: candidate)
        var detailRequest = URLRequest(url: detailURL)
        detailRequest.setValue(candidate.provider == .netease ? "https://music.163.com/" : "https://y.qq.com/", forHTTPHeaderField: "Referer")
        let (detail, detailResponse) = try await session.data(for: detailRequest)
        try Task.checkCancellation()
        guard let detailResponse = detailResponse as? HTTPURLResponse,
              (200..<300).contains(detailResponse.statusCode),
              detail.count <= 2_000_000 else { throw ArtworkDownloadError.unavailable }
        let imageURL = try Self.imageURL(from: detail, for: candidate)
        var imageRequest = URLRequest(url: imageURL)
        imageRequest.setValue(detailRequest.value(forHTTPHeaderField: "Referer"), forHTTPHeaderField: "Referer")
        let (image, imageResponse) = try await session.data(for: imageRequest)
        try Task.checkCancellation()
        guard let imageResponse = imageResponse as? HTTPURLResponse,
              (200..<300).contains(imageResponse.statusCode),
              let finalURL = imageResponse.url,
              Self.isAllowedImageURL(finalURL, provider: candidate.provider),
              !image.isEmpty, image.count <= AlbumArtFormat.maxArtworkSize,
              let decoded = ImageUtils.downsampledImage(from: image, maxDimension: 1600),
              let jpeg = ImageUtils.encodeJPEG(decoded, quality: 0.85) else {
            throw ArtworkDownloadError.invalidResponse
        }
        return jpeg
    }

    static func detailURL(for candidate: OnlineTagCandidate) throws -> URL {
        var components: URLComponents
        switch candidate.provider {
        case .netease:
            guard Int64(candidate.songID) != nil else { throw ArtworkDownloadError.invalidResponse }
            components = URLComponents(string: "https://music.163.com/api/song/detail/")!
            components.queryItems = [
                .init(name: "id", value: candidate.songID),
                .init(name: "ids", value: "[\(candidate.songID)]"),
                .init(name: "csrf_token", value: "")
            ]
        case .qqMusic:
            guard !candidate.songID.isEmpty,
                  candidate.songID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                throw ArtworkDownloadError.invalidResponse
            }
            components = URLComponents(string: "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg")!
            components.queryItems = [.init(name: "songmid", value: candidate.songID), .init(name: "format", value: "json")]
        }
        guard let url = components.url else { throw ArtworkDownloadError.invalidResponse }
        return url
    }

    static func imageURL(from data: Data, for candidate: OnlineTagCandidate) throws -> URL {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ArtworkDownloadError.invalidResponse
        }
        switch candidate.provider {
        case .netease:
            guard let songs = json["songs"] as? [[String: Any]],
                  let song = songs.first,
                  (song["id"] as? NSNumber)?.stringValue == candidate.songID,
                  let album = song["album"] as? [String: Any],
                  let raw = album["picUrl"] as? String,
                  let parsed = URL(string: raw),
                  let url = secureImageURL(parsed, provider: .netease) else {
                throw ArtworkDownloadError.invalidResponse
            }
            return url
        case .qqMusic:
            guard let songs = json["data"] as? [[String: Any]],
                  let song = songs.first,
                  (song["mid"] as? String ?? song["songmid"] as? String) == candidate.songID,
                  let album = song["album"] as? [String: Any],
                  let mid = album["mid"] as? String,
                  !mid.isEmpty, mid.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                  let url = URL(string: "https://y.gtimg.cn/music/photo_new/T002R800x800M000\(mid).jpg") else {
                throw ArtworkDownloadError.invalidResponse
            }
            return url
        }
    }

    private static func isAllowedImageURL(_ url: URL, provider: OnlineTagProvider) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        switch provider {
        case .netease: return host == "music.126.net" || host.hasSuffix(".music.126.net")
        case .qqMusic: return host == "y.gtimg.cn"
        }
    }

    private static func secureImageURL(_ url: URL, provider: OnlineTagProvider) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http" || components.scheme == "https" else { return nil }
        components.scheme = "https"
        guard let secured = components.url,
              isAllowedImageURL(secured, provider: provider) else { return nil }
        return secured
    }
}
