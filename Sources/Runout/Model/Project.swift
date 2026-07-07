import Foundation

/// The root object serialized to `manifest.json` inside a `.runout` project package.
/// See docs/DATA_MODEL.md for the full package layout.
struct Project: Codable, Identifiable, Equatable {
    /// Bump on any breaking manifest format change; loaders must check this before assuming field shapes.
    static let currentSchemaVersion = 1

    var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var audioSettings: AudioSettings
    var albumMetadata: AlbumMetadata
    var sides: [RecordingSide]
    var tracks: [Track]
    var schemaVersion: Int

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date,
        modifiedAt: Date,
        audioSettings: AudioSettings = .defaultSettings,
        albumMetadata: AlbumMetadata = AlbumMetadata(),
        sides: [RecordingSide] = [],
        tracks: [Track] = [],
        schemaVersion: Int = Project.currentSchemaVersion
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.audioSettings = audioSettings
        self.albumMetadata = albumMetadata
        self.sides = sides
        self.tracks = tracks
        self.schemaVersion = schemaVersion
    }
}
