#if os(iOS)
import AVFoundation
import Foundation

/// AVAudioSession route/port enumeration and selection.
final class IOSAudioInputManager: AudioInputManager {
    private var routeChangeObserver: NSObjectProtocol?

    func startObservingDeviceChanges(_ onChange: @escaping () -> Void) {
        stopObservingDeviceChanges()
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { _ in onChange() }
    }

    func stopObservingDeviceChanges() {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
    }

    deinit {
        stopObservingDeviceChanges()
    }

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

    func systemDefaultDeviceID() -> String? {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
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
