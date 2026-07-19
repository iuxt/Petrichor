import Foundation

/// Pure transport state for one audio file while its metadata is being
/// rewritten. PlaybackManager owns the engine effects and the deferred Track;
/// this value only decides whether transport may open the guarded URL.
struct MetadataWriteAccessGuard: Equatable, Sendable {
    enum PlayDisposition: Equatable, Sendable {
        case deferTarget
        case allowDifferentTarget
    }

    let generation: UInt64

    private let trackID: Int64?
    private let standardizedURL: URL
    private(set) var deferredShouldStartPlaying: Bool?

    init(generation: UInt64, trackID: Int64?, url: URL) {
        self.generation = generation
        self.trackID = trackID
        standardizedURL = url.standardizedFileURL
    }

    func matches(trackID candidateID: Int64?, url candidateURL: URL) -> Bool {
        if let trackID, let candidateID, trackID == candidateID {
            return true
        }
        return standardizedURL == candidateURL.standardizedFileURL
    }

    mutating func requestPlay(
        trackID candidateID: Int64?,
        url candidateURL: URL
    ) -> PlayDisposition {
        guard matches(trackID: candidateID, url: candidateURL) else {
            deferredShouldStartPlaying = nil
            return .allowDifferentTarget
        }

        deferredShouldStartPlaying = true
        return .deferTarget
    }

    @discardableResult
    mutating func adoptPendingPlayback(
        trackID candidateID: Int64?,
        url candidateURL: URL,
        shouldStartPlaying: Bool
    ) -> Bool {
        guard matches(trackID: candidateID, url: candidateURL) else {
            return false
        }
        deferredShouldStartPlaying = shouldStartPlaying
        return true
    }

    mutating func requestPlaying() -> Bool {
        guard deferredShouldStartPlaying != nil else { return false }
        deferredShouldStartPlaying = true
        return true
    }

    @discardableResult
    mutating func seedDeferredPlayback(
        trackID candidateID: Int64?,
        url candidateURL: URL,
        shouldStartPlaying: Bool
    ) -> Bool {
        guard deferredShouldStartPlaying == nil,
              matches(trackID: candidateID, url: candidateURL) else {
            return false
        }
        deferredShouldStartPlaying = shouldStartPlaying
        return true
    }

    mutating func requestPaused() -> Bool {
        guard deferredShouldStartPlaying != nil else { return false }
        deferredShouldStartPlaying = false
        return true
    }

    mutating func toggle() -> Bool {
        guard let shouldStartPlaying = deferredShouldStartPlaying else {
            return false
        }
        deferredShouldStartPlaying = !shouldStartPlaying
        return true
    }

    mutating func requestStop() -> Bool {
        guard deferredShouldStartPlaying != nil else { return false }
        deferredShouldStartPlaying = nil
        return true
    }

    mutating func takeDeferredPlayback() -> Bool? {
        defer { deferredShouldStartPlaying = nil }
        return deferredShouldStartPlaying
    }
}
