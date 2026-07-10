import Foundation

/// A thin seam over `URLSession.data(for:)` so `MusicBrainzClient`/`CoverArtArchiveClient` can be
/// unit-tested against canned responses instead of the real network.
protocol HTTPDataFetching {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataFetching {}
