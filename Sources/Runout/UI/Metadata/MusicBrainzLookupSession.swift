import Foundation

/// Drives the "Look Up on MusicBrainz" sheet (docs/UI_SPEC.md, docs/FEATURES.md §3): search,
/// pick a release, fetch its full track listing before the user commits to using it.
@MainActor
final class MusicBrainzLookupSession: ObservableObject {
    @Published var artistQuery: String
    @Published var albumQuery: String
    @Published private(set) var results: [MusicBrainzReleaseSummary] = []
    @Published private(set) var isSearching = false
    @Published private(set) var selectedDetail: MusicBrainzReleaseDetail?
    @Published private(set) var isFetchingDetail = false
    @Published private(set) var errorMessage: String?

    private let client: MusicBrainzClient

    init(initialArtist: String, initialAlbum: String, client: MusicBrainzClient = MusicBrainzClient()) {
        self.artistQuery = initialArtist
        self.albumQuery = initialAlbum
        self.client = client
    }

    func search() async {
        guard !artistQuery.isEmpty || !albumQuery.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        selectedDetail = nil
        defer { isSearching = false }
        do {
            results = try await client.search(artist: artistQuery, album: albumQuery)
        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
    }

    func selectRelease(_ summary: MusicBrainzReleaseSummary) async {
        isFetchingDetail = true
        errorMessage = nil
        defer { isFetchingDetail = false }
        do {
            selectedDetail = try await client.fetchReleaseDetail(releaseID: summary.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
