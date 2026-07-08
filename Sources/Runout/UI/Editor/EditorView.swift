import SwiftUI

/// Screen 2 — see docs/UI_SPEC.md and assets/mockups/02-waveform-editor.png.
/// M3 scope: read-only waveform display for the most recently recorded file. Marker placement
/// and editing (M4) aren't wired up yet.
struct EditorView: View {
    let recordingURL: URL?

    @State private var peakCache: PeakCache?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let recordingURL {
                if let peakCache {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(recordingURL.lastPathComponent)
                            .font(.title2.bold())
                        WaveformView(peakCache: peakCache)
                        Spacer()
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                            await buildPeakCache(for: recordingURL)
                        }
                }
            } else {
                PlaceholderScreen(
                    title: "Split Into Tracks",
                    systemImage: "waveform",
                    message: "Record something first — marker placement and editing land in M4."
                )
            }
        }
    }

    private func buildPeakCache(for url: URL) async {
        do {
            let cache = try await Task.detached(priority: .userInitiated) {
                try PeakCacheBuilder.build(fromFileAt: url)
            }.value
            peakCache = cache
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
