import Foundation

/// A single, small, well-tested click/pop reduction pass (docs/ROADMAP.md M10) — deliberately not
/// a general restoration suite. Detects isolated single-sample impulses (the kind of transient
/// spike a stylus produces on a surface defect) by comparing each sample against the linear
/// interpolation of its neighbors, flags it as a click if that deviation is a large outlier
/// relative to the local neighborhood, and replaces it with that interpolated value.
enum Declicker {
    struct Result {
        let samples: [Float]
        let clicksFixed: Int
    }

    /// `windowRadius` samples on each side are used to establish the local "normal" deviation
    /// magnitude (via median, so a handful of nearby loud transients don't skew the threshold).
    /// `thresholdMultiplier` controls how far outside that local norm a sample must fall before
    /// it's treated as a click rather than legitimate signal.
    static func declick(_ input: [Float], windowRadius: Int = 12, thresholdMultiplier: Float = 8.0) -> Result {
        guard input.count > windowRadius * 2 + 2 else { return Result(samples: input, clicksFixed: 0) }

        var deviations = [Float](repeating: 0, count: input.count)
        for i in 1..<(input.count - 1) {
            let predicted = (input[i - 1] + input[i + 1]) / 2
            deviations[i] = abs(input[i] - predicted)
        }

        var output = input
        var clicksFixed = 0

        for i in 1..<(input.count - 1) {
            // A single-sample spike inflates the interpolation error at its immediate neighbors
            // too (their "predicted" value leans on the corrupted sample) — requiring `i` to be a
            // local maximum of deviation keeps the fix localized to the actual spike instead of
            // also mangling the two samples next to it.
            guard deviations[i] >= deviations[i - 1], deviations[i] >= deviations[i + 1] else { continue }

            let lowerBound = max(1, i - windowRadius)
            let upperBound = min(input.count - 2, i + windowRadius)
            var neighborhood: [Float] = []
            neighborhood.reserveCapacity(upperBound - lowerBound)
            for j in lowerBound...upperBound where j != i {
                neighborhood.append(deviations[j])
            }
            guard !neighborhood.isEmpty else { continue }

            let localNorm = median(of: neighborhood)
            let threshold = max(localNorm * thresholdMultiplier, 0.001)
            if deviations[i] > threshold {
                output[i] = (input[i - 1] + input[i + 1]) / 2
                clicksFixed += 1
            }
        }

        return Result(samples: output, clicksFixed: clicksFixed)
    }

    private static func median(of values: [Float]) -> Float {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
