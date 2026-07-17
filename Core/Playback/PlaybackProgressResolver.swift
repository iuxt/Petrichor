import Foundation

struct PlaybackProgressResolution: Equatable {
    enum Transition: Equatable {
        case none
        case enteredFallback
        case recovered
    }

    let progress: TimeInterval?
    let transition: Transition
}

struct PlaybackProgressResolver {
    private(set) var isUsingFallback = false
    private var consecutiveStalledSamples = 0

    mutating func resolve(
        engineProgress: TimeInterval,
        previousEngineProgress: TimeInterval?,
        displayedProgress: TimeInterval,
        elapsed: TimeInterval,
        duration: TimeInterval,
        playbackIsActive: Bool,
        tolerance: TimeInterval = 0.05
    ) -> PlaybackProgressResolution {
        guard engineProgress.isFinite, engineProgress >= 0 else {
            return PlaybackProgressResolution(progress: nil, transition: .none)
        }

        let safeDisplayedProgress = displayedProgress.isFinite
            ? max(0, displayedProgress)
            : engineProgress
        let safeElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let safeTolerance = tolerance.isFinite ? max(0, tolerance) : 0

        guard playbackIsActive else {
            let transition: PlaybackProgressResolution.Transition =
                isUsingFallback ? .recovered : .none
            isUsingFallback = false
            consecutiveStalledSamples = 0
            return PlaybackProgressResolution(
                progress: clamped(engineProgress, duration: duration),
                transition: transition
            )
        }

        guard let previousEngineProgress, previousEngineProgress.isFinite else {
            consecutiveStalledSamples = 0
            return PlaybackProgressResolution(
                progress: clamped(engineProgress, duration: duration),
                transition: .none
            )
        }

        let engineAdvanced = engineProgress > previousEngineProgress + safeTolerance
        if engineAdvanced {
            if isUsingFallback,
               engineProgress + safeTolerance < safeDisplayedProgress {
                return PlaybackProgressResolution(
                    progress: clamped(
                        safeDisplayedProgress + safeElapsed,
                        duration: duration
                    ),
                    transition: .none
                )
            }

            let transition: PlaybackProgressResolution.Transition =
                isUsingFallback ? .recovered : .none
            isUsingFallback = false
            consecutiveStalledSamples = 0
            return PlaybackProgressResolution(
                progress: clamped(
                    max(engineProgress, safeDisplayedProgress),
                    duration: duration
                ),
                transition: transition
            )
        }

        consecutiveStalledSamples += 1
        guard consecutiveStalledSamples >= 2 else {
            return PlaybackProgressResolution(
                progress: clamped(
                    max(engineProgress, safeDisplayedProgress),
                    duration: duration
                ),
                transition: .none
            )
        }

        let transition: PlaybackProgressResolution.Transition =
            isUsingFallback ? .none : .enteredFallback
        isUsingFallback = true
        return PlaybackProgressResolution(
            progress: clamped(
                safeDisplayedProgress + safeElapsed,
                duration: duration
            ),
            transition: transition
        )
    }

    mutating func reset() {
        isUsingFallback = false
        consecutiveStalledSamples = 0
    }

    private func clamped(
        _ progress: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        let nonnegativeProgress = max(0, progress)
        guard duration.isFinite, duration > 0 else {
            return nonnegativeProgress
        }
        return min(nonnegativeProgress, duration)
    }
}
