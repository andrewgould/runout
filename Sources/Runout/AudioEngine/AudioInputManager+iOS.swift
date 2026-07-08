#if os(iOS)
import AVFoundation
import Foundation

/// AVAudioSession route/port enumeration and selection.
final class IOSAudioInputManager: AudioInputManager {
    func availableDevices() throws -> [AudioInputDevice] {
        let session = AVAudioSession.sharedInstance()
        do {
            // Not .allowBluetoothHFP: that option requires a newer iOS SDK than some toolchains
            // (including CI's) currently ship, and .allowBluetooth still works everywhere.
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
            try session.setActive(true)
        } catch {
            throw AudioInputManagerError.sessionConfigurationFailed(error)
        }
        return (session.availableInputs ?? []).map {
            AudioInputDevice(id: $0.uid, name: $0.portName)
        }
    }

    func applyInputDevice(_ device: AudioInputDevice, to engine: AVAudioEngine) throws {
        let session = AVAudioSession.sharedInstance()
        guard let port = session.availableInputs?.first(where: { $0.uid == device.id }) else {
            throw AudioInputManagerError.deviceUnavailable
        }
        do {
            try session.setPreferredInput(port)
        } catch {
            throw AudioInputManagerError.sessionConfigurationFailed(error)
        }
    }
}
#endif
