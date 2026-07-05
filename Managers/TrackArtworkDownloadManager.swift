import AppKit
import Foundation

actor TrackArtworkDownloadManager {
    static let shared = TrackArtworkDownloadManager()
    static let trackArtworkDownloadEnabledKey = "trackArtworkDownloadEnabled"

    private enum MusicBrainz {
        static let releaseSearchURL = "https://musicbrainz.org/ws/2/release/"
        static let rateLimitDelay: TimeInterval = 1.1
    }

    private enum CoverArtArchive {
        static let baseURL = "https://coverartarchive.org"
        static let rateLimitDelay: TimeInterval = 0.25
    }

    private let fileManager: FileManager
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var lastMusicBrainzRequest: Date?
    private var lastCoverArtRequest: Date?

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.trackArtworkDownloadEnabledKey)
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func downloadArtwork(for fullTrack: FullTrack) async -> URL? {
        guard !Task.isCancelled else { return nil }
        guard isEnabled else { return nil }
        guard isValidForArtworkFetch(fullTrack) else { return nil }

        let audioURL = fullTrack.url
        let key = audioURL.standardizedFileURL.path

        if let task = inFlight[key] {
            return await valueCancellingOnCallerCancellation(task)
        }

        let task = Task { [weak self] () -> URL? in
            guard !Task.isCancelled else { return nil }
            guard let self else { return nil }
            return await self.performDownload(for: fullTrack)
        }
        inFlight[key] = task
        let result = await valueCancellingOnCallerCancellation(task)
        inFlight[key] = nil
        return result
    }

    private func performDownload(for fullTrack: FullTrack) async -> URL? {
        guard !Task.isCancelled else { return nil }

        if let existing = TrackArtworkSidecarWriter.existingSameStemArtworkURL(
            forAudioURL: fullTrack.url,
            fileManager: fileManager
        ) {
            return existing
        }

        guard let downloaded = await fetchArtwork(for: fullTrack),
              let jpegData = jpegData(from: downloaded) else {
            return nil
        }

        guard !Task.isCancelled else { return nil }

        do {
            let destination = try TrackArtworkSidecarWriter.write(
                jpegData,
                forAudioURL: fullTrack.url,
                fileManager: fileManager
            )
            Logger.info("TrackArtworkDownloadManager: wrote \(destination.lastPathComponent)")
            return destination
        } catch {
            Logger.error("TrackArtworkDownloadManager: failed to write artwork sidecar for '\(fullTrack.title)': \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchArtwork(for fullTrack: FullTrack) async -> Data? {
        guard !Task.isCancelled else { return nil }

        if let releaseID = fullTrack.extendedMetadata?.musicBrainzAlbumId?.nilIfEmpty,
           let data = await downloadCoverArt(path: "/release/\(releaseID)/front-500") {
            return data
        }

        guard !Task.isCancelled else { return nil }

        if let releaseGroupID = fullTrack.extendedMetadata?.musicBrainzReleaseGroupId?.nilIfEmpty,
           let data = await downloadCoverArt(path: "/release-group/\(releaseGroupID)/front-500") {
            return data
        }

        guard !Task.isCancelled else { return nil }

        guard let release = await searchMusicBrainzRelease(for: fullTrack) else {
            return nil
        }

        guard !Task.isCancelled else { return nil }

        if let data = await downloadCoverArt(path: "/release/\(release.id)/front-500") {
            return data
        }

        guard !Task.isCancelled else { return nil }

        if let releaseGroupID = release.releaseGroupID {
            return await downloadCoverArt(path: "/release-group/\(releaseGroupID)/front-500")
        }

        return nil
    }

    private func searchMusicBrainzRelease(for fullTrack: FullTrack) async -> ReleaseMatch? {
        guard !Task.isCancelled else { return nil }
        guard await waitForRateLimit(.musicBrainz) else { return nil }

        guard var components = URLComponents(string: MusicBrainz.releaseSearchURL) else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "query", value: musicBrainzQuery(for: fullTrack)),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "3")
        ]

        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await AppInfo.urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }

            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode != 404 {
                    Logger.info("TrackArtworkDownloadManager: MusicBrainz returned status \(httpResponse.statusCode)")
                }
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let releases = json["releases"] as? [[String: Any]] else {
                return nil
            }

            for release in releases {
                guard let id = release["id"] as? String else { continue }
                let releaseGroup = release["release-group"] as? [String: Any]
                let releaseGroupID = releaseGroup?["id"] as? String
                return ReleaseMatch(id: id, releaseGroupID: releaseGroupID)
            }

            return nil
        } catch {
            if !isCancellation(error) {
                Logger.error("TrackArtworkDownloadManager: MusicBrainz error for '\(fullTrack.title)': \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func downloadCoverArt(path: String) async -> Data? {
        guard !Task.isCancelled else { return nil }
        guard await waitForRateLimit(.coverArt) else { return nil }

        guard let url = URL(string: CoverArtArchive.baseURL + path) else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await AppInfo.urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }

            switch httpResponse.statusCode {
            case 200:
                guard data.count > 0, data.count <= AlbumArtFormat.maxArtworkSize else {
                    return nil
                }
                return data
            case 400, 404:
                return nil
            default:
                Logger.info("TrackArtworkDownloadManager: Cover Art Archive returned status \(httpResponse.statusCode)")
                return nil
            }
        } catch {
            if !isCancellation(error) {
                Logger.error("TrackArtworkDownloadManager: cover art download failed for \(path): \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func musicBrainzQuery(for fullTrack: FullTrack) -> String {
        [
            "artist:\"\(escapedQueryValue(fullTrack.artist))\"",
            "release:\"\(escapedQueryValue(fullTrack.album))\"",
            "recording:\"\(escapedQueryValue(fullTrack.title))\""
        ].joined(separator: " AND ")
    }

    private func escapedQueryValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func isValidForArtworkFetch(_ fullTrack: FullTrack) -> Bool {
        let title = fullTrack.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = fullTrack.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = fullTrack.album.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty,
              !artist.isEmpty,
              !album.isEmpty,
              title != "Unknown Title",
              artist != "Unknown Artist",
              album != "Unknown Album" else {
            return false
        }

        return true
    }

    private func jpegData(from data: Data) -> Data? {
        guard data.count > 0, data.count <= AlbumArtFormat.maxArtworkSize else {
            return nil
        }

        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        return ImageUtils.encodeJPEG(cgImage)
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private enum RateLimitBucket {
        case musicBrainz
        case coverArt
    }

    private func valueCancellingOnCallerCancellation(_ task: Task<URL?, Never>) async -> URL? {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func waitForRateLimit(_ bucket: RateLimitBucket) async -> Bool {
        let delay: TimeInterval
        let lastRequest: Date?

        switch bucket {
        case .musicBrainz:
            delay = MusicBrainz.rateLimitDelay
            lastRequest = lastMusicBrainzRequest
        case .coverArt:
            delay = CoverArtArchive.rateLimitDelay
            lastRequest = lastCoverArtRequest
        }

        if let lastRequest {
            let elapsed = Date().timeIntervalSince(lastRequest)
            let waitTime = delay - elapsed
            if waitTime > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                } catch {
                    return false
                }
            }
        }

        guard !Task.isCancelled else { return false }

        switch bucket {
        case .musicBrainz:
            lastMusicBrainzRequest = Date()
        case .coverArt:
            lastCoverArtRequest = Date()
        }

        return true
    }

    private struct ReleaseMatch {
        let id: String
        let releaseGroupID: String?
    }
}
