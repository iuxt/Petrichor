import Foundation

/// Pure state for the interval in which an edited current track must remain
/// closed. `PlaybackManager` owns the engine effects; this value only resolves
/// user transport requests into the state that should exist after the write.
struct MetadataEditPlaybackSuspension: Equatable, Sendable {
    enum RestorableMode: Equatable, Sendable {
        case playing
        case paused
        case idle
    }

    enum PlayDisposition: Equatable, Sendable {
        case deferEditedTrack
        case playDifferentTrack
    }

    enum Restoration: Equatable, Sendable {
        case superseded
        case stop
        case restore(
            mode: RestorableMode,
            position: Double,
            queueIndex: Int?
        )

        var queueIndex: Int? {
            guard case .restore(_, _, let queueIndex) = self else {
                return nil
            }
            return queueIndex
        }
    }

    private enum DesiredMode: Equatable, Sendable {
        case playing
        case paused
        case idle
        case stopRequested
    }

    let generation: UInt64

    private let trackID: Int64?
    private let standardizedURL: URL
    private let originalQueueIndex: Int
    private var desiredMode: DesiredMode
    private var desiredPosition: Double
    private var restoresOriginalQueue = true
    private var isSuperseded = false

    init(
        generation: UInt64,
        trackID: Int64?,
        url: URL,
        position: Double,
        wasPlaying: Bool,
        wasEngineActive: Bool,
        queueIndex: Int
    ) {
        self.generation = generation
        self.trackID = trackID
        standardizedURL = url.standardizedFileURL
        originalQueueIndex = queueIndex
        desiredPosition = Self.sanitized(position)

        if wasPlaying {
            desiredMode = .playing
        } else if wasEngineActive {
            desiredMode = .paused
        } else {
            desiredMode = .idle
        }
    }

    var restoration: Restoration {
        guard !isSuperseded else { return .superseded }
        return fallbackRestoration
    }

    /// The edited track's latest desired state even while another track has
    /// superseded it. This is used only if that replacement later fails.
    var fallbackRestoration: Restoration {
        switch desiredMode {
        case .playing:
            return restoration(mode: .playing)
        case .paused:
            return restoration(mode: .paused)
        case .idle:
            return restoration(mode: .idle)
        case .stopRequested:
            return .stop
        }
    }

    var fallbackPosition: Double {
        desiredPosition
    }

    func fallbackRestoration(
        overridingShouldPlay shouldPlay: Bool?
    ) -> Restoration {
        var fallback = self
        fallback.isSuperseded = false
        if let shouldPlay {
            if shouldPlay {
                _ = fallback.requestPlaying()
            } else {
                _ = fallback.requestPaused()
            }
        }
        return fallback.restoration
    }

    mutating func updateFallbackPlayback(shouldPlay: Bool) -> Bool {
        guard isSuperseded else { return false }
        if shouldPlay {
            desiredMode = .playing
        } else {
            switch desiredMode {
            case .playing, .paused:
                desiredMode = .paused
            case .idle, .stopRequested:
                break
            }
        }
        return true
    }

    mutating func requestFallbackStop() -> Bool {
        guard isSuperseded else { return false }
        desiredMode = .stopRequested
        return true
    }

    func matches(trackID candidateID: Int64?, url candidateURL: URL) -> Bool {
        if let trackID, let candidateID, trackID == candidateID {
            return true
        }
        return standardizedURL == candidateURL.standardizedFileURL
    }

    /// Returns false after another track has superseded this restoration, so
    /// the caller can apply the toggle to that newer playback normally.
    mutating func toggle() -> Bool {
        guard !isSuperseded else { return false }

        switch desiredMode {
        case .playing:
            desiredMode = .paused
        case .paused, .idle, .stopRequested:
            desiredMode = .playing
        }
        return true
    }

    /// Returns false after supersession so stop applies to the newer track.
    mutating func requestStop() -> Bool {
        guard !isSuperseded else { return false }
        desiredMode = .stopRequested
        return true
    }

    mutating func requestPlaying() -> Bool {
        guard !isSuperseded else { return false }
        desiredMode = .playing
        return true
    }

    mutating func requestPaused() -> Bool {
        guard !isSuperseded else { return false }
        switch desiredMode {
        case .playing, .paused:
            desiredMode = .paused
        case .idle, .stopRequested:
            break
        }
        return true
    }

    /// Returns nil after supersession so seek applies to the newer track.
    @discardableResult
    mutating func seek(to position: Double) -> Double? {
        guard !isSuperseded else { return nil }
        desiredPosition = Self.sanitized(position)
        return desiredPosition
    }

    mutating func requestPlay(
        trackID candidateID: Int64?,
        url candidateURL: URL
    ) -> PlayDisposition {
        restoresOriginalQueue = false

        if matches(trackID: candidateID, url: candidateURL) {
            isSuperseded = false
            desiredMode = .playing
            desiredPosition = 0
            return .deferEditedTrack
        }

        isSuperseded = true
        return .playDifferentTrack
    }

    mutating func restoreAfterFailedSupersession(
        shouldPlay: Bool?
    ) -> Bool {
        guard isSuperseded else { return false }
        isSuperseded = false

        if let shouldPlay {
            if shouldPlay {
                _ = requestPlaying()
            } else {
                _ = requestPaused()
            }
        }
        return true
    }

    private func restoration(mode: RestorableMode) -> Restoration {
        .restore(
            mode: mode,
            position: desiredPosition,
            queueIndex: restoresOriginalQueue ? originalQueueIndex : nil
        )
    }

    private static func sanitized(_ position: Double) -> Double {
        position.isFinite && position >= 0 ? position : 0
    }
}
