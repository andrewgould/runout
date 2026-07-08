import Foundation

/// Coordinates album/track metadata and cover art behind Screen 3 (docs/UI_SPEC.md).
///
/// Persistence note: like `EditorSession`'s markers, this saves to a
/// `<recording>.metadata.json` sidecar — a temporary bridge until M7's real `.runout` project
/// package lands. Track sample ranges come from the same marker sidecar `EditorSession` writes
/// (via `MarkerSidecarStore` + `TrackRanges`), so this reads the *current* split even if it was
/// last edited in a previous app launch, without needing a live `EditorSession` instance.
@MainActor
final class MetadataSession: ObservableObject {
    @Published var albumMetadata: AlbumMetadata {
        didSet { save() }
    }
    @Published private(set) var tracks: [Track]
    @Published private(set) var coverArtURL: URL?
    @Published private(set) var errorMessage: String?

    let recordingURL: URL
    private let sideID: UUID

    private struct PersistedState: Codable {
        var sideID: UUID
        var albumMetadata: AlbumMetadata
        var tracks: [Track]
        var coverArtRelativeFilename: String?
    }

    private var sidecarURL: URL {
        recordingURL.deletingPathExtension().appendingPathExtension("metadata.json")
    }

    init(recordingURL: URL, totalSampleCount: Int64) {
        self.recordingURL = recordingURL
        let markers = MarkerSidecarStore.load(forRecordingAt: recordingURL)
        let ranges = TrackRanges.compute(markers: markers, totalSampleCount: totalSampleCount)

        if let data = try? Data(contentsOf: MetadataSession.sidecarURL(for: recordingURL)),
           let persisted = try? JSONDecoder().decode(PersistedState.self, from: data) {
            self.sideID = persisted.sideID
            self.albumMetadata = persisted.albumMetadata
            self.tracks = MetadataSession.reconcile(persisted.tracks, with: ranges, sideID: persisted.sideID)
            if let filename = persisted.coverArtRelativeFilename {
                let url = recordingURL.deletingLastPathComponent().appendingPathComponent(filename)
                self.coverArtURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        } else {
            self.sideID = UUID()
            self.albumMetadata = AlbumMetadata()
            self.tracks = MetadataSession.makeDefaultTracks(from: ranges, sideID: sideID)
        }
        save()
    }

    private static func sidecarURL(for recordingURL: URL) -> URL {
        recordingURL.deletingPathExtension().appendingPathExtension("metadata.json")
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

    private static func makeDefaultTracks(from ranges: [Range<Int64>], sideID: UUID) -> [Track] {
        ranges.enumerated().map { index, range in defaultTrack(range: range, number: index + 1, sideID: sideID) }
    }

    private static func defaultTrack(range: Range<Int64>, number: Int, sideID: UUID) -> Track {
        Track(sideID: sideID, startSample: range.lowerBound, endSample: range.upperBound, title: "Track \(number)", trackNumber: number)
    }

    // MARK: - Editing

    func updateTrack(_ id: UUID, mutate: (inout Track) -> Void) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tracks[index])
        save()
    }

    /// Clears per-track artist/genre/year overrides so every track inherits the album's values —
    /// see docs/UI_SPEC.md's "Apply Album Info to All Tracks" button.
    func applyAlbumInfoToAllTracks() {
        for index in tracks.indices {
            tracks[index].artist = nil
            tracks[index].genre = nil
            tracks[index].year = nil
        }
        save()
    }

    func resolvedFilename(for track: Track, template: String = FileNameTemplate.defaultTemplate) -> String {
        FileNameTemplate.resolve(template, track: track, album: albumMetadata) + ".flac"
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
        let filename = recordingURL.deletingPathExtension().lastPathComponent + ".artwork." + fileExtension
        let destination = recordingURL.deletingLastPathComponent().appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try data.write(to: destination, options: .atomic)
        coverArtURL = destination
        save()
    }

    // MARK: - Persistence

    private func save() {
        let state = PersistedState(
            sideID: sideID,
            albumMetadata: albumMetadata,
            tracks: tracks,
            coverArtRelativeFilename: coverArtURL?.lastPathComponent
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: sidecarURL, options: .atomic)
    }
}
