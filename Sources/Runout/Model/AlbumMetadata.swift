import Foundation

/// See docs/DATA_MODEL.md.
struct AlbumMetadata: Codable, Equatable {
    var albumTitle: String
    var albumArtist: String
    var year: String?
    var genre: String?
    var discCount: Int
    var coverArtRelativePath: String?

    init(
        albumTitle: String = "",
        albumArtist: String = "",
        year: String? = nil,
        genre: String? = nil,
        discCount: Int = 1,
        coverArtRelativePath: String? = nil
    ) {
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
        self.year = year
        self.genre = genre
        self.discCount = discCount
        self.coverArtRelativePath = coverArtRelativePath
    }
}
