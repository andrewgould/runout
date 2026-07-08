import AVFoundation
import XCTest
@testable import Runout

final class PeakCacheBuilderTests: XCTestCase {
    func testBuildsPlausiblePeaksForAFullScaleSineWave() async throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            return XCTFail("Could not construct format")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("flac")
        defer { try? FileManager.default.removeItem(at: url) }

        // 4 seconds at 48kHz gives comfortably more than one finest-level bucket (256 samples)
        // and enough buckets to build multiple mip levels.
        let frameCount: AVAudioFrameCount = 48_000 * 4
        let writer = RecordingWriter()
        try await writer.start(url: url, sourceFormat: format, bitDepth: 24)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData
        else {
            return XCTFail("Could not construct buffer")
        }
        buffer.frameLength = frameCount
        for i in 0..<Int(frameCount) {
            channelData[0][i] = Float(sin(2.0 * Double.pi * 440.0 * Double(i) / 48_000.0))
        }
        guard let copy = buffer.copy() else { return XCTFail("Could not copy buffer") }
        try await writer.append(copy)
        await writer.stop()

        let cache = try PeakCacheBuilder.build(fromFileAt: url)

        XCTAssertEqual(cache.samplesPerBucketAtFinestLevel, PeakCacheBuilder.samplesPerBucketAtFinestLevel)
        XCTAssertGreaterThan(cache.levels.count, 1, "4 seconds at 48kHz should produce more than one mip level")

        let expectedFinestBucketCount = Int(frameCount) / PeakCacheBuilder.samplesPerBucketAtFinestLevel
        XCTAssertEqual(cache.levels[0].count, expectedFinestBucketCount)

        // A full-scale sine wave's peaks should sit close to +/- Int16.max in (almost) every bucket.
        let nearFullScale = Int16(Double(Int16.max) * 0.9)
        let bucketsNearFullScale = cache.levels[0].filter { $0.max >= nearFullScale && $0.min <= -nearFullScale }
        XCTAssertGreaterThan(Double(bucketsNearFullScale.count) / Double(cache.levels[0].count), 0.9)

        // Each mip level should be roughly half the bucket count of the previous one.
        for i in 1..<cache.levels.count {
            let previousCount = cache.levels[i - 1].count
            let expectedCount = (previousCount + 1) / 2
            XCTAssertEqual(cache.levels[i].count, expectedCount)
        }
    }

    /// A FLAC file that never had any audio appended to it isn't a file `AVAudioFile` can open at
    /// all (confirmed against a real file: `ExtAudioFileOpenURL` itself fails) — this documents
    /// that real limitation rather than asserting behavior `PeakCacheBuilder` can't control.
    /// Callers should never build a peak cache for a side that was never actually recorded.
    func testFileWithNoAudioEverWrittenCannotBeOpened() async throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            return XCTFail("Could not construct format")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("flac")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = RecordingWriter()
        try await writer.start(url: url, sourceFormat: format, bitDepth: 24)
        await writer.stop()

        XCTAssertThrowsError(try PeakCacheBuilder.build(fromFileAt: url))
    }
}
