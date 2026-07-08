import Foundation

/// See docs/DATA_MODEL.md. `masterFileRelativePath`/`peakCacheRelativePath` are paths relative to the
/// project package root (e.g. "side-a.flac", "side-a.peaks").
struct RecordingSide: Codable, Identifiable, Equatable {
    var id: UUID
    var label: String
    var masterFileRelativePath: String
    var peakCacheRelativePath: String
    var durationSamples: Int64
    var createdAt: Date
    /// Split points within this side, sorted by `sampleOffset`. Added in M7 — the real
    /// replacement for the `<recording>.markers.json` sidecar `MarkerSidecarStore` used as a
    /// temporary bridge in M4, now that the project manifest is a real persisted document.
    var markers: [Marker]

    init(
        id: UUID = UUID(),
        label: String,
        masterFileRelativePath: String,
        peakCacheRelativePath: String,
        durationSamples: Int64 = 0,
        createdAt: Date,
        markers: [Marker] = []
    ) {
        self.id = id
        self.label = label
        self.masterFileRelativePath = masterFileRelativePath
        self.peakCacheRelativePath = peakCacheRelativePath
        self.durationSamples = durationSamples
        self.createdAt = createdAt
        self.markers = markers
    }
}
