import XCTest
@testable import Runout

final class FileNameTemplateTests: XCTestCase {
    private func makeTrack(
        title: String = "Come Together",
        artist: String? = nil,
        trackNumber: Int = 1,
        discNumber: Int = 1,
        year: String? = nil
    ) -> Track {
        Track(sideID: UUID(), startSample: 0, endSample: 100, title: title, artist: artist, trackNumber: trackNumber, discNumber: discNumber, year: year)
    }

    private func makeAlbum(
        albumTitle: String = "Abbey Road",
        albumArtist: String = "The Beatles",
        year: String? = "1969"
    ) -> AlbumMetadata {
        AlbumMetadata(albumTitle: albumTitle, albumArtist: albumArtist, year: year)
    }

    func testDefaultTemplateResolvesTrackNumberAndTitle() {
        let result = FileNameTemplate.resolve(FileNameTemplate.defaultTemplate, track: makeTrack(), album: makeAlbum())
        XCTAssertEqual(result, "01 - Come Together")
    }

    func testTrackNumberIsZeroPadded() {
        let track = makeTrack(trackNumber: 7)
        let result = FileNameTemplate.resolve("{trackNumber}", track: track, album: makeAlbum())
        XCTAssertEqual(result, "07")
    }

    func testArtistInheritsAlbumArtistWhenTrackHasNoOverride() {
        let result = FileNameTemplate.resolve("{artist}", track: makeTrack(artist: nil), album: makeAlbum())
        XCTAssertEqual(result, "The Beatles")
    }

    func testArtistOverrideWinsOverAlbumArtist() {
        let result = FileNameTemplate.resolve("{artist}", track: makeTrack(artist: "Someone Else"), album: makeAlbum())
        XCTAssertEqual(result, "Someone Else")
    }

    func testYearInheritsFromAlbumWhenTrackHasNoOverride() {
        let result = FileNameTemplate.resolve("{year}", track: makeTrack(year: nil), album: makeAlbum(year: "1969"))
        XCTAssertEqual(result, "1969")
    }

    func testAllTokensResolveTogether() {
        let track = makeTrack(title: "Something", trackNumber: 2, discNumber: 1)
        let result = FileNameTemplate.resolve("{trackNumber} - {artist} - {album} ({year}) - {title}", track: track, album: makeAlbum())
        XCTAssertEqual(result, "02 - The Beatles - Abbey Road (1969) - Something")
    }

    func testSanitizesInvalidFilesystemCharacters() {
        let track = makeTrack(title: "Rock/Pop: A \"Great\" Mix?")
        let result = FileNameTemplate.resolve("{title}", track: track, album: makeAlbum())
        XCTAssertFalse(result.contains("/"))
        XCTAssertFalse(result.contains(":"))
        XCTAssertFalse(result.contains("\""))
        XCTAssertFalse(result.contains("?"))
    }

    func testEmptyResolvedNameFallsBackToUntitled() {
        let track = makeTrack(title: "///???")
        let result = FileNameTemplate.resolve("{title}", track: track, album: makeAlbum())
        XCTAssertEqual(result, "Untitled")
    }
}
