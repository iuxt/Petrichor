import AppKit
import Foundation
import ImageIO

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
    private var inFlight: [String: InFlightArtworkDownload] = [:]
    private var onlineMisses: [String: Date] = [:]
    private var successfulDisplayCache: [String: SuccessfulDisplayCacheEntry] = [:]
    private var lastMusicBrainzRequest: Date?
    private var lastCoverArtRequest: Date?

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.trackArtworkDownloadEnabledKey)
    }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func downloadArtwork(for fullTrack: FullTrack) async -> TrackArtworkDownloadResult? {
        guard !Task.isCancelled else { return nil }
        guard isEnabled else { return nil }
        guard isValidForArtworkFetch(fullTrack) else { return nil }

        let audioURL = fullTrack.url
        let key = audioURL.standardizedFileURL.path

        let waiterID = UUID()
        let flight: InFlightArtworkDownload

        if var existing = inFlight[key] {
            existing.waiters.insert(waiterID)
            inFlight[key] = existing
            flight = existing
        } else {
            let task = Task { [weak self] () -> TrackArtworkDownloadResult? in
                guard !Task.isCancelled else { return nil }
                guard let self else { return nil }
                return await self.performDownload(for: fullTrack)
            }
            flight = InFlightArtworkDownload(id: UUID(), task: task, waiters: [waiterID])
            inFlight[key] = flight
        }

        let result = await valueForWaiter(
            task: flight.task,
            key: key,
            flightID: flight.id,
            waiterID: waiterID
        )
        removeWaiter(
            key: key,
            flightID: flight.id,
            waiterID: waiterID,
            cancelIfLast: Task.isCancelled
        )
        return result
    }

    private func performDownload(for fullTrack: FullTrack) async -> TrackArtworkDownloadResult? {
        guard !Task.isCancelled else { return nil }
        guard isEnabled else { return nil }
        let key = fullTrack.url.standardizedFileURL.path
        var hasInvalidExistingSidecar = false

        if let existing = TrackArtworkSidecarWriter.existingSameStemArtworkURL(
            forAudioURL: fullTrack.url,
            fileManager: fileManager
        ) {
            if isDisplayableArtworkFile(existing) {
                guard isEnabled else { return nil }
                return TrackArtworkDownloadResult(sidecarURL: existing)
            }
            hasInvalidExistingSidecar = true
            Logger.info("TrackArtworkDownloadManager: ignoring invalid existing artwork sidecar \(existing.lastPathComponent)")
        }

        if let cached = cachedOnlineDisplayResult(for: key) {
            return cached
        }

        guard !hasRecentOnlineMiss(for: key) else { return nil }

        let downloaded = await fetchArtwork(for: fullTrack)
        guard !Task.isCancelled else { return nil }

        guard let downloaded,
              let jpegData = jpegData(from: downloaded) else {
            guard !Task.isCancelled else { return nil }
            guard isEnabled else { return nil }
            recordOnlineMiss(for: fullTrack.url)
            return nil
        }

        guard !Task.isCancelled else { return nil }
        guard isEnabled else { return nil }

        if hasInvalidExistingSidecar {
            guard isEnabled else { return nil }
            storeOnlineDisplayResult(jpegData, for: key)
            guard isEnabled else { return nil }
            return TrackArtworkDownloadResult(displayData: jpegData)
        }

        do {
            guard isEnabled else { return nil }
            let writeResult = try TrackArtworkSidecarWriter.writeResult(
                jpegData,
                forAudioURL: fullTrack.url,
                fileManager: fileManager
            )
            let destination = writeResult.url
            guard isDisplayableArtworkFile(destination) else {
                Logger.info("TrackArtworkDownloadManager: downloaded artwork could not replace invalid sidecar \(destination.lastPathComponent)")
                guard isEnabled else { return nil }
                storeOnlineDisplayResult(jpegData, for: key)
                guard isEnabled else { return nil }
                return TrackArtworkDownloadResult(displayData: jpegData)
            }

            if writeResult.didWriteSidecar {
                guard isEnabled else { return nil }
                await postTrackArtworkSidecarDidChange(for: fullTrack.url)
                Logger.info("TrackArtworkDownloadManager: wrote \(destination.lastPathComponent)")
            }
            guard isEnabled else { return nil }
            return TrackArtworkDownloadResult(sidecarURL: destination, didWriteSidecar: writeResult.didWriteSidecar)
        } catch {
            Logger.error("TrackArtworkDownloadManager: failed to write artwork sidecar for '\(fullTrack.title)': \(error.localizedDescription)")
            guard isEnabled else { return nil }
            storeOnlineDisplayResult(jpegData, for: key)
            guard isEnabled else { return nil }
            return TrackArtworkDownloadResult(displayData: jpegData)
        }
    }

    private func fetchArtwork(for fullTrack: FullTrack) async -> Data? {
        guard !Task.isCancelled else { return nil }
        guard isEnabled else { return nil }

        if let releaseID = fullTrack.extendedMetadata?.musicBrainzAlbumId?.nilIfEmpty,
           let data = await downloadCoverArt(path: "/release/\(releaseID)/front-500") {
            return data
        }

        guard !Task.isCancelled else { return nil }
        guard isEnabled else { return nil }

        if let releaseGroupID = fullTrack.extendedMetadata?.musicBrainzReleaseGroupId?.nilIfEmpty,
           let data = await downloadCoverArt(path: "/release-group/\(releaseGroupID)/front-500") {
            return data
        }

        guard !Task.isCancelled else { return nil }
        guard isEnabled else { return nil }

        guard let release = await searchMusicBrainzRelease(for: fullTrack) else {
            return nil
        }

        guard !Task.isCancelled else { return nil }
        guard isEnabled else { return nil }

        if let data = await downloadCoverArt(path: "/release/\(release.id)/front-500") {
            return data
        }

        guard !Task.isCancelled else { return nil }
        guard isEnabled else { return nil }

        if let releaseGroupID = release.releaseGroupID {
            guard isEnabled else { return nil }
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

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }

        let pixelLimit = CGFloat(AlbumArtFormat.maxArtworkPixelDimension)
        guard width <= pixelLimit, height <= pixelLimit else {
            Logger.warning("Skipping oversized downloaded artwork \(Int(width))x\(Int(height))")
            return nil
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        guard let encoded = ImageUtils.encodeJPEG(cgImage),
              encoded.count > 0, encoded.count <= AlbumArtFormat.maxArtworkSize else {
            return nil
        }

        return encoded
    }

    private func isDisplayableArtworkFile(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              data.count > 0,
              data.count <= AlbumArtFormat.maxArtworkSize,
              ImageUtils.compressImage(from: data, source: url.lastPathComponent) != nil else {
            return false
        }
        return true
    }

    private func cachedOnlineDisplayResult(for key: String) -> TrackArtworkDownloadResult? {
        guard isEnabled else { return nil }
        pruneExpiredSuccessfulDisplayCache()
        guard let entry = successfulDisplayCache[key] else { return nil }
        return TrackArtworkDownloadResult(displayData: entry.data)
    }

    private func storeOnlineDisplayResult(_ data: Data, for key: String) {
        pruneExpiredSuccessfulDisplayCache()
        successfulDisplayCache[key] = SuccessfulDisplayCacheEntry(data: data, storedAt: Date())

        if successfulDisplayCache.count > SuccessfulDisplayCache.maxEntries {
            let overflow = successfulDisplayCache.count - SuccessfulDisplayCache.maxEntries
            for key in successfulDisplayCache.sorted(by: { $0.value.storedAt < $1.value.storedAt }).prefix(overflow).map(\.key) {
                successfulDisplayCache[key] = nil
            }
        }
    }

    private func pruneExpiredSuccessfulDisplayCache() {
        let cutoff = Date().addingTimeInterval(-SuccessfulDisplayCache.cooldown)
        successfulDisplayCache = successfulDisplayCache.filter { $0.value.storedAt >= cutoff }
    }

    private func hasRecentOnlineMiss(for key: String) -> Bool {
        pruneExpiredOnlineMisses()
        guard let missedAt = onlineMisses[key] else { return false }
        return Date().timeIntervalSince(missedAt) < OnlineMissCache.cooldown
    }

    private func recordOnlineMiss(for audioURL: URL) {
        pruneExpiredOnlineMisses()
        onlineMisses[audioURL.standardizedFileURL.path] = Date()

        if onlineMisses.count > OnlineMissCache.maxEntries {
            let overflow = onlineMisses.count - OnlineMissCache.maxEntries
            for key in onlineMisses.sorted(by: { $0.value < $1.value }).prefix(overflow).map(\.key) {
                onlineMisses[key] = nil
            }
        }
    }

    private func pruneExpiredOnlineMisses() {
        let cutoff = Date().addingTimeInterval(-OnlineMissCache.cooldown)
        onlineMisses = onlineMisses.filter { $0.value >= cutoff }
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

    private enum OnlineMissCache {
        static let cooldown: TimeInterval = 6 * 60 * 60
        static let maxEntries = 1_000
    }

    private enum SuccessfulDisplayCache {
        static let cooldown: TimeInterval = 6 * 60 * 60
        static let maxEntries = 200
    }

    private func postTrackArtworkSidecarDidChange(for audioURL: URL) async {
        await MainActor.run {
            NotificationCenter.default.post(name: .trackArtworkSidecarDidChange, object: audioURL)
        }
    }

    private func valueForWaiter(
        task: Task<TrackArtworkDownloadResult?, Never>,
        key: String,
        flightID: UUID,
        waiterID: UUID
    ) async -> TrackArtworkDownloadResult? {
        let continuation = WaiterContinuation()
        let completionTask = Task {
            continuation.resume(await task.value)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { checkedContinuation in
                continuation.set(checkedContinuation)
                if Task.isCancelled {
                    Task {
                        await self.removeWaiter(
                            key: key,
                            flightID: flightID,
                            waiterID: waiterID,
                            cancelIfLast: true
                        )
                    }
                    completionTask.cancel()
                    continuation.resume(nil)
                }
            }
        } onCancel: {
            Task {
                await self.removeWaiter(
                    key: key,
                    flightID: flightID,
                    waiterID: waiterID,
                    cancelIfLast: true
                )
            }
            completionTask.cancel()
            continuation.resume(nil)
        }
    }

    private func removeWaiter(
        key: String,
        flightID: UUID,
        waiterID: UUID,
        cancelIfLast: Bool
    ) {
        guard var flight = inFlight[key], flight.id == flightID else { return }
        flight.waiters.remove(waiterID)

        if flight.waiters.isEmpty {
            if cancelIfLast {
                flight.task.cancel()
            }
            inFlight[key] = nil
        } else {
            inFlight[key] = flight
        }
    }

    private func waitForRateLimit(_ bucket: RateLimitBucket) async -> Bool {
        let delay: TimeInterval
        let scheduledRequest: Date

        let now = Date()
        switch bucket {
        case .musicBrainz:
            delay = MusicBrainz.rateLimitDelay
            let earliest = lastMusicBrainzRequest?.addingTimeInterval(delay) ?? now
            scheduledRequest = earliest > now ? earliest : now
            lastMusicBrainzRequest = scheduledRequest
        case .coverArt:
            delay = CoverArtArchive.rateLimitDelay
            let earliest = lastCoverArtRequest?.addingTimeInterval(delay) ?? now
            scheduledRequest = earliest > now ? earliest : now
            lastCoverArtRequest = scheduledRequest
        }

        let waitTime = scheduledRequest.timeIntervalSince(now)
        if waitTime > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            } catch {
                return false
            }
        }

        guard !Task.isCancelled else { return false }

        return true
    }

    private struct InFlightArtworkDownload {
        let id: UUID
        let task: Task<TrackArtworkDownloadResult?, Never>
        var waiters: Set<UUID>
    }

    private struct SuccessfulDisplayCacheEntry {
        let data: Data
        let storedAt: Date
    }

    private final class WaiterContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<TrackArtworkDownloadResult?, Never>?
        private var result: TrackArtworkDownloadResult?
        private var didResume = false

        func set(_ continuation: CheckedContinuation<TrackArtworkDownloadResult?, Never>) {
            lock.lock()
            if didResume {
                let result = result
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func resume(_ result: TrackArtworkDownloadResult?) {
            lock.lock()
            guard !didResume else {
                lock.unlock()
                return
            }

            didResume = true
            self.result = result
            let continuation = continuation
            self.continuation = nil
            lock.unlock()

            continuation?.resume(returning: result)
        }
    }

    private struct ReleaseMatch {
        let id: String
        let releaseGroupID: String?
    }
}

struct TrackArtworkDownloadResult: Sendable {
    let sidecarURL: URL?
    let displayData: Data?
    let didWriteSidecar: Bool

    init(sidecarURL: URL? = nil, displayData: Data? = nil, didWriteSidecar: Bool = false) {
        self.sidecarURL = sidecarURL
        self.displayData = displayData
        self.didWriteSidecar = didWriteSidecar
    }
}
