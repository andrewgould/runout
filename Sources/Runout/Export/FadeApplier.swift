import Foundation

/// Applies a short linear fade-in/fade-out at track boundaries during export (docs/FEATURES.md
/// §2) — a second line of defense against clicks at cut points, independent of zero-crossing
/// snapping in the editor.
enum FadeApplier {
    /// Applies fades to `samples` in place, returning the modified array. `fadeSampleCount` is
    /// clamped to at most half the track's length so a fade-in and fade-out never overlap.
    static func applyFades(to samples: [Float], fadeSampleCount: Int) -> [Float] {
        guard fadeSampleCount > 0, !samples.isEmpty else { return samples }

        let clampedCount = min(fadeSampleCount, samples.count / 2)
        guard clampedCount > 0 else { return samples }

        var output = samples
        for i in 0..<clampedCount {
            let gain = Float(i) / Float(clampedCount)
            output[i] *= gain
        }
        for i in 0..<clampedCount {
            let gain = Float(i) / Float(clampedCount)
            output[output.count - 1 - i] *= gain
        }
        return output
    }

    static func sampleCount(forDurationSeconds seconds: Double, sampleRate: Double) -> Int {
        guard seconds > 0, sampleRate > 0 else { return 0 }
        return Int((seconds * sampleRate).rounded())
    }
}
