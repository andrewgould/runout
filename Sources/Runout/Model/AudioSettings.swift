import Foundation

/// See docs/DATA_MODEL.md.
struct AudioSettings: Codable, Equatable {
    var sampleRate: Double
    var bitDepth: Int
    var channelCount: Int
    var inputDeviceUID: String

    static let defaultSettings = AudioSettings(
        sampleRate: 96_000,
        bitDepth: 24,
        channelCount: 2,
        inputDeviceUID: ""
    )
}
