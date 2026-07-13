import Foundation

/// Applies a short linear fade-in/fade-out at track boundaries during export (docs/FEATURES.md
/// §2) — a second line of defense against clicks at cut points, independent of zero-crossing
/// snapping in the editor.
///
/// The chunk-based form exists so the export pipeline can stream a track without holding it all
/// in memory (docs/IMPROVEMENT_PLAN.md P1-2): a fade only ever touches the first and last
/// `fadeSampleCount` samples, so each streamed chunk just needs to know its own offset within
/// the track.
enum FadeApplier {
    /// Applies fades in place to one chunk of a longer track. `chunkStartIndex` is the chunk's
    /// first sample's index within the whole track of `totalSampleCount` samples. The fade
    /// length is clamped to at most half the track so fade-in and fade-out never overlap.
    static func applyFades(
        to chunk: inout [Float],
        chunkStartIndex: Int64,
        totalSampleCount: Int64,
        fadeSampleCount: Int
    ) {
        guard fadeSampleCount > 0, totalSampleCount > 0, !chunk.isEmpty else { return }
        let clamped = Int64(min(Int64(fadeSampleCount), totalSampleCount / 2))
        guard clamped > 0 else { return }

        let fadeOutStart = totalSampleCount - clamped
        for offset in 0..<chunk.count {
            let globalIndex = chunkStartIndex + Int64(offset)
            if globalIndex < clamped {
                chunk[offset] *= Float(globalIndex) / Float(clamped)
            } else if globalIndex >= fadeOutStart {
                chunk[offset] *= Float(totalSampleCount - 1 - globalIndex) / Float(clamped)
            }
        }
    }

    /// Whole-array convenience (also the reference the chunked form is tested against).
    static func applyFades(to samples: [Float], fadeSampleCount: Int) -> [Float] {
        var output = samples
        applyFades(to: &output, chunkStartIndex: 0, totalSampleCount: Int64(samples.count), fadeSampleCount: fadeSampleCount)
        return output
    }

    static func sampleCount(forDurationSeconds seconds: Double, sampleRate: Double) -> Int {
        guard seconds > 0, sampleRate > 0 else { return 0 }
        return Int((seconds * sampleRate).rounded())
    }
}
