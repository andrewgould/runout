import AVFoundation
import Foundation

/// Coordinates marker editing and playback behind Screen 2 (docs/UI_SPEC.md).
///
/// Markers are the real, persisted `RecordingSide.markers` inside `document.project` — the
/// `<recording>.markers.json` sidecar used as a temporary bridge in M4 is gone now that the
/// project manifest is a real document. `markers` here is a working copy kept in sync by
/// `saveMarkers()` writing straight through to `document.project` on every mutation, so
/// SwiftUI's document-change tracking (and therefore autosave) picks it up immediately.
@MainActor
final class EditorSession: ObservableObject {
    @Published private(set) var markers: [Marker] = []
    /// Silence-detected candidate markers awaiting review — see docs/FEATURES.md §2. Never
    /// written to `document.project`; only `acceptProposedMarker`/`acceptAllProposedMarkers`
    /// (which route through the normal `addMarker` path) actually commit anything.
    @Published private(set) var proposedMarkers: [Marker] = []
    @Published var snapToZeroCrossing = true
    @Published private(set) var isPlaying = false
    @Published private(set) var playheadSample: Int64 = 0
    @Published private(set) var errorMessage: String?
    @Published var selectedMarkerID: UUID?

    private let document: RunoutDocument
    private let sideID: UUID
    let recordingFileURL: URL
    let sampleRate: Double
    let totalSampleCount: Int64

    private let undoManager = UndoManager()
    private var player: AVAudioPlayer?
    private var playheadTimer: Timer?

    init(document: RunoutDocument, sideID: UUID, recordingFileURL: URL, sampleRate: Double, totalSampleCount: Int64) {
        self.document = document
        self.sideID = sideID
        self.recordingFileURL = recordingFileURL
        self.sampleRate = sampleRate
        self.totalSampleCount = totalSampleCount
        // Group explicitly per user action (see each public editing method) instead of relying
        // on the default event-loop-based grouping, which would silently merge unrelated edits
        // into one undo step if they happen to land in the same run loop turn.
        undoManager.groupsByEvent = false
        markers = document.project.sides.first(where: { $0.id == sideID })?.markers ?? []
        preparePlayer()
    }

    deinit {
        playheadTimer?.invalidate()
    }

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }
    func undo() { undoManager.undo() }
    func redo() { undoManager.redo() }

    // MARK: - Persistence

    private func saveMarkers() {
        guard let index = document.project.sides.firstIndex(where: { $0.id == sideID }) else { return }
        document.project.sides[index].markers = markers
    }

    // MARK: - Marker editing
    //
    // All mutation funnels through `performAdd`/`performDelete`/`performMove`, each of which
    // registers its own inverse as the undo action — so undoing an undo (a redo) re-registers
    // correctly for free, the standard NSUndoManager idiom. Each public entry point wraps its
    // work in an explicit undo group (see `groupsByEvent = false` in `init`) so it's always
    // exactly one undo step, regardless of run loop timing.

    func addMarker(atSample sample: Int64) {
        let snapped = snappedSample(sample)
        undoManager.beginUndoGrouping()
        performAdd(Marker(sampleOffset: snapped), registerUndo: true)
        undoManager.endUndoGrouping()
    }

    func splitAtPlayhead() {
        addMarker(atSample: playheadSample)
    }

    func moveMarker(_ id: UUID, toSample sample: Int64) {
        guard let current = markers.first(where: { $0.id == id }) else { return }
        let snapped = snappedSample(sample)
        guard snapped != current.sampleOffset else { return }
        undoManager.beginUndoGrouping()
        performMove(id, toSample: snapped, previousSample: current.sampleOffset, registerUndo: true)
        undoManager.endUndoGrouping()
    }

    func deleteSelectedMarker() {
        guard let id = selectedMarkerID else { return }
        deleteMarker(id)
    }

    func deleteMarker(_ id: UUID) {
        guard let marker = markers.first(where: { $0.id == id }) else { return }
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        performDelete(id, registerUndo: true, restoring: marker)
        if selectedMarkerID == id { selectedMarkerID = nil }
    }

    // MARK: - Silence-detected proposals (docs/FEATURES.md §2, docs/ROADMAP.md M8)
    //
    // Proposals never touch `document.project` directly — only accepting one (individually or
    // via "accept all") routes it through `addMarker`, so it gets exactly the same zero-crossing
    // snapping and undo registration as a manually-placed marker.

    func detectSilenceBreaks(
        peakCache: PeakCache,
        thresholdDecibels: Float = SilenceDetector.defaultThresholdDecibels,
        minimumGapDuration: Double = SilenceDetector.defaultMinimumGapDuration
    ) {
        let candidates = SilenceDetector.detectTrackBreaks(
            in: peakCache,
            sampleRate: sampleRate,
            thresholdDecibels: thresholdDecibels,
            minimumGapDuration: minimumGapDuration
        )
        // Skip proposals that land right on top of a marker that already exists.
        let tolerance = Int64(MarkerSnapping.defaultSearchWindowInSamples)
        proposedMarkers = candidates.filter { candidate in
            !markers.contains { abs($0.sampleOffset - candidate.sampleOffset) < tolerance }
        }
    }

    func acceptProposedMarker(_ id: UUID) {
        guard let marker = proposedMarkers.first(where: { $0.id == id }) else { return }
        proposedMarkers.removeAll { $0.id == id }
        addMarker(atSample: marker.sampleOffset)
    }

    func rejectProposedMarker(_ id: UUID) {
        proposedMarkers.removeAll { $0.id == id }
    }

    func acceptAllProposedMarkers() {
        let toAccept = proposedMarkers
        proposedMarkers = []
        for marker in toAccept {
            addMarker(atSample: marker.sampleOffset)
        }
    }

    func rejectAllProposedMarkers() {
        proposedMarkers = []
    }

    private func snappedSample(_ sample: Int64) -> Int64 {
        let clamped = max(0, min(totalSampleCount, sample))
        guard snapToZeroCrossing else { return clamped }
        return MarkerSnapping.nearestZeroCrossing(toSample: clamped, fileURL: recordingFileURL) ?? clamped
    }

    private func performAdd(_ marker: Marker, registerUndo: Bool) {
        markers.append(marker)
        markers.sort { $0.sampleOffset < $1.sampleOffset }
        saveMarkers()
        if registerUndo {
            undoManager.registerUndo(withTarget: self) { target in
                target.performDelete(marker.id, registerUndo: true, restoring: marker)
            }
        }
    }

    private func performDelete(_ id: UUID, registerUndo: Bool, restoring marker: Marker) {
        markers.removeAll { $0.id == id }
        saveMarkers()
        if registerUndo {
            undoManager.registerUndo(withTarget: self) { target in
                target.performAdd(marker, registerUndo: true)
            }
        }
    }

    private func performMove(_ id: UUID, toSample sample: Int64, previousSample: Int64, registerUndo: Bool) {
        guard let index = markers.firstIndex(where: { $0.id == id }) else { return }
        markers[index].sampleOffset = sample
        markers.sort { $0.sampleOffset < $1.sampleOffset }
        saveMarkers()
        if registerUndo {
            undoManager.registerUndo(withTarget: self) { target in
                target.performMove(id, toSample: previousSample, previousSample: sample, registerUndo: true)
            }
        }
    }

    // MARK: - Playback

    private func preparePlayer() {
        do {
            let player = try AVAudioPlayer(contentsOf: recordingFileURL)
            player.prepareToPlay()
            self.player = player
        } catch {
            errorMessage = "Couldn't prepare playback: \(error.localizedDescription)"
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            pause()
        } else {
            player.currentTime = Double(playheadSample) / sampleRate
            player.play()
            isPlaying = true
            startPlayheadTimer()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopPlayheadTimer()
        if let player {
            playheadSample = Int64(player.currentTime * sampleRate)
        }
    }

    func seek(toSample sample: Int64) {
        let clamped = max(0, min(totalSampleCount, sample))
        playheadSample = clamped
        player?.currentTime = Double(clamped) / sampleRate
    }

    private func startPlayheadTimer() {
        stopPlayheadTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickPlayhead()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        playheadTimer = timer
    }

    private func stopPlayheadTimer() {
        playheadTimer?.invalidate()
        playheadTimer = nil
    }

    private func tickPlayhead() {
        guard let player else { return }
        if !player.isPlaying {
            isPlaying = false
            stopPlayheadTimer()
        }
        playheadSample = Int64(player.currentTime * sampleRate)
    }
}
