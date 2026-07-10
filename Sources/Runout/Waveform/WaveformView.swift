import SwiftUI

/// Waveform display with zoom/scroll, marker placement/editing, and a playhead — see
/// docs/UI_SPEC.md (Screen 2) and docs/ROADMAP.md M3/M4.
///
/// Zoom is discrete, stepping directly through the peak cache's cached mip levels (rather than
/// a continuous slider) — simple, robust, and each step is exactly a resolution the cache
/// already has on hand, so no interpolation or edge-case math is needed.
struct WaveformView: View {
    let peakCache: PeakCache
    let totalSampleCount: Int64
    let markers: [Marker]
    /// Silence-detected candidates awaiting review (docs/ROADMAP.md M8) — rendered distinctly
    /// (dashed, non-interactive) so they're visibly different from committed markers until
    /// accepted via the editor's Accept All/Reject All controls.
    let proposedMarkers: [Marker]
    let selectedMarkerID: UUID?
    let playheadSample: Int64?

    var onSeek: (Int64) -> Void = { _ in }
    var onSelectMarker: (UUID?) -> Void = { _ in }
    var onMoveMarker: (UUID, Int64) -> Void = { _, _ in }
    /// Cmd+click on the waveform (docs/FEATURES.md §5's macOS keyboard shortcuts) — adds a
    /// marker at the click point without disturbing the current selection/seek position.
    var onAddMarker: (Int64) -> Void = { _ in }

    @State private var levelIndex: Int

    init(
        peakCache: PeakCache,
        totalSampleCount: Int64,
        markers: [Marker] = [],
        proposedMarkers: [Marker] = [],
        selectedMarkerID: UUID? = nil,
        playheadSample: Int64? = nil,
        onSeek: @escaping (Int64) -> Void = { _ in },
        onSelectMarker: @escaping (UUID?) -> Void = { _ in },
        onMoveMarker: @escaping (UUID, Int64) -> Void = { _, _ in },
        onAddMarker: @escaping (Int64) -> Void = { _ in }
    ) {
        self.peakCache = peakCache
        self.totalSampleCount = totalSampleCount
        self.markers = markers
        self.proposedMarkers = proposedMarkers
        self.selectedMarkerID = selectedMarkerID
        self.playheadSample = playheadSample
        self.onSeek = onSeek
        self.onSelectMarker = onSelectMarker
        self.onMoveMarker = onMoveMarker
        self.onAddMarker = onAddMarker
        _levelIndex = State(initialValue: peakCache.levels.isEmpty ? 0 : peakCache.levels.count / 2)
    }

    private static let pointsPerBucket: CGFloat = 3
    private static let canvasHeight: CGFloat = 200

    private var currentLevel: [PeakBucket] {
        guard peakCache.levels.indices.contains(levelIndex) else { return [] }
        return peakCache.levels[levelIndex]
    }

    private var bucketSize: Int {
        peakCache.samplesPerBucketAtFinestLevel << levelIndex
    }

    private var totalWidth: CGFloat {
        CGFloat(currentLevel.count) * Self.pointsPerBucket
    }

    private func x(forSample sample: Int64) -> CGFloat {
        CGFloat(Double(sample) / Double(bucketSize)) * Self.pointsPerBucket
    }

    private func sample(forX x: CGFloat) -> Int64 {
        let raw = Double(x / Self.pointsPerBucket) * Double(bucketSize)
        return max(0, min(totalSampleCount, Int64(raw)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            zoomControl
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    waveformCanvas
                    if let playheadSample {
                        playheadLine(atSample: playheadSample)
                    }
                    ForEach(proposedMarkers) { marker in
                        proposedMarkerLine(atSample: marker.sampleOffset)
                    }
                    ForEach(markers) { marker in
                        markerHandle(for: marker)
                    }
                }
                .frame(width: max(totalWidth, 1), height: Self.canvasHeight)
                .contentShape(Rectangle())
                #if os(macOS)
                .gesture(
                    // Cmd+click adds a marker (docs/FEATURES.md §5, macOS-only — no keyboard
                    // modifiers on a plain touch tap on iPadOS).
                    SpatialTapGesture()
                        .modifiers(.command)
                        .onEnded { value in
                            onAddMarker(sample(forX: value.location.x))
                        }
                        .exclusively(before: SpatialTapGesture().onEnded { value in
                            onSelectMarker(nil)
                            onSeek(sample(forX: value.location.x))
                        })
                )
                #else
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        onSelectMarker(nil)
                        onSeek(sample(forX: value.location.x))
                    }
                )
                #endif
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
            .accessibilityLabel("Zoom Out")

            Button {
                levelIndex = max(levelIndex - 1, 0)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(levelIndex <= 0)
            .accessibilityLabel("Zoom In")

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

    private func playheadLine(atSample sample: Int64) -> some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 1.5, height: Self.canvasHeight)
            .offset(x: x(forSample: sample))
            .allowsHitTesting(false)
    }

    /// Dashed rather than solid so a proposal reads as "not yet committed" at a glance.
    private func proposedMarkerLine(atSample sample: Int64) -> some View {
        Rectangle()
            .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .frame(width: 2, height: Self.canvasHeight)
            .offset(x: x(forSample: sample) - 1)
            .allowsHitTesting(false)
    }

    private func markerHandle(for marker: Marker) -> some View {
        MarkerHandleView(
            isSelected: marker.id == selectedMarkerID,
            height: Self.canvasHeight,
            xPosition: x(forSample: marker.sampleOffset),
            onSelect: { onSelectMarker(marker.id) },
            onDragEnded: { deltaX in
                let newX = x(forSample: marker.sampleOffset) + deltaX
                onMoveMarker(marker.id, sample(forX: newX))
            }
        )
    }
}

/// A vertical marker line with a draggable flag handle at the top. Drag position is tracked
/// locally and only committed (via `onDragEnded`) on release, so a drag-in-progress doesn't spam
/// the undo stack with a move per frame.
private struct MarkerHandleView: View {
    let isSelected: Bool
    let height: CGFloat
    let xPosition: CGFloat
    let onSelect: () -> Void
    let onDragEnded: (CGFloat) -> Void

    @State private var dragTranslation: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(isSelected ? Color.white : Color.orange)
                .frame(width: 2, height: height)
            Image(systemName: "flag.fill")
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? Color.white : Color.orange)
                .padding(6)
                .contentShape(Rectangle())
        }
        .offset(x: xPosition + dragTranslation - 1)
        .onTapGesture { onSelect() }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    dragTranslation = value.translation.width
                }
                .onEnded { value in
                    onDragEnded(value.translation.width)
                    dragTranslation = 0
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Marker")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Double-tap to select. Once selected, use the left and right arrow keys to move it.")
    }
}

#Preview {
    let levels: [[PeakBucket]] = [
        (0..<400).map { i in
            let v = Int16(Double(Int16.max) * sin(Double(i) / 8))
            return PeakBucket(min: -abs(v), max: abs(v))
        }
    ]
    let cache = PeakCache(samplesPerBucketAtFinestLevel: 256, levels: levels)
    return WaveformView(
        peakCache: cache,
        totalSampleCount: cache.totalSampleCountEstimate,
        markers: [Marker(sampleOffset: 20_000)],
        selectedMarkerID: nil,
        playheadSample: 10_000
    )
    .padding()
    .background(Color.black)
}
