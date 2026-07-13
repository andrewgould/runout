import AVFoundation
import XCTest
@testable import Runout

final class ExportPipelineTests: XCTestCase {
    private var masterURL: URL!
    private var destinationFolder: URL!
    private let sampleRate: Double = 48_000

    override func setUp() async throws {
        try await super.setUp()
        destinationFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return XCTFail("Could not construct format")
        }
        masterURL = destinationFolder.appendingPathComponent("master.flac")
        let writer = RecordingWriter()
        try await writer.start(url: masterURL, sourceFormat: format, bitDepth: 24)

        // 3 seconds total: three distinct 1-second tones so slices are easy to tell apart.
        let frameCount = AVAudioFrameCount(sampleRate * 3)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData
        else { return XCTFail("Could not construct buffer") }
        buffer.frameLength = frameCount
        for i in 0..<Int(frameCount) {
            let second = i / Int(sampleRate)
            let frequency = 220.0 * Double(second + 1)
            channelData[0][i] = Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate)) * 0.5
        }
        guard let copy = buffer.copy() else { return XCTFail("Could not copy buffer") }
        try await writer.append(copy)
        await writer.stop()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: destinationFolder)
        try await super.tearDown()
    }

    private func makeTrack(title: String, number: Int, startSecond: Double, endSecond: Double) -> Track {
        Track(
            sideID: UUID(),
            startSample: Int64(startSecond * sampleRate),
            endSample: Int64(endSecond * sampleRate),
            title: title,
            trackNumber: number
        )
    }

    func testExportsCorrectSliceLengthAndTags() throws {
        let track = makeTrack(title: "Middle Third", number: 2, startSecond: 1, endSecond: 2)
        let album = AlbumMetadata(albumTitle: "Test Album", albumArtist: "Test Artist")

        let outcome = try ExportPipeline.exportTrack(
            track,
            from: masterURL,
            album: album,
            coverArtURL: nil,
            to: destinationFolder,
            fileNameTemplate: "{trackNumber} - {title}",
            overwriteBehavior: .appendNumber,
            bitDepth: 24
        )

        guard case .exported(let outputURL) = outcome else {
            return XCTFail("Expected .exported")
        }
        XCTAssertEqual(outputURL.lastPathComponent, "02 - Middle Third.flac")

        let outputFile = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(outputFile.length, Int64(sampleRate)) // exactly 1 second sliced out

        let magic = try Data(contentsOf: outputURL).prefix(4)
        XCTAssertEqual(magic, Data("fLaC".utf8))
    }

    func testExportedAudioMatchesTheCorrespondingSliceOfTheMaster() throws {
        let track = makeTrack(title: "Second Third", number: 2, startSecond: 1, endSecond: 2)
        let album = AlbumMetadata(albumTitle: "Test Album", albumArtist: "Test Artist")

        let outcome = try ExportPipeline.exportTrack(
            track, from: masterURL, album: album, coverArtURL: nil,
            to: destinationFolder, fileNameTemplate: "{trackNumber} - {title}",
            overwriteBehavior: .appendNumber, bitDepth: 24
        )
        guard case .exported(let outputURL) = outcome else { return XCTFail("Expected .exported") }

        // Read the corresponding slice directly out of the master for comparison.
        let masterFile = try AVAudioFile(forReading: masterURL)
        masterFile.framePosition = track.startSample
        let frameCount = AVAudioFrameCount(track.endSample - track.startSample)
        guard let masterBuffer = AVAudioPCMBuffer(pcmFormat: masterFile.processingFormat, frameCapacity: frameCount) else {
            return XCTFail("Could not allocate buffer")
        }
        try masterFile.read(into: masterBuffer, frameCount: frameCount)

        let exportedFile = try AVAudioFile(forReading: outputURL)
        guard let exportedBuffer = AVAudioPCMBuffer(pcmFormat: exportedFile.processingFormat, frameCapacity: AVAudioFrameCount(exportedFile.length)) else {
            return XCTFail("Could not allocate buffer")
        }
        try exportedFile.read(into: exportedBuffer, frameCount: AVAudioFrameCount(exportedFile.length))

        XCTAssertEqual(exportedBuffer.frameLength, masterBuffer.frameLength)
        let masterSamples = masterBuffer.floatChannelData![0]
        let exportedSamples = exportedBuffer.floatChannelData![0]
        for i in stride(from: 0, to: Int(masterBuffer.frameLength), by: 500) {
            XCTAssertEqual(exportedSamples[i], masterSamples[i], accuracy: 0.001)
        }
    }

    func testTagsAreEmbeddedCorrectly() throws {
        let track = makeTrack(title: "Come Together", number: 1, startSecond: 0, endSecond: 1)
        let album = AlbumMetadata(albumTitle: "Abbey Road", albumArtist: "The Beatles", year: "1969")

        let outcome = try ExportPipeline.exportTrack(
            track, from: masterURL, album: album, coverArtURL: nil,
            to: destinationFolder, fileNameTemplate: "{trackNumber} - {title}",
            overwriteBehavior: .appendNumber, bitDepth: 24
        )
        guard case .exported(let outputURL) = outcome else { return XCTFail("Expected .exported") }

        let comments = try readVorbisComments(from: outputURL)
        XCTAssertEqual(comments["TITLE"], "Come Together")
        XCTAssertEqual(comments["ARTIST"], "The Beatles")
        XCTAssertEqual(comments["ALBUM"], "Abbey Road")
        XCTAssertEqual(comments["DATE"], "1969")
    }

    /// docs/IMPROVEMENT_PLAN.md P2-2: composer was modeled on Track but never reached the
    /// exported file, and TRACKTOTAL/DISCTOTAL were never written at all.
    func testComposerAndTotalsReachTheExportedFile() throws {
        var track = makeTrack(title: "A Day in the Life", number: 1, startSecond: 0, endSecond: 1)
        track.composer = "Lennon-McCartney"
        var album = AlbumMetadata(albumTitle: "Sgt. Pepper's", albumArtist: "The Beatles")
        album.discCount = 1

        let outcome = try ExportPipeline.exportTrack(
            track, from: masterURL, album: album, coverArtURL: nil,
            to: destinationFolder, fileNameTemplate: "{trackNumber} - {title}",
            overwriteBehavior: .appendNumber, bitDepth: 24, trackTotal: 13
        )
        guard case .exported(let outputURL) = outcome else { return XCTFail("Expected .exported") }

        let comments = try readVorbisComments(from: outputURL)
        XCTAssertEqual(comments["COMPOSER"], "Lennon-McCartney")
        XCTAssertEqual(comments["TRACKTOTAL"], "13")
        XCTAssertEqual(comments["DISCTOTAL"], "1")
    }

    func testOverwriteBehaviorSkipDoesNotWriteWhenFileExists() throws {
        let track = makeTrack(title: "Track", number: 1, startSecond: 0, endSecond: 1)
        let album = AlbumMetadata(albumTitle: "Album", albumArtist: "Artist")
        let existingPath = destinationFolder.appendingPathComponent("01 - Track.flac")
        try "not a real flac".data(using: .utf8)!.write(to: existingPath)

        let outcome = try ExportPipeline.exportTrack(
            track, from: masterURL, album: album, coverArtURL: nil,
            to: destinationFolder, fileNameTemplate: "{trackNumber} - {title}",
            overwriteBehavior: .skip, bitDepth: 24
        )

        guard case .skipped = outcome else { return XCTFail("Expected .skipped") }
        let contents = try String(contentsOf: existingPath, encoding: .utf8)
        XCTAssertEqual(contents, "not a real flac", "skip must never touch the existing file")
    }

    func testOverwriteBehaviorAppendNumberCreatesANewFile() throws {
        let track = makeTrack(title: "Track", number: 1, startSecond: 0, endSecond: 1)
        let album = AlbumMetadata(albumTitle: "Album", albumArtist: "Artist")
        let existingPath = destinationFolder.appendingPathComponent("01 - Track.flac")
        try "not a real flac".data(using: .utf8)!.write(to: existingPath)

        let outcome = try ExportPipeline.exportTrack(
            track, from: masterURL, album: album, coverArtURL: nil,
            to: destinationFolder, fileNameTemplate: "{trackNumber} - {title}",
            overwriteBehavior: .appendNumber, bitDepth: 24
        )

        guard case .exported(let outputURL) = outcome else { return XCTFail("Expected .exported") }
        XCTAssertEqual(outputURL.lastPathComponent, "01 - Track (2).flac")
        let originalContents = try String(contentsOf: existingPath, encoding: .utf8)
        XCTAssertEqual(originalContents, "not a real flac", "the original file must be untouched")
    }

    func testOverwriteBehaviorOverwriteReplacesTheExistingFile() throws {
        let track = makeTrack(title: "Track", number: 1, startSecond: 0, endSecond: 1)
        let album = AlbumMetadata(albumTitle: "Album", albumArtist: "Artist")
        let existingPath = destinationFolder.appendingPathComponent("01 - Track.flac")
        try "not a real flac".data(using: .utf8)!.write(to: existingPath)

        let outcome = try ExportPipeline.exportTrack(
            track, from: masterURL, album: album, coverArtURL: nil,
            to: destinationFolder, fileNameTemplate: "{trackNumber} - {title}",
            overwriteBehavior: .overwrite, bitDepth: 24
        )

        guard case .exported(let outputURL) = outcome else { return XCTFail("Expected .exported") }
        XCTAssertEqual(outputURL.lastPathComponent, "01 - Track.flac")
        let magic = try Data(contentsOf: outputURL).prefix(4)
        XCTAssertEqual(magic, Data("fLaC".utf8), "the placeholder file should have been replaced with a real FLAC")
    }

    // MARK: - Independent parsing helper (not reusing FlacMetadataWriter's own code)

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
                var innerOffset = blockStart
                func readUInt32LE() -> Int {
                    let value = Int(data[innerOffset]) | (Int(data[innerOffset + 1]) << 8) | (Int(data[innerOffset + 2]) << 16) | (Int(data[innerOffset + 3]) << 24)
                    innerOffset += 4
                    return value
                }
                let vendorLength = readUInt32LE()
                innerOffset += vendorLength
                let commentCount = readUInt32LE()
                var result: [String: String] = [:]
                for _ in 0..<commentCount {
                    let length = readUInt32LE()
                    let bytes = data.subdata(in: innerOffset..<innerOffset + length)
                    innerOffset += length
                    let string = String(decoding: bytes, as: UTF8.self)
                    if let eq = string.firstIndex(of: "=") {
                        result[String(string[string.startIndex..<eq])] = String(string[string.index(after: eq)...])
                    }
                }
                return result
            }
            offset = blockStart + length
            if isLast { break }
        }
        return [:]
    }
}
