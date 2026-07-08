import AVFoundation
import Foundation

/// Shared `AVAudioFile` settings for writing native FLAC (`kAudioFormatFLAC`, supported by Core
/// Audio since macOS 11 / iOS 14 — no vendored libFLAC, see docs/ARCHITECTURE.md). Used by both
/// `RecordingWriter` (the live tap) and `ExportPipeline` (slicing tracks out of a master
/// recording), so the two never drift on what "writing a FLAC file" means in this app.
enum FlacSettings {
    static func writingSettings(sampleRate: Double, channelCount: AVAudioChannelCount, bitDepth: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
    }
}
