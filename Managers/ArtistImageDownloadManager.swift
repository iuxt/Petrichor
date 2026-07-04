import AppKit
import CryptoKit
import Foundation

final class ArtistImageDownloadManager {
    static let shared = ArtistImageDownloadManager()
    static let artistImageDownloadEnabledKey = "artistImageDownloadEnabled"

    private static let minimumImageSize = 15_000

    private enum MusicBrainz {
        static let searchURL = "https://musicbrainz.org/ws/2/artist/"
        static let rateLimitDelay: TimeInterval = 1.1
    }

    private enum Wikidata {
        static let apiURL = "https://www.wikidata.org/w/api.php"
        static let rateLimitDelay: TimeInterval = 0.5
    }

    private let fileManager: FileManager
    private var downloadTask: Task<Void, Never>?
    private var lastMusicBrainzRequest: Date?
    private var lastWikidataRequest: Date?
    private var lastWikimediaRequest: Date?

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.artistImageDownloadEnabledKey)
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func downloadMissingArtistImages(using libraryManager: LibraryManager) {
        guard isEnabled else { return }

        downloadTask?.cancel()
        downloadTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            let tracks = libraryManager.databaseManager.getAllTracks()
            let folders = libraryManager.databaseManager.getAllFolders()
            let work = ArtistImageStore.groupedArtistsByMusicRoot(from: tracks, folders: folders)
            guard !work.isEmpty else { return }

            Logger.info("ArtistImageDownloadManager: checking artist images in \(work.count) music folders")

            var imageCache: [String: Data] = [:]
            var failedArtists: Set<String> = []

            var wroteAnyImage = false

            for (musicRoot, artistNames) in work.sorted(by: {
                $0.key.path.localizedCaseInsensitiveCompare($1.key.path) == .orderedAscending
            }) {
                guard !Task.isCancelled, self.isEnabled else { break }

                for artistName in artistNames.sorted(by: {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }) {
                    guard !Task.isCancelled, self.isEnabled else { break }

                    guard ArtistImageStore.existingImageURL(
                        artistName: artistName,
                        musicRoot: musicRoot,
                        fileManager: self.fileManager
                    ) == nil else {
                        continue
                    }

                    let normalizedArtistName = ArtistParser.normalizeArtistName(artistName)
                    let imageData: Data

                    if let cached = imageCache[normalizedArtistName] {
                        imageData = cached
                    } else {
                        guard !failedArtists.contains(normalizedArtistName),
                              let downloaded = await self.fetchArtistImage(name: artistName) else {
                            failedArtists.insert(normalizedArtistName)
                            continue
                        }
                        imageCache[normalizedArtistName] = downloaded
                        imageData = downloaded
                    }

                    do {
                        let destination = try ArtistImageStore.writeImage(
                            imageData,
                            artistName: artistName,
                            musicRoot: musicRoot,
                            fileManager: self.fileManager
                        )
                        wroteAnyImage = true
                        Logger.info("ArtistImageDownloadManager: wrote \(destination.lastPathComponent)")
                    } catch {
                        Logger.error("ArtistImageDownloadManager: failed to write artist image for '\(artistName)' in \(musicRoot.path): \(error.localizedDescription)")
                    }
                }
            }

            if wroteAnyImage {
                await MainActor.run {
                    NotificationCenter.default.post(name: .artistImagesDidChange, object: nil)
                }
            }

            Logger.info("ArtistImageDownloadManager: finished artist image folder pass")
        }
    }

    private func fetchArtistImage(name: String) async -> Data? {
        guard let result = await searchMusicBrainzImage(name: name) else { return nil }
        return jpegData(from: result.imageData)
    }

    private func searchMusicBrainzImage(name: String) async -> ImageResult? {
        await waitForRateLimit(lastRequest: &lastMusicBrainzRequest, delay: MusicBrainz.rateLimitDelay)

        guard var components = URLComponents(string: MusicBrainz.searchURL) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(name)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "3")
        ]
        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await AppInfo.urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let artists = json["artists"] as? [[String: Any]] else {
                return nil
            }

            for artist in artists {
                guard let mbid = artist["id"] as? String else { continue }
                if let resultName = artist["name"] as? String,
                   !isNameMatch(query: name, result: resultName) {
                    continue
                }
                if let imageResult = await resolveImageViaMusicBrainz(mbid: mbid) {
                    return imageResult
                }
            }
            return nil
        } catch {
            if !isCancellation(error) {
                Logger.error("ArtistImageDownloadManager: MusicBrainz error for '\(name)': \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func resolveImageViaMusicBrainz(mbid: String) async -> ImageResult? {
        await waitForRateLimit(lastRequest: &lastMusicBrainzRequest, delay: MusicBrainz.rateLimitDelay)

        guard let url = URL(string: "\(MusicBrainz.searchURL)\(mbid)?inc=url-rels&fmt=json") else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await AppInfo.urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let relations = json["relations"] as? [[String: Any]] else {
                return nil
            }

            for relation in relations {
                guard let type = relation["type"] as? String, type == "wikidata",
                      let urlInfo = relation["url"] as? [String: Any],
                      let resource = urlInfo["resource"] as? String,
                      let imageResult = await resolveWikidataImage(wikidataURL: resource) else {
                    continue
                }
                return imageResult
            }

            return nil
        } catch {
            if !isCancellation(error) {
                Logger.error("ArtistImageDownloadManager: MusicBrainz lookup error for '\(mbid)': \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func resolveWikidataImage(wikidataURL: String) async -> ImageResult? {
        guard let qid = wikidataURL.split(separator: "/").last.map(String.init) else { return nil }

        await waitForRateLimit(lastRequest: &lastWikidataRequest, delay: Wikidata.rateLimitDelay)

        guard var components = URLComponents(string: Wikidata.apiURL) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "action", value: "wbgetclaims"),
            URLQueryItem(name: "entity", value: qid),
            URLQueryItem(name: "property", value: "P18"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await AppInfo.urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let claims = json["claims"] as? [String: Any],
                  let p18Claims = claims["P18"] as? [[String: Any]],
                  let firstClaim = p18Claims.first,
                  let mainsnak = firstClaim["mainsnak"] as? [String: Any],
                  let datavalue = mainsnak["datavalue"] as? [String: Any],
                  let filename = datavalue["value"] as? String else {
                return nil
            }

            let imageURL = commonsThumbUrl(filename: filename, width: 500)
            guard let imageData = await downloadImageData(from: imageURL) else { return nil }
            return ImageResult(imageData: imageData, imageURL: imageURL)
        } catch {
            if !isCancellation(error) {
                Logger.error("ArtistImageDownloadManager: Wikidata error for '\(qid)': \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func commonsThumbUrl(filename: String, width: Int) -> String {
        let normalized = filename.replacingOccurrences(of: " ", with: "_")
        let md5 = md5Hash(normalized)
        let a = String(md5.prefix(1))
        let ab = String(md5.prefix(2))
        let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalized
        return "https://upload.wikimedia.org/wikipedia/commons/thumb/\(a)/\(ab)/\(encoded)/\(width)px-\(encoded)"
    }

    private func md5Hash(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func downloadImageData(from urlString: String) async -> Data? {
        await waitForRateLimit(lastRequest: &lastWikimediaRequest, delay: Wikidata.rateLimitDelay)

        guard let url = URL(string: urlString) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await AppInfo.urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  data.count >= Self.minimumImageSize,
                  data.count <= AlbumArtFormat.maxArtworkSize else {
                return nil
            }
            return data
        } catch {
            if !isCancellation(error) {
                Logger.error("ArtistImageDownloadManager: image download failed for \(urlString): \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func jpegData(from data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return ImageUtils.encodeJPEG(cgImage)
    }

    private func isNameMatch(query: String, result: String) -> Bool {
        let normalizedQuery = ArtistParser.normalizeArtistName(query)
        let normalizedResult = ArtistParser.normalizeArtistName(result)
        return normalizedQuery == normalizedResult
            || normalizedQuery.contains(normalizedResult)
            || normalizedResult.contains(normalizedQuery)
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func waitForRateLimit(lastRequest: inout Date?, delay: TimeInterval) async {
        if let lastRequest {
            let elapsed = Date().timeIntervalSince(lastRequest)
            let waitTime = delay - elapsed
            if waitTime > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            }
        }
        lastRequest = Date()
    }

    private struct ImageResult {
        let imageData: Data
        let imageURL: String
    }
}
