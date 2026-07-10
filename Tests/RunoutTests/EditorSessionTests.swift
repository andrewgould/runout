import AVFoundation
import XCTest
@testable import Runout

@MainActor
final class EditorSessionTests: XCTestCase {
    private var fileURL: URL!
    private var document: RunoutDocument!
    private var sideID: UUID!
    private let sampleRate: Double = 48_000
    private let totalSampleCount: Int64 = 48_000 // 1 second

    override func setUp() async throws {
        try await super.setUp()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return XCTFail("Could not construct format")
        }
        document = RunoutDocument()
        fileURL = document.scratchFileURL(named: "side-a.flac")

        let writer = RecordingWriter()
        try await writer.start(url: fileURL, sourceFormat: format, bitDepth: 24)
        let frameCount = AVAudioFrameCount(totalSampleCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData
        else {
            return XCTFail("Could not construct buffer")
        }
        buffer.frameLength = frameCount
        for i in 0..<Int(frameCount) {
            channelData[0][i] = Float(sin(2.0 * Double.pi * 440.0 * Double(i) / sampleRate))
        }
        guard let copy = buffer.copy() else { return XCTFail("Could not copy buffer") }
        try await writer.append(copy)
        await writer.stop()

        try document.ingestFile(at: fileURL, asRelativePath: "side-a.flac")
        let side = RecordingSide(
            label: "Side A",
            masterFileRelativePath: "side-a.flac",
            peakCacheRelativePath: "side-a.peaks",
            durationSamples: totalSampleCount,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        sideID = side.id
        document.project.sides = [side]
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL)
        try await super.tearDown()
    }

    private func makeSession() -> EditorSession {
        EditorSession(document: document, sideID: sideID, recordingFileURL: fileURL, sampleRate: sampleRate, totalSampleCount: totalSampleCount)
    }

    func testAddMarkerWithoutSnappingUsesExactSample() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        session.addMarker(atSample: 12345)
        XCTAssertEqual(session.markers.map(\.sampleOffset), [12345])
    }

    func testMarkersStaySortedBySampleOffset() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        session.addMarker(atSample: 30000)
        session.addMarker(atSample: 10000)
        session.addMarker(atSample: 20000)
        XCTAssertEqual(session.markers.map(\.sampleOffset), [10000, 20000, 30000])
    }

    func testDeleteMarkerRemovesIt() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        session.addMarker(atSample: 10000)
        let id = session.markers[0].id
        session.deleteMarker(id)
        XCTAssertTrue(session.markers.isEmpty)
    }

    func testUndoRedoOfAddMarker() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        session.addMarker(atSample: 10000)
        XCTAssertEqual(session.markers.count, 1)

        session.undo()
        XCTAssertTrue(session.markers.isEmpty)

        session.redo()
        XCTAssertEqual(session.markers.map(\.sampleOffset), [10000])
    }

    func testUndoRedoOfDeleteMarker() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        session.addMarker(atSample: 10000)
        let id = session.markers[0].id
        session.deleteMarker(id)
        XCTAssertTrue(session.markers.isEmpty)

        session.undo()
        XCTAssertEqual(session.markers.map(\.sampleOffset), [10000])

        session.redo()
        XCTAssertTrue(session.markers.isEmpty)
    }

    func testUndoRedoOfMoveMarker() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        session.addMarker(atSample: 10000)
        let id = session.markers[0].id

        session.moveMarker(id, toSample: 20000)
        XCTAssertEqual(session.markers.map(\.sampleOffset), [20000])

        session.undo()
        XCTAssertEqual(session.markers.map(\.sampleOffset), [10000])

        session.redo()
        XCTAssertEqual(session.markers.map(\.sampleOffset), [20000])
    }

    /// Markers are written straight through to `document.project.sides[i].markers` on every
    /// mutation (see `EditorSession.saveMarkers()`) — a second session reading the same document
    /// sees them immediately, and (per `RunoutDocumentTests`) that `Project` round-trips through
    /// real disk I/O losslessly, so together these confirm markers genuinely persist.
    func testMarkersAreVisibleToASecondSessionReadingTheSameDocument() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        session.addMarker(atSample: 5000)
        session.addMarker(atSample: 15000)

        let secondSession = makeSession()
        XCTAssertEqual(secondSession.markers.map(\.sampleOffset), [5000, 15000])
    }

    func testSplitAtPlayheadAddsMarkerAtCurrentPlayhead() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        session.seek(toSample: 7000)
        session.splitAtPlayhead()
        XCTAssertEqual(session.markers.map(\.sampleOffset), [7000])
    }

    func testAddMarkerBeyondTotalSampleCountClamps() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        session.addMarker(atSample: totalSampleCount + 100_000)
        XCTAssertEqual(session.markers.first?.sampleOffset, totalSampleCount)
    }

    func testAddMarkerWithSnappingStaysWithinSearchWindowOfRequestedSample() {
        let session = makeSession()
        session.snapToZeroCrossing = true
        session.addMarker(atSample: 20000)
        guard let snapped = session.markers.first?.sampleOffset else {
            return XCTFail("Expected a marker to be added")
        }
        XCTAssertLessThanOrEqual(abs(snapped - 20000), Int64(MarkerSnapping.defaultSearchWindowInSamples))
    }

    // MARK: - Silence-detected proposals (M8)
    //
    // SilenceDetectorTests already covers the detection algorithm itself; these just verify
    // EditorSession's review plumbing (never auto-committing, accept/reject, de-duplication
    // against existing markers) using small synthetic peak caches sized to fit the 1-second
    // fixture from setUp() — with an explicitly short minimumGapDuration to match.

    private static let testBucketSize = 256
    private static let testMinimumGapDuration = 0.2

    private func makeSilentGapPeakCache() -> PeakCache {
        let loud = PeakBucket(min: -20000, max: 20000)
        let silent = PeakBucket(min: -10, max: 10)
        let buckets = Array(repeating: loud, count: 30) + Array(repeating: silent, count: 60) + Array(repeating: loud, count: 30)
        return PeakCache(samplesPerBucketAtFinestLevel: Self.testBucketSize, levels: [buckets])
    }

    private func makeTwoGapPeakCache() -> PeakCache {
        let loud = PeakBucket(min: -20000, max: 20000)
        let silent = PeakBucket(min: -10, max: 10)
        let buckets = Array(repeating: loud, count: 20)
            + Array(repeating: silent, count: 50)
            + Array(repeating: loud, count: 20)
            + Array(repeating: silent, count: 50)
            + Array(repeating: loud, count: 20)
        return PeakCache(samplesPerBucketAtFinestLevel: Self.testBucketSize, levels: [buckets])
    }

    func testDetectSilenceBreaksPopulatesProposedMarkersWithoutCommitting() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        session.detectSilenceBreaks(peakCache: makeSilentGapPeakCache(), minimumGapDuration: Self.testMinimumGapDuration)

        XCTAssertEqual(session.proposedMarkers.count, 1)
        XCTAssertTrue(session.markers.isEmpty, "detecting must never auto-commit")
    }

    func testAcceptProposedMarkerCommitsItAsARealMarker() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        session.detectSilenceBreaks(peakCache: makeSilentGapPeakCache(), minimumGapDuration: Self.testMinimumGapDuration)
        guard let proposed = session.proposedMarkers.first else { return XCTFail("Expected a proposal") }

        session.acceptProposedMarker(proposed.id)

        XCTAssertTrue(session.proposedMarkers.isEmpty)
        XCTAssertEqual(session.markers.map(\.sampleOffset), [proposed.sampleOffset])
    }

    func testRejectProposedMarkerDiscardsItWithoutCommitting() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        session.detectSilenceBreaks(peakCache: makeSilentGapPeakCache(), minimumGapDuration: Self.testMinimumGapDuration)
        guard let proposed = session.proposedMarkers.first else { return XCTFail("Expected a proposal") }

        session.rejectProposedMarker(proposed.id)

        XCTAssertTrue(session.proposedMarkers.isEmpty)
        XCTAssertTrue(session.markers.isEmpty)
    }

    func testAcceptAllProposedMarkersCommitsEveryOne() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        session.detectSilenceBreaks(peakCache: makeTwoGapPeakCache(), minimumGapDuration: Self.testMinimumGapDuration)
        XCTAssertEqual(session.proposedMarkers.count, 2)

        session.acceptAllProposedMarkers()

        XCTAssertTrue(session.proposedMarkers.isEmpty)
        XCTAssertEqual(session.markers.count, 2)
    }

    func testRejectAllProposedMarkersDiscardsAllWithoutCommitting() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        session.detectSilenceBreaks(peakCache: makeTwoGapPeakCache(), minimumGapDuration: Self.testMinimumGapDuration)
        XCTAssertEqual(session.proposedMarkers.count, 2)

        session.rejectAllProposedMarkers()

        XCTAssertTrue(session.proposedMarkers.isEmpty)
        XCTAssertTrue(session.markers.isEmpty)
    }

    func testDetectSilenceBreaksSkipsProposalsNearExistingMarkers() {
        let session = makeSession()
        session.snapToZeroCrossing = false
        let cache = makeSilentGapPeakCache()

        // The gap in makeSilentGapPeakCache runs from bucket 30 to bucket 90 (60 silent
        // buckets), so its midpoint is bucket 60 — place a marker essentially right there.
        let midpointSample = Int64(60 * Self.testBucketSize)
        session.addMarker(atSample: midpointSample)

        session.detectSilenceBreaks(peakCache: cache, minimumGapDuration: Self.testMinimumGapDuration)

        XCTAssertTrue(session.proposedMarkers.isEmpty, "shouldn't propose a marker essentially on top of an existing one")
    }
}
