import Foundation

/// Derives track sample ranges from a sorted list of markers plus the total recording length —
/// shared by the waveform editor (Screen 2) and metadata (Screen 3), which both need the exact
/// same track boundaries computed the same way.
enum TrackRanges {
    static func compute(markers: [Marker], totalSampleCount: Int64) -> [Range<Int64>] {
        let boundaries: [Int64] = [0] + markers.map(\.sampleOffset).sorted() + [totalSampleCount]
        guard boundaries.count > 1 else { return [] }
        return (0..<boundaries.count - 1).map { boundaries[$0]..<boundaries[$0 + 1] }
    }
}
