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
        let result = Declicker.declick(samples, windowRadius: 12)
        XCTAssertEqual(result.samples, samples)
        XCTAssertEqual(result.clicksFixed, 0)
    }
}
