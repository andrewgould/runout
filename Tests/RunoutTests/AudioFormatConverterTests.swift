import AVFoundation
import XCTest
@testable import Runout

final class AudioFormatConverterTests: XCTestCase {
    private func makeToneBuffer(format: AVAudioFormat, frameCount: Int, frequency: Double = 440) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<Int(format.channelCount) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<frameCount {
                data[i] = Float(sin(2.0 * Double.pi * frequency * Double(i) / format.sampleRate)) * 0.5
            }
        }
        return buffer
    }

    /// A single buffer's conversion ratio isn't exactly 2x — a resampling filter has internal
    /// latency/history, so individual chunks can be a bit short or long. What must hold is the
    /// aggregate ratio across a whole recording (many buffers, as `RecordingSession` actually
    /// feeds this), which is what a real tap-buffer-by-tap-buffer stream looks like.
    func testSampleRateConversionConvergesToExpectedRatioAcrossManyBuffers() throws {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 96_000, channels: 2, interleaved: false)!
        let converter = try AudioFormatConverter(from: input, to: output)

        var totalInput = 0
        var totalOutput = 0
        for _ in 0..<50 {
            let inputBuffer = makeToneBuffer(format: input, frameCount: 4096)
            let outputBuffer = try converter.convert(inputBuffer)
            totalInput += Int(inputBuffer.frameLength)
            totalOutput += Int(outputBuffer.frameLength)
        }

        let ratio = Double(totalOutput) / Double(totalInput)
        XCTAssertEqual(ratio, 2.0, accuracy: 0.02, "across many buffers the aggregate ratio must converge tightly to 2x")
    }

    func testOutputFormatMatchesRequestedSampleRate() throws {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 96_000, channels: 2, interleaved: false)!
        let converter = try AudioFormatConverter(from: input, to: output)
        let outputBuffer = try converter.convert(makeToneBuffer(format: input, frameCount: 4800))
        XCTAssertEqual(outputBuffer.format.sampleRate, 96_000)
    }

    func testChannelCountDownmixStereoToMonoProducesNonSilentAudio() throws {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let converter = try AudioFormatConverter(from: input, to: output)

        let inputBuffer = makeToneBuffer(format: input, frameCount: 4410)
        let outputBuffer = try converter.convert(inputBuffer)

        XCTAssertEqual(outputBuffer.format.channelCount, 1)
        var peak: Float = 0
        let data = outputBuffer.floatChannelData![0]
        for i in 0..<Int(outputBuffer.frameLength) {
            peak = max(peak, abs(data[i]))
        }
        XCTAssertGreaterThan(peak, 0.1, "downmixed mono output must contain real signal, not silence")
    }

    func testChannelCountUpmixMonoToStereoProducesAudioOnBothChannels() throws {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let converter = try AudioFormatConverter(from: input, to: output)

        let inputBuffer = makeToneBuffer(format: input, frameCount: 4410)
        let outputBuffer = try converter.convert(inputBuffer)

        XCTAssertEqual(outputBuffer.format.channelCount, 2)
        for channel in 0..<2 {
            var peak: Float = 0
            let data = outputBuffer.floatChannelData![channel]
            for i in 0..<Int(outputBuffer.frameLength) {
                peak = max(peak, abs(data[i]))
            }
            XCTAssertGreaterThan(peak, 0.1, "channel \(channel) must contain real signal")
        }
    }

    func testIdentityFormatPassesAudioThroughEssentiallyUnchanged() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 96_000, channels: 2, interleaved: false)!
        let converter = try AudioFormatConverter(from: format, to: format)

        let inputBuffer = makeToneBuffer(format: format, frameCount: 9600)
        let outputBuffer = try converter.convert(inputBuffer)

        XCTAssertEqual(Int(outputBuffer.frameLength), Int(inputBuffer.frameLength))
        let inData = inputBuffer.floatChannelData![0]
        let outData = outputBuffer.floatChannelData![0]
        for i in 0..<Int(inputBuffer.frameLength) {
            XCTAssertEqual(inData[i], outData[i], accuracy: 0.001)
        }
    }
}
