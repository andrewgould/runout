import AVFoundation
import SwiftUI

/// Screen 2 — see docs/UI_SPEC.md and assets/mockups/02-waveform-editor.png.
struct EditorView: View {
    @ObservedObject var document: RunoutDocument
    let sideID: UUID?

    @State private var peakCache: PeakCache?
    @State private var sampleRate: Double?
    @State private var totalSampleCount: Int64?
    @State private var recordingFileURL: URL?
    @State private var errorMessage: String?
    @State private var loadedForSideID: UUID?

    var body: some View {
        Group {
            if let sideID, let side = document.project.sides.first(where: { $0.id == sideID }) {
                if loadedForSideID == sideID, let peakCache, let sampleRate, let totalSampleCount, let recordingFileURL {
                    EditorWorkspaceView(
                        document: document,
                        sideID: sideID,
                        recordingFileURL: recordingFileURL,
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
                        .task(id: sideID) {
                            await loadWaveform(for: side)
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

    private func loadWaveform(for side: RecordingSide) async {
        do {
            let fileURL = try document.materializedFileURL(forRelativePath: side.masterFileRelativePath)
            let (cache, rate, length) = try await Task.detached(priority: .userInitiated) { () -> (PeakCache, Double, Int64) in
                let cache = try PeakCacheBuilder.build(fromFileAt: fileURL)
                let file = try AVAudioFile(forReading: fileURL)
                return (cache, file.processingFormat.sampleRate, file.length)
            }.value
            recordingFileURL = fileURL
            peakCache = cache
            sampleRate = rate
            totalSampleCount = length
            loadedForSideID = side.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Split out so `EditorSession` (a `@StateObject`) can be constructed once, directly from data
/// that's only available after `EditorView`'s async waveform load completes.
private struct EditorWorkspaceView: View {
    let document: RunoutDocument
    let sideID: UUID
    let recordingFileURL: URL
    let peakCache: PeakCache
    let sampleRate: Double
    let totalSampleCount: Int64

    @StateObject private var session: EditorSession

    init(document: RunoutDocument, sideID: UUID, recordingFileURL: URL, peakCache: PeakCache, sampleRate: Double, totalSampleCount: Int64) {
        self.document = document
        self.sideID = sideID
        self.recordingFileURL = recordingFileURL
        self.peakCache = peakCache
        self.sampleRate = sampleRate
        self.totalSampleCount = totalSampleCount
        _session = StateObject(wrappedValue: EditorSession(
            document: document,
            sideID: sideID,
            recordingFileURL: recordingFileURL,
            sampleRate: sampleRate,
            totalSampleCount: totalSampleCount
        ))
    }

    private var sideLabel: String {
        document.project.sides.first(where: { $0.id == sideID })?.label ?? "Recording"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(sideLabel)
                .font(.title2.bold())

            toolbar

            WaveformView(
                peakCache: peakCache,
                totalSampleCount: totalSampleCount,
                markers: session.markers,
                proposedMarkers: session.proposedMarkers,
                selectedMarkerID: session.selectedMarkerID,
                playheadSample: session.playheadSample,
                onSeek: { session.seek(toSample: $0) },
                onSelectMarker: { session.selectedMarkerID = $0 },
                onMoveMarker: { session.moveMarker($0, toSample: $1) }
            )

            if !session.proposedMarkers.isEmpty {
                proposedMarkersBanner
            }

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
                session.detectSilenceBreaks(peakCache: peakCache)
            } label: {
                Label("Auto-Detect Tracks", systemImage: "waveform.badge.magnifyingglass")
            }

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

    private var proposedMarkersBanner: some View {
        HStack {
            Label(
                "\(session.proposedMarkers.count) proposed track break\(session.proposedMarkers.count == 1 ? "" : "s") found",
                systemImage: "waveform.badge.magnifyingglass"
            )
            .foregroundStyle(.yellow)
            .font(.footnote)

            Spacer()

            Button("Reject All") {
                session.rejectAllProposedMarkers()
            }
            Button("Accept All") {
                session.acceptAllProposedMarkers()
            }
            .buttonStyle(.borderedProminent)
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
        TrackRanges.compute(markers: session.markers, totalSampleCount: totalSampleCount)
    }

    private func timeString(forSample sample: Int64) -> String {
        let totalSeconds = Double(sample) / sampleRate
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        let hundredths = Int((totalSeconds - Double(Int(totalSeconds))) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    }
}
