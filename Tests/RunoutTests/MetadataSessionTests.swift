import XCTest
@testable import Runout

@MainActor
final class MetadataSessionTests: XCTestCase {
    private var recordingURL: URL!

    override func setUp() {
        super.setUp()
        recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("flac")
    }

    override func tearDown() {
        let base = recordingURL!
        for ext in ["markers.json", "metadata.json"] {
            try? FileManager.default.removeItem(at: base.deletingPathExtension().appendingPathExtension(ext))
        }
        let coverArtGlobPrefix = base.deletingPathExtension().lastPathComponent + ".artwork."
        let directory = base.deletingLastPathComponent()
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in contents where name.hasPrefix(coverArtGlobPrefix) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        super.tearDown()
    }

    private func writeMarkers(_ sampleOffsets: [Int64]) {
        let markers = sampleOffsets.map { Marker(sampleOffset: $0) }
        MarkerSidecarStore.save(markers, forRecordingAt: recordingURL)
    }

    func testDefaultTracksMatchMarkerDerivedRanges() {
        writeMarkers([300, 700])
        let session = MetadataSession(recordingURL: recordingURL, totalSampleCount: 1000)
        XCTAssertEqual(session.tracks.map { $0.startSample..<$0.endSample }, [0..<300, 300..<700, 700..<1000])
        XCTAssertEqual(session.tracks.map(\.trackNumber), [1, 2, 3])
        XCTAssertEqual(session.tracks.map(\.title), ["Track 1", "Track 2", "Track 3"])
    }

    func testAlbumMetadataPersistsAcrossSessionInstances() {
        let session = MetadataSession(recordingURL: recordingURL, totalSampleCount: 1000)
        session.albumMetadata.albumTitle = "Abbey Road"
        session.albumMetadata.albumArtist = "The Beatles"

        let reloaded = MetadataSession(recordingURL: recordingURL, totalSampleCount: 1000)
        XCTAssertEqual(reloaded.albumMetadata.albumTitle, "Abbey Road")
        XCTAssertEqual(reloaded.albumMetadata.albumArtist, "The Beatles")
    }

    func testUpdateTrackPersistsAcrossSessionInstances() {
        writeMarkers([500])
        let session = MetadataSession(recordingURL: recordingURL, totalSampleCount: 1000)
        let id = session.tracks[0].id
        session.updateTrack(id) { $0.title = "Come Together" }

        let reloaded = MetadataSession(recordingURL: recordingURL, totalSampleCount: 1000)
        XCTAssertEqual(reloaded.tracks[0].title, "Come Together")
    }

    func testReconciliationPreservesMetadataForUnchangedRangesAndDefaultsNewOnes() {
        writeMarkers([500])
        let session = MetadataSession(recordingURL: recordingURL, totalSampleCount: 1000)
        session.updateTrack(session.tracks[0].id) { $0.title = "Side A, Part 1" }
        session.updateTrack(session.tracks[1].id) { $0.title = "Side A, Part 2" }

        // Simulate re-splitting in the editor: add a new marker inside the second track.
        writeMarkers([500, 750])
        let reloaded = MetadataSession(recordingURL: recordingURL, totalSampleCount: 1000)

        XCTAssertEqual(reloaded.tracks.count, 3)
        XCTAssertEqual(reloaded.tracks[0].title, "Side A, Part 1", "unchanged range 0..<500 should keep its title")
        XCTAssertEqual(reloaded.tracks[1].title, "Track 2", "the new 500..<750 range is a fresh boundary, so it gets a default title")
        XCTAssertEqual(reloaded.tracks[2].title, "Track 3")
    }

    func testApplyAlbumInfoToAllTracksClearsOverrides() {
        writeMarkers([500])
        let session = MetadataSession(recordingURL: recordingURL, totalSampleCount: 1000)
        session.updateTrack(session.tracks[0].id) { $0.artist = "Guest Artist"; $0.year = "1999"; $0.genre = "Jazz" }

        session.applyAlbumInfoToAllTracks()

        for track in session.tracks {
            XCTAssertNil(track.artist)
            XCTAssertNil(track.year)
            XCTAssertNil(track.genre)
        }
    }

    func testResolvedFilenameUsesAlbumAndTrackMetadata() {
        let session = MetadataSession(recordingURL: recordingURL, totalSampleCount: 1000)
        session.albumMetadata.albumArtist = "The Beatles"
        session.updateTrack(session.tracks[0].id) { $0.title = "Come Together" }

        XCTAssertEqual(session.resolvedFilename(for: session.tracks[0]), "01 - Come Together.flac")
    }

    func testSetCoverArtWritesFileAndPersistsAcrossSessionInstances() throws {
        let session = MetadataSession(recordingURL: recordingURL, totalSampleCount: 1000)
        let imageData = Data([0xFF, 0xD8, 0xFF]) // not a real JPEG, just distinguishable bytes
        session.setCoverArt(data: imageData, fileExtension: "jpg")

        XCTAssertNotNil(session.coverArtURL)
        XCTAssertNil(session.errorMessage)
        let writtenData = try Data(contentsOf: session.coverArtURL!)
        XCTAssertEqual(writtenData, imageData)

        let reloaded = MetadataSession(recordingURL: recordingURL, totalSampleCount: 1000)
        XCTAssertEqual(reloaded.coverArtURL?.lastPathComponent, session.coverArtURL?.lastPathComponent)
    }
}
