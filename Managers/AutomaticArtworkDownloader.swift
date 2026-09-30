import Combine
import Foundation

/// Runs beside the opt-in automatic lyrics lookup and after an explicit online tag save.
@MainActor
final class AutomaticArtworkDownloader {
    private let settings: LyricsDownloadSettings
    private let search: any OnlineTagSearching
    private let service: any OnlineArtworkServing
    private let writer: any DownloadedArtworkWriting
    private var subscriptions = Set<AnyCancellable>()
    private var task: Task<Void, Never>?
    private var activeKey: String?
    private var attempts: [String: Date] = [:]

    init(settings: LyricsDownloadSettings? = nil,
         search: any OnlineTagSearching = OnlineTagLookupService(),
         service: any OnlineArtworkServing = OnlineArtworkService(),
         writer: any DownloadedArtworkWriting = DownloadedArtworkFileStore.shared) {
        self.settings = settings ?? .shared
        self.search = search
        self.service = service
        self.writer = writer
    }

    func connect(playbackManager: PlaybackManager) {
        playbackManager.$currentTrack.combineLatest(playbackManager.$isPlaying)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak playbackManager] track, playing in
                guard let playbackManager else { return }
                self?.update(track: track, isPlaying: playing, playbackManager: playbackManager)
            }
            .store(in: &subscriptions)
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak playbackManager] _ in
                Task { @MainActor [weak self, weak playbackManager] in
                    guard let playbackManager else { return }
                    self?.update(track: playbackManager.currentTrack,
                                 isPlaying: playbackManager.isPlaying, playbackManager: playbackManager)
                }
            }
            .store(in: &subscriptions)
    }

    deinit { task?.cancel() }

    private func update(track: Track?, isPlaying: Bool, playbackManager: PlaybackManager) {
        guard settings.automaticallyDownload, isPlaying, let track else {
            task?.cancel()
            task = nil
            activeKey = nil
            return
        }
        let provider = settings.artworkSource
        let query = LyricsMatchQuery(title: track.title, artist: track.artist,
                                     album: track.album, duration: track.duration)
        let key = [track.url.path, track.title, track.artist, track.album,
                   String(track.duration), provider.rawValue].joined(separator: "\u{0}")
        guard key != activeKey else { return }
        task?.cancel()
        activeKey = key
        guard query.isComplete else { return }
        if let last = attempts[key], Date().timeIntervalSince(last) < 300 { return }

        let search = search
        task = Task { [weak self, weak playbackManager] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
                let request = ArtworkRequest.album(albumId: track.albumId,
                                                   representativeTrackURL: track.url,
                                                   albumTitle: track.album)
                if await ArtworkResolver.shared.artworkData(for: request) != nil { return }
                try Task.checkCancellation()
                let candidates = try await search.search(provider: provider, title: track.title, artist: track.artist)
                try Task.checkCancellation()
                guard let candidate = query.automaticMatch(in: candidates) else {
                    self?.recordAttempt(key)
                    self?.notifyFailure(for: track.url, reason: String(appLocalized: "No confident song match was found."))
                    return
                }
                let savedURL = try await self?.saveIfMissing(candidate, audioURL: track.url,
                                                              album: track.album, playbackManager: playbackManager)
                guard let self, !Task.isCancelled, self.activeKey == key else { return }
                self.recordAttempt(key)
                if let savedURL { self.notifySaved(savedURL, for: track.url) }
            } catch {
                guard let self, !Task.isCancelled, self.activeKey == key else { return }
                self.recordAttempt(key)
                if case ArtworkDownloadError.existingArtwork = error { return }
                self.notifyFailure(for: track.url, reason: self.failureReason(for: error))
            }
        }
    }

    /// The user chose this provider result and then saved its tags to the audio file.
    /// This path does not depend on playback or automatic download preferences.
    func downloadAfterTagSave(_ candidate: OnlineTagCandidate, audioURL: URL,
                              album: String, playbackManager: PlaybackManager) {
        Task { [weak self, weak playbackManager] in
            guard let self else { return }
            do {
                if let savedURL = try await self.saveIfMissing(candidate, audioURL: audioURL,
                                                                album: album, playbackManager: playbackManager) {
                    self.notifySaved(savedURL, for: audioURL)
                }
            } catch {
                if case ArtworkDownloadError.existingArtwork = error { return }
                self.notifyFailure(for: audioURL, reason: self.failureReason(for: error))
            }
        }
    }

    private func saveIfMissing(_ candidate: OnlineTagCandidate, audioURL: URL,
                               album: String, playbackManager: PlaybackManager?) async throws -> URL? {
        let request = ArtworkRequest.album(albumId: nil, representativeTrackURL: audioURL, albumTitle: album)
        if await ArtworkResolver.shared.artworkData(for: request) != nil { return nil }
        try Task.checkCancellation()
        let image = try await service.download(for: candidate)
        try Task.checkCancellation()
        if await ArtworkResolver.shared.artworkData(for: request) != nil { return nil }
        try Task.checkCancellation()
        let savedURL = try await writer.save(image, for: audioURL, album: album, matchedAlbum: candidate.album)
        ArtworkResolver.shared.invalidateMemoryCache()
        await TrackThumbnailCache.shared.removeAll()
        playbackManager?.refreshCurrentTrackArtworkAfterDownload(for: audioURL)
        NotificationCenter.default.post(name: .downloadedArtworkDidChange, object: audioURL)
        return savedURL
    }

    private func notifySaved(_ savedURL: URL, for audioURL: URL) {
        NotificationManager.shared.addMessage(.info, String.localizedStringWithFormat(
            String(appLocalized: "Artwork downloaded for %1$@: %2$@"),
            audioURL.lastPathComponent, savedURL.lastPathComponent
        ))
    }

    private func notifyFailure(for audioURL: URL, reason: String) {
        NotificationManager.shared.addMessage(.error, String.localizedStringWithFormat(
            String(appLocalized: "Could not download artwork for %1$@: %2$@"),
            audioURL.lastPathComponent, reason
        ))
    }

    private func failureReason(for error: Error) -> String {
        switch error {
        case ArtworkDownloadError.invalidResponse:
            return String(appLocalized: "The artwork source returned no usable image.")
        case ArtworkDownloadError.unavailable:
            return String(appLocalized: "The artwork source is unavailable.")
        case ArtworkDownloadError.unsafeDestination:
            return String(appLocalized: "The artwork could not be saved beside the song.")
        default:
            if error is URLError { return String(appLocalized: "Check your connection and try again.") }
            return String(appLocalized: "Check the song folder's write access and try again.")
        }
    }

    private func recordAttempt(_ key: String) {
        if attempts.count >= 256 { attempts = attempts.filter { Date().timeIntervalSince($0.value) < 300 } }
        if attempts.count >= 256 { attempts.removeAll() }
        attempts[key] = Date()
    }
}

extension Notification.Name {
    static let downloadedArtworkDidChange = Notification.Name("DownloadedArtworkDidChange")
    static let searchArtworkOnline = Notification.Name("SearchArtworkOnline")
}
