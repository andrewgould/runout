#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation

/// Core Audio (AudioObjectID) device enumeration and selection.
final class MacAudioInputManager: AudioInputManager {
    func availableDevices() throws -> [AudioInputDevice] {
        try allDeviceIDs().compactMap { deviceID in
            guard try inputChannelCount(of: deviceID) > 0 else { return nil }
            guard let uid = try stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID),
                  let name = try stringProperty(kAudioObjectPropertyName, of: deviceID)
            else { return nil }
            return AudioInputDevice(id: uid, name: name)
        }
    }

    func applyInputDevice(_ device: AudioInputDevice, to engine: AVAudioEngine) throws {
        guard let deviceID = try deviceID(forUID: device.id) else {
            throw AudioInputManagerError.deviceUnavailable
        }
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw AudioInputManagerError.deviceUnavailable
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioInputManagerError.coreAudio(status)
        }
    }

    // MARK: - Core Audio HAL plumbing

    private func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard status == noErr else { throw AudioInputManagerError.coreAudio(status) }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { throw AudioInputManagerError.coreAudio(status) }
        return deviceIDs
    }

    private func inputChannelCount(of deviceID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else { return 0 }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferListPointer.deallocate() }

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer)
        guard status == noErr else { throw AudioInputManagerError.coreAudio(status) }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector, of deviceID: AudioDeviceID) throws -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfString: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { pointer -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else { return nil }
        return cfString as String
    }

    private func deviceID(forUID uid: String) throws -> AudioDeviceID? {
        try allDeviceIDs().first { deviceID in
            (try? stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID)) == uid
        }
    }
}
#endif
