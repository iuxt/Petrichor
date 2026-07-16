import Foundation

enum KaraokeTiming {
    static func fillFractions(for line: LyricLine, at playbackTime: TimeInterval) -> [Double]? {
        guard let segments = line.timingSegments, !segments.isEmpty else { return nil }
        if let endTime = line.endTime, playbackTime >= endTime {
            return Array(repeating: 1, count: segments.count)
        }

        let localTime = playbackTime - line.startTime
        return segments.map { segment in
            if localTime < segment.startOffset { return 0 }
            if segment.duration == 0 { return 1 }
            return min(1, max(0, (localTime - segment.startOffset) / segment.duration))
        }
    }
}

struct KaraokePlaybackTimeAnchor: Sendable {
    let sampleTime: TimeInterval
    let sampleInstant: ContinuousClock.Instant
    let isPlaying: Bool

    func time(
        at instant: ContinuousClock.Instant,
        upperBound: TimeInterval?
    ) -> TimeInterval {
        let elapsed: TimeInterval
        if isPlaying {
            let components = sampleInstant.duration(to: instant).components
            elapsed = max(0, Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000)
        } else {
            elapsed = 0
        }

        let interpolated = max(0, sampleTime + elapsed)
        return upperBound.map { min(interpolated, $0) } ?? interpolated
    }
}
