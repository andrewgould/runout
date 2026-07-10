import Foundation

/// Proposes track-break markers from gaps below a configurable dBFS threshold, using the
/// recording's already-computed `PeakCache` rather than re-scanning raw audio. Proposals are for
/// the user to review/accept/reject in the UI — never auto-committed, see docs/FEATURES.md §2.
enum SilenceDetector {
    static let defaultThresholdDecibels: Float = -40
    static let defaultMinimumGapDuration: Double = 2.0

    /// Scans the peak cache's finest resolution level for runs of consecutive buckets whose peak
    /// stays below `thresholdDecibels` for at least `minimumGapDuration` seconds, proposing one
    /// marker at the midpoint of each such run. A gap that runs to the very end of the recording
    /// is not proposed (that's trailing silence, not a break between two tracks).
    static func detectTrackBreaks(
        in peakCache: PeakCache,
        sampleRate: Double,
        thresholdDecibels: Float = defaultThresholdDecibels,
        minimumGapDuration: Double = defaultMinimumGapDuration
    ) -> [Marker] {
        guard let finestLevel = peakCache.levels.first, !finestLevel.isEmpty, sampleRate > 0 else { return [] }
        let bucketSize = peakCache.samplesPerBucketAtFinestLevel
        guard bucketSize > 0 else { return [] }

        let thresholdQuantized = quantizedThreshold(forDecibels: thresholdDecibels)
        let minimumGapBuckets = max(1, Int((minimumGapDuration * sampleRate) / Double(bucketSize)))

        var markers: [Marker] = []
        var silenceStartBucket: Int?

        for (index, bucket) in finestLevel.enumerated() {
            let peak = max(abs(Int(bucket.min)), abs(Int(bucket.max)))
            let isSilent = peak < thresholdQuantized

            if isSilent {
                if silenceStartBucket == nil { silenceStartBucket = index }
            } else if let start = silenceStartBucket {
                let gapBucketCount = index - start
                if gapBucketCount >= minimumGapBuckets {
                    let midpointBucket = start + gapBucketCount / 2
                    markers.append(Marker(sampleOffset: Int64(midpointBucket) * Int64(bucketSize)))
                }
                silenceStartBucket = nil
            }
        }

        return markers
    }

    /// Converts a dBFS threshold to the quantized Int16 scale `PeakBucket` values use.
    static func quantizedThreshold(forDecibels decibels: Float) -> Int {
        let amplitude = pow(10, decibels / 20)
        return Int(amplitude * Float(Int16.max))
    }
}
