import AVFoundation
import XCTest
@testable import Runout

final class LevelMeterTests: XCTestCase {
    func testSilenceIsNegativeInfinityDecibels() {
        let samples: [Float] = [0, 0, 0, 0]
        let (peak, rms) = samples.withUnsafeBufferPointer { LevelMeter.measure(samples: $0) }
        XCTAssertEqual(peak, -.infinity)
        XCTAssertEqual(rms, -.infinity)
    }

    func testFullScaleSineIsApproximatelyZeroDBFS() {
        let sampleCount = 4800
        let samples: [Float] = (0..<sampleCount).map { i in
            Float(sin(2.0 * Double.pi * 440.0 * Double(i) / 48_000.0))
        }
        let (peak, _) = samples.withUnsafeBufferPointer { LevelMeter.measure(samples: $0) }
        XCTAssertEqual(peak, 0, accuracy: 0.1)
    }

    func testRMSIsQuieterThanPeakForASineWave() {
        let sampleCount = 4800
        let samples: [Float] = (0..<sampleCount).map { i in
            Float(sin(2.0 * Double.pi * 440.0 * Double(i) / 48_000.0))
        }
        let (peak, rms) = samples.withUnsafeBufferPointer { LevelMeter.measure(samples: $0) }
        // A sine wave's RMS is peak / sqrt(2), i.e. ~-3dB relative to its peak.
        XCTAssertEqual(rms, peak - 3.0103, accuracy: 0.05)
    }

    func testEmptyBufferDoesNotCrash() {
        let samples: [Float] = []
        let (peak, rms) = samples.withUnsafeBufferPointer { LevelMeter.measure(samples: $0) }
        XCTAssertEqual(peak, -.infinity)
        XCTAssertEqual(rms, -.infinity)
    }

    func testClipIndicatorLatchesAndRequiresExplicitClear() {
        let meter = LevelMeter()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let loudBuffer = makeBuffer(format: format, amplitude: 1.0, frameCount: 100),
              let quietBuffer = makeBuffer(format: format, amplitude: 0.1, frameCount: 100)
        else {
            return XCTFail("Could not construct test buffers")
        }

        meter.process(loudBuffer)
        XCTAssertTrue(meter.channelLevels[0].isClipping)

        // A later, quiet buffer must not silently clear a prior clip.
        meter.process(quietBuffer)
        XCTAssertTrue(meter.channelLevels[0].isClipping)

        meter.clearClipIndicators()
        XCTAssertFalse(meter.channelLevels[0].isClipping)
    }

    private func makeBuffer(format: AVAudioFormat, amplitude: Float, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let channelData = buffer.floatChannelData else { return nil }
        for i in 0..<Int(frameCount) {
            channelData[0][i] = amplitude
        }
        return buffer
    }
}
