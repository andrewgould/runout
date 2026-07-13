import XCTest
@testable import Runout

final class FadeApplierTests: XCTestCase {
    func testFadeInRampsLinearlyFromZero() {
        let samples = [Float](repeating: 1.0, count: 10)
        let output = FadeApplier.applyFades(to: samples, fadeSampleCount: 4)

        XCTAssertEqual(output[0], 0.0, accuracy: 0.0001)
        XCTAssertEqual(output[1], 0.25, accuracy: 0.0001)
        XCTAssertEqual(output[2], 0.5, accuracy: 0.0001)
        XCTAssertEqual(output[3], 0.75, accuracy: 0.0001)
        XCTAssertEqual(output[4], 1.0, accuracy: 0.0001, "unaffected middle sample")
    }

    func testFadeOutRampsLinearlyToZero() {
        let samples = [Float](repeating: 1.0, count: 10)
        let output = FadeApplier.applyFades(to: samples, fadeSampleCount: 4)

        XCTAssertEqual(output[9], 0.0, accuracy: 0.0001)
        XCTAssertEqual(output[8], 0.25, accuracy: 0.0001)
        XCTAssertEqual(output[7], 0.5, accuracy: 0.0001)
        XCTAssertEqual(output[6], 0.75, accuracy: 0.0001)
        XCTAssertEqual(output[5], 1.0, accuracy: 0.0001, "unaffected middle sample")
    }

    func testZeroFadeDurationLeavesSamplesUnchanged() {
        let samples: [Float] = [1, 2, 3, 4, 5]
        XCTAssertEqual(FadeApplier.applyFades(to: samples, fadeSampleCount: 0), samples)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(FadeApplier.applyFades(to: [], fadeSampleCount: 10), [])
    }

    func testFadeLongerThanHalfTheBufferIsClampedSoFadesDontOverlap() {
        // 10 samples, requesting a fade of 100 — should clamp to 5 (half), so fade-in and
        // fade-out each own exactly half without overlapping into each other.
        let samples = [Float](repeating: 1.0, count: 10)
        let output = FadeApplier.applyFades(to: samples, fadeSampleCount: 100)

        XCTAssertEqual(output.count, 10)
        XCTAssertEqual(output[0], 0.0, accuracy: 0.0001)
        XCTAssertEqual(output[9], 0.0, accuracy: 0.0001)
    }

    func testSampleCountForDurationComputesFromSampleRate() {
        XCTAssertEqual(FadeApplier.sampleCount(forDurationSeconds: 0.010, sampleRate: 44100), 441)
        XCTAssertEqual(FadeApplier.sampleCount(forDurationSeconds: 0, sampleRate: 44100), 0)
        XCTAssertEqual(FadeApplier.sampleCount(forDurationSeconds: 0.010, sampleRate: 0), 0)
    }

    /// The chunked form (docs/IMPROVEMENT_PLAN.md P1-2) must match the whole-array form exactly
    /// no matter where the chunk boundaries fall — including boundaries inside a fade region.
    func testChunkedFadesMatchWholeArrayAcrossChunkings() {
        let samples = (0..<10_000).map { i in Float(sin(Double(i) * 0.05)) }
        let fadeSampleCount = 441
        let reference = FadeApplier.applyFades(to: samples, fadeSampleCount: fadeSampleCount)

        for chunkSize in [1, 100, 441, 500, 9_999, 10_000] {
            var output: [Float] = []
            var offset = 0
            while offset < samples.count {
                let end = min(offset + chunkSize, samples.count)
                var chunk = Array(samples[offset..<end])
                FadeApplier.applyFades(
                    to: &chunk,
                    chunkStartIndex: Int64(offset),
                    totalSampleCount: Int64(samples.count),
                    fadeSampleCount: fadeSampleCount
                )
                output.append(contentsOf: chunk)
                offset = end
            }
            XCTAssertEqual(output, reference, "chunk size \(chunkSize) diverged from the whole-array fade")
        }
    }
}
