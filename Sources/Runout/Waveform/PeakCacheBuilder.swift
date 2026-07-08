import AVFoundation
import Foundation

/// Generates the multi-resolution min/max peak cache (see `PeakCache`) from a finished recording.
/// Streams the file in bounded-size chunks rather than loading a full ~20-minute side into memory.
enum PeakCacheBuilder {
    static let samplesPerBucketAtFinestLevel = 256
    /// Stop halving once a level would have this few buckets or fewer — no point going coarser.
    static let minimumBucketCountForCoarsestLevel = 64
    private static let readChunkSizeInFrames: AVAudioFrameCount = 1 << 20

    static func build(fromFileAt url: URL) throws -> PeakCache {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)

        guard file.length > 0, channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readChunkSizeInFrames)
        else {
            return PeakCache(samplesPerBucketAtFinestLevel: samplesPerBucketAtFinestLevel, levels: [[]])
        }

        var finestBuckets: [PeakBucket] = []
        finestBuckets.reserveCapacity(Int(file.length) / samplesPerBucketAtFinestLevel + 1)

        var pendingMin: Float = .greatestFiniteMagnitude
        var pendingMax: Float = -.greatestFiniteMagnitude
        var samplesInPendingBucket = 0

        // Pass the exact remaining frame count rather than always requesting a full chunk —
        // requesting more than remains has been observed to throw rather than clamp on some
        // AVFoundation versions, despite Apple's docs describing the latter.
        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let framesToRead = AVAudioFrameCount(Swift.min(Int64(readChunkSizeInFrames), remaining))
            try file.read(into: buffer, frameCount: framesToRead)
            let framesRead = Int(buffer.frameLength)
            if framesRead == 0 { break }
            guard let channelData = buffer.floatChannelData else { break }

            for frame in 0..<framesRead {
                // Mono-mixdown for display purposes: widest excursion across channels wins.
                var sampleMin: Float = channelData[0][frame]
                var sampleMax: Float = sampleMin
                for channel in 1..<channelCount {
                    let sample = channelData[channel][frame]
                    if sample < sampleMin { sampleMin = sample }
                    if sample > sampleMax { sampleMax = sample }
                }

                if sampleMin < pendingMin { pendingMin = sampleMin }
                if sampleMax > pendingMax { pendingMax = sampleMax }
                samplesInPendingBucket += 1

                if samplesInPendingBucket == samplesPerBucketAtFinestLevel {
                    finestBuckets.append(PeakBucket(min: quantize(pendingMin), max: quantize(pendingMax)))
                    pendingMin = .greatestFiniteMagnitude
                    pendingMax = -.greatestFiniteMagnitude
                    samplesInPendingBucket = 0
                }
            }
        }

        if samplesInPendingBucket > 0 {
            finestBuckets.append(PeakBucket(min: quantize(pendingMin), max: quantize(pendingMax)))
        }

        return PeakCache(samplesPerBucketAtFinestLevel: samplesPerBucketAtFinestLevel, levels: mipLevels(from: finestBuckets))
    }

    /// Builds each coarser level by merging adjacent pairs of the previous level — never
    /// recomputing from raw audio, per docs/DATA_MODEL.md.
    private static func mipLevels(from finest: [PeakBucket]) -> [[PeakBucket]] {
        var levels = [finest]
        var current = finest
        while current.count > minimumBucketCountForCoarsestLevel {
            var next: [PeakBucket] = []
            next.reserveCapacity((current.count + 1) / 2)
            var index = 0
            while index < current.count {
                if index + 1 < current.count {
                    let a = current[index]
                    let b = current[index + 1]
                    next.append(PeakBucket(min: Swift.min(a.min, b.min), max: Swift.max(a.max, b.max)))
                } else {
                    next.append(current[index])
                }
                index += 2
            }
            levels.append(next)
            current = next
        }
        return levels
    }

    private static func quantize(_ sample: Float) -> Int16 {
        let clamped = Swift.max(-1, Swift.min(1, sample))
        return Int16(clamped * Float(Int16.max))
    }
}
