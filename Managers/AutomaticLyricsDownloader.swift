import Combine
import Foundation

/// Owned by the coordinator so downloads work even with every lyrics window closed.
@MainActor
final class AutomaticLyricsDownloader: ObservableObject {
    @Published private(set) var status: String?
    private let settings: LyricsDownloadSettings
    private let service: any OnlineLyricsServing
    private let writer: any DownloadedLyricsWriting
    private var subscriptions = Set<AnyCancellable>()
    private var task: Task<Void, Never>?
    private var activeKey: String?
    private var attempts: [String: Date] = [:]
    private let loadLocal: (Track) async throws -> Bool
    private let didSave: @MainActor (URL) -> Void

    init(settings: LyricsDownloadSettings? = nil,
         service: any OnlineLyricsServing = OnlineLyricsService(),
         writer: any DownloadedLyricsWriting = DownloadedLyricsFileStore.shared,
         loadLocal: @escaping (Track) async throws -> Bool,
         didSave: @escaping @MainActor (URL) -> Void = { url in
             LyricsStore.shared.invalidate(for: url)
             NotificationCenter.default.post(name: .downloadedLyricsDidChange, object: url)
         }) {
        self.settings = settings ?? .shared
        self.service = service
        self.writer = writer
        self.loadLocal = loadLocal
        self.didSave = didSave
    }

    func connect(playbackManager: PlaybackManager) {
        playbackManager.$currentTrack.combineLatest(playbackManager.$isPlaying)
            .receive(on: RunLoop.main)
            .sink { [weak self] track, playing in self?.update(track: track, isPlaying: playing) }
            .store(in: &subscriptions)
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak playbackManager] _ in
                guard let playbackManager else { return }
                self?.update(track: playbackManager.currentTrack, isPlaying: playbackManager.isPlaying)
            }
            .store(in: &subscriptions)
    }

    deinit { task?.cancel() }

    func update(track: Track?, isPlaying: Bool) {
        guard settings.automaticallyDownload, isPlaying, let track else {
            task?.cancel()
            task = nil
            activeKey = nil
            return
        }
        let query = LyricsMatchQuery(title: track.title, artist: track.artist, album: track.album, duration: track.duration)
        let provider = settings.provider, includeTranslation = settings.includeTranslation
        let key = [track.url.path, track.title, track.artist, track.album, String(track.duration), provider.rawValue, String(includeTranslation)].joined(separator: "\u{0}")
        guard key != activeKey else { return }
        task?.cancel()
        activeKey = key
        guard query.isComplete else { return }
        // Avoid hammering the provider when replaying an unmatched song. Failures can
        // be retried after five minutes, and manual search is always available.
        if let last = attempts[key], Date().timeIntervalSince(last) < 300 { return }
        let service = service, writer = writer, loadLocal = loadLocal
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
                if try await loadLocal(track) { return }
                try Task.checkCancellation()
                let candidates = try await service.search(provider: provider, title: track.title, artist: track.artist)
                try Task.checkCancellation()
                guard let candidate = query.automaticMatch(in: candidates) else {
                    self?.recordAttempt(key)
                    self?.status = String(appLocalized: "No confident lyrics match. Use Search Lyrics Online to choose a result.")
                    return
                }
                let lyrics = try await service.download(candidate, includeTranslation: includeTranslation)
                try Task.checkCancellation()
                // A manual download or new embedded lyrics may have arrived meanwhile.
                if try await loadLocal(track) { return }
                try Task.checkCancellation()
                let url = try await writer.save(lyrics, for: track.url, overwrite: false, automatic: true)
                guard let self, !Task.isCancelled, self.activeKey == key else { return }
                self.recordAttempt(key)
                self.didSave(track.url)
                self.status = String.localizedStringWithFormat(String(appLocalized: "Lyrics saved: %1$@"), url.lastPathComponent)
            } catch {
                guard let self, !Task.isCancelled, self.activeKey == key else { return }
                self.recordAttempt(key)
                if let error = error as? LyricsDownloadError, error == .existingFile || error == .existingSidecar { return }
                self.status = String(appLocalized: "Automatic lyrics download failed. You can retry with Search Lyrics Online.")
            }
        }
    }

    private func recordAttempt(_ key: String) {
        if attempts.count >= 256 { attempts = attempts.filter { Date().timeIntervalSince($0.value) < 300 } }
        if attempts.count >= 256 { attempts.removeAll() }
        attempts[key] = Date()
    }
}
