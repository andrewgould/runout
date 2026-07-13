import Foundation

/// Coordinates album/track metadata and cover art behind Screen 3 (docs/UI_SPEC.md).
///
/// Album metadata and per-side tracks now live directly in `document.project` — the
/// `<recording>.metadata.json` sidecar used as a temporary bridge in M5 is gone. `tracks` here is
/// a working copy for just this side, kept in sync by `pushTracksToDocument` writing straight
/// through to `document.project.tracks` (merged back in alongside any other sides' tracks) on
/// every mutation.
@MainActor
final class MetadataSession: ObservableObject {
    @Published var albumMetadata: AlbumMetadata {
        didSet { document.project.albumMetadata = albumMetadata }
    }
    @Published private(set) var tracks: [Track]
    @Published private(set) var coverArtURL: URL?
    @Published private(set) var errorMessage: String?

    private let document: RunoutDocument
    private let sideID: UUID

    init(document: RunoutDocument, sideID: UUID, totalSampleCount: Int64) {
        self.document = document
        self.sideID = sideID

        let markers = document.project.sides.first(where: { $0.id == sideID })?.markers ?? []
        let ranges = TrackRanges.compute(markers: markers, totalSampleCount: totalSampleCount)
        let existingTracksForSide = document.project.tracks.filter { $0.sideID == sideID }
        let reconciled = Self.reconcile(existingTracksForSide, with: ranges, sideID: sideID)

        self.albumMetadata = document.project.albumMetadata
        self.tracks = reconciled

        if let path = document.project.albumMetadata.coverArtRelativePath,
           let url = try? document.materializedFileURL(forRelativePath: path) {
            self.coverArtURL = url
        }

        var all = document.project.tracks
        all.removeAll { $0.sideID == sideID }
        all.append(contentsOf: reconciled)
        document.project.tracks = all
    }

    /// Rebuilds the track list from the current marker-derived ranges, preserving existing
    /// metadata for ranges that still match exactly, and creating fresh defaults for new ones —
    /// so re-splitting in the editor doesn't silently discard typed-in titles for tracks whose
    /// boundaries didn't change.
    private static func reconcile(_ existing: [Track], with ranges: [Range<Int64>], sideID: UUID) -> [Track] {
        ranges.enumerated().map { index, range in
            if let match = existing.first(where: { $0.startSample == range.lowerBound && $0.endSample == range.upperBound }) {
                var track = match
                track.trackNumber = index + 1
                return track
            }
            return defaultTrack(range: range, number: index + 1, sideID: sideID)
        }
    }

    private static func defaultTrack(range: Range<Int64>, number: Int, sideID: UUID) -> Track {
        Track(sideID: sideID, startSample: range.lowerBound, endSample: range.upperBound, title: "Track \(number)", trackNumber: number)
    }

    // MARK: - Editing

    func updateTrack(_ id: UUID, mutate: (inout Track) -> Void) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tracks[index])
        pushTracksToDocument()
    }

    /// Clears per-track artist/genre/year overrides so every track inherits the album's values —
    /// see docs/UI_SPEC.md's "Apply Album Info to All Tracks" button.
    func applyAlbumInfoToAllTracks() {
        for index in tracks.indices {
            tracks[index].artist = nil
            tracks[index].genre = nil
            tracks[index].year = nil
        }
        pushTracksToDocument()
    }

    func resolvedFilename(for track: Track, template: String = FileNameTemplate.defaultTemplate) -> String {
        FileNameTemplate.resolve(template, track: track, album: albumMetadata) + ".flac"
    }

    /// Applies a MusicBrainz lookup result (docs/ROADMAP.md M9): album title/artist/year, and
    /// per-track titles matched by track number against MusicBrainz's track position. Never
    /// adds or removes tracks — this app's tracks come from actual marker positions in the
    /// recording, not from an external listing, so a release with a different track count just
    /// leaves any unmatched tracks' titles untouched.
    func applyMusicBrainzRelease(_ detail: MusicBrainzReleaseDetail) {
        albumMetadata.albumTitle = detail.title
        albumMetadata.albumArtist = detail.artist
        if let date = detail.date {
            let year = String(date.prefix(4))
            if year.count == 4 { albumMetadata.year = year }
        }
        for index in tracks.indices {
            if let match = detail.tracks.first(where: { $0.position == tracks[index].trackNumber }) {
                tracks[index].title = match.title
            }
        }
        pushTracksToDocument()
    }

    // MARK: - Cover art

    func setCoverArt(fromFileAt sourceURL: URL) {
        do {
            let data = try Data(contentsOf: sourceURL)
            try storeCoverArt(data, fileExtension: sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension)
        } catch {
            errorMessage = "Couldn't import cover art: \(error.localizedDescription)"
        }
    }

    func setCoverArt(data: Data, fileExtension: String) {
        do {
            try storeCoverArt(data, fileExtension: fileExtension)
        } catch {
            errorMessage = "Couldn't import cover art: \(error.localizedDescription)"
        }
    }

    private func storeCoverArt(_ data: Data, fileExtension: String) throws {
        let relativePath = "artwork.\(fileExtension)"
        let scratchURL = document.scratchFileURL(named: "artwork-\(UUID().uuidString).\(fileExtension)")
        try data.write(to: scratchURL, options: .atomic)
        // The scratch file must outlive the ingest: the document's file wrappers are lazy and
        // read from it at save time. It's cleaned up with the rest of the working directory
        // when the document closes.
        try document.ingestFile(at: scratchURL, asRelativePath: relativePath)

        albumMetadata.coverArtRelativePath = relativePath
        coverArtURL = try document.materializedFileURL(forRelativePath: relativePath)
    }

    // MARK: - Persistence

    private func pushTracksToDocument() {
        var all = document.project.tracks
        all.removeAll { $0.sideID == sideID }
        all.append(contentsOf: tracks)
        document.project.tracks = all
    }
}
