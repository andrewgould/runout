import XCTest
@testable import Runout

final class SilenceDetectorTests: XCTestCase {
    private let sampleRate: Double = 48_000
    private let bucketSize = 256

    /// Builds a synthetic finest-level peak cache: `loud` buckets, then `silentBucketCount`
    /// silent buckets, then `loud` buckets again — a single gap in the middle.
    private func makeCache(loudBucketsBefore: Int, silentBucketCount: Int, loudBucketsAfter: Int) -> PeakCache {
        let loud = PeakBucket(min: -20000, max: 20000)
        let silent = PeakBucket(min: -10, max: 10)
        let buckets = Array(repeating: loud, count: loudBucketsBefore)
            + Array(repeating: silent, count: silentBucketCount)
            + Array(repeating: loud, count: loudBucketsAfter)
        return PeakCache(samplesPerBucketAtFinestLevel: bucketSize, levels: [buckets])
    }

    private func bucketsForDuration(_ seconds: Double) -> Int {
        Int((seconds * sampleRate) / Double(bucketSize))
    }

    func testDetectsAGapLongerThanMinimumDuration() {
        let gapBuckets = bucketsForDuration(3.0) // longer than the 2s default minimum
        let cache = makeCache(loudBucketsBefore: 100, silentBucketCount: gapBuckets, loudBucketsAfter: 100)

        let markers = SilenceDetector.detectTrackBreaks(in: cache, sampleRate: sampleRate)

        XCTAssertEqual(markers.count, 1)
        let expectedMidpointBucket = 100 + gapBuckets / 2
        let expectedSample = Int64(expectedMidpointBucket * bucketSize)
        XCTAssertEqual(markers[0].sampleOffset, expectedSample)
    }

    func testIgnoresGapsShorterThanMinimumDuration() {
        let shortGapBuckets = bucketsForDuration(0.5) // shorter than the 2s default minimum
        let cache = makeCache(loudBucketsBefore: 100, silentBucketCount: shortGapBuckets, loudBucketsAfter: 100)

        let markers = SilenceDetector.detectTrackBreaks(in: cache, sampleRate: sampleRate)

        XCTAssertTrue(markers.isEmpty)
    }

    func testTrailingSilenceAtEndOfRecordingIsNotProposedAsABreak() {
        let gapBuckets = bucketsForDuration(3.0)
        let cache = makeCache(loudBucketsBefore: 100, silentBucketCount: gapBuckets, loudBucketsAfter: 0)

        let markers = SilenceDetector.detectTrackBreaks(in: cache, sampleRate: sampleRate)

        XCTAssertTrue(markers.isEmpty, "silence running to the end of the recording is trailing silence, not a track break")
    }

    func testDetectsMultipleGaps() {
        let gapBuckets = bucketsForDuration(3.0)
        let loud = PeakBucket(min: -20000, max: 20000)
        let silent = PeakBucket(min: -10, max: 10)
        let buckets = Array(repeating: loud, count: 100)
            + Array(repeating: silent, count: gapBuckets)
            + Array(repeating: loud, count: 100)
            + Array(repeating: silent, count: gapBuckets)
            + Array(repeating: loud, count: 100)
        let cache = PeakCache(samplesPerBucketAtFinestLevel: bucketSize, levels: [buckets])

        let markers = SilenceDetector.detectTrackBreaks(in: cache, sampleRate: sampleRate)

        XCTAssertEqual(markers.count, 2)
    }

    func testEmptyCacheProducesNoMarkers() {
        let cache = PeakCache(samplesPerBucketAtFinestLevel: bucketSize, levels: [[]])
        XCTAssertTrue(SilenceDetector.detectTrackBreaks(in: cache, sampleRate: sampleRate).isEmpty)
    }

    func testThresholdControlsWhatCountsAsSilent() {
        // A "quiet but not silent" passage: peak around -30dBFS.
        let quietAmplitude = pow(10, Float(-30) / 20)
        let quietBucket = PeakBucket(
            min: -Int16(quietAmplitude * Float(Int16.max)),
            max: Int16(quietAmplitude * Float(Int16.max))
        )
        let loud = PeakBucket(min: -20000, max: 20000)
        let gapBuckets = bucketsForDuration(3.0)
        let buckets = Array(repeating: loud, count: 100) + Array(repeating: quietBucket, count: gapBuckets) + Array(repeating: loud, count: 100)
        let cache = PeakCache(samplesPerBucketAtFinestLevel: bucketSize, levels: [buckets])

        // -40dBFS default threshold: -30dBFS quiet passage should NOT count as silence.
        XCTAssertTrue(SilenceDetector.detectTrackBreaks(in: cache, sampleRate: sampleRate).isEmpty)

        // A more lenient -20dBFS threshold: now it should.
        let markers = SilenceDetector.detectTrackBreaks(in: cache, sampleRate: sampleRate, thresholdDecibels: -20)
        XCTAssertEqual(markers.count, 1)
    }
}
