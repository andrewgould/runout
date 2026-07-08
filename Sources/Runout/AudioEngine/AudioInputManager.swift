import AVFoundation
import Foundation

/// One available audio input device/route (e.g. a USB turntable interface).
struct AudioInputDevice: Identifiable, Hashable {
    /// A persistent identifier: a Core Audio device UID on macOS, an `AVAudioSessionPortDescription.uid` on iOS.
    let id: String
    let name: String
}

enum AudioInputManagerError: Error, LocalizedError {
    case coreAudio(OSStatus)
    case deviceUnavailable
    case sessionConfigurationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let status):
            return "Core Audio error (status \(status))."
        case .deviceUnavailable:
            return "The selected audio input device is no longer available."
        case .sessionConfigurationFailed(let error):
            return "Could not configure the audio session: \(error.localizedDescription)"
        }
    }
}

/// Platform-specific audio input enumeration and device selection.
/// macOS and iOS conformances live in AudioInputManager+macOS.swift / AudioInputManager+iOS.swift.
/// See docs/ARCHITECTURE.md (Platform differences).
protocol AudioInputManager: AnyObject {
    /// All currently connected input-capable devices/routes.
    func availableDevices() throws -> [AudioInputDevice]

    /// Directs `engine`'s input to use `device`. `engine` must not be running when this is called.
    func applyInputDevice(_ device: AudioInputDevice, to engine: AVAudioEngine) throws
}

#if os(macOS)
typealias PlatformAudioInputManager = MacAudioInputManager
#elseif os(iOS)
typealias PlatformAudioInputManager = IOSAudioInputManager
#endif
