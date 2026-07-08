import AVFoundation
import Foundation

#if os(iOS)
import UIKit
#endif

enum RecordingState: Equatable {
    case idle
    case recording
    case paused
}

/// Coordinates the input device, level metering, and file writing behind Screen 1
/// (docs/UI_SPEC.md). Owns the one `AVAudioEngine` instance for a recording session.
///
/// M1 scope: records at the input device's current native format (see `applyInputDevice`);
/// explicit sample-rate/bit-depth negotiation is a fast-follow, tracked separately from this
/// milestone. Native FLAC output (vs. the CAF container used here) lands in M2.
@MainActor
final class RecordingSession: ObservableObject {
    @Published private(set) var availableDevices: [AudioInputDevice] = []
    @Published var selectedDevice: AudioInputDevice?
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var channelLevels: [ChannelLevel] = []
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var diskSpaceWarning: String?
    @Published private(set) var lastError: String?

    private let engine = AVAudioEngine()
    private let inputManager: AudioInputManager = PlatformAudioInputManager()
    private let levelMeter = LevelMeter()
    private let writer = RecordingWriter()

    private var uiRefreshTimer: Timer?
    private var recordingStartDate: Date?
    private var pausedAccumulatedSeconds: TimeInterval = 0
    private var sleepPreventionToken: NSObjectProtocol?

    /// Assumed max side length used for the disk space estimate — see docs/FEATURES.md §1.
    private static let assumedMaxRecordingDuration: TimeInterval = 30 * 60

    func refreshDevices() {
        do {
            availableDevices = try inputManager.availableDevices()
            if selectedDevice == nil || !availableDevices.contains(where: { $0.id == selectedDevice?.id }) {
                selectedDevice = availableDevices.first
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Checks free space at `url`'s volume against an estimate for a full side at `settings`'
    /// format, publishing a warning (never a hard block) if it's tight — see docs/FEATURES.md §1.
    func checkDiskSpace(at url: URL, settings: AudioSettings) {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else {
            diskSpaceWarning = nil
            return
        }
        let bytesPerSecond = settings.sampleRate * Double(settings.bitDepth / 8) * Double(settings.channelCount)
        let estimatedBytes = bytesPerSecond * Self.assumedMaxRecordingDuration
        if Double(available) < estimatedBytes {
            let availableGB = Double(available) / 1_000_000_000
            diskSpaceWarning = String(
                format: "Only %.1f GB free at that location — may not be enough for a full side at this quality.",
                availableGB
            )
        } else {
            diskSpaceWarning = nil
        }
    }

    func startRecording(to url: URL) async {
        guard state == .idle else { return }
        guard let device = selectedDevice else {
            lastError = "No input device selected."
            return
        }
        do {
            try inputManager.applyInputDevice(device, to: engine)
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            try await writer.start(url: url, format: inputFormat)

            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }
                // Real-time thread: only fast, allocation-light work happens here directly.
                self.levelMeter.process(buffer)
                guard let copy = buffer.copy() else { return }
                Task { try? await self.writer.append(copy) }
            }

            engine.prepare()
            try engine.start()

            preventSleep()
            recordingStartDate = Date()
            pausedAccumulatedSeconds = 0
            state = .recording
            startUIRefreshTimer()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pauseRecording() {
        guard state == .recording else { return }
        engine.pause()
        if let start = recordingStartDate {
            pausedAccumulatedSeconds += Date().timeIntervalSince(start)
        }
        recordingStartDate = nil
        state = .paused
    }

    func resumeRecording() {
        guard state == .paused else { return }
        do {
            try engine.start()
            recordingStartDate = Date()
            state = .recording
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard state != .idle else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        await writer.stop()
        allowSleep()
        stopUIRefreshTimer()
        state = .idle
        recordingStartDate = nil
        pausedAccumulatedSeconds = 0
        elapsedSeconds = 0
    }

    func clearClipIndicators() {
        levelMeter.clearClipIndicators()
    }

    // MARK: - UI refresh

    private func startUIRefreshTimer() {
        stopUIRefreshTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshUIState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        uiRefreshTimer = timer
    }

    private func stopUIRefreshTimer() {
        uiRefreshTimer?.invalidate()
        uiRefreshTimer = nil
        channelLevels = []
    }

    private func refreshUIState() {
        channelLevels = levelMeter.channelLevels
        if state == .recording, let start = recordingStartDate {
            elapsedSeconds = pausedAccumulatedSeconds + Date().timeIntervalSince(start)
        }
    }

    // MARK: - Sleep prevention (docs/FEATURES.md §1)

    private func preventSleep() {
        #if os(macOS)
        sleepPreventionToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled],
            reason: "Recording vinyl side"
        )
        #elseif os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
    }

    private func allowSleep() {
        #if os(macOS)
        if let token = sleepPreventionToken {
            ProcessInfo.processInfo.endActivity(token)
            sleepPreventionToken = nil
        }
        #elseif os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }
}
