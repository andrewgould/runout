import AVFoundation
import SwiftUI

/// Screen 2 — see docs/UI_SPEC.md and assets/mockups/02-waveform-editor.png.
struct EditorView: View {
    let recordingURL: URL?

    @State private var peakCache: PeakCache?
    @State private var sampleRate: Double?
    @State private var totalSampleCount: Int64?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let recordingURL {
                if let peakCache, let sampleRate, let totalSampleCount {
                    EditorWorkspaceView(
                        recordingURL: recordingURL,
                        peakCache: peakCache,
                        sampleRate: sampleRate,
                        totalSampleCount: totalSampleCount
                    )
                } else if let errorMessage {
                    PlaceholderScreen(
                        title: "Couldn't Load Waveform",
                        systemImage: "exclamationmark.triangle",
                        message: errorMessage
                    )
                } else {
                    ProgressView("Analyzing waveform…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task(id: recordingURL) {
                            await loadWaveform(for: recordingURL)
                        }
                }
            } else {
                PlaceholderScreen(
                    title: "Split Into Tracks",
                    systemImage: "waveform",
                    message: "Record something first."
                )
            }
        }
    }

    private func loadWaveform(for url: URL) async {
        do {
            let (cache, rate, length) = try await Task.detached(priority: .userInitiated) { () -> (PeakCache, Double, Int64) in
                let cache = try PeakCacheBuilder.build(fromFileAt: url)
                let file = try AVAudioFile(forReading: url)
                return (cache, file.processingFormat.sampleRate, file.length)
            }.value
            peakCache = cache
            sampleRate = rate
            totalSampleCount = length
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Split out so `EditorSession` (a `@StateObject`) can be constructed once, directly from data
/// that's only available after `EditorView`'s async waveform load completes.
private struct EditorWorkspaceView: View {
    let recordingURL: URL
    let peakCache: PeakCache
    let sampleRate: Double
    let totalSampleCount: Int64

    @StateObject private var session: EditorSession

    init(recordingURL: URL, peakCache: PeakCache, sampleRate: Double, totalSampleCount: Int64) {
        self.recordingURL = recordingURL
        self.peakCache = peakCache
        self.sampleRate = sampleRate
        self.totalSampleCount = totalSampleCount
        _session = StateObject(wrappedValue: EditorSession(
            recordingURL: recordingURL,
            sampleRate: sampleRate,
            totalSampleCount: totalSampleCount
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(recordingURL.lastPathComponent)
                .font(.title2.bold())

            toolbar

            WaveformView(
                peakCache: peakCache,
                totalSampleCount: totalSampleCount,
                markers: session.markers,
                selectedMarkerID: session.selectedMarkerID,
                playheadSample: session.playheadSample,
                onSeek: { session.seek(toSample: $0) },
                onSelectMarker: { session.selectedMarkerID = $0 },
                onMoveMarker: { session.moveMarker($0, toSample: $1) }
            )

            trackList

            if let error = session.errorMessage {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Button {
                session.togglePlayback()
            } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
            }

            Text(timeString(forSample: session.playheadSample))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            Divider().frame(height: 20)

            Toggle("Snap to Zero-Crossing", isOn: $session.snapToZeroCrossing)
                .toggleStyle(.button)

            Button {
                session.splitAtPlayhead()
            } label: {
                Label("Add Marker", systemImage: "plus")
            }

            Button(role: .destructive) {
                session.deleteSelectedMarker()
            } label: {
                Label("Delete Marker", systemImage: "trash")
            }
            .disabled(session.selectedMarkerID == nil)

            Divider().frame(height: 20)

            Button {
                session.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!session.canUndo)

            Button {
                session.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!session.canRedo)
        }
    }

    private var trackList: some View {
        let tracks = trackRanges()
        return VStack(alignment: .leading, spacing: 4) {
            Text("Tracks")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, range in
                HStack {
                    Text("\(index + 1)")
                        .frame(width: 24, alignment: .leading)
                    Text("Track \(index + 1)")
                    Spacer()
                    Text(timeString(forSample: range.upperBound - range.lowerBound))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    private func trackRanges() -> [Range<Int64>] {
        let boundaries: [Int64] = [0] + session.markers.map(\.sampleOffset).sorted() + [totalSampleCount]
        guard boundaries.count > 1 else { return [] }
        return (0..<boundaries.count - 1).map { boundaries[$0]..<boundaries[$0 + 1] }
    }

    private func timeString(forSample sample: Int64) -> String {
        let totalSeconds = Double(sample) / sampleRate
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        let hundredths = Int((totalSeconds - Double(Int(totalSeconds))) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }
}
