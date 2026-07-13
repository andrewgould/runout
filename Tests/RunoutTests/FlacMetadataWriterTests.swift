import AVFoundation
import XCTest
@testable import Runout

/// These tests deliberately re-parse the output with hand-rolled reading code, independent of
/// `FlacMetadataWriter`'s own parsing — so a shared mistaken assumption in both reader and
/// writer wouldn't silently pass. See docs/FLAC_METADATA_SPEC.md's testing section.
final class FlacMetadataWriterTests: XCTestCase {
    private func makeSyntheticFlac(seconds: Double = 0.1) async throws -> URL {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            throw NSError(domain: "test", code: 1)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("flac")

        let writer = RecordingWriter()
        try await writer.start(url: url, sourceFormat: format, bitDepth: 24)
        let frameCount = AVAudioFrameCount(48_000 * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData
        else { throw NSError(domain: "test", code: 2) }
        buffer.frameLength = frameCount
        for i in 0..<Int(frameCount) {
            channelData[0][i] = Float(sin(2.0 * Double.pi * 440.0 * Double(i) / 48_000.0)) * 0.5
        }
        guard let copy = buffer.copy() else { throw NSError(domain: "test", code: 3) }
        try await writer.append(copy)
        await writer.stop()
        return url
    }

    private func makeTags() -> FlacMetadataWriter.Tags {
        FlacMetadataWriter.Tags(
            title: "Come Together",
            artist: "The Beatles",
            album: "Abbey Road",
            albumArtist: "The Beatles",
            trackNumber: 1,
            discNumber: 1,
            date: "1969",
            genre: "Rock",
            comment: "Ripped with Runout"
        )
    }

    func testWrittenFileStartsWithFlacMagic() async throws {
        let url = try await makeSyntheticFlac()
        defer { try? FileManager.default.removeItem(at: url) }
        try FlacMetadataWriter.write(tags: makeTags(), picture: nil, to: url)

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.prefix(4), Data("fLaC".utf8))
    }

    func testTagsRoundTripThroughIndependentParsing() async throws {
        let url = try await makeSyntheticFlac()
        defer { try? FileManager.default.removeItem(at: url) }
        try FlacMetadataWriter.write(tags: makeTags(), picture: nil, to: url)

        let comments = try readVorbisComments(from: url)
        XCTAssertEqual(comments["TITLE"], "Come Together")
        XCTAssertEqual(comments["ARTIST"], "The Beatles")
        XCTAssertEqual(comments["ALBUM"], "Abbey Road")
        XCTAssertEqual(comments["ALBUMARTIST"], "The Beatles")
        XCTAssertEqual(comments["TRACKNUMBER"], "1")
        XCTAssertEqual(comments["DISCNUMBER"], "1")
        XCTAssertEqual(comments["DATE"], "1969")
        XCTAssertEqual(comments["GENRE"], "Rock")
        XCTAssertEqual(comments["COMMENT"], "Ripped with Runout")
    }

    /// docs/IMPROVEMENT_PLAN.md P3: AVLinearPCMBitDepthKey is absent from a real FLAC file's
    /// fileFormat.settings (confirmed empirically against a real written file), so callers must
    /// read the true bit depth from STREAMINFO instead of trusting that key.
    /// Reads back whatever bit depth a real file was ACTUALLY encoded at — this test
    /// deliberately doesn't assert a specific number, because (see docs/IMPROVEMENT_PLAN.md
    /// P1-7, discovered while writing this test) `AVLinearPCMBitDepthKey` currently has no
    /// effect on Core Audio's FLAC encoder for a float32 source: files requested at 16-bit and
    /// 24-bit come out byte-for-byte identical. `readBitDepth` is correct regardless — it
    /// reports what a file really contains, which is the whole point of not trusting a wrong
    /// guess — this test just pins that its answer is self-consistent and sane.
    func testReadBitDepthReportsASaneValueForARealFile() async throws {
        let url = try await makeSyntheticFlac()
        defer { try? FileManager.default.removeItem(at: url) }
        let readDepth = try FlacMetadataWriter.readBitDepth(ofFileAt: url)
        XCTAssertTrue([16, 24].contains(readDepth), "expected a real, standard bit depth, got \(readDepth)")
    }

    /// Direct evidence for docs/IMPROVEMENT_PLAN.md P1-7: two files requested at different bit
    /// depths through the exact writer path RecordingSession/ExportPipeline use are byte-for-byte
    /// identical, proving the requested depth has zero effect on the encoder's actual output.
    /// docs/IMPROVEMENT_PLAN.md P1-7, now fixed: a float32 client format made
    /// `AVLinearPCMBitDepthKey` a no-op regardless of what `settings` requested. The real fix is
    /// the client format itself — `RecordingWriter`'s callers (`RecordingSession`,
    /// `ExportPipeline`) now hand it an `.pcmFormatInt16` buffer for a 16-bit request. This test
    /// exercises `RecordingWriter` exactly as those callers do (varying commonFormat, not just
    /// the `bitDepth` int) and confirms the two outputs now genuinely differ and decode correctly.
    func testMatchingClientFormatToBitDepthProducesARealDifference() async throws {
        var outputsByBitDepth: [Int: Data] = [:]
        for bitDepth in [16, 24] {
            let commonFormat: AVAudioCommonFormat = bitDepth == 16 ? .pcmFormatInt16 : .pcmFormatFloat32
            guard let format = AVAudioFormat(commonFormat: commonFormat, sampleRate: 48_000, channels: 1, interleaved: false) else {
                return XCTFail("format")
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("flac")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = RecordingWriter()
            try await writer.start(url: url, sourceFormat: format, bitDepth: bitDepth)

            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            buffer.frameLength = 4800
            for i in 0..<4800 {
                let sample = sin(2.0 * Double.pi * 440.0 * Double(i) / 48_000.0) * 0.5
                if bitDepth == 16 {
                    buffer.int16ChannelData![0][i] = Int16((sample * 32767).rounded())
                } else {
                    buffer.floatChannelData![0][i] = Float(sample)
                }
            }
            try await writer.append(buffer)
            await writer.stop()
            outputsByBitDepth[bitDepth] = try Data(contentsOf: url)

            let readDepth = try FlacMetadataWriter.readBitDepth(ofFileAt: url)
            XCTAssertEqual(readDepth, bitDepth, "STREAMINFO must report the depth actually requested")
        }

        XCTAssertNotEqual(outputsByBitDepth[16], outputsByBitDepth[24], "16-bit and 24-bit output must now genuinely differ")
        XCTAssertLessThan(outputsByBitDepth[16]!.count, outputsByBitDepth[24]!.count, "16-bit encoding of the same audio should be smaller")
    }

    /// Confirms the real, live bug this fix addresses: AVAudioFile's own settings dictionary
    /// doesn't carry the bit depth for a FLAC source, so any code trusting it needs a real
    /// fallback (STREAMINFO), not a guessed default.
    func testAVLinearPCMBitDepthKeyIsAbsentFromRealFlacFileFormat() async throws {
        let url = try await makeSyntheticFlac()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        XCTAssertNil(file.fileFormat.settings[AVLinearPCMBitDepthKey], "if this ever starts passing, ExportView's fallback logic can be simplified")
    }

    func testComposerAndTotalsRoundTripThroughIndependentParsing() async throws {
        let url = try await makeSyntheticFlac()
        defer { try? FileManager.default.removeItem(at: url) }
        var tags = makeTags()
        tags.composer = "George Martin"
        tags.trackTotal = 17
        tags.discTotal = 2
        try FlacMetadataWriter.write(tags: tags, picture: nil, to: url)

        let comments = try readVorbisComments(from: url)
        XCTAssertEqual(comments["COMPOSER"], "George Martin")
        XCTAssertEqual(comments["TRACKTOTAL"], "17")
        XCTAssertEqual(comments["DISCTOTAL"], "2")
    }

    func testOmitsNonPositiveOrNilTotalsRatherThanWritingZero() async throws {
        let url = try await makeSyntheticFlac()
        defer { try? FileManager.default.removeItem(at: url) }
        var tags = makeTags()
        tags.trackTotal = 0
        tags.discTotal = nil
        try FlacMetadataWriter.write(tags: tags, picture: nil, to: url)

        let comments = try readVorbisComments(from: url)
        XCTAssertNil(comments["TRACKTOTAL"])
        XCTAssertNil(comments["DISCTOTAL"])
    }

    func testOmitsEmptyOptionalFieldsRatherThanWritingBlankValues() async throws {
        let url = try await makeSyntheticFlac()
        defer { try? FileManager.default.removeItem(at: url) }
        var tags = makeTags()
        tags.date = nil
        tags.genre = ""
        tags.comment = nil
        try FlacMetadataWriter.write(tags: tags, picture: nil, to: url)

        let comments = try readVorbisComments(from: url)
        XCTAssertNil(comments["DATE"])
        XCTAssertNil(comments["GENRE"])
        XCTAssertNil(comments["COMMENT"])
        XCTAssertEqual(comments["TITLE"], "Come Together")
    }

    func testPictureBlockRoundTripsThroughIndependentParsing() async throws {
        let url = try await makeSyntheticFlac()
        defer { try? FileManager.default.removeItem(at: url) }
        let imageBytes = Data((0..<256).map { UInt8($0) }) // synthetic "image" data, not a real JPEG
        let picture = FlacMetadataWriter.Picture(mimeType: "image/jpeg", data: imageBytes, width: 600, height: 600)
        try FlacMetadataWriter.write(tags: makeTags(), picture: picture, to: url)

        let parsedPicture = try readPictureBlock(from: url)
        XCTAssertEqual(parsedPicture.mimeType, "image/jpeg")
        XCTAssertEqual(parsedPicture.width, 600)
        XCTAssertEqual(parsedPicture.height, 600)
        XCTAssertEqual(parsedPicture.data, imageBytes)
    }

    /// The 24-bit block-length regression (docs/IMPROVEMENT_PLAN.md P0-2): a picture past the
    /// limit previously had its length silently bit-masked, writing a corrupt file. It must
    /// throw — and must not have touched the file on disk.
    func testOversizedPictureThrowsAndLeavesFileUntouched() async throws {
        let url = try await makeSyntheticFlac()
        defer { try? FileManager.default.removeItem(at: url) }
        let originalBytes = try Data(contentsOf: url)

        let oversized = FlacMetadataWriter.Picture(
            mimeType: "image/jpeg",
            data: Data(count: FlacMetadataWriter.maxBlockLength + 1),
            width: 9000,
            height: 9000
        )
        XCTAssertThrowsError(try FlacMetadataWriter.write(tags: makeTags(), picture: oversized, to: url)) { error in
            guard case FlacMetadataError.metadataBlockTooLarge = error else {
                XCTFail("expected metadataBlockTooLarge, got \(error)")
                return
            }
        }

        XCTAssertEqual(try Data(contentsOf: url), originalBytes, "a failed write must leave the original file intact")
    }

    func testAudioFrameBytesAreByteForByteIdenticalBeforeAndAfter() async throws {
        let url = try await makeSyntheticFlac(seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }

        let beforeData = try Data(contentsOf: url)
        let beforeAudioOffset = try findAudioFramesOffset(in: beforeData)
        let beforeAudioBytes = beforeData[beforeAudioOffset...]

        try FlacMetadataWriter.write(tags: makeTags(), picture: nil, to: url)

        let afterData = try Data(contentsOf: url)
        let afterAudioOffset = try findAudioFramesOffset(in: afterData)
        let afterAudioBytes = afterData[afterAudioOffset...]

        XCTAssertEqual(Data(afterAudioBytes), Data(beforeAudioBytes), "metadata writing must never touch the audio frame bytes")
    }

    func testResultDecodesCorrectlyAndIsStillLosslesslyPlayable() async throws {
        let url = try await makeSyntheticFlac(seconds: 0.25)
        defer { try? FileManager.default.removeItem(at: url) }
        let beforeFile = try AVAudioFile(forReading: url)
        let beforeLength = beforeFile.length

        try FlacMetadataWriter.write(tags: makeTags(), picture: nil, to: url)

        let afterFile = try AVAudioFile(forReading: url)
        XCTAssertEqual(afterFile.length, beforeLength)
    }

    // MARK: - Independent (hand-rolled, not reusing FlacMetadataWriter's own code) parsing

    private func findAudioFramesOffset(in data: Data) throws -> Int {
        var offset = data.startIndex + 4
        while true {
            let headerByte = data[offset]
            let isLast = (headerByte & 0x80) != 0
            let length = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset = offset + 4 + length
            if isLast { return offset }
        }
    }

    private func readVorbisComments(from url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        var offset = data.startIndex + 4
        while true {
            let headerByte = data[offset]
            let isLast = (headerByte & 0x80) != 0
            let blockType = headerByte & 0x7F
            let length = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            let blockStart = offset + 4

            if blockType == 4 {
                return parseVorbisCommentData(data.subdata(in: blockStart..<blockStart + length))
            }
            offset = blockStart + length
            if isLast { break }
        }
        return [:]
    }

    private func parseVorbisCommentData(_ data: Data) -> [String: String] {
        var offset = data.startIndex
        func readUInt32LE() -> Int {
            let value = Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16) | (Int(data[offset + 3]) << 24)
            offset += 4
            return value
        }
        let vendorLength = readUInt32LE()
        offset += vendorLength // skip vendor string
        let commentCount = readUInt32LE()

        var result: [String: String] = [:]
        for _ in 0..<commentCount {
            let length = readUInt32LE()
            let bytes = data.subdata(in: offset..<offset + length)
            offset += length
            let string = String(decoding: bytes, as: UTF8.self)
            if let equalsIndex = string.firstIndex(of: "=") {
                let key = String(string[string.startIndex..<equalsIndex])
                let value = String(string[string.index(after: equalsIndex)...])
                result[key] = value
            }
        }
        return result
    }

    private func readPictureBlock(from url: URL) throws -> (mimeType: String, width: Int, height: Int, data: Data) {
        let fileData = try Data(contentsOf: url)
        var offset = fileData.startIndex + 4
        while true {
            let headerByte = fileData[offset]
            let isLast = (headerByte & 0x80) != 0
            let blockType = headerByte & 0x7F
            let length = Int(fileData[offset + 1]) << 16 | Int(fileData[offset + 2]) << 8 | Int(fileData[offset + 3])
            let blockStart = offset + 4

            if blockType == 6 {
                return parsePictureData(fileData.subdata(in: blockStart..<blockStart + length))
            }
            offset = blockStart + length
            if isLast { break }
        }
        throw FlacMetadataError.truncatedFile
    }

    private func parsePictureData(_ data: Data) -> (mimeType: String, width: Int, height: Int, data: Data) {
        var offset = data.startIndex
        func readUInt32BE() -> Int {
            let value = (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16) | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
            offset += 4
            return value
        }
        _ = readUInt32BE() // picture type
        let mimeLength = readUInt32BE()
        let mimeType = String(decoding: data.subdata(in: offset..<offset + mimeLength), as: UTF8.self)
        offset += mimeLength
        let descriptionLength = readUInt32BE()
        offset += descriptionLength
        let width = readUInt32BE()
        let height = readUInt32BE()
        _ = readUInt32BE() // color depth
        _ = readUInt32BE() // colors used
        let pictureDataLength = readUInt32BE()
        let pictureData = data.subdata(in: offset..<offset + pictureDataLength)
        return (mimeType, width, height, pictureData)
    }
}
