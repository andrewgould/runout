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

    /// The identifier of the system's current default input device, if determinable — used to
    /// preselect it in the picker, and (on macOS) to know when the engine's own default-device
    /// tracking should be left alone rather than overridden.
    func systemDefaultDeviceID() -> String?

    /// Directs `engine`'s input to use `device`. `engine` must not be running when this is called.
    func applyInputDevice(_ device: AudioInputDevice, to engine: AVAudioEngine) throws

    /// Invokes `onChange` (always on the main queue) whenever the set of available input
    /// devices/routes changes — a device plugged/unplugged on macOS, a route change on iOS
    /// (docs/IMPROVEMENT_PLAN.md P3: the picker previously only refreshed on screen appear).
    /// Calling this again replaces any previously-registered handler.
    func startObservingDeviceChanges(_ onChange: @escaping () -> Void)

    /// Stops any observation started by `startObservingDeviceChanges`. Safe to call even if
    /// observation was never started.
    func stopObservingDeviceChanges()
}

#if os(macOS)
typealias PlatformAudioInputManager = MacAudioInputManager
#elseif os(iOS)
typealias PlatformAudioInputManager = IOSAudioInputManager
#endif
