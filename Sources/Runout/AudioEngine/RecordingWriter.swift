import AVFoundation
import Foundation

/// Background actor that writes tapped audio buffers to disk.
///
/// Never call `append` directly from the real-time tap callback with the tap's own buffer —
/// copy it first (see `AVAudioPCMBuffer.copy()` below) and hand the copy off via `Task { }`, so
/// the tap thread's only job is a fast memcpy, never a blocking disk write. See
/// docs/ARCHITECTURE.md (Concurrency model) for why this matters.
///
/// M1 writes plain PCM (CAF container); native FLAC output lands in M2.
actor RecordingWriter {
    private var audioFile: AVAudioFile?
    private(set) var framesWritten: AVAudioFramePosition = 0

    func start(url: URL, format: AVAudioFormat) throws {
        audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        framesWritten = 0
    }

    /// Appends one buffer. Pass only buffers already copied off the tap thread.
    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let audioFile else { return }
        try audioFile.write(from: buffer)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
    }

    /// Stops writing and releases the file handle. Safe to call even if never started.
    func stop() {
        audioFile = nil
    }
}

extension AVAudioPCMBuffer {
    /// A deep copy safe to retain past the lifetime of a tap callback's buffer, which the
    /// audio engine may reuse or deallocate as soon as the callback returns.
    func copy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        copy.frameLength = frameLength
        let channelCount = Int(format.channelCount)
        let count = Int(frameLength)

        if let src = floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<channelCount { dst[channel].update(from: src[channel], count: count) }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0..<channelCount { dst[channel].update(from: src[channel], count: count) }
        } else if let src = int32ChannelData, let dst = copy.int32ChannelData {
            for channel in 0..<channelCount { dst[channel].update(from: src[channel], count: count) }
        }
        return copy
    }
}
