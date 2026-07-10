import XCTest
@testable import Runout

@MainActor
final class MetadataSessionTests: XCTestCase {
    private var document: RunoutDocument!
    private var sideID: UUID!

    override func setUp() {
        super.setUp()
        document = RunoutDocument()
        let side = RecordingSide(
            label: "Side A",
            masterFileRelativePath: "side-a.flac",
            peakCacheRelativePath: "side-a.peaks",
            durationSamples: 1000,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        sideID = side.id
        document.project.sides = [side]
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: document.workingDirectory)
        super.tearDown()
    }

    private func writeMarkers(_ sampleOffsets: [Int64]) {
        guard let index = document.project.sides.firstIndex(where: { $0.id == sideID }) else { return }
        document.project.sides[index].markers = sampleOffsets.map { Marker(sampleOffset: $0) }
    }

    private func makeSession(totalSampleCount: Int64 = 1000) -> MetadataSession {
        MetadataSession(document: document, sideID: sideID, totalSampleCount: totalSampleCount)
    }

    func testDefaultTracksMatchMarkerDerivedRanges() {
        writeMarkers([300, 700])
        let session = makeSession()
        XCTAssertEqual(session.tracks.map { $0.startSample..<$0.endSample }, [0..<300, 300..<700, 700..<1000])
        XCTAssertEqual(session.tracks.map(\.trackNumber), [1, 2, 3])
        XCTAssertEqual(session.tracks.map(\.title), ["Track 1", "Track 2", "Track 3"])
    }

    func testAlbumMetadataPersistsAcrossSessionInstances() {
        let session = makeSession()
        session.albumMetadata.albumTitle = "Abbey Road"
        session.albumMetadata.albumArtist = "The Beatles"

        let reloaded = makeSession()
        XCTAssertEqual(reloaded.albumMetadata.albumTitle, "Abbey Road")
        XCTAssertEqual(reloaded.albumMetadata.albumArtist, "The Beatles")
    }

    func testUpdateTrackPersistsAcrossSessionInstances() {
        writeMarkers([500])
        let session = makeSession()
        let id = session.tracks[0].id
        session.updateTrack(id) { $0.title = "Come Together" }

        let reloaded = makeSession()
        XCTAssertEqual(reloaded.tracks[0].title, "Come Together")
    }

    func testReconciliationPreservesMetadataForUnchangedRangesAndDefaultsNewOnes() {
        writeMarkers([500])
        let session = makeSession()
        session.updateTrack(session.tracks[0].id) { $0.title = "Side A, Part 1" }
        session.updateTrack(session.tracks[1].id) { $0.title = "Side A, Part 2" }

        // Simulate re-splitting in the editor: add a new marker inside the second track.
        writeMarkers([500, 750])
        let reloaded = makeSession()

        XCTAssertEqual(reloaded.tracks.count, 3)
        XCTAssertEqual(reloaded.tracks[0].title, "Side A, Part 1", "unchanged range 0..<500 should keep its title")
        XCTAssertEqual(reloaded.tracks[1].title, "Track 2", "the new 500..<750 range is a fresh boundary, so it gets a default title")
        XCTAssertEqual(reloaded.tracks[2].title, "Track 3")
    }

    func testApplyAlbumInfoToAllTracksClearsOverrides() {
        writeMarkers([500])
        let session = makeSession()
        session.updateTrack(session.tracks[0].id) { $0.artist = "Guest Artist"; $0.year = "1999"; $0.genre = "Jazz" }

        session.applyAlbumInfoToAllTracks()

        for track in session.tracks {
            XCTAssertNil(track.artist)
            XCTAssertNil(track.year)
            XCTAssertNil(track.genre)
        }
    }

    func testResolvedFilenameUsesAlbumAndTrackMetadata() {
        let session = makeSession()
        session.albumMetadata.albumArtist = "The Beatles"
        session.updateTrack(session.tracks[0].id) { $0.title = "Come Together" }

        XCTAssertEqual(session.resolvedFilename(for: session.tracks[0]), "01 - Come Together.flac")
    }

    func testSetCoverArtWritesFileAndPersistsAcrossSessionInstances() throws {
        let session = makeSession()
        let imageData = Data([0xFF, 0xD8, 0xFF]) // not a real JPEG, just distinguishable bytes
        session.setCoverArt(data: imageData, fileExtension: "jpg")

        XCTAssertNotNil(session.coverArtURL)
        XCTAssertNil(session.errorMessage)
        let writtenData = try Data(contentsOf: session.coverArtURL!)
        XCTAssertEqual(writtenData, imageData)
        XCTAssertEqual(document.project.albumMetadata.coverArtRelativePath, "artwork.jpg")

        let reloaded = makeSession()
        XCTAssertEqual(reloaded.coverArtURL?.lastPathComponent, session.coverArtURL?.lastPathComponent)
    }

    /// A multi-side project's tracks are a single flat array keyed by `sideID` — editing this
    /// side must never touch another side's tracks.
    func testTracksFromOtherSidesAreUnaffected() {
        let otherSide = RecordingSide(
            label: "Side B",
            masterFileRelativePath: "side-b.flac",
            peakCacheRelativePath: "side-b.peaks",
            durationSamples: 500,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        document.project.sides.append(otherSide)
        document.project.tracks = [Track(sideID: otherSide.id, startSample: 0, endSample: 500, title: "Other Side Track", trackNumber: 1)]

        writeMarkers([500])
        let session = makeSession()
        session.updateTrack(session.tracks[0].id) { $0.title = "This Side Track" }

        XCTAssertTrue(document.project.tracks.contains { $0.title == "Other Side Track" })
        XCTAssertTrue(document.project.tracks.contains { $0.title == "This Side Track" })
    }

    // MARK: - MusicBrainz lookup application (M9)

    private func makeMusicBrainzDetail(tracks: [MusicBrainzTrack], date: String? = "1969-09-26") -> MusicBrainzReleaseDetail {
        MusicBrainzReleaseDetail(
            id: "05e77dbd-1c4f-4e5e-8461-caac6e5fbae7",
            title: "Abbey Road",
            artist: "The Beatles",
            date: date,
            hasCoverArt: true,
            tracks: tracks
        )
    }

    func testApplyMusicBrainzReleaseSetsAlbumMetadata() {
        let session = makeSession()
        session.applyMusicBrainzRelease(makeMusicBrainzDetail(tracks: []))

        XCTAssertEqual(session.albumMetadata.albumTitle, "Abbey Road")
        XCTAssertEqual(session.albumMetadata.albumArtist, "The Beatles")
        XCTAssertEqual(session.albumMetadata.year, "1969")
    }

    func testApplyMusicBrainzReleaseMatchesTracksByPosition() {
        writeMarkers([500])
        let session = makeSession()
        XCTAssertEqual(session.tracks.map(\.trackNumber), [1, 2])

        session.applyMusicBrainzRelease(makeMusicBrainzDetail(tracks: [
            MusicBrainzTrack(position: 1, title: "Come Together"),
            MusicBrainzTrack(position: 2, title: "Something"),
        ]))

        XCTAssertEqual(session.tracks.first(where: { $0.trackNumber == 1 })?.title, "Come Together")
        XCTAssertEqual(session.tracks.first(where: { $0.trackNumber == 2 })?.title, "Something")
    }

    func testApplyMusicBrainzReleaseLeavesUnmatchedTrackNumbersUntouched() {
        writeMarkers([500])
        let session = makeSession()
        session.updateTrack(session.tracks[1].id) { $0.title = "Manually Typed Title" }

        // Only one MusicBrainz track (position 1) — position 2 has nothing to match against.
        session.applyMusicBrainzRelease(makeMusicBrainzDetail(tracks: [
            MusicBrainzTrack(position: 1, title: "Come Together"),
        ]))

        XCTAssertEqual(session.tracks.first(where: { $0.trackNumber == 1 })?.title, "Come Together")
        XCTAssertEqual(session.tracks.first(where: { $0.trackNumber == 2 })?.title, "Manually Typed Title")
    }

    func testApplyMusicBrainzReleaseWithoutDateLeavesYearUnchanged() {
        let session = makeSession()
        session.albumMetadata.year = "2020"
        session.applyMusicBrainzRelease(makeMusicBrainzDetail(tracks: [], date: nil))
        XCTAssertEqual(session.albumMetadata.year, "2020")
    }

    func testApplyMusicBrainzReleasePersistsAcrossSessionInstances() {
        let session = makeSession()
        session.applyMusicBrainzRelease(makeMusicBrainzDetail(tracks: []))

        let reloaded = makeSession()
        XCTAssertEqual(reloaded.albumMetadata.albumTitle, "Abbey Road")
    }
}
