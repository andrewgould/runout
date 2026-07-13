import AVFoundation
import Foundation

enum AudioFormatConverterError: Error, LocalizedError {
    case couldNotCreateConverter
    case conversionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateConverter: return "Couldn't set up sample rate/channel conversion for the selected format."
        case .conversionFailed(let error): return "Audio format conversion failed: \(error.localizedDescription)"
        }
    }
}

/// Converts tapped buffers from a device's native format to the user's chosen recording format
/// (sample rate × channel count — see docs/FEATURES.md §1, docs/IMPROVEMENT_PLAN.md P2-1).
/// Bit depth isn't handled here: that's applied by `RecordingWriter`/`FlacSettings` at FLAC
/// encode time, downstream of this converter.
///
/// Not used on the real-time tap thread — conversion runs in `OrderedBufferFeed`'s consumer task,
/// keeping the tap callback itself limited to metering + a cheap buffer copy.
final class AudioFormatConverter {
    private let converter: AVAudioConverter
    let outputFormat: AVAudioFormat

    init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioFormatConverterError.couldNotCreateConverter
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        // Sample rate changes can grow the frame count; overallocate generously rather than
        // compute an exact ratio, since a single conversion call can under-fill this buffer.
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioFormatConverterError.couldNotCreateConverter
        }

        var error: NSError?
        var suppliedInput = false
        converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if let error {
            throw AudioFormatConverterError.conversionFailed(error)
        }
        return outputBuffer
    }
}
