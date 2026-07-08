import AVFoundation
import Foundation

/// One channel's current level reading. `isClipping` latches (stays true) once 0dBFS is hit,
/// until explicitly cleared — see docs/FEATURES.md §1 on why a momentary clip must not be missed.
struct ChannelLevel: Equatable {
    var peakDecibels: Float
    var rmsDecibels: Float
    var isClipping: Bool

    static let silent = ChannelLevel(peakDecibels: -.infinity, rmsDecibels: -.infinity, isClipping: false)
}

/// Running peak/RMS calculation and latched clip detection for one or more channels.
/// The sample math (`measure`, `amplitudeToDecibels`) is pure and unit-testable without
/// constructing a real `AVAudioPCMBuffer`.
///
/// `process(_:)` is called from the real-time tap thread; `channelLevels` is read from the
/// main thread (e.g. by a UI refresh timer at ~15-30Hz). Both are guarded by `lock` since this
/// is the one piece of mutable state shared across that boundary.
final class LevelMeter {
    private let lock = NSLock()
    private var _channelLevels: [ChannelLevel] = []

    var channelLevels: [ChannelLevel] {
        lock.lock()
        defer { lock.unlock() }
        return _channelLevels
    }

    /// Peak and RMS amplitude, converted to dBFS, for one channel's samples.
    /// Returns -infinity dBFS for a silent (or empty) buffer.
    static func measure(samples: UnsafeBufferPointer<Float>) -> (peakDecibels: Float, rmsDecibels: Float) {
        guard !samples.isEmpty else { return (-.infinity, -.infinity) }
        var peak: Float = 0
        var sumOfSquares: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()
        return (amplitudeToDecibels(peak), amplitudeToDecibels(rms))
    }

    static func amplitudeToDecibels(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return -.infinity }
        return 20 * log10(amplitude)
    }

    /// Processes one tapped buffer, updating `channelLevels` (including the clip latch).
    /// Cheap enough to call directly from the recording tap callback — see RecordingWriter.
    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        lock.lock()
        defer { lock.unlock() }

        if _channelLevels.count != channelCount {
            _channelLevels = Array(repeating: ChannelLevel.silent, count: channelCount)
        }

        for channel in 0..<channelCount {
            let pointer = UnsafeBufferPointer(start: channelData[channel], count: frameLength)
            let (peakDB, rmsDB) = Self.measure(samples: pointer)
            var level = _channelLevels[channel]
            level.peakDecibels = peakDB
            level.rmsDecibels = rmsDB
            if peakDB >= 0 { level.isClipping = true }
            _channelLevels[channel] = level
        }
    }

    /// Clears the latched clip indicator for every channel (an explicit user action, never automatic).
    func clearClipIndicators() {
        lock.lock()
        defer { lock.unlock() }
        for index in _channelLevels.indices {
            _channelLevels[index].isClipping = false
        }
    }
}
