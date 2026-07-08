import AVFoundation
import XCTest
@testable import Runout

final class RecordingWriterTests: XCTestCase {
    func testWrittenFileIsFLACAndRoundTripsSampleCountAndAudio() async throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            return XCTFail("Could not construct format")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("flac")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = RecordingWriter()
        try await writer.start(url: url, sourceFormat: format, bitDepth: 24)

        let frameCount: AVAudioFrameCount = 4800
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData
        else {
            return XCTFail("Could not construct buffer")
        }
        buffer.frameLength = frameCount
        for i in 0..<Int(frameCount) {
            channelData[0][i] = Float(sin(2.0 * Double.pi * 440.0 * Double(i) / 48_000.0)) * 0.5
        }

        // Simulate two consecutive tap callbacks, each handing off a copy (as RecordingSession will).
        guard let copy1 = buffer.copy(), let copy2 = buffer.copy() else {
            return XCTFail("Could not copy buffer")
        }
        try await writer.append(copy1)
        try await writer.append(copy2)

        let framesWritten = await writer.framesWritten
        XCTAssertEqual(framesWritten, AVAudioFramePosition(frameCount * 2))

        await writer.stop()

        // Confirm this is really a FLAC file on disk, not just something AVAudioFile happens to read back.
        let fileHandle = try FileHandle(forReadingFrom: url)
        let magic = fileHandle.readData(ofLength: 4)
        try fileHandle.close()
        XCTAssertEqual(magic, Data("fLaC".utf8))

        let readBackFile = try AVAudioFile(forReading: url)
        XCTAssertEqual(readBackFile.length, AVAudioFramePosition(frameCount * 2))

        guard let readBackBuffer = AVAudioPCMBuffer(pcmFormat: readBackFile.processingFormat, frameCapacity: AVAudioFrameCount(readBackFile.length)) else {
            return XCTFail("Could not allocate read-back buffer")
        }
        try readBackFile.read(into: readBackBuffer)
        XCTAssertEqual(readBackBuffer.frameLength, AVAudioFrameCount(frameCount * 2))

        // FLAC quantizes our float32 source to 24-bit integer samples, so this is lossy relative
        // to the original float32 value (though lossless from that quantization point onward) —
        // tolerance is generous relative to a 24-bit step (~1.2e-7) to allow for that.
        let readSample = readBackBuffer.floatChannelData![0][10]
        let expectedSample = channelData[0][10]
        XCTAssertEqual(readSample, expectedSample, accuracy: 0.001)
    }

    func testBufferCopyIsIndependentOfSourceMutation() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10),
              let channelData = buffer.floatChannelData
        else {
            return XCTFail("Could not construct buffer")
        }
        buffer.frameLength = 10
        for i in 0..<10 { channelData[0][i] = 1.0 }

        guard let copy = buffer.copy(), let copyData = copy.floatChannelData else {
            return XCTFail("Could not copy buffer")
        }

        // Mutate the source after copying — the copy must be unaffected.
        for i in 0..<10 { channelData[0][i] = 0.0 }

        XCTAssertEqual(copyData[0][0], 1.0)
        XCTAssertEqual(copy.frameLength, 10)
    }
}
