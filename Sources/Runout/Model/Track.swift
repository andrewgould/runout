import Foundation

/// A `Track` is the span between two consecutive markers (or start/end of a side).
/// `artist`/`genre`/`year` of `nil` mean "inherit from `AlbumMetadata`" — see docs/DATA_MODEL.md.
struct Track: Codable, Identifiable, Equatable {
    var id: UUID
    var sideID: UUID
    var startSample: Int64
    var endSample: Int64
    var title: String
    var artist: String?
    var trackNumber: Int
    var discNumber: Int
    var genre: String?
    var year: String?
    var composer: String?
    var comment: String?

    init(
        id: UUID = UUID(),
        sideID: UUID,
        startSample: Int64,
        endSample: Int64,
        title: String,
        artist: String? = nil,
        trackNumber: Int,
        discNumber: Int = 1,
        genre: String? = nil,
        year: String? = nil,
        composer: String? = nil,
        comment: String? = nil
    ) {
        self.id = id
        self.sideID = sideID
        self.startSample = startSample
        self.endSample = endSample
        self.title = title
        self.artist = artist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.genre = genre
        self.year = year
        self.composer = composer
        self.comment = comment
    }
}
