import SwiftUI

/// Screen 1 — see docs/UI_SPEC.md and assets/mockups/01-recording.png.
///
/// M1 scope: records to a fixed location under the user's Music folder. M7 replaces this with
/// a proper project package (see docs/DATA_MODEL.md) once document-based persistence lands.
struct RecordingView: View {
    @StateObject private var session = RecordingSession()

    private static let recordingsDirectory: URL = {
        let musicDirectory = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return musicDirectory.appendingPathComponent("Runout", isDirectory: true)
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Recording")
                .font(.title.bold())

            devicePicker

            metersRow

            transportRow

            if let warning = session.diskSpaceWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            if let error = session.lastError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            session.refreshDevices()
            session.checkDiskSpace(at: Self.recordingsDirectory, settings: .defaultSettings)
        }
    }

    private var devicePicker: some View {
        Picker("Input", selection: $session.selectedDevice) {
            ForEach(session.availableDevices) { device in
                Text(device.name).tag(Optional(device))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 320)
        .disabled(session.state != .idle)
    }

    private var metersRow: some View {
        HStack(spacing: 24) {
            ForEach(Array(session.channelLevels.enumerated()), id: \.offset) { _, level in
                LevelMeterBar(level: level)
            }
            if session.channelLevels.isEmpty {
                Text("No input signal")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if session.channelLevels.contains(where: { $0.isClipping }) {
                Button {
                    session.clearClipIndicators()
                } label: {
                    Label("Clip", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 160)
    }

    private var transportRow: some View {
        HStack(spacing: 16) {
            switch session.state {
            case .idle:
                Button {
                    startRecording()
                } label: {
                    Label("Record", systemImage: "record.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(session.selectedDevice == nil)

            case .recording:
                Button("Pause") { session.pauseRecording() }
                    .buttonStyle(.bordered)
                Button("Stop") { Task { await session.stopRecording() } }
                    .buttonStyle(.borderedProminent)

            case .paused:
                Button("Resume") { session.resumeRecording() }
                    .buttonStyle(.borderedProminent)
                Button("Stop") { Task { await session.stopRecording() } }
                    .buttonStyle(.bordered)
            }

            Text(elapsedTimeString)
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var elapsedTimeString: String {
        let total = Int(session.elapsedSeconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func startRecording() {
        let directory = Self.recordingsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(recordingFileName())
        Task { await session.startRecording(to: url) }
    }

    private func recordingFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Recording \(formatter.string(from: Date())).caf"
    }
}

private struct LevelMeterBar: View {
    let level: ChannelLevel

    /// Maps a dBFS value to a 0...1 fill fraction across an 48dB display range.
    private static func fraction(for decibels: Float) -> CGFloat {
        guard decibels.isFinite else { return 0 }
        let clamped = max(-48, min(0, decibels))
        return CGFloat((clamped + 48) / 48)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 4)
                    .fill(level.isClipping ? Color.red : Color.orange)
                    .frame(height: proxy.size.height * Self.fraction(for: level.peakDecibels))
            }
        }
        .frame(width: 28)
        .overlay(alignment: .bottom) {
            Text(decibelLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .offset(y: 20)
        }
    }

    private var decibelLabel: String {
        level.peakDecibels.isFinite ? String(format: "%.0f dB", level.peakDecibels) : "-∞"
    }
}
