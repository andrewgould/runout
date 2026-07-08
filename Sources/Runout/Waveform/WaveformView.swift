import SwiftUI

/// Read-only waveform display with zoom/scroll — see docs/UI_SPEC.md (Screen 2) and
/// docs/ROADMAP.md M3. Marker editing (M4) is not part of this view yet.
///
/// Zoom is discrete, stepping directly through the peak cache's cached mip levels (rather than
/// a continuous slider) — simple, robust, and each step is exactly a resolution the cache
/// already has on hand, so no interpolation or edge-case math is needed.
struct WaveformView: View {
    let peakCache: PeakCache

    @State private var levelIndex: Int

    init(peakCache: PeakCache) {
        self.peakCache = peakCache
        _levelIndex = State(initialValue: peakCache.levels.isEmpty ? 0 : peakCache.levels.count / 2)
    }

    private var currentLevel: [PeakBucket] {
        guard peakCache.levels.indices.contains(levelIndex) else { return [] }
        return peakCache.levels[levelIndex]
    }

    private var bucketSize: Int {
        peakCache.samplesPerBucketAtFinestLevel << levelIndex
    }

    private static let pointsPerBucket: CGFloat = 3

    private var totalWidth: CGFloat {
        CGFloat(currentLevel.count) * Self.pointsPerBucket
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            zoomControl
            ScrollView(.horizontal) {
                waveformCanvas
                    .frame(width: max(totalWidth, 1), height: 200)
            }
        }
    }

    private var zoomControl: some View {
        HStack(spacing: 12) {
            Text("Zoom")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                levelIndex = min(levelIndex + 1, max(peakCache.levels.count - 1, 0))
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(levelIndex >= peakCache.levels.count - 1)

            Button {
                levelIndex = max(levelIndex - 1, 0)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(levelIndex <= 0)

            Text("\(bucketSize) samples/point")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var waveformCanvas: some View {
        let buckets = currentLevel
        return Canvas { context, size in
            guard !buckets.isEmpty else { return }
            let midY = size.height / 2
            var path = Path()
            for (index, bucket) in buckets.enumerated() {
                let x = CGFloat(index) * Self.pointsPerBucket
                let topY = midY - CGFloat(bucket.max) / CGFloat(Int16.max) * midY
                let bottomY = midY - CGFloat(bucket.min) / CGFloat(Int16.max) * midY
                path.move(to: CGPoint(x: x, y: topY))
                path.addLine(to: CGPoint(x: x, y: bottomY))
            }
            context.stroke(path, with: .color(.orange), lineWidth: Self.pointsPerBucket)
        }
    }
}

#Preview {
    let levels: [[PeakBucket]] = [
        (0..<400).map { i in
            let v = Int16(Double(Int16.max) * sin(Double(i) / 8))
            return PeakBucket(min: -abs(v), max: abs(v))
        }
    ]
    return WaveformView(peakCache: PeakCache(samplesPerBucketAtFinestLevel: 256, levels: levels))
        .padding()
        .background(Color.black)
}
