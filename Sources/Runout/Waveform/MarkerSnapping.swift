import AVFoundation
import Foundation

/// Snaps a candidate marker position to the nearest zero-crossing, so splitting a recording at
/// that sample doesn't produce an audible click — see docs/FEATURES.md §2.
enum MarkerSnapping {
    /// ~50ms at 44.1kHz; scales fine for higher sample rates too, since it only needs to be
    /// "a bit more than one full wave cycle" for typical audio, not sample-rate-proportional.
    static let defaultSearchWindowInSamples = 2205

    /// Pure and unit-testable: the index within `samples` closest to `targetIndex` where the
    /// signal crosses zero (a sign change between consecutive samples), searching outward in
    /// both directions. Returns `targetIndex` unchanged if no crossing exists in the array.
    static func nearestZeroCrossingIndex(in samples: [Float], around targetIndex: Int) -> Int {
        guard samples.indices.contains(targetIndex) else { return targetIndex }
        if isZeroCrossing(samples, at: targetIndex) { return targetIndex }

        var offset = 1
        while targetIndex - offset >= 0 || targetIndex + offset < samples.count {
            let after = targetIndex + offset
            if after < samples.count, isZeroCrossing(samples, at: after) { return after }
            let before = targetIndex - offset
            if before >= 0, isZeroCrossing(samples, at: before) { return before }
            offset += 1
        }
        return targetIndex
    }

    private static func isZeroCrossing(_ samples: [Float], at index: Int) -> Bool {
        guard index > 0, index < samples.count else { return false }
        let previous = samples[index - 1]
        let current = samples[index]
        return (previous <= 0 && current > 0) || (previous >= 0 && current < 0)
    }

    /// Reads a small real-audio window around `targetSample` from `fileURL` and returns the
    /// nearest zero-crossing, translated back into the file's own sample coordinate space.
    /// Returns `nil` if the file can't be read (caller should fall back to the unsnapped sample).
    static func nearestZeroCrossing(
        toSample targetSample: Int64,
        fileURL: URL,
        searchWindow: Int = defaultSearchWindowInSamples
    ) -> Int64? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }

        let windowStart = max(0, targetSample - Int64(searchWindow))
        let windowLength = min(Int64(searchWindow * 2), file.length - windowStart)
        guard windowLength > 0 else { return nil }

        file.framePosition = windowStart
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(windowLength))
        else { return nil }
        do {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(windowLength))
        } catch {
            return nil
        }
        guard let channelData = buffer.floatChannelData else { return nil }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(file.processingFormat.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

        // Mono-mixdown, matching how the waveform/peak cache treats multi-channel audio.
        var mono = [Float](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channelData[channel][frame] }
            mono[frame] = sum / Float(channelCount)
        }

        let targetIndexInWindow = Int(targetSample - windowStart)
        let snappedIndex = nearestZeroCrossingIndex(in: mono, around: targetIndexInWindow)
        return windowStart + Int64(snappedIndex)
    }
}
