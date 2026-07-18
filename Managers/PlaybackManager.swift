//
// PlaybackManager class
//
// This class handles track playback coordination with PlaybackEngine,
// including database updates, state persistence, and integration with
// PlaylistManager and NowPlayingManager.
//

import AVFoundation
import Combine
import Foundation

/// App-facing playback coordinator. `@MainActor` because it is an `ObservableObject`
/// consumed by SwiftUI, drives a main-queue progress timer, and almost every method
/// already assumed the main thread (or re-dispatched to it). Isolating it removes the
/// ad-hoc `Thread.isMainThread` / `DispatchQueue.main.async` hops and closes latent
/// races on `pendingNext`, `currentEntryId`, `playbackRequestGeneration`, etc.
@MainActor
final class PlaybackManager: NSObject, ObservableObject {
    let playbackProgressState = PlaybackProgressState()

    // MARK: - Published Properties

    @Published var currentTrack: Track? {
        didSet {
            refreshCurrentTrackArtworkIfNeeded()
        }
    }
    @Published var isPlaying: Bool = false {
        didSet {
            NotificationCenter.default.post(
                name: NSNotification.Name("PlaybackStateChanged"), object: nil)
        }
    }
    var currentTime: Double {
        get { playbackProgressState.currentTime }
        set { playbackProgressState.currentTime = newValue }
    }
    // The real-time lyrics display need this to get the current time.
    // We can not use the currentTime because it is a computed property
    @Published var volume: Float = 0.7 {
        didSet {
            audioPlayer.volume = volume
        }
    }
    @Published var restoredUITrack: Track?

    // MARK: - Computed Properties
    
    /// Alias for currentTime for backwards compatibility
    var actualCurrentTime: Double {
        currentTime
    }

    // MARK: - Private Properties
    
    private let audioPlayer: PlaybackEngine
    private var currentFullTrack: FullTrack?
    private var progressUpdateTimer: DispatchSourceTimer?
    private var lastObservedEngineProgress: Double?
    private var progressResolver = PlaybackProgressResolver()
    private var lastProgressSampleUptime: TimeInterval?
    private var fineProgressSampling = false
    // Reference count of views requesting fine sampling (e.g. main-window and
    // mini-player lyrics can be visible at once); sampling stays fine while > 0.
    private var fineSamplingConsumers = 0
    private var lastNowPlayingUpdate: TimeInterval = 0
    private var stateSaveTimer: Timer?
    private var restoredPosition: Double = 0
    private var artworkLoadTask: Task<Void, Never>?
    private var currentArtworkIdentity: String?
    private var playbackRequestGeneration: UInt64 = 0
    private var wantsPlaybackActive = false
    private let playPauseToggleThrottleInterval: TimeInterval = 0.25
    private var lastPlayPauseToggleTime: TimeInterval = 0

    /// Position and requested play/pause intent to restore once a track settles in
    /// `.paused` (see `audioPlayerStateChanged`). Deferring to that transition
    /// instead of a fixed delay ensures the asset is open before the seek lands,
    /// avoiding the stuck-paused race on the async Crescendo backend. Carries the
    /// entry identity so a normal user-pause never trips the restore.
    private struct PendingPlaybackRestore {
        let entryId: AudioEntryId
        let position: Double
        let shouldResume: Bool
    }

    private struct MetadataRestoreOperation {
        let entryId: AudioEntryId
        let generation: UInt64
    }

    private var pendingPlaybackRestore: PendingPlaybackRestore?
    private var metadataRestoreCompletion:
        ((Result<Void, MetadataPlaybackRestoreError>) -> Void)?
    private var metadataRestoreOperation: MetadataRestoreOperation?
    private var metadataRestoreTimeoutTask: Task<Void, Never>?
    private var metadataRestoreGeneration: UInt64 = 0

    // MARK: - Gapless lookahead (Crescendo path)

    /// Identity of the track currently loaded in the engine.
    private var currentEntryId: AudioEntryId?
    /// Maps engine entry id -> the track it plays, so a finish can credit the track
    /// that actually ended even after a gapless advance promoted the next one.
    private var trackForEntry: [String: Track] = [:]
    /// The pre-decoded next track (the "+1") primed into a gapless engine, or nil.
    private var pendingNext: PendingNext?
    /// Set when the primed next track was rejected by the engine. On EOF, fall back
    /// to app-driven completion instead of waiting for a gapless start callback.
    private var pendingNextWasSkipped = false
    private var queueObservers: Set<AnyCancellable> = []

    private struct PendingNext {
        let entryId: AudioEntryId
        let track: Track
        let index: Int
        var fullTrack: FullTrack?
    }

    enum MetadataPlaybackRestoreError: LocalizedError {
        case missingTrackData
        case seekFailed
        case timedOut
        case engine(String)

        var errorDescription: String? {
            switch self {
            case .missingTrackData:
                return String(appLocalized: "Playback could not be restored because track data is missing.")
            case .seekFailed:
                return String(appLocalized: "Playback resumed, but its saved position could not be restored.")
            case .timedOut:
                return String(appLocalized: "Playback restoration timed out.")
            case .engine(let detail):
                return String(
                    format: String(appLocalized: "Playback could not be restored: %1$@"),
                    detail
                )
            }
        }
    }

    struct MetadataEditPlaybackSnapshot {
        let track: Track
        let fullTrack: FullTrack?
        let position: Double
        let wasPlaying: Bool
        let wasEngineActive: Bool
        let queueIndex: Int
        let restoredPosition: Double
    }

    struct TrashMoveSnapshot {
        let track: Track
        let fullTrack: FullTrack?
        let position: Double
        let wasPlaying: Bool
        let restoredPosition: Double
    }
    
    // MARK: - Dependencies
    
    private let libraryManager: LibraryManager
    private let playlistManager: PlaylistManager
    // The single Petrichor-side Now Playing owner (info tile + remote commands)
    // for both engines. For 1.6, Crescendo publishes neither (NowPlayingManager
    // owns the tile so the restore-resume anchor stays correct); Crescendo takes
    // over Now Playing in 1.7 when SFB is removed.
    private let nowPlayingManager: NowPlayingManager
    
    // MARK: - Initialization
    
    init(libraryManager: LibraryManager, playlistManager: PlaylistManager) {
        self.libraryManager = libraryManager
        self.playlistManager = playlistManager
        self.nowPlayingManager = NowPlayingManager()
        self.audioPlayer = PlaybackEngine()
        
        super.init()
        
        self.audioPlayer.delegate = self
        self.audioPlayer.volume = volume
        
        startProgressUpdateTimer()
        restoreAudioEffectsSettings()
        observeQueueForGaplessLookahead()
    }

    deinit {
        // `PlaybackManager` is an app-lifetime singleton owned by `AppCoordinator`,
        // so this runs only at process termination. `deinit` cannot call
        // `@MainActor` methods, and mutating `@Published` / posting notifications
        // from a half-deallocated `ObservableObject` is fragile, so we don't drive
        // a full `stop()` here. The engine and timers are torn down by the OS on
        // process exit; if lifetime ever changes, add a `prepareForDeinit()` that
        // the owner calls on the main actor before release.
    }
    
    // MARK: - Player State Management
    
    func restoreUIState(_ uiState: PlaybackUIState) {
        var tempTrack = Track(url: URL(fileURLWithPath: "/restored"))
        tempTrack.title = uiState.trackTitle
        tempTrack.artist = uiState.trackArtist
        tempTrack.album = uiState.trackAlbum
        tempTrack.duration = uiState.trackDuration
        
        restoredUITrack = tempTrack
        currentTrack = tempTrack
        restoredPosition = uiState.playbackPosition
        currentTime = uiState.playbackPosition
        resetProgressResolution(engineProgress: uiState.playbackPosition)
        volume = uiState.volume
        
        nowPlayingManager.updateNowPlayingInfo(
            track: tempTrack,
            currentTime: uiState.playbackPosition,
            isPlaying: false
        )
    }
    
    func prepareTrackForRestoration(_ track: Track, at position: Double) {
        restoredUITrack = nil
        let requestGeneration = beginPlaybackRequest()
        
        Task { [weak self, track, requestGeneration] in
            guard let self else { return }
            do {
                guard let fullTrack = try await track.fullTrack(using: self.libraryManager.databaseManager.dbQueue) else {
                    await MainActor.run {
                        guard self.isCurrentPlaybackRequest(requestGeneration) else { return }
                        Logger.error("Failed to fetch track data for restoration")
                    }
                    return
                }
                
                await MainActor.run {
                    guard self.isCurrentPlaybackRequest(requestGeneration) else { return }
                    self.currentTrack = track
                    self.currentFullTrack = fullTrack
                    self.restoredPosition = position
                    self.currentTime = position
                    self.resetProgressResolution(engineProgress: position)
                    self.wantsPlaybackActive = false
                    self.isPlaying = false
                    
                    self.nowPlayingManager.updateNowPlayingInfo(
                        track: track,
                        currentTime: position,
                        isPlaying: false
                    )
                    
                    Logger.info("Prepared track for restoration at position: \(position)")
                }
            } catch {
                await MainActor.run {
                    guard self.isCurrentPlaybackRequest(requestGeneration) else { return }
                    Logger.error("Failed to prepare track for restoration: \(error)")
                }
            }
        }
    }
    
    // MARK: - Playback Controls
    
    func playTrack(_ track: Track) {
        cancelMetadataRestoreForPlaybackChange()
        let requestGeneration = beginPlaybackRequest()
        restoredUITrack = nil
        restoredPosition = 0
        
        guard FileManager.default.fileExists(atPath: track.url.path) else {
            Logger.warning("Track file does not exist: \(track.url.path)")
            Task { @MainActor in
                NotificationManager.shared.addMessage(.error, String(appLocalized: "Cannot play '\(track.title)': File not found"))
            }
            
            // Auto-skip to next track if in queue
            if playlistManager.currentQueue.count > 1 {
                Logger.info("File not found, skipping to next track in queue")
                playlistManager.playNextTrack()
            }
            return
        }
                
        Task { [weak self, track, requestGeneration] in
            guard let self else { return }
            do {
                guard let fullTrack = try await track.fullTrack(using: self.libraryManager.databaseManager.dbQueue) else {
                    await MainActor.run {
                        guard self.isCurrentPlaybackRequest(requestGeneration) else { return }
                        Logger.error("Failed to fetch full track data for: \(track.title)")
                        NotificationManager.shared.addMessage(.error, String(appLocalized: "Cannot play track - missing data"))
                    }
                    return
                }
                
                await MainActor.run {
                    guard self.isCurrentPlaybackRequest(requestGeneration) else { return }
                    self.startPlayback(of: fullTrack, lightweightTrack: track)
                }
            } catch {
                await MainActor.run {
                    guard self.isCurrentPlaybackRequest(requestGeneration) else { return }
                    Logger.error("Failed to fetch track data: \(error)")
                    NotificationManager.shared.addMessage(.error, String(appLocalized: "Failed to load track for playback"))
                }
            }
        }
    }
    
    func togglePlayPause() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.togglePlayPause()
            }
            return
        }

        guard shouldAcceptPlayPauseToggle() else {
            return
        }

        cancelMetadataRestoreForPlaybackChange()
        
        if isPlaying {
            wantsPlaybackActive = false
            audioPlayer.pause()
            setPlaybackActive(false)
        } else {
            wantsPlaybackActive = true
            if let fullTrack = currentFullTrack, let track = currentTrack, audioPlayer.state != .paused {
                startPlayback(of: fullTrack, lightweightTrack: track)
            } else {
                wantsPlaybackActive = true
                audioPlayer.resume()
                syncPlaybackStateWithEngine()
            }
        }
    }
    
    func stop() {
        cancelMetadataRestoreForPlaybackChange()
        invalidatePlaybackRequests()
        wantsPlaybackActive = false
        audioPlayer.stop()
        currentTrack = nil
        currentFullTrack = nil
        currentEntryId = nil
        pendingNext = nil
        pendingNextWasSkipped = false
        currentTime = 0
        resetProgressResolution(engineProgress: 0)
        isPlaying = false
        restoredPosition = 0
        stopStateSaveTimer()
        Logger.info("Playback stopped")
    }

    func stopGracefully() {
        cancelMetadataRestoreForPlaybackChange()
        invalidatePlaybackRequests()
        wantsPlaybackActive = false
        audioPlayer.stop()
        currentTrack = nil
        currentFullTrack = nil
        currentEntryId = nil
        pendingNext = nil
        pendingNextWasSkipped = false
        currentTime = 0
        resetProgressResolution(engineProgress: 0)
        isPlaying = false
        stopStateSaveTimer()
        Logger.info("Playback stopped gracefully")
    }

    @MainActor
    func prepareCurrentTrackForTrashMove(_ track: Track) -> TrashMoveSnapshot? {
        guard isCurrentTrack(track), let currentTrack else { return nil }
        cancelMetadataRestoreForPlaybackChange()

        let snapshot = TrashMoveSnapshot(
            track: currentTrack,
            fullTrack: currentFullTrack,
            position: currentTime,
            wasPlaying: isPlaying,
            restoredPosition: restoredPosition
        )

        invalidatePlaybackRequests()
        wantsPlaybackActive = false
        pendingPlaybackRestore = nil
        audioPlayer.clearNextTrack()
        currentEntryId = nil
        trackForEntry.removeAll()
        pendingNext = nil
        pendingNextWasSkipped = false
        audioPlayer.stop()
        currentTime = snapshot.position
        resetProgressResolution(engineProgress: snapshot.position)
        isPlaying = false
        restoredPosition = snapshot.restoredPosition
        stopStateSaveTimer()
        updateNowPlayingInfo()

        return snapshot
    }

    @MainActor
    func prepareCurrentTrackForMetadataEdit(_ track: Track) -> MetadataEditPlaybackSnapshot? {
        guard isCurrentTrack(track), let currentTrack else { return nil }
        cancelMetadataRestoreForPlaybackChange()

        let wasPlaying = wantsPlaybackActive || isPlaying
        let snapshot = MetadataEditPlaybackSnapshot(
            track: currentTrack,
            fullTrack: currentFullTrack,
            position: currentTime,
            wasPlaying: wasPlaying,
            wasEngineActive: wasPlaying || audioPlayer.state == .paused,
            queueIndex: playlistManager.currentQueueIndex,
            restoredPosition: restoredPosition
        )

        invalidatePlaybackRequests()
        wantsPlaybackActive = false
        pendingPlaybackRestore = nil
        audioPlayer.clearNextTrack()
        currentEntryId = nil
        trackForEntry.removeAll()
        pendingNext = nil
        pendingNextWasSkipped = false
        audioPlayer.stop()
        currentTime = snapshot.position
        resetProgressResolution(engineProgress: snapshot.position)
        isPlaying = false
        restoredPosition = snapshot.restoredPosition
        stopStateSaveTimer()
        updateNowPlayingInfo()

        return snapshot
    }

    func applyMetadataEditResult(_ track: Track) {
        trackForEntry = trackForEntry.mapValues { value in
            value.trackId == track.trackId ? track : value
        }

        if currentTrack?.trackId == track.trackId {
            currentTrack = track
        }

        if pendingNext?.track.trackId == track.trackId {
            pendingNext = nil
            pendingNextWasSkipped = false
            primeNextTrack()
        }
    }

    @MainActor
    func restoreCurrentTrackAfterMetadataEdit(
        _ snapshot: MetadataEditPlaybackSnapshot?,
        track updatedTrack: Track?,
        fullTrack updatedFullTrack: FullTrack?,
        completion: @escaping (Result<Void, MetadataPlaybackRestoreError>) -> Void
    ) {
        guard let snapshot else {
            completion(.success(()))
            return
        }
        cancelMetadataRestoreForPlaybackChange()

        let track = updatedTrack ?? snapshot.track
        let fullTrack = updatedFullTrack ?? snapshot.fullTrack

        pendingPlaybackRestore = nil
        pendingNext = nil
        pendingNextWasSkipped = false
        trackForEntry.removeAll()
        currentEntryId = nil
        wantsPlaybackActive = false
        playlistManager.restoreQueueIndexAfterMetadataEdit(snapshot.queueIndex)
        currentArtworkIdentity = nil
        currentTrack = track
        currentFullTrack = fullTrack
        let duration = HelperUtils.sanitizedDuration(fullTrack?.duration ?? 0)
        let restoredTime = duration > 0
            ? min(max(snapshot.position, 0), duration)
            : max(snapshot.position, 0)
        currentTime = restoredTime
        resetProgressResolution(engineProgress: restoredTime)
        restoredPosition = restoredTime
        isPlaying = false
        stopStateSaveTimer()

        guard snapshot.wasEngineActive else {
            updateNowPlayingInfo()
            completion(.success(()))
            return
        }

        guard let fullTrack else {
            completion(.failure(.missingTrackData))
            return
        }

        metadataRestoreGeneration &+= 1
        let restoreGeneration = metadataRestoreGeneration
        let restoreEntryId = AudioEntryId(id: UUID().uuidString)
        metadataRestoreOperation = MetadataRestoreOperation(
            entryId: restoreEntryId,
            generation: restoreGeneration
        )
        metadataRestoreCompletion = completion
        startMetadataRestoreTimeout(for: restoreGeneration)
        startPlayback(
            of: fullTrack,
            lightweightTrack: track,
            resumeAfterRestore: snapshot.wasPlaying,
            entryId: restoreEntryId
        )
    }

    @MainActor
    func restoreCurrentTrackAfterFailedTrashMove(_ snapshot: TrashMoveSnapshot?) {
        guard let snapshot else { return }
        cancelMetadataRestoreForPlaybackChange()

        pendingPlaybackRestore = nil
        pendingNext = nil
        pendingNextWasSkipped = false
        trackForEntry.removeAll()
        currentEntryId = nil
        wantsPlaybackActive = false
        currentTrack = snapshot.track
        currentFullTrack = snapshot.fullTrack
        currentTime = snapshot.position
        resetProgressResolution(engineProgress: snapshot.position)
        restoredPosition = snapshot.position
        isPlaying = false
        stopStateSaveTimer()

        if snapshot.wasPlaying, let fullTrack = snapshot.fullTrack {
            startPlayback(of: fullTrack, lightweightTrack: snapshot.track)
        } else {
            updateNowPlayingInfo()
        }
    }

    @MainActor
    func handleTrackMovedToTrash(_ track: Track) {
        guard isCurrentTrack(track) else { return }

        invalidatePlaybackRequests()
        wantsPlaybackActive = false
        pendingPlaybackRestore = nil
        audioPlayer.clearNextTrack()
        audioPlayer.stop()

        currentTrack = nil
        currentFullTrack = nil
        currentEntryId = nil
        trackForEntry.removeAll()
        pendingNext = nil
        pendingNextWasSkipped = false
        currentTime = 0
        resetProgressResolution(engineProgress: 0)
        isPlaying = false
        restoredPosition = 0
        stopStateSaveTimer()

        let didStartNextTrack = playlistManager.playNextAfterRemovingCurrentTrack(track)
        if didStartNextTrack {
            Logger.info("Moved trashed current track out of playback and advanced to next track")
        } else {
            NotificationCenter.default.post(
                name: NSNotification.Name("SavePlaybackState"),
                object: nil
            )
            Logger.info("Moved trashed current track out of playback; no next track available")
        }
    }
    
    func seekTo(time: Double) {
        // Clamp seek position to the engine's actual duration to prevent seek
        // errors when the DB-stored duration differs from the actual track
        // duration, this happens in edge-cases for MP3, although it is fixed
        // in MetadataEngine so hard refresh on library should resolve this.
        let engineDuration = audioPlayer.duration
        let clampedTime = engineDuration > 0 ? min(time, engineDuration) : time
        audioPlayer.seek(to: clampedTime)
        currentTime = clampedTime
        resetProgressResolution(engineProgress: clampedTime)
        restoredPosition = clampedTime
        
        NotificationCenter.default.post(
            name: NSNotification.Name("PlayerDidSeek"),
            object: nil,
            userInfo: ["time": clampedTime]
        )

        if let track = currentTrack {
            nowPlayingManager.updateNowPlayingInfo(
                track: track, currentTime: clampedTime, isPlaying: isPlaying)
        }
    }
    
    func setVolume(_ newVolume: Float) {
        volume = max(0, min(1, newVolume))
    }
    
    func updateNowPlayingInfo() {
        guard let track = currentTrack else { return }
        nowPlayingManager.updateNowPlayingInfo(
            track: track,
            currentTime: currentTime,
            isPlaying: isPlaying
        )
    }

    private func isCurrentTrack(_ track: Track) -> Bool {
        guard let currentTrack else { return false }
        if let currentTrackId = currentTrack.trackId, let trackId = track.trackId {
            return currentTrackId == trackId
        }
        return currentTrack.url == track.url
    }

    private func beginPlaybackRequest() -> UInt64 {
        playbackRequestGeneration &+= 1
        return playbackRequestGeneration
    }

    private func invalidatePlaybackRequests() {
        playbackRequestGeneration &+= 1
    }

    private func isCurrentPlaybackRequest(_ generation: UInt64) -> Bool {
        playbackRequestGeneration == generation
    }

    private func artworkIdentity(for track: Track) -> String {
        if let trackId = track.trackId {
            return "id:\(trackId)"
        }
        return "path:\(track.url.standardizedFileURL.path)"
    }

    private func refreshCurrentTrackArtworkIfNeeded() {
        guard let track = currentTrack else {
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            currentArtworkIdentity = nil
            return
        }

        let identity = artworkIdentity(for: track)
        guard identity != currentArtworkIdentity else { return }
        currentArtworkIdentity = identity

        artworkLoadTask?.cancel()
        artworkLoadTask = Task { [weak self, track, identity] in
            let request = ArtworkRequest.album(albumId: track.albumId, representativeTrackURL: track.url, albumTitle: track.album)
            let data = await ArtworkResolver.shared.artworkData(for: request)

            await MainActor.run { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      let current = self.currentTrack,
                      self.artworkIdentity(for: current) == identity else {
                    return
                }

                self.currentTrack?.albumArtworkData = data
                self.restoredUITrack?.albumArtworkData = data
                self.updateNowPlayingInfo()
            }
        }
    }

    private func shouldAcceptPlayPauseToggle() -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastPlayPauseToggleTime >= playPauseToggleThrottleInterval else {
            Logger.info("Ignoring rapid play/pause toggle while playback state is settling")
            return false
        }

        lastPlayPauseToggleTime = now
        return true
    }

    private func setPlaybackActive(_ playing: Bool) {
        let oldIsPlaying = isPlaying
        isPlaying = playing

        if playing {
            startStateSaveTimer()
        } else {
            stopStateSaveTimer()
        }

        if oldIsPlaying != isPlaying {
            updateNowPlayingInfo()
        }
    }

    private func syncPlaybackStateWithEngine() {
        switch audioPlayer.state {
        case .playing:
            setPlaybackActive(wantsPlaybackActive)
        case .paused, .stopped, .ready:
            setPlaybackActive(false)
        }
    }

    /// Rebuilds the playback engine for the currently selected backend (used when
    /// the user switches engines in Settings). Playback is halted, but the loaded
    /// track, queue, and position are kept so the progress bar stays put and the
    /// user can resume from the same spot on the new engine by pressing play.
    func reloadPlaybackEngine() {
        cancelMetadataRestoreForPlaybackChange()
        invalidatePlaybackRequests()
        let resumePosition = currentTime

        audioPlayer.reload()
        wantsPlaybackActive = false
        isPlaying = false
        // The freshly built backend has nothing primed; the next play re-primes.
        pendingNext = nil
        pendingNextWasSkipped = false
        currentEntryId = nil
        stopStateSaveTimer()

        // The new backend starts clean, so re-apply volume and audio effects.
        audioPlayer.volume = volume
        restoreAudioEffectsSettings()

        // Keep the current track loaded and the bar where it was; startPlayback
        // reads restoredPosition to continue from here on the next play.
        if currentTrack != nil {
            restoredPosition = resumePosition
            currentTime = resumePosition
            updateNowPlayingInfo()
        }
        resetProgressResolution(engineProgress: resumePosition)

        Logger.info("Playback engine reloaded for backend: \(MediaBackend.current)")
    }

    /// Wires the system remote command center (lock screen / Control Center) to
    /// this manager. PlaybackManager owns the single Petrichor-side Now Playing
    /// path for both engines in 1.6.
    func connectRemoteCommandCenter() {
        nowPlayingManager.connectRemoteCommandCenter(
            audioPlayer: self,
            playlistManager: playlistManager
        )
    }
    
    // MARK: - Audio Effects

    /// Enable or disable stereo widening effect
    /// - Parameter enabled: true to enable, false to disable
    func setStereoWidening(enabled: Bool) {
        audioPlayer.setStereoWidening(enabled: enabled)
        UserDefaults.standard.set(enabled, forKey: "stereoWideningEnabled")
        Logger.info("Stereo widening \(enabled ? "enabled" : "disabled") via PlaybackManager")
    }

    /// Check if stereo widening is currently enabled
    /// - Returns: true if enabled, false otherwise
    func isStereoWideningEnabled() -> Bool {
        audioPlayer.isStereoWideningEnabled()
    }

    /// Enable or disable the equalizer
    /// - Parameter enabled: true to enable, false to disable
    func setEQEnabled(_ enabled: Bool) {
        audioPlayer.setEQEnabled(enabled)
        UserDefaults.standard.set(enabled, forKey: "eqEnabled")
        Logger.info("EQ \(enabled ? "enabled" : "disabled") via PlaybackManager")
    }

    /// Check if EQ is currently enabled
    /// - Returns: true if enabled, false otherwise
    func isEQEnabled() -> Bool {
        audioPlayer.isEQEnabled()
    }

    /// Apply an EQ preset
    /// - Parameter preset: The EqualizerPreset to apply
    func applyEQPreset(_ preset: EqualizerPreset) {
        audioPlayer.applyEQPreset(preset)
        if preset != .flat && !audioPlayer.isEQEnabled() {
            setEQEnabled(true)
        }
        UserDefaults.standard.set(preset.rawValue, forKey: "eqPreset")
        Logger.info("Applied EQ preset: \(preset.displayName) via PlaybackManager")
    }

    /// Apply custom EQ gains
    /// - Parameter gains: Array of 10 Float values in dB
    func applyEQCustom(gains: [Float]) {
        guard gains.count == 10 else {
            Logger.warning("Invalid EQ gains array size: \(gains.count), expected 10")
            return
        }
        
        audioPlayer.applyEQCustom(gains: gains)
        if !audioPlayer.isEQEnabled() {
            setEQEnabled(true)
        }
        UserDefaults.standard.set(gains, forKey: "customEQGains")
        UserDefaults.standard.set("custom", forKey: "eqPreset")
        Logger.info("Applied custom EQ gains via PlaybackManager")
    }
    
    /// Set the preamp gain
    /// - Parameter gain: Gain value in dB, range -12 to +12
    func setPreamp(_ gain: Float) {
        audioPlayer.setPreamp(gain)
        UserDefaults.standard.set(gain, forKey: "preampGain")
        Logger.info("Preamp set to \(gain) dB via PlaybackManager")
    }

    /// Get the current preamp gain
    /// - Returns: Current preamp gain in dB
    func getPreamp() -> Float {
        audioPlayer.getPreamp()
    }
    
    // MARK: - Private Methods
    
    private func startPlayback(
        of fullTrack: FullTrack,
        lightweightTrack: Track,
        resumeAfterRestore: Bool = true,
        entryId restoredEntryId: AudioEntryId? = nil
    ) {
        wantsPlaybackActive = resumeAfterRestore
        currentTrack = lightweightTrack
        currentFullTrack = fullTrack

        // Fresh identity for this play; play(url:) replaces the engine's queue, so
        // any previously primed gapless next is gone.
        let entryId = restoredEntryId ?? AudioEntryId(id: UUID().uuidString)
        currentEntryId = entryId
        // Fresh play replaces the engine queue, so prior entries are gone.
        trackForEntry = [entryId.id: lightweightTrack]
        pendingNext = nil
        pendingNextWasSkipped = false

        let seekToPosition = restoredPosition
        restoredPosition = 0
        resetProgressResolution(engineProgress: seekToPosition > 0 ? seekToPosition : 0)
        pendingPlaybackRestore = nil

        if seekToPosition > 0 || !resumeAfterRestore {
            // Load paused and defer the seek plus requested play/pause state to the
            // `.paused` transition.
            // this produces (see audioPlayerStateChanged): that signal fires only
            // once the engine has the asset open, so the seek can't race the
            // engine's async loading. Set the marker before play() because the
            // `.paused` callback can arrive synchronously on some backends.
            pendingPlaybackRestore = PendingPlaybackRestore(
                entryId: entryId,
                position: seekToPosition,
                shouldResume: resumeAfterRestore
            )
            currentTime = seekToPosition
            audioPlayer.play(url: fullTrack.url, entryId: entryId, startPaused: true)
        } else {
            currentTime = 0
            audioPlayer.play(url: fullTrack.url, entryId: entryId, startPaused: false)
            Logger.info("Started playback: \(lightweightTrack.title)")
        }

        if resumeAfterRestore {
            startStateSaveTimer()
        } else {
            stopStateSaveTimer()
        }
        updateNowPlayingInfo()
        // The gapless next is primed from `audioPlayerDidStartPlaying`, once the
        // engine confirms this track is actually playing - priming here (before
        // the engine's async play starts) is too early: the successor can't be
        // pre-decoded against a not-yet-established current.
    }

    private func startMetadataRestoreTimeout(for generation: UInt64) {
        metadataRestoreTimeoutTask?.cancel()
        metadataRestoreTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.handleMetadataRestoreTimeout(generation: generation)
        }
    }

    private func handleMetadataRestoreTimeout(generation: UInt64) {
        guard let operation = metadataRestoreOperation,
              operation.generation == generation else {
            return
        }

        if pendingPlaybackRestore?.entryId == operation.entryId {
            pendingPlaybackRestore = nil
        }

        if currentEntryId == operation.entryId {
            wantsPlaybackActive = false
            restoredPosition = currentTime
            currentEntryId = nil
            trackForEntry.removeValue(forKey: operation.entryId.id)
            pendingNext = nil
            pendingNextWasSkipped = false
            audioPlayer.clearNextTrack()
            audioPlayer.stop()
            setPlaybackActive(false)
            updateNowPlayingInfo()
        }

        finishMetadataRestore(
            .failure(.timedOut),
            generation: operation.generation,
            entryId: operation.entryId
        )
    }

    private func cancelMetadataRestoreForPlaybackChange() {
        guard let operation = metadataRestoreOperation else { return }

        if pendingPlaybackRestore?.entryId == operation.entryId {
            pendingPlaybackRestore = nil
        }

        finishMetadataRestore(
            .failure(
                .engine(
                    String(appLocalized: "Playback restoration was interrupted by another playback action.")
                )
            ),
            generation: operation.generation,
            entryId: operation.entryId
        )
    }

    private func finishMetadataRestore(
        _ result: Result<Void, MetadataPlaybackRestoreError>,
        generation: UInt64? = nil,
        entryId: AudioEntryId? = nil
    ) {
        guard let operation = metadataRestoreOperation,
              operation.generation == metadataRestoreGeneration else {
            return
        }
        if let generation, generation != operation.generation { return }
        if let entryId, entryId != operation.entryId { return }
        guard let completion = metadataRestoreCompletion else { return }
        metadataRestoreCompletion = nil
        metadataRestoreOperation = nil
        metadataRestoreGeneration &+= 1
        metadataRestoreTimeoutTask?.cancel()
        metadataRestoreTimeoutTask = nil
        completion(result)
    }

    // MARK: - Gapless lookahead

    /// Subscribes to queue/repeat/shuffle changes so the engine's gapless next
    /// entry is re-derived whenever what plays next could change. The current
    /// track keeps playing; only the lookahead is swapped. `primeNextTrack` is a
    /// no-op on non-gapless engines, so this is safe to wire unconditionally
    /// (the active engine can change at runtime via the toggle).
    private func observeQueueForGaplessLookahead() {
        Publishers.Merge3(
            playlistManager.$currentQueue.map { _ in () },
            playlistManager.$repeatMode.map { _ in () },
            playlistManager.$isShuffleEnabled.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            guard let self, self.currentTrack != nil else { return }
            // Only re-prime while a track is actually loaded in the engine. During
            // the initial start the queue is set before the engine is playing, and
            // priming then inserts into a not-yet-established session.
            let state = self.audioPlayer.state
            guard state == .playing || state == .paused else { return }
            self.primeNextTrack()
        }
        .store(in: &queueObservers)
    }

    /// Primes (or re-primes) the engine's gapless next entry from the queue.
    /// No-op unless the active engine supports a gapless lookahead.
    private func primeNextTrack() {
        guard audioPlayer.supportsGaplessQueue else { return }

        guard let next = playlistManager.peekNextTrack() else {
            audioPlayer.clearNextTrack()
            pendingNext = nil
            pendingNextWasSkipped = false
            return
        }

        // Already primed for this exact upcoming entry - avoid a redundant swap
        // (redundant command-center/engine writes are wasteful).
        if let pending = pendingNext,
           pending.track == next.track,
           pending.track.url == next.track.url,
           pending.index == next.index {
            return
        }

        let entryId = AudioEntryId(id: UUID().uuidString)
        pendingNext = PendingNext(entryId: entryId, track: next.track, index: next.index, fullTrack: nil)
        pendingNextWasSkipped = false
        audioPlayer.setNextTrack(url: next.track.url, entryId: entryId)
        Logger.info("Primed gapless next: \(next.track.title)")

        // Pre-fetch the full track so a gapless advance has it ready immediately.
        Task { [weak self] in
            guard let self else { return }
            let full = try? await next.track.fullTrack(using: self.libraryManager.databaseManager.dbQueue)
            await MainActor.run {
                if self.pendingNext?.entryId == entryId {
                    self.pendingNext?.fullTrack = full
                }
            }
        }
    }

    /// Promotes the primed next track to current after the engine gaplessly
    /// advanced into it. The audio is already playing; this just syncs Petrichor's
    /// queue state, bookkeeping, and re-primes the following track.
    private func handleGaplessAdvance(to pending: PendingNext) {
        restoredUITrack = nil
        currentTrack = pending.track
        currentFullTrack = pending.fullTrack
        currentEntryId = pending.entryId
        // Keep the outgoing entry so its (possibly late) finish can still credit it.
        trackForEntry[pending.entryId.id] = pending.track
        playlistManager.advanceQueueIndex(to: pending.index)
        currentTime = 0
        resetProgressResolution(engineProgress: 0)
        wantsPlaybackActive = true
        setPlaybackActive(true)
        pendingNext = nil
        pendingNextWasSkipped = false
        Logger.info("Gapless advance to: \(pending.track.title)")

        // If the pre-fetch didn't finish in time, load it now for pause/resume + UI.
        if currentFullTrack == nil {
            let track = pending.track
            Task { [weak self] in
                guard let self else { return }
                let full = try? await track.fullTrack(using: self.libraryManager.databaseManager.dbQueue)
                await MainActor.run {
                    if self.currentTrack?.url == track.url { self.currentFullTrack = full }
                }
            }
        }

        primeNextTrack()
    }
    
    private func startProgressUpdateTimer() {
        progressUpdateTimer?.cancel()
        
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // 1s by default; 0.5s only while the lyrics view is open (it needs finer
        // line timing). Sampling faster than 1s otherwise just doubles UI
        // re-renders for no benefit, so it's scoped to when lyrics are visible.
        let interval: DispatchTimeInterval = fineProgressSampling ? .milliseconds(500) : .seconds(1)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(50))

        timer.setEventHandler { [weak self] in
            guard let self else { return }

            let sampleUptime = ProcessInfo.processInfo.systemUptime
            let elapsed = self.lastProgressSampleUptime
                .map { max(0, sampleUptime - $0) } ?? 0
            self.lastProgressSampleUptime = sampleUptime

            let engineState = self.audioPlayer.state
            let engineProgress = self.audioPlayer.currentPlaybackProgress
            let previousEngineProgress = self.lastObservedEngineProgress
            self.lastObservedEngineProgress = engineProgress

            guard self.shouldPublishProgressSample(
                engineState: engineState,
                engineProgress: engineProgress,
                previousEngineProgress: previousEngineProgress
            ) else { return }

            if self.wantsPlaybackActive && engineState != .playing && !self.isPlaying {
                Logger.warning(
                    "Playback progress advanced while engine state was \(engineState); resyncing playback UI"
                )
                self.setPlaybackActive(true)
            }

            let tolerance = self.fineProgressSampling ? 0.05 : 0.2
            let resolution = self.progressResolver.resolve(
                engineProgress: engineProgress,
                previousEngineProgress: previousEngineProgress,
                displayedProgress: self.currentTime,
                elapsed: elapsed,
                duration: self.currentTrack?.duration ?? self.audioPlayer.duration,
                playbackIsActive: self.wantsPlaybackActive
                    && (engineState == .playing || self.isPlaying),
                tolerance: tolerance
            )

            guard let resolvedProgress = resolution.progress else { return }

            switch resolution.transition {
            case .enteredFallback:
                Logger.warning(
                    "Playback progress stalled on \(MediaBackend.current) while engine state was \(engineState); using monotonic display progress from \(engineProgress)s"
                )
            case .recovered:
                Logger.info(
                    "Playback engine progress recovered at \(engineProgress)s; ending monotonic display fallback"
                )
            case .none:
                break
            }

            self.currentTime = resolvedProgress
            // Refresh the system Now Playing tile at ~1s regardless of sampling
            // rate - it extrapolates elapsed between updates from the rate anchor,
            // so a higher rate is wasted work (and an artwork re-decode on SFB).
            let now = Date().timeIntervalSinceReferenceDate
            if now - self.lastNowPlayingUpdate >= 1.0 {
                self.lastNowPlayingUpdate = now
                self.updateNowPlayingInfo()
            }
        }
        
        timer.resume()
        progressUpdateTimer = timer
    }

    /// Switches the progress sampler to 0.5s while a lyrics view is visible (for
    /// tight line highlighting) and back to 1s otherwise (minimum CPU during normal
    /// listening). Reference-counted so multiple lyrics views (main window +
    /// mini player) don't disable sampling out from under each other; called by
    /// each lyrics view on appear (`true`) / disappear (`false`).
    func setFineProgressSampling(_ enabled: Bool) {
        if enabled {
            fineSamplingConsumers += 1
        } else {
            fineSamplingConsumers = max(0, fineSamplingConsumers - 1)
        }

        let shouldSampleFine = fineSamplingConsumers > 0
        guard shouldSampleFine != fineProgressSampling else { return }
        fineProgressSampling = shouldSampleFine
        startProgressUpdateTimer()
    }

    private func shouldPublishProgressSample(
        engineState: AudioPlayerState,
        engineProgress: Double,
        previousEngineProgress: Double?
    ) -> Bool {
        guard currentTrack != nil, engineProgress.isFinite, engineProgress >= 0 else { return false }

        if engineState == .playing || isPlaying {
            return true
        }

        guard let previousEngineProgress else { return false }

        let tolerance = fineProgressSampling ? 0.05 : 0.2
        let progressAdvanced = engineProgress > previousEngineProgress + tolerance
        let uiTimeIsStale = abs(engineProgress - currentTime) > tolerance

        return progressAdvanced && uiTimeIsStale
    }

    private func resetProgressResolution(engineProgress: TimeInterval? = nil) {
        progressResolver.reset()
        lastObservedEngineProgress = engineProgress
        lastProgressSampleUptime = nil
    }

    private func stopProgressUpdateTimer() {
        progressUpdateTimer?.cancel()
        progressUpdateTimer = nil
    }
    
    private func startStateSaveTimer() {
        stateSaveTimer?.invalidate()
        // `Timer.scheduledTimer` fires on the current run loop, which is the main
        // run loop here (this method is `@MainActor`). The closure is treated as
        // `@Sendable`, so we re-enter the main actor explicitly before reading
        // `isPlaying`.
        stateSaveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                if self.isPlaying {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("SavePlaybackState"),
                        object: nil
                    )
                }
            }
        }
    }
    
    private func stopStateSaveTimer() {
        stateSaveTimer?.invalidate()
        stateSaveTimer = nil
    }
    
    /// Restore audio effects settings from UserDefaults
    private func restoreAudioEffectsSettings() {
        // Restore stereo widening
        let stereoWideningEnabled = UserDefaults.standard.bool(forKey: "stereoWideningEnabled")
        if stereoWideningEnabled {
            audioPlayer.setStereoWidening(enabled: true)
            Logger.info("Restored stereo widening: enabled")
        }

        // Restore EQ preset or custom gains BEFORE flipping the enabled flag, so the
        // band gains and headroom-compensated preamp are in place when the EQ goes
        // live. (applyEQCustom/applyEQPreset attach the effects graph and compute the
        // effective preamp against the supplied gains.) Otherwise enabling first
        // leaves the EQ momentarily flat at 0dB until the preset is applied.
        let eqEnabled = UserDefaults.standard.bool(forKey: "eqEnabled")
        if eqEnabled {
            if let presetRawValue = UserDefaults.standard.string(forKey: "eqPreset") {
                if presetRawValue == "custom" {
                    // Restore custom gains
                    if let customGains = UserDefaults.standard.array(forKey: "customEQGains") as? [Float],
                       customGains.count == 10 {
                        audioPlayer.applyEQCustom(gains: customGains)
                        Logger.info("Restored custom EQ gains")
                    }
                } else {
                    // Restore preset
                    if let preset = EqualizerPreset(rawValue: presetRawValue) {
                        audioPlayer.applyEQPreset(preset)
                        Logger.info("Restored EQ preset: \(preset.displayName)")
                    }
                }
            }

            // Now flip the enabled state with the correct gains already applied.
            audioPlayer.setEQEnabled(true)
            Logger.info("Restored EQ: enabled")
        }

        // Restore preamp gain
        if UserDefaults.standard.object(forKey: "preampGain") != nil {
            let preampGain = UserDefaults.standard.float(forKey: "preampGain")
            audioPlayer.setPreamp(preampGain)
            Logger.info("Restored preamp: \(preampGain) dB")
        }
    }
}

// MARK: - AudioPlayerDelegate

// `AudioPlayerDelegate` is a non-isolated protocol (it predates strict
// concurrency and is implemented by other call sites), but `PlaybackManager`
// is `@MainActor`. The conformance is `@preconcurrency` to acknowledge the
// cross-isolation match is intentional — every method already hops to main
// before touching `@MainActor` state.
extension PlaybackManager: @preconcurrency AudioPlayerDelegate {
    func audioPlayerDidStartPlaying(player: PlaybackEngine, with entryId: AudioEntryId) {
        DispatchQueue.main.async {
            guard self.audioPlayer.state == .playing else {
                Logger.info("Ignoring stale start-playing callback while engine is \(self.audioPlayer.state)")
                return
            }

            // A gapless engine fires this for the primed next track when it
            // self-advances; promote it instead of treating it as a fresh start.
            if let pending = self.pendingNext, pending.entryId == entryId {
                guard self.wantsPlaybackActive else {
                    Logger.info("Ignoring stale gapless start callback after pause intent")
                    return
                }
                self.handleGaplessAdvance(to: pending)
            } else {
                guard self.wantsPlaybackActive, entryId == self.currentEntryId else {
                    Logger.info("Ignoring stale start-playing callback for \(entryId.id)")
                    return
                }
                self.setPlaybackActive(true)
            }

            if let operation = self.metadataRestoreOperation,
               operation.entryId == entryId,
               self.pendingPlaybackRestore == nil,
               self.wantsPlaybackActive {
                self.finishMetadataRestore(
                    .success(()),
                    generation: operation.generation,
                    entryId: entryId
                )
            }
            Logger.info("Track started playing: \(entryId.id)")
        }
    }
    
    func audioPlayerStateChanged(player: PlaybackEngine, with newState: AudioPlayerState, previous: AudioPlayerState) {
        DispatchQueue.main.async {
            let effectiveState = self.audioPlayer.state

            switch effectiveState {
            case .playing:
                if self.wantsPlaybackActive {
                    self.setPlaybackActive(true)
                } else {
                    Logger.info("Ignoring stale playing state after pause intent")
                    self.setPlaybackActive(false)
                }
            case .paused:
                self.setPlaybackActive(false)
            case .stopped:
                self.setPlaybackActive(false)
            case .ready:
                self.setPlaybackActive(false)
            }

            // Finish a deferred restore: the startPaused load has now settled in
            // `.paused`, so the asset is open and the seek plus requested state are
            // safe. Guarded by entry identity so an unrelated pause never trips it.
            if effectiveState == .paused,
               let pending = self.pendingPlaybackRestore,
               pending.entryId == self.currentEntryId {
                self.pendingPlaybackRestore = nil
                if self.audioPlayer.seek(to: pending.position) {
                    self.currentTime = pending.position
                    self.resetProgressResolution(engineProgress: pending.position)
                    if pending.shouldResume {
                        self.wantsPlaybackActive = true
                        self.audioPlayer.resume()
                        Logger.info("Resumed restored playback from \(pending.position)s")
                    } else {
                        self.wantsPlaybackActive = false
                        self.updateNowPlayingInfo()
                        self.finishMetadataRestore(
                            .success(()),
                            entryId: pending.entryId
                        )
                        Logger.info("Restored paused playback at \(pending.position)s")
                    }
                } else {
                    Logger.warning("Restore seek failed")
                    self.currentTime = 0
                    self.resetProgressResolution(engineProgress: 0)
                    if pending.shouldResume, let url = self.currentFullTrack?.url {
                        self.wantsPlaybackActive = true
                        self.audioPlayer.play(
                            url: url,
                            entryId: pending.entryId,
                            startPaused: false
                        )
                        Logger.warning("Restore seek failed, starting from beginning")
                    } else {
                        self.wantsPlaybackActive = false
                        self.updateNowPlayingInfo()
                        Logger.warning("Restore seek failed, staying paused at beginning")
                    }
                    self.finishMetadataRestore(
                        .failure(.seekFailed),
                        entryId: pending.entryId
                    )
                }
            }

            if effectiveState == .playing,
               let operation = self.metadataRestoreOperation,
               operation.entryId == self.currentEntryId,
               self.pendingPlaybackRestore == nil,
               self.wantsPlaybackActive {
                self.finishMetadataRestore(
                    .success(()),
                    generation: operation.generation,
                    entryId: operation.entryId
                )
            }

            // Prime the gapless next once the engine is actually playing. This
            // fires for every start path - fresh play, restored resume (which
            // goes startPaused -> seek -> resume), and resume-from-pause - so
            // priming is reliable where `didStartPlaying` alone was not.
            // A gapless advance keeps the state at .playing (no transition here),
            // so it re-primes via handleGaplessAdvance instead.
            if effectiveState == .playing {
                self.primeNextTrack()
            }

            Logger.info("Player state changed: \(previous) → \(newState), effective: \(effectiveState)")
        }
    }
    
    func audioPlayerDidFinishPlaying(
        player: PlaybackEngine,
        entryId: AudioEntryId,
        stopReason: AudioPlayerStopReason,
        progress: Double,
        duration: Double
    ) {
        DispatchQueue.main.async {
            // Credit the track that actually finished, resolved by entry id: on a
            // gapless advance currentTrack may already be the next track.
            let finishedTrack = self.trackForEntry.removeValue(forKey: entryId.id)

            guard self.currentTrack != nil else {
                Logger.info("Ignoring finish - no current track")
                return
            }

            Logger.info("Track finished (reason: \(stopReason))")

            if stopReason == .eof, let finishedTrack {
                self.playlistManager.incrementPlayCount(for: finishedTrack)

                Logger.info("Track completed naturally, updating play count and last played date")
            }

            // Only tear down current playback when the finished entry is still
            // current; a stale finish that raced ahead of a gapless advance must not
            // flip isPlaying false under the now-playing track (which freezes its bar).
            let finishedEntryIsCurrent = entryId == self.currentEntryId

            switch stopReason {
            case .eof:
                self.restoredPosition = 0
                if self.audioPlayer.supportsGaplessQueue {
                    // True end of queue only: nothing primed and this finish is for
                    // the current entry (not a stale one that raced the advance).
                    if self.pendingNext == nil && finishedEntryIsCurrent {
                        self.currentTime = 0
                        if self.pendingNextWasSkipped {
                            self.pendingNextWasSkipped = false
                            self.playlistManager.handleTrackCompletion()
                        } else {
                            self.wantsPlaybackActive = false
                            self.resetProgressResolution(engineProgress: 0)
                            self.setPlaybackActive(false)
                            NotificationCenter.default.post(
                                name: NSNotification.Name("SavePlaybackState"),
                                object: nil
                            )
                        }
                    }
                } else {
                    self.currentTime = 0
                    self.playlistManager.handleTrackCompletion()
                    if !self.isPlaying {
                        self.resetProgressResolution(engineProgress: 0)
                        self.stopStateSaveTimer()

                        NotificationCenter.default.post(
                            name: NSNotification.Name("SavePlaybackState"),
                            object: nil
                        )
                    }
                }

            case .userAction:
                if finishedEntryIsCurrent {
                    self.wantsPlaybackActive = false
                    self.currentTime = 0
                    self.resetProgressResolution(engineProgress: 0)
                    self.stopStateSaveTimer()
                } else {
                    Logger.info("Ignoring stale user stop for non-current entry")
                }

            case .error:
                if let operation = self.metadataRestoreOperation,
                   operation.entryId == entryId {
                    if self.pendingPlaybackRestore?.entryId == operation.entryId {
                        self.pendingPlaybackRestore = nil
                    }
                    self.finishMetadataRestore(
                        .failure(.engine(String(appLocalized: "Playback error occurred"))),
                        generation: operation.generation,
                        entryId: operation.entryId
                    )
                }
                self.currentTime = 0
                self.resetProgressResolution(engineProgress: 0)
                self.wantsPlaybackActive = false
                self.setPlaybackActive(false)
                Logger.error("Playback finished with error")
                Task { @MainActor in
                    NotificationManager.shared.addMessage(.error, String(appLocalized: "Playback error occurred"))
                }
            }
        }
    }
    
    func audioPlayerUnexpectedError(player: PlaybackEngine, error: AudioPlayerError) {
        DispatchQueue.main.async {
            Logger.error("Audio player error: \(error.localizedDescription)")
            if let operation = self.metadataRestoreOperation,
               operation.entryId == self.currentEntryId {
                if self.pendingPlaybackRestore?.entryId == operation.entryId {
                    self.pendingPlaybackRestore = nil
                }
                self.finishMetadataRestore(
                    .failure(.engine(error.localizedDescription)),
                    generation: operation.generation,
                    entryId: operation.entryId
                )
            }
            Task { @MainActor in
                NotificationManager.shared.addMessage(.error, String(appLocalized: "Playback error: \(error.localizedDescription)"))
            }
        }
    }

    func audioPlayerDidSkipQueueEntry(player: PlaybackEngine, entryId: AudioEntryId) {
        DispatchQueue.main.async {
            guard self.pendingNext?.entryId == entryId else { return }
            Logger.warning("Gapless lookahead skipped; falling back to app-driven advance")
            self.pendingNext = nil
            self.pendingNextWasSkipped = true
        }
    }
}
