import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Screen 4 — see docs/UI_SPEC.md and assets/mockups/04-export.png.
struct ExportView: View {
    let recordingURL: URL?

    @State private var totalSampleCount: Int64?
    @State private var bitDepth: Int?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let recordingURL {
                if let totalSampleCount, let bitDepth {
                    ExportWorkspaceView(recordingURL: recordingURL, totalSampleCount: totalSampleCount, bitDepth: bitDepth)
                } else if let errorMessage {
                    PlaceholderScreen(title: "Couldn't Load Recording", systemImage: "exclamationmark.triangle", message: errorMessage)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .task(id: recordingURL) { await load(for: recordingURL) }
                }
            } else {
                PlaceholderScreen(
                    title: "Export",
                    systemImage: "square.and.arrow.up",
                    message: "Record, split, and tag something first."
                )
            }
        }
    }

    private func load(for url: URL) async {
        do {
            let (length, depth) = try await Task.detached(priority: .userInitiated) { () -> (Int64, Int) in
                let file = try AVAudioFile(forReading: url)
                let depth = file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 24
                return (file.length, depth)
            }.value
            totalSampleCount = length
            bitDepth = depth
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ExportWorkspaceView: View {
    let recordingURL: URL
    let totalSampleCount: Int64
    let bitDepth: Int

    @StateObject private var metadata: MetadataSession
    @StateObject private var session: ExportSession
    @State private var isChoosingDestination = false

    init(recordingURL: URL, totalSampleCount: Int64, bitDepth: Int) {
        self.recordingURL = recordingURL
        self.totalSampleCount = totalSampleCount
        self.bitDepth = bitDepth
        let metadataSession = MetadataSession(recordingURL: recordingURL, totalSampleCount: totalSampleCount)
        _metadata = StateObject(wrappedValue: metadataSession)
        _session = StateObject(wrappedValue: ExportSession(
            recordingURL: recordingURL,
            bitDepth: bitDepth,
            tracks: metadataSession.tracks,
            albumMetadata: metadataSession.albumMetadata,
            coverArtURL: metadataSession.coverArtURL
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export — \(metadata.albumMetadata.albumTitle.isEmpty ? "Untitled Album" : metadata.albumMetadata.albumTitle)")
                .font(.title2.bold())

            destinationRow
            templateRow
            formatSummary

            trackTable

            if let error = session.errorMessage {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            footer
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fileImporter(isPresented: $isChoosingDestination, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                session.destinationFolder = url
            }
        }
    }

    private var destinationRow: some View {
        HStack {
            Text("Destination:")
                .foregroundStyle(.secondary)
            Text(session.destinationFolder.path)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose…") { isChoosingDestination = true }
        }
    }

    private var templateRow: some View {
        HStack {
            Text("Filename:")
                .foregroundStyle(.secondary)
            TextField("Template", text: $session.fileNameTemplate)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: 320)

            Picker("If a file already exists", selection: $session.overwriteBehavior) {
                Text("Skip").tag(OverwriteBehavior.skip)
                Text("Overwrite").tag(OverwriteBehavior.overwrite)
                Text("Append Number").tag(OverwriteBehavior.appendNumber)
            }
            .frame(maxWidth: 260)
        }
    }

    private var formatSummary: some View {
        Text("FLAC · lossless · \(bitDepth)-bit — passthrough, no re-encode")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var trackTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(metadata.tracks) { track in
                HStack {
                    Text(metadata.resolvedFilename(for: track, template: session.fileNameTemplate))
                        .font(.system(.callout, design: .monospaced))
                    Spacer()
                    statusView(for: session.status(for: track))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func statusView(for status: TrackExportStatus) -> some View {
        switch status {
        case .queued:
            Text("Queued").foregroundStyle(.secondary)
        case .exporting:
            ProgressView().controlSize(.small)
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped:
            Label("Skipped", systemImage: "arrow.uturn.forward.circle").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(session.completedCount) of \(metadata.tracks.count) tracks processed")
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await session.exportAll() }
            } label: {
                Label("Export All", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isExporting || metadata.tracks.isEmpty)
        }
    }
}
