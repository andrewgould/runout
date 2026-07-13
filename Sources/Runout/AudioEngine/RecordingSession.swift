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

enum RecordingError: Error, LocalizedError {
    case inputDeliveredNoAudio
    case inputStalled
    case diskSpaceCriticallyLow

    var errorDescription: String? {
        switch self {
        case .inputDeliveredNoAudio:
            return "The input device isn't delivering any audio. Check that Runout has microphone access (System Settings → Privacy & Security → Microphone) and that the device is connected and awake, or choose a different input."
        case .inputStalled:
            return "The input device stopped delivering audio partway through — it may have been disconnected, gone to sleep, or been reconfigured. The recording up to this point has been saved."
        case .diskSpaceCriticallyLow:
            return "Recording stopped because free disk space ran critically low. The recording up to this point has been saved."
        }
    }
}

/// Coordinates the input device, level metering, and file writing behind Screen 1
/// (docs/UI_SPEC.md). Owns the one `AVAudioEngine` instance for a recording session.
///
/// Records native FLAC (see RecordingWriter). `audioSettings` (sample rate × bit depth × channel
/// count, docs/FEATURES.md §1) is the format actually written: the tap runs at the device's own
/// native format (required — AVAudioEngine only taps in that format) and every buffer is
/// converted to `audioSettings` before it reaches the writer, via `AudioFormatConverter`.
@MainActor
final class RecordingSession: ObservableObject {
    @Published private(set) var availableDevices: [AudioInputDevice] = []
    @Published var selectedDevice: AudioInputDevice? {
        didSet { audioSettings.inputDeviceUID = selectedDevice?.id ?? "" }
    }
    @Published var audioSettings: AudioSettings = .defaultSettings
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
    private var bufferFeed: OrderedBufferFeed?
    private var stallMonitorTask: Task<Void, Never>?
    private var recordingURL: URL?
    private var lastCriticalDiskCheckDate: Date?

    /// Assumed max side length used for the disk space estimate — see docs/FEATURES.md §1.
    private static let assumedMaxRecordingDuration: TimeInterval = 30 * 60
    /// Below this, stop rather than risk a write failing mid-buffer — docs/FEATURES.md §1
    /// "warn/stop gracefully rather than crash if space actually runs out."
    private static let criticalFreeSpaceBytes: Double = 50_000_000
    private static let criticalDiskCheckInterval: TimeInterval = 5.0
    private static let stallCheckInterval: TimeInterval = 2.0

    /// Loads previously-saved format/device settings for this project (docs/FEATURES.md §1
    /// "remember the last choice per project") — call before the first `refreshDevices()` so its
    /// device preselection can honor the remembered device UID.
    func restoreSettings(_ settings: AudioSettings) {
        audioSettings = settings
    }

    private var isObservingDeviceChanges = false

    func refreshDevices() {
        // Started lazily on first call (RecordingView's onAppear) rather than in init, since
        // starting it unconditionally would fire for every RecordingSession ever constructed,
        // including ones a test creates and never uses.
        if !isObservingDeviceChanges {
            isObservingDeviceChanges = true
            inputManager.startObservingDeviceChanges { [weak self] in self?.refreshDevices() }
        }
        do {
            availableDevices = try inputManager.availableDevices()
            if selectedDevice == nil || !availableDevices.contains(where: { $0.id == selectedDevice?.id }) {
                // Prefer this project's remembered device, then the system default, then
                // whichever enumerates first — the default is the one device guaranteed to work
                // without touching the engine's input routing (see MacAudioInputManager).
                let rememberedID = audioSettings.inputDeviceUID
                let defaultID = inputManager.systemDefaultDeviceID()
                selectedDevice = availableDevices.first(where: { $0.id == rememberedID })
                    ?? availableDevices.first(where: { $0.id == defaultID })
                    ?? availableDevices.first
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
        // Without this, an unauthorized app "records" an empty file: the engine starts fine but
        // the tap never fires, so nothing downstream ever sees an error. Prompts on first use;
        // returns immediately once the user has decided.
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            lastError = "Microphone access is denied. Enable it for Runout in System Settings → Privacy & Security → Microphone."
            return
        }
        do {
            try inputManager.applyInputDevice(device, to: engine)
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)

            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: audioSettings.sampleRate,
                channels: AVAudioChannelCount(audioSettings.channelCount),
                interleaved: false
            ) else {
                lastError = "Invalid recording format."
                return
            }
            let converter = try AudioFormatConverter(from: inputFormat, to: targetFormat)
            try await writer.start(url: url, sourceFormat: targetFormat, bitDepth: audioSettings.bitDepth)

            // Ordered handoff to the writer — never one Task per buffer, which has no ordering
            // guarantee and can silently corrupt the master recording. See OrderedBufferFeed
            // and docs/IMPROVEMENT_PLAN.md P0-1. Format conversion happens here (the async
            // consumer), not on the tap thread, keeping the real-time callback allocation-light.
            let feed = OrderedBufferFeed(
                append: { [writer] buffer in
                    try await writer.append(try converter.convert(buffer))
                },
                onFailure: { [weak self] error in await self?.recordingFailed(with: error) }
            )
            bufferFeed = feed

            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [levelMeter] buffer, _ in
                // Real-time thread: only fast, allocation-light work happens here directly.
                // Metering reads the device's actual native-format buffer, ahead of any
                // downmix/upmix — showing the real input, not the chosen output channel count.
                levelMeter.process(buffer)
                guard let copy = buffer.copy() else { return }
                feed.yield(copy)
            }

            engine.prepare()
            try engine.start()

            preventSleep()
            recordingURL = url
            lastCriticalDiskCheckDate = nil
            recordingStartDate = Date()
            pausedAccumulatedSeconds = 0
            state = .recording
            startUIRefreshTimer()
            startStallMonitor()
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
        stallMonitorTask?.cancel()
        stallMonitorTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Drain every buffer the tap already delivered before closing the file, so the
        // recording's final fraction of a second isn't dropped.
        await bufferFeed?.finishAndDrain()
        bufferFeed = nil
        await writer.stop()
        allowSleep()
        stopUIRefreshTimer()
        state = .idle
        recordingStartDate = nil
        pausedAccumulatedSeconds = 0
        elapsedSeconds = 0
        recordingURL = nil
    }

    /// An engine that stops delivering buffers — at the very start (mic permission missing,
    /// device asleep, or the macOS device-selection quirk documented in MacAudioInputManager) or
    /// partway through (device disconnected, put to sleep, or reconfigured) — is indistinguishable
    /// from a healthy (possibly silent) recording anywhere else in the UI. Runs for the whole
    /// recording, not just a one-shot check at start, so a stall 10 minutes in is caught just as
    /// fast as one at frame zero. Frame counting, not amplitude: genuine silence still delivers
    /// frames and never trips this.
    ///
    /// Deliberately doesn't observe `AVAudioEngineConfigurationChangeNotification`: that fires for
    /// plenty of benign reasons (unrelated devices connecting elsewhere, transparent sample-rate
    /// renegotiation) and reacting to it directly risks stopping a perfectly healthy recording.
    /// Frame delivery is the ground truth for "is this still working," so it's the only signal
    /// used here.
    private func startStallMonitor() {
        stallMonitorTask?.cancel()
        stallMonitorTask = Task { [weak self] in
            var lastKnownFrameCount: AVAudioFramePosition = 0
            while true {
                try? await Task.sleep(nanoseconds: UInt64(Self.stallCheckInterval * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self else { return }

                guard self.state == .recording else {
                    if self.state == .idle { return }
                    // Paused: keep the baseline current so resuming doesn't immediately read as
                    // a stall against a long-stale frame count.
                    lastKnownFrameCount = await self.writer.framesWritten
                    continue
                }

                let current = await self.writer.framesWritten
                if current == lastKnownFrameCount {
                    let error: RecordingError = current == 0 ? .inputDeliveredNoAudio : .inputStalled
                    await self.recordingFailed(with: error)
                    return
                }
                lastKnownFrameCount = current
            }
        }
    }

    /// A buffer append threw (disk full, volume ejected, …) — tear the recording down instead of
    /// silently producing a truncated file (docs/FEATURES.md §1). The partial recording up to the
    /// failure is closed properly and remains playable.
    private func recordingFailed(with error: Error) async {
        guard state != .idle else { return }
        stallMonitorTask?.cancel()
        stallMonitorTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        bufferFeed = nil
        await writer.stop()
        allowSleep()
        stopUIRefreshTimer()
        state = .idle
        recordingStartDate = nil
        pausedAccumulatedSeconds = 0
        elapsedSeconds = 0
        recordingURL = nil
        lastError = "Recording stopped: \(error.localizedDescription)"
    }

    deinit {
        inputManager.stopObservingDeviceChanges()
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
        checkCriticalDiskSpaceIfDue()
    }

    /// Piggybacks on the existing 20Hz UI timer but throttles the actual `statfs` call to once
    /// every few seconds — docs/FEATURES.md §1 "continuously re-check during recording," not
    /// just the one-time estimate before starting.
    private func checkCriticalDiskSpaceIfDue() {
        guard state == .recording, let url = recordingURL else { return }
        let now = Date()
        if let last = lastCriticalDiskCheckDate, now.timeIntervalSince(last) < Self.criticalDiskCheckInterval { return }
        lastCriticalDiskCheckDate = now

        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return }

        if Double(available) < Self.criticalFreeSpaceBytes {
            Task { [weak self] in await self?.recordingFailed(with: RecordingError.diskSpaceCriticallyLow) }
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
