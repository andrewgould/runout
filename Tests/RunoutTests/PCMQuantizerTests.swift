import XCTest
@testable import Runout

final class PCMQuantizerTests: XCTestCase {
    func testZeroMapsToZero() {
        XCTAssertEqual(PCMQuantizer.quantizeToInt16([0.0]), [0])
    }

    func testFullScalePositiveMapsToMaxInt16() {
        XCTAssertEqual(PCMQuantizer.quantizeToInt16([1.0]), [32767])
    }

    /// -1.0 maps to -32767, not -32768: the scale factor (32767) is symmetric for both signs,
    /// so the full range isn't used on the negative side — standard, matches most PCM encoders.
    /// -32768 is still reachable, just only for input more negative than -1.0 (clamped).
    func testFullScaleNegativeMapsToNegativeMax() {
        XCTAssertEqual(PCMQuantizer.quantizeToInt16([-1.0]), [-32767])
    }

    /// Out-of-range input (a bug elsewhere, or a fade/declick edge case) must clamp, never wrap
    /// around to the opposite sign — a wrapped sample would be a much louder, more audible
    /// artifact than a merely clipped one.
    func testOutOfRangeInputClampsRatherThanWrapping() {
        XCTAssertEqual(PCMQuantizer.quantizeToInt16([1.5]), [32767])
        XCTAssertEqual(PCMQuantizer.quantizeToInt16([-1.5]), [-32768])
    }

    func testRoundsToNearestRatherThanTruncating() {
        // 0.5/32767 is small enough that rounding vs truncation only differs by 1 LSB — pick a
        // value where the fractional part is unambiguous.
        let almostOne: Float = 32760.6 / 32767.0
        XCTAssertEqual(PCMQuantizer.quantizeToInt16([almostOne]), [32761])
    }

    func testPreservesSampleCountAndOrder() {
        let input: [Float] = [0.1, -0.2, 0.3, -0.4, 0.0]
        let output = PCMQuantizer.quantizeToInt16(input)
        XCTAssertEqual(output.count, input.count)
        // Monotonic ordering must be preserved — quantization is a scale+round, not a reorder.
        XCTAssertLessThan(output[1], output[0])
        XCTAssertLessThan(output[3], output[2])
    }
}
