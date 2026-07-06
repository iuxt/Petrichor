import Foundation

/// Shared EQ headroom policy used by playback backends.
///
/// Positive EQ boosts consume digital headroom before the signal reaches the
/// output path. Offset the largest boost, plus a small safety margin, so the
/// user-facing preamp can remain stable while the backend feeds a safer
/// effective gain to its engine.
///
/// Extracted to its own file so it can be unit-tested without pulling in the
/// full `PlaybackEngine` / backend dependency graph.
enum EqualizerHeadroomCompensation {
    static func gainOffset(eqEnabled: Bool, gains: [Float]) -> Float {
        guard eqEnabled else { return 0 }

        let maxBandGain = gains.max() ?? 0
        if maxBandGain > 0 {
            return -(maxBandGain + 1.0)
        }
        return 0
    }
}
