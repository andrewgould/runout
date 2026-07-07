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

    init(
        id: UUID = UUID(),
        label: String,
        masterFileRelativePath: String,
        peakCacheRelativePath: String,
        durationSamples: Int64 = 0,
        createdAt: Date
    ) {
        self.id = id
        self.label = label
        self.masterFileRelativePath = masterFileRelativePath
        self.peakCacheRelativePath = peakCacheRelativePath
        self.durationSamples = durationSamples
        self.createdAt = createdAt
    }
}
