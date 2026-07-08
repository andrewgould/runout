import AVFoundation
import SwiftUI

/// Screen 1 — see docs/UI_SPEC.md and assets/mockups/01-recording.png.
///
/// Recording is written to a document-owned scratch location, then ingested into the project
/// package as a new `RecordingSide` once it finishes — see `RunoutDocument`'s materialize/ingest
/// bridge for why the actual audio capture code (`RecordingSession`, unchanged since M1) still
/// just deals in plain file URLs.
struct RecordingView: View {
    @ObservedObject var document: RunoutDocument
    @StateObject private var session = RecordingSession()
    @State private var currentScratchURL: URL?
    @State private var pendingSide: (slug: String, label: String)?
    @State private var ingestError: String?
    var onRecordingFinished: (UUID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Recording — \(nextSideLabel)")
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
            if let ingestError {
                Label(ingestError, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            session.refreshDevices()
            session.checkDiskSpace(at: document.workingDirectory, settings: .defaultSettings)
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
                Button("Stop") { Task { await stopRecording() } }
                    .buttonStyle(.borderedProminent)

            case .paused:
                Button("Resume") { session.resumeRecording() }
                    .buttonStyle(.borderedProminent)
                Button("Stop") { Task { await stopRecording() } }
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

    private func slugAndLabel(forSideIndex index: Int) -> (slug: String, label: String) {
        let letter = String(UnicodeScalar(UInt8(65 + min(index, 25))))
        return ("side-\(letter.lowercased())", "Side \(letter)")
    }

    private var nextSideLabel: String {
        slugAndLabel(forSideIndex: document.project.sides.count).label
    }

    private func startRecording() {
        let pending = slugAndLabel(forSideIndex: document.project.sides.count)
        pendingSide = pending
        let url = document.scratchFileURL(named: "\(pending.slug).flac")
        currentScratchURL = url
        Task { await session.startRecording(to: url) }
    }

    private func stopRecording() async {
        await session.stopRecording()
        guard let url = currentScratchURL, let pending = pendingSide else { return }
        currentScratchURL = nil
        pendingSide = nil

        do {
            let audioFile = try AVAudioFile(forReading: url)
            let peakCache = try PeakCacheBuilder.build(fromFileAt: url)
            let peaksURL = document.scratchFileURL(named: "\(pending.slug).peaks")
            try peakCache.serialized().write(to: peaksURL, options: .atomic)

            try document.ingestFile(at: url, asRelativePath: "\(pending.slug).flac")
            try document.ingestFile(at: peaksURL, asRelativePath: "\(pending.slug).peaks")

            let side = RecordingSide(
                label: pending.label,
                masterFileRelativePath: "\(pending.slug).flac",
                peakCacheRelativePath: "\(pending.slug).peaks",
                durationSamples: audioFile.length,
                createdAt: Date()
            )
            document.project.sides.append(side)
            ingestError = nil
            onRecordingFinished(side.id)
        } catch {
            ingestError = "Couldn't save the recording into the project: \(error.localizedDescription)"
        }
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
