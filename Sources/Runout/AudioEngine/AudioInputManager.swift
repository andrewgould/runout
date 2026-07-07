import Foundation

/// One available audio input device/route (e.g. a USB turntable interface).
struct AudioInputDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Platform-specific audio input enumeration and capture control.
/// macOS and iOS conformances live in AudioInputManager+macOS.swift / AudioInputManager+iOS.swift.
/// Implemented in M1 — see docs/ROADMAP.md and docs/ARCHITECTURE.md (Platform differences).
protocol AudioInputManager {
    func availableDevices() -> [AudioInputDevice]
}
