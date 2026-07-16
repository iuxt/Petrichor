import Combine
import Foundation

@MainActor
final class DesktopLyricsLineProvider: ObservableObject {
    enum DisplayState: Equatable {
        case idle
        case loading
        case lyrics(DesktopLyricsDisplayLines)
        case empty
        case failed
    }

    @Published private(set) var state: DisplayState = .idle

    private weak var playbackManager: PlaybackManager?
    private weak var libraryManager: LibraryManager?
    private var loadTask: Task<Void, Never>?
    private var loadedTrackId: UUID?
    private var lyricLines: [LyricLine] = []
    private var hasTimedLyrics = false
    private var isKaraokeLyrics = false
    private var isSampling = false
    private let boundaryScheduler = KaraokeLineBoundaryScheduler()

    init(playbackManager: PlaybackManager, libraryManager: LibraryManager) {
        self.playbackManager = playbackManager
        self.libraryManager = libraryManager
    }

    deinit {
        loadTask?.cancel()
        if isSampling {
            // Release the fine-sampling ref the provider held. `setFineProgressSampling`
            // is `@MainActor`; hop asynchronously rather than asserting main, so a
            // deinit off the main thread (rare but possible) can't trap. A slightly
            // delayed decrement is harmless since the consumer is already gone.
            Task { @MainActor [weak playbackManager] in
                playbackManager?.setFineProgressSampling(false)
            }
        }
    }

    func appear() {
        setFineProgressSampling(true)
        loadLyricsForCurrentTrack(forceReload: false)
    }

    func disappear() {
        loadTask?.cancel()
        boundaryScheduler.cancel()
        setFineProgressSampling(false)
    }

    func currentTrackChanged() {
        boundaryScheduler.cancel()
        loadedTrackId = nil
        lyricLines = []
        hasTimedLyrics = false
        isKaraokeLyrics = false
        loadLyricsForCurrentTrack(forceReload: false)
    }

    func playbackTimeChanged(_ time: TimeInterval) {
        guard hasTimedLyrics else { return }
        updateTimedDisplay(at: time)
        resetKaraokeBoundarySchedule(at: time)
    }

    func playbackStateChanged(isPlaying: Bool) {
        guard isKaraokeLyrics else {
            boundaryScheduler.cancel()
            return
        }
        let transitionTime = boundaryScheduler.transition(
            isPlaying: isPlaying,
            lines: lyricLines,
            isKaraoke: true
        ) { [weak self] boundaryTime in
            self?.updateTimedDisplay(at: boundaryTime)
        }
        updateTimedDisplay(at: transitionTime)
    }

    private func loadLyricsForCurrentTrack(forceReload: Bool) {
        guard let playbackManager, let libraryManager else {
            state = .failed
            return
        }

        guard let track = playbackManager.currentTrack else {
            loadTask?.cancel()
            loadedTrackId = nil
            lyricLines = []
            hasTimedLyrics = false
            isKaraokeLyrics = false
            boundaryScheduler.cancel()
            state = .idle
            return
        }

        if !forceReload, loadedTrackId == track.id, !lyricLines.isEmpty {
            publishLoadedLines(for: playbackManager.playbackProgressState.currentTime)
            return
        }

        loadedTrackId = track.id

        if !forceReload, let cached = LyricsStore.shared.cachedLyrics(for: track.id) {
            lyricLines = cached.lines
            hasTimedLyrics = cached.hasTimed
            isKaraokeLyrics = cached.isKaraoke
            publishLoadedLines(for: playbackManager.playbackProgressState.currentTime)
            return
        }

        loadTask?.cancel()
        state = .loading
        lyricLines = []
        hasTimedLyrics = false
        isKaraokeLyrics = false
        boundaryScheduler.cancel()

        loadTask = Task { [weak self, weak libraryManager, weak playbackManager] in
            guard let self, let libraryManager, let playbackManager else { return }
            do {
                let result = try await LyricsStore.shared.lyrics(
                    for: track,
                    using: libraryManager.databaseManager.dbQueue
                )

                guard !Task.isCancelled else { return }
                guard playbackManager.currentTrack?.id == track.id else { return }

                self.lyricLines = result.lines
                self.hasTimedLyrics = result.hasTimed
                self.isKaraokeLyrics = result.isKaraoke
                self.publishLoadedLines(for: playbackManager.playbackProgressState.currentTime)
            } catch {
                guard !Task.isCancelled else { return }
                guard playbackManager.currentTrack?.id == track.id else { return }
                self.lyricLines = []
                self.hasTimedLyrics = false
                self.isKaraokeLyrics = false
                self.boundaryScheduler.cancel()
                self.state = .failed
            }
        }
    }

    private func publishLoadedLines(for time: TimeInterval) {
        if hasTimedLyrics {
            updateTimedDisplay(at: time)
        } else if let lines = DesktopLyricsLineSelection.plainDisplayLines(lines: lyricLines) {
            state = .lyrics(lines)
        } else {
            state = .empty
        }
        resetKaraokeBoundarySchedule(at: time)
    }

    private func updateTimedDisplay(at time: TimeInterval) {
        if let lines = DesktopLyricsLineSelection.syncedDisplayLines(lines: lyricLines, at: time) {
            state = .lyrics(lines)
        } else {
            state = .empty
        }
    }

    private func resetKaraokeBoundarySchedule(at sampleTime: TimeInterval) {
        guard isKaraokeLyrics, let playbackManager else {
            boundaryScheduler.cancel()
            return
        }
        boundaryScheduler.reset(
            sampleTime: sampleTime,
            isPlaying: playbackManager.isPlaying,
            lines: lyricLines,
            isKaraoke: true
        ) { [weak self] boundaryTime in
            self?.updateTimedDisplay(at: boundaryTime)
        }
    }

    private func setFineProgressSampling(_ enabled: Bool) {
        guard enabled != isSampling else { return }
        playbackManager?.setFineProgressSampling(enabled)
        isSampling = enabled
    }
}
