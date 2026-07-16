import Combine
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

enum KaraokeLineBoundaries {
    static func all(in lines: [LyricLine]) -> [TimeInterval] {
        let sorted = lines.flatMap { line -> [TimeInterval] in
            var values = line.startTime.isFinite ? [line.startTime] : []
            if let endTime = line.endTime, endTime.isFinite {
                values.append(endTime)
            }
            return values
        }.sorted()

        return sorted.reduce(into: []) { boundaries, boundary in
            if boundaries.last != boundary {
                boundaries.append(boundary)
            }
        }
    }

    static func next(after playbackTime: TimeInterval, in lines: [LyricLine]) -> TimeInterval? {
        all(in: lines).first { $0 > playbackTime }
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

    func reanchored(
        at instant: ContinuousClock.Instant,
        isPlaying: Bool,
        upperBound: TimeInterval?
    ) -> KaraokePlaybackTimeAnchor {
        KaraokePlaybackTimeAnchor(
            sampleTime: time(at: instant, upperBound: upperBound),
            sampleInstant: instant,
            isPlaying: isPlaying
        )
    }
}

@MainActor
final class KaraokeLineBoundaryScheduler: ObservableObject {
    private let clock = ContinuousClock()
    private var anchor: KaraokePlaybackTimeAnchor
    private var task: Task<Void, Never>?

    init() {
        let now = clock.now
        anchor = KaraokePlaybackTimeAnchor(sampleTime: 0, sampleInstant: now, isPlaying: false)
    }

    deinit {
        task?.cancel()
    }

    func reset(
        sampleTime: TimeInterval,
        isPlaying: Bool,
        lines: [LyricLine],
        isKaraoke: Bool,
        onBoundary: @escaping @MainActor (TimeInterval) -> Void
    ) {
        let now = clock.now
        anchor = KaraokePlaybackTimeAnchor(
            sampleTime: sampleTime,
            sampleInstant: now,
            isPlaying: isPlaying
        )
        schedule(lines: lines, isKaraoke: isKaraoke, onBoundary: onBoundary)
    }

    @discardableResult
    func transition(
        isPlaying: Bool,
        lines: [LyricLine],
        isKaraoke: Bool,
        onBoundary: @escaping @MainActor (TimeInterval) -> Void
    ) -> TimeInterval {
        let now = clock.now
        anchor = anchor.reanchored(at: now, isPlaying: isPlaying, upperBound: nil)
        schedule(lines: lines, isKaraoke: isKaraoke, onBoundary: onBoundary)
        return anchor.sampleTime
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func schedule(
        lines: [LyricLine],
        isKaraoke: Bool,
        onBoundary: @escaping @MainActor (TimeInterval) -> Void
    ) {
        cancel()
        guard isKaraoke, anchor.isPlaying else { return }

        let scheduledAnchor = anchor
        let boundaries = KaraokeLineBoundaries.all(in: lines)
        let clock = clock
        task = Task { @MainActor in
            for boundary in boundaries where boundary > scheduledAnchor.sampleTime {
                guard !Task.isCancelled else { return }
                let delay = max(0, boundary - scheduledAnchor.sampleTime)
                let deadline = scheduledAnchor.sampleInstant.advanced(by: .seconds(delay))
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                onBoundary(boundary)
            }
        }
    }
}
