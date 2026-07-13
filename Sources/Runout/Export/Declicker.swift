import Foundation

/// A single, small, well-tested click/pop reduction pass (docs/ROADMAP.md M10) — deliberately not
/// a general restoration suite. Detects isolated single-sample impulses (the kind of transient
/// spike a stylus produces on a surface defect) by comparing each sample against the linear
/// interpolation of its neighbors, flagging it as a click when that deviation is a large outlier
/// and a local maximum, and replacing it with the interpolated value.
///
/// The outlier threshold is computed once per `blockSize`-sample block (median of the block's
/// deviations × `thresholdMultiplier`) rather than per-sample — the per-sample ±12-neighbor
/// median the first version used made declicking a full side take minutes
/// (docs/IMPROVEMENT_PLAN.md P1-3). `StreamingDeclicker` below produces byte-identical results
/// chunk-by-chunk so the export pipeline never needs the whole track in memory (P1-2).
enum Declicker {
    static let blockSize = 4096
    static let defaultThresholdMultiplier: Float = 8.0
    /// Deviations this small are quantization-level noise, not clicks — a silent passage's
    /// median would otherwise make the threshold absurdly sensitive.
    static let minimumThreshold: Float = 0.001

    struct Result {
        let samples: [Float]
        let clicksFixed: Int
    }

    /// Whole-array form — also the reference `StreamingDeclicker` is tested against.
    static func declick(_ input: [Float], thresholdMultiplier: Float = defaultThresholdMultiplier) -> Result {
        guard input.count >= 5 else { return Result(samples: input, clicksFixed: 0) }

        let deviations = Self.deviations(of: input)
        var thresholds: [Float] = []
        var blockStart = 0
        while blockStart < input.count {
            let blockEnd = min(blockStart + blockSize, input.count)
            thresholds.append(threshold(forBlock: Array(deviations[blockStart..<blockEnd]), multiplier: thresholdMultiplier))
            blockStart = blockEnd
        }

        var output = input
        var clicksFixed = 0
        for i in 1..<(input.count - 1) where isClick(at: i, deviations: deviations, threshold: thresholds[i / blockSize]) {
            output[i] = (input[i - 1] + input[i + 1]) / 2
            clicksFixed += 1
        }
        return Result(samples: output, clicksFixed: clicksFixed)
    }

    // MARK: - Shared pieces (used by both forms; must stay in lockstep for equivalence)

    /// `d[i] = |x[i] − (x[i−1]+x[i+1])/2|`, with the two edge samples defined as 0.
    static func deviations(of samples: [Float]) -> [Float] {
        var deviations = [Float](repeating: 0, count: samples.count)
        for i in 1..<(samples.count - 1) {
            deviations[i] = abs(samples[i] - (samples[i - 1] + samples[i + 1]) / 2)
        }
        return deviations
    }

    static func threshold(forBlock blockDeviations: [Float], multiplier: Float) -> Float {
        max(median(of: blockDeviations) * multiplier, minimumThreshold)
    }

    /// A click is a deviation outlier that's also a local maximum — a single-sample spike also
    /// inflates its neighbors' deviations (their interpolation leans on the corrupted sample),
    /// and the local-max requirement keeps the fix on the actual spike.
    static func isClick(at i: Int, deviations: [Float], threshold: Float) -> Bool {
        deviations[i] >= deviations[i - 1]
            && deviations[i] >= deviations[i + 1]
            && deviations[i] > threshold
    }

    private static func median(of values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}

/// Chunk-by-chunk declicking with output byte-identical to `Declicker.declick` on the
/// concatenated input. Holds at most ~one block plus a few context samples in memory: a
/// position is emitted only once its own deviation, both neighbors' deviations, and its
/// block's threshold are final — so emission lags input by at most `blockSize + 2` samples.
final class StreamingDeclicker {
    private let multiplier: Float

    /// Samples not yet emitted, preceded by up to 2 already-emitted context samples.
    private var window: [Float] = []
    /// Global index of `window[0]`.
    private var windowStart: Int64 = 0
    /// Global index of the next sample to emit.
    private var nextToEmit: Int64 = 0
    /// Total samples received so far.
    private var received: Int64 = 0
    private(set) var clicksFixed = 0

    init(thresholdMultiplier: Float = Declicker.defaultThresholdMultiplier) {
        multiplier = thresholdMultiplier
    }

    /// Feeds one chunk; returns whatever output became final. Output across all `process` calls
    /// plus the final `flush()` concatenates to exactly the whole-array result.
    func process(_ chunk: [Float]) -> [Float] {
        window.append(contentsOf: chunk)
        received += Int64(chunk.count)

        // A position p needs x[p+2] for its neighbor's deviation (all inputs strictly before
        // p+2 ≤ received-1), and its block finalized: deviations through the block's last
        // sample need x[blockEnd], so block b is final once received > (b+1)*blockSize.
        let lastFinalizedBlock = (received - 1) / Int64(Declicker.blockSize) - 1
        guard lastFinalizedBlock >= 0 else { return [] }
        let emitLimit = min(received - 3, (lastFinalizedBlock + 1) * Int64(Declicker.blockSize) - 1)
        return emit(through: emitLimit, isFinal: false)
    }

    /// Ends the stream and returns all remaining output.
    func flush() -> [Float] {
        emit(through: received - 1, isFinal: true)
    }

    private func emit(through lastGlobal: Int64, isFinal: Bool) -> [Float] {
        guard lastGlobal >= nextToEmit else { return [] }

        // Inputs shorter than 5 samples are returned unchanged, matching the whole-array form.
        if isFinal && received < 5 {
            let output = Array(window[Int(nextToEmit - windowStart)...])
            nextToEmit = received
            return output
        }

        // Deviations for the whole window: window[0] may be mid-track (its true deviation needs
        // a sample we've dropped), but positions at global index < windowStart+1 are never
        // re-examined — only ever read as d[p-1] context, and we always keep 2 emitted samples,
        // so every d value actually consulted is exact. Global edge samples come out as 0 here
        // because their neighbors are absent from the window only at the true track edges.
        //
        // The whole-array deviations for window[0]/window.last are 0 by definition; positions
        // whose TRUE deviation must read as 0 are the global track edges (0 and received-1),
        // which coincide with window edges exactly when they're in the window — so plain local
        // indexing below needs no per-sample global-edge branches. (This loop runs once per
        // exported sample; keep it free of closures and per-sample Int64 division.)
        let localDeviations = Declicker.deviations(of: window)
        let emitCount = Int(lastGlobal - nextToEmit + 1)
        var output = [Float](repeating: 0, count: emitCount)
        let blockSize = Int64(Declicker.blockSize)
        var fixed = 0

        window.withUnsafeBufferPointer { x in
            localDeviations.withUnsafeBufferPointer { d in
                output.withUnsafeMutableBufferPointer { out in
                    var p = nextToEmit
                    var outIndex = 0
                    while p <= lastGlobal {
                        // Threshold for p's block; positions are emitted in order, so one block
                        // ends exactly where the next begins.
                        let block = p / blockSize
                        let blockStart = block * blockSize
                        let blockEnd = Swift.min(blockStart + blockSize, received)
                        let blockDeviations = Array(d[Int(blockStart - windowStart)..<Int(blockEnd - windowStart)])
                        let threshold = Declicker.threshold(forBlock: blockDeviations, multiplier: multiplier)

                        let runEnd = Swift.min(lastGlobal, blockEnd - 1)
                        var local = Int(p - windowStart)
                        let runCount = Int(runEnd - p + 1)
                        for _ in 0..<runCount {
                            let dev = d[local]
                            if dev > threshold, local > 0, local < d.count - 1,
                               dev >= d[local - 1], dev >= d[local + 1] {
                                out[outIndex] = (x[local - 1] + x[local + 1]) / 2
                                fixed += 1
                            } else {
                                out[outIndex] = x[local]
                            }
                            local += 1
                            outIndex += 1
                        }
                        p = runEnd + 1
                    }
                }
            }
        }
        clicksFixed += fixed

        nextToEmit = lastGlobal + 1
        // Keep enough context for the next call: deviations d[p-1] reach back to x[p-2], and if
        // emission stopped mid-block, recomputing that block's median needs the whole block —
        // whose first deviation reads x[blockStart-1]. Still bounded (≤ blockSize + 2 samples).
        let nextBlockStart = (nextToEmit / Int64(Declicker.blockSize)) * Int64(Declicker.blockSize)
        let keepFromGlobal = max(windowStart, min(nextToEmit - 2, nextBlockStart - 1))
        window.removeFirst(Int(keepFromGlobal - windowStart))
        windowStart = keepFromGlobal
        return output
    }
}
