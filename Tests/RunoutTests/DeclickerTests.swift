import XCTest
@testable import Runout

final class DeclickerTests: XCTestCase {
    private func sineWave(count: Int, frequency: Double = 440, sampleRate: Double = 44100, amplitude: Float = 0.5) -> [Float] {
        (0..<count).map { i in
            Float(amplitude) * Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    func testDetectsAndFixesASingleSampleImpulse() {
        var samples = sineWave(count: 200)
        let clickIndex = 100
        let originalValue = samples[clickIndex]
        samples[clickIndex] = 1.0 // a full-scale spike stuck into an otherwise ~0.5-amplitude sine

        let result = Declicker.declick(samples)

        XCTAssertEqual(result.clicksFixed, 1)
        XCTAssertEqual(result.samples[clickIndex], originalValue, accuracy: 0.05)
    }

    func testFixesMultipleIsolatedClicks() {
        var samples = sineWave(count: 500)
        for index in [50, 150, 300, 420] {
            samples[index] = samples[index] > 0 ? -1.0 : 1.0
        }

        let result = Declicker.declick(samples)
        XCTAssertEqual(result.clicksFixed, 4)
    }

    func testCleanSineWaveHasNoClicksFixed() {
        let samples = sineWave(count: 500)
        let result = Declicker.declick(samples)
        XCTAssertEqual(result.clicksFixed, 0)
        XCTAssertEqual(result.samples, samples)
    }

    func testAmplitudeModulatedSignalIsNotFalselyFlagged() {
        // A tremolo-style envelope still varies smoothly sample-to-sample — shouldn't trip the
        // click detector just because overall level rises and falls.
        let carrier = sineWave(count: 1000, frequency: 440)
        let envelope = (0..<1000).map { i in Float(0.5 + 0.5 * sin(2.0 * Double.pi * 5 * Double(i) / 44100)) }
        let samples = zip(carrier, envelope).map(*)

        let result = Declicker.declick(samples)
        XCTAssertEqual(result.clicksFixed, 0)
    }

    func testTooShortInputIsReturnedUnchanged() {
        let samples: [Float] = [0.1, 0.2, 0.3]
        let result = Declicker.declick(samples)
        XCTAssertEqual(result.samples, samples)
        XCTAssertEqual(result.clicksFixed, 0)
    }

    // MARK: - Streaming equivalence (docs/IMPROVEMENT_PLAN.md P1-2/P1-3)

    /// The streaming form must produce byte-identical output to the whole-array form regardless
    /// of how the input is split into chunks — otherwise export results would depend on the
    /// pipeline's internal chunk size.
    func testStreamingOutputIsIdenticalToWholeArrayAcrossChunkings() {
        var samples = sineWave(count: 50_000, frequency: 220, amplitude: 0.4)
        // Deterministic pseudo-random click positions, including ones near chunk boundaries and
        // Declicker block (4096) boundaries.
        var seed: UInt64 = 42
        for _ in 0..<60 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let index = Int(seed % 49_000) + 500
            samples[index] = samples[index] > 0 ? -0.95 : 0.95
        }
        for boundaryIndex in [4095, 4096, 4097, 8191, 8192, 12_288] {
            samples[boundaryIndex] = 0.9
        }

        let reference = Declicker.declick(samples)
        XCTAssertGreaterThan(reference.clicksFixed, 0, "test setup: some clicks must be detected")

        for chunkSize in [1_000, 4_096, 5_000, 17, 50_000] {
            let streamer = StreamingDeclicker()
            var output: [Float] = []
            var offset = 0
            while offset < samples.count {
                let end = min(offset + chunkSize, samples.count)
                output.append(contentsOf: streamer.process(Array(samples[offset..<end])))
                offset = end
            }
            output.append(contentsOf: streamer.flush())

            XCTAssertEqual(output, reference.samples, "chunk size \(chunkSize) diverged from the whole-array result")
            XCTAssertEqual(streamer.clicksFixed, reference.clicksFixed, "chunk size \(chunkSize) fixed a different click count")
        }
    }

    func testStreamingHandlesShortInputLikeWholeArray() {
        let samples: [Float] = [0.1, 0.2, 0.3]
        let streamer = StreamingDeclicker()
        var output = streamer.process(samples)
        output.append(contentsOf: streamer.flush())
        XCTAssertEqual(output, samples)
        XCTAssertEqual(streamer.clicksFixed, 0)
    }
}
