//
// CrescendoPlaybackBackend
//
// The Crescendo-backed `PlaybackBackend`. It wraps `CrescendoPlayer` and reports
// events to the `PlaybackEngine` facade. This is the only playback file that
// imports Crescendo.
//
// Concurrency: `CrescendoPlayer` and `CrescendoPlayerDelegate` are `@MainActor`,
// and this backend is `@MainActor` too. All backend calls happen on the main
// thread today (UI, delegate hops, the .main progress timer), so isolating the
// class removes the previous `onMain`/`DispatchQueue.main.sync` bridging (the
// synchronous hop was a deadlock risk when called off-main). The SFB backend
// stays non-isolated because its `reconfigureProcessingGraph` callback runs
// synchronously on the engine's render thread, so the shared `PlaybackBackend`
// protocol is non-isolated; this class marks its conformance `@preconcurrency`
// to acknowledge that the cross-isolation match is intentional and not a race.
//

import Crescendo
import Foundation

/// `@MainActor` so all backend state (`pendingNextEntryId`, EQ/widening fields) is
/// mutated on a single thread. This removes the previous `onMain`/`onMainStatic`
/// synchronous main-queue hop (a deadlock risk when called off-main) — the backend
/// is driven entirely from the main thread today (UI, the `.main` progress timer,
/// the `@MainActor` delegate bridge).
@MainActor
final class CrescendoPlaybackBackend: @preconcurrency PlaybackBackend {
    // MARK: - Backend Surface

    weak var backendDelegate: PlaybackBackendDelegate?

    let supportsGaplessQueue = true

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var state: AudioPlayerState {
        Self.mapState(player.state)
    }

    var currentPlaybackProgress: Double {
        player.currentTime
    }

    var duration: Double {
        player.duration
    }

    // MARK: - Private Properties

    private let player: CrescendoPlayer
    private var delegateBridge: CrescendoDelegateBridge?

    // The single pre-decoded next entry (the "+1" of the N+1 lookahead), or nil.
    private var pendingNextEntryId: CrescendoEntryId?

    // Effects state. Crescendo applies all effects as property sets, so there is
    // no graph to build; we keep the user-facing state here and push it down.
    private var eqEnabled = false
    private var currentEQGains = [Float](repeating: 0, count: 10)
    private var stereoWideningEnabled = false
    private var userPreampGain: Float = 0

    private static let flatEQGains = [Float](repeating: 0, count: 10)

    // MARK: - Initialization

    init() {
        player = CrescendoPlayer()
        let bridge = CrescendoDelegateBridge(owner: self)
        self.delegateBridge = bridge
        player.delegate = bridge
        // For the 1.6 co-existence release, Petrichor's NowPlayingManager owns
        // the system Now Playing tile and remote commands for BOTH engines, so
        // Crescendo publishes neither. Crescendo takes over Now Playing in 1.7
        // when SFB is removed (and its restore-resume tile-anchor bug is fixed).
        player.nowPlayingInfoEnabled = false
        player.remoteCommandsEnabled = false
        installLogBridge()
    }

    // MARK: - Playback Control

    func play(url: URL, entryId: AudioEntryId, startPaused: Bool) {
        // play(url:) replaces Crescendo's queue, so any pending next is gone.
        player.play(url: url, entryId: CrescendoEntryId(id: entryId.id), startPaused: startPaused)
        pendingNextEntryId = nil
    }

    func setNextTrack(url: URL, entryId: AudioEntryId) {
        let nextId = CrescendoEntryId(id: entryId.id)
        // Surgically swap just the lookahead entry: drop the stale next (if
        // any) and prime the new one right after the current track. The
        // playing entry is never touched, so the timeline is uninterrupted.
        if let stale = pendingNextEntryId {
            _ = player.remove(entryId: stale)
        }
        player.insertNext(url: url, entryId: nextId)
        pendingNextEntryId = nextId
    }

    func clearNextTrack() {
        if let stale = pendingNextEntryId {
            _ = player.remove(entryId: stale)
        }
        pendingNextEntryId = nil
    }

    func pause() { player.pause() }
    func resume() { player.resume() }
    func stop() { player.stop() }
    func togglePlayPause() { player.togglePlayPause() }

    @discardableResult
    func seek(to time: Double) -> Bool {
        guard time >= 0 else { return false }
        return player.seek(to: time)
    }

    @discardableResult
    func seekForward(_ seconds: Double) -> Bool {
        player.seekForward(seconds)
    }

    @discardableResult
    func seekBackward(_ seconds: Double) -> Bool {
        player.seekBackward(seconds)
    }

    // MARK: - Audio Effects

    func setStereoWidening(enabled: Bool) {
        stereoWideningEnabled = enabled
        // Crescendo uses a mid/side width (1.0 neutral); SFB used a Haas delay, so
        // the two engines sound slightly different here.
        player.stereoWidth = enabled ? 2.0 : 1.0
    }

    func isStereoWideningEnabled() -> Bool { stereoWideningEnabled }

    func setEQEnabled(_ enabled: Bool) {
        eqEnabled = enabled
        pushEQGains()
        pushEffectivePreamp()
    }

    func isEQEnabled() -> Bool { eqEnabled }

    func applyEQPreset(_ preset: EqualizerPreset) {
        currentEQGains = preset.gains
        pushEQGains()
        pushEffectivePreamp()
    }

    func applyEQCustom(gains: [Float]) {
        guard gains.count == 10 else {
            Logger.warning("Equalizer gains array must contain exactly 10 values, got \(gains.count)")
            return
        }
        currentEQGains = gains
        pushEQGains()
        pushEffectivePreamp()
    }

    func setPreamp(_ gain: Float) {
        userPreampGain = max(-12, min(12, gain))
        pushEffectivePreamp()
    }

    func getPreamp() -> Float { userPreampGain }

    // Disabled EQ is expressed as flat (all-zero) gains rather than Crescendo's
    // `effectsEnabled`, which would bypass preamp and width too.
    private func pushEQGains() {
        let gains = eqEnabled ? currentEQGains : Self.flatEQGains
        player.equalizerGains = gains
    }

    private func pushEffectivePreamp() {
        let compensation = EqualizerHeadroomCompensation.gainOffset(
            eqEnabled: eqEnabled,
            gains: currentEQGains
        )
        player.preampGain = userPreampGain + compensation
    }

    // MARK: - Logging bridge

    @MainActor
    private func installLogBridge() {
        player.logHandler = { record in
            let message = "[Crescendo/\(record.category.rawValue)] \(record.message)"
            switch record.level {
            case .warning: Logger.warning(message)
            case .error: Logger.error(message)
            case .fault: Logger.critical(message)
            case .debug, .info: Logger.info(message)
            @unknown default: Logger.info(message)
            }
        }
        player.logLevel = AppInfo.isDebugBuild ? .info : .warning
    }

    // MARK: - Delegate event handling (called by the @MainActor bridge)

    func handleStartPlaying(entryId: CrescendoEntryId) {
        // On a gapless advance the primed next becomes the active track, so it's
        // no longer "pending" - clear it before the app primes the new next.
        if entryId == pendingNextEntryId {
            pendingNextEntryId = nil
        }
        backendDelegate?.backendDidStartPlaying(with: AudioEntryId(id: entryId.id))
    }

    func handleStateChange(from oldState: CrescendoPlayerState, to newState: CrescendoPlayerState) {
        backendDelegate?.backendStateChanged(with: Self.mapState(newState), previous: Self.mapState(oldState))
    }

    func handleFinish(entryId: CrescendoEntryId, reason: CrescendoStopReason, progress: Double, duration: Double) {
        backendDelegate?.backendDidFinishPlaying(
            entryId: AudioEntryId(id: entryId.id),
            stopReason: Self.mapStopReason(reason),
            progress: progress,
            duration: duration
        )
    }

    func handleError(_ error: CrescendoError, entryId: CrescendoEntryId?) {
        backendDelegate?.backendUnexpectedError(
            error: Self.mapError(error),
            entryId: entryId.map { AudioEntryId(id: $0.id) }
        )
    }

    func handleFinishBuffering(entryId: CrescendoEntryId) {
        backendDelegate?.backendDidFinishBuffering(with: AudioEntryId(id: entryId.id))
    }

    func handleSkippedEntry(entryId: CrescendoEntryId, url: URL, reason: CrescendoError) {
        Logger.warning("Crescendo skipped \(url.lastPathComponent): \(reason.localizedDescription)")
        if entryId == pendingNextEntryId {
            pendingNextEntryId = nil
        }
        backendDelegate?.backendDidSkipQueueEntry(entryId: AudioEntryId(id: entryId.id))
    }

    // MARK: - Mapping

    private static func mapState(_ state: CrescendoPlayerState) -> AudioPlayerState {
        switch state {
        case .idle, .ready: return .ready
        case .playing: return .playing
        case .paused: return .paused
        case .stopped: return .stopped
        @unknown default: return .ready
        }
    }

    private static func mapStopReason(_ reason: CrescendoStopReason) -> AudioPlayerStopReason {
        switch reason {
        case .endOfFile: return .eof
        case .userAction: return .userAction
        case .error: return .error
        // Treat an unknown future reason as a user action so it neither advances
        // the queue nor surfaces as an error.
        @unknown default: return .userAction
        }
    }

    private static func mapError(_ error: CrescendoError) -> AudioPlayerError {
        switch error {
        case .fileNotFound: return .fileNotFound
        case .unsupportedFormat: return .invalidFormat
        case .seekFailed: return .seekError
        case .invalidState: return .invalidState
        case .decoderError, .rendererError, .streamingError, .notImplemented: return .engineError(error)
        @unknown default: return .engineError(error)
        }
    }
}

// MARK: - Delegate Bridge

/// Bridges `CrescendoPlayer`'s `@MainActor` delegate callbacks to the backend. Both
/// the bridge and the backend are `@MainActor`, so the callbacks land directly on
/// the main actor with no hop.
@MainActor
private final class CrescendoDelegateBridge: CrescendoPlayerDelegate {
    weak var owner: CrescendoPlaybackBackend?

    init(owner: CrescendoPlaybackBackend) {
        self.owner = owner
    }

    func playerDidStartPlaying(_ player: CrescendoPlayer, entryId: CrescendoEntryId) {
        owner?.handleStartPlaying(entryId: entryId)
    }

    func playerDidChangeState(
        _ player: CrescendoPlayer,
        from oldState: CrescendoPlayerState,
        to newState: CrescendoPlayerState
    ) {
        owner?.handleStateChange(from: oldState, to: newState)
    }

    func playerDidFinishPlaying(
        _ player: CrescendoPlayer,
        entryId: CrescendoEntryId,
        reason: CrescendoStopReason,
        progress: TimeInterval,
        duration: TimeInterval
    ) {
        owner?.handleFinish(entryId: entryId, reason: reason, progress: progress, duration: duration)
    }

    func playerDidEncounterError(_ player: CrescendoPlayer, error: CrescendoError, entryId: CrescendoEntryId?) {
        owner?.handleError(error, entryId: entryId)
    }

    func playerDidFinishBuffering(_ player: CrescendoPlayer, entryId: CrescendoEntryId) {
        owner?.handleFinishBuffering(entryId: entryId)
    }

    func playerDidSkipQueueEntry(
        _ player: CrescendoPlayer,
        entryId: CrescendoEntryId,
        url: URL,
        reason: CrescendoError
    ) {
        owner?.handleSkippedEntry(entryId: entryId, url: url, reason: reason)
    }
}
