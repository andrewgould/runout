import Foundation

struct MusicBrainzReleaseSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let date: String?
    let country: String?
    let trackCount: Int?
}

struct MusicBrainzTrack: Equatable {
    let position: Int
    let title: String
}

struct MusicBrainzReleaseDetail: Equatable {
    let id: String
    let title: String
    let artist: String
    let date: String?
    let hasCoverArt: Bool
    let tracks: [MusicBrainzTrack]
}

enum MusicBrainzError: Error, LocalizedError {
    case invalidResponse(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let status): return "MusicBrainz returned an unexpected response (status \(status))."
        case .decodingFailed: return "Couldn't understand MusicBrainz's response."
        }
    }
}

/// Keyless MusicBrainz search to pre-fill album/track metadata, respecting the service's
/// documented 1 request/second rate limit — see docs/FEATURES.md §3.
final class MusicBrainzClient {
    /// MusicBrainz's usage policy requires a descriptive User-Agent identifying the application
    /// and a contact point — see https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting.
    static let userAgent = "Runout/0.1 ( https://github.com/andrewgould/runout )"

    private let session: HTTPDataFetching
    private let rateLimiter: MusicBrainzRateLimiter

    init(session: HTTPDataFetching = URLSession.shared, rateLimiter: MusicBrainzRateLimiter = .shared) {
        self.session = session
        self.rateLimiter = rateLimiter
    }

    func search(artist: String, album: String) async throws -> [MusicBrainzReleaseSummary] {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        components.queryItems = [
            URLQueryItem(name: "query", value: "artist:\(artist) AND release:\"\(album)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        let data = try await performRequest(url: components.url!)
        return try Self.parseSearchResults(data)
    }

    func fetchReleaseDetail(releaseID: String) async throws -> MusicBrainzReleaseDetail {
        let url = URL(string: "https://musicbrainz.org/ws/2/release/\(releaseID)?inc=recordings+artist-credits&fmt=json")!
        let data = try await performRequest(url: url)
        return try Self.parseReleaseDetail(data)
    }

    private func performRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        await rateLimiter.waitIfNeeded()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MusicBrainzError.invalidResponse(status)
        }
        return data
    }

    // MARK: - Parsing (real captured MusicBrainz JSON, see MusicBrainzClientTests fixtures)

    static func parseSearchResults(_ data: Data) throws -> [MusicBrainzReleaseSummary] {
        let decoded: SearchResponseWire
        do {
            decoded = try JSONDecoder().decode(SearchResponseWire.self, from: data)
        } catch {
            throw MusicBrainzError.decodingFailed
        }
        return decoded.releases.map { release in
            MusicBrainzReleaseSummary(
                id: release.id,
                title: release.title,
                artist: release.artistCredit.first?.name ?? "",
                date: release.date,
                country: release.country,
                trackCount: release.trackCount
            )
        }
    }

    static func parseReleaseDetail(_ data: Data) throws -> MusicBrainzReleaseDetail {
        let decoded: ReleaseDetailWire
        do {
            decoded = try JSONDecoder().decode(ReleaseDetailWire.self, from: data)
        } catch {
            throw MusicBrainzError.decodingFailed
        }
        let tracks = decoded.media.flatMap { medium in
            medium.tracks.map { MusicBrainzTrack(position: $0.position, title: $0.title) }
        }
        return MusicBrainzReleaseDetail(
            id: decoded.id,
            title: decoded.title,
            artist: decoded.artistCredit.first?.name ?? "",
            date: decoded.date,
            hasCoverArt: decoded.coverArtArchive?.front ?? false,
            tracks: tracks
        )
    }
}

// MARK: - Wire types (field names match MusicBrainz's real JSON exactly)

private struct ArtistCreditWire: Decodable {
    let name: String
}

private struct SearchResponseWire: Decodable {
    let releases: [ReleaseSummaryWire]
}

private struct ReleaseSummaryWire: Decodable {
    let id: String
    let title: String
    let date: String?
    let country: String?
    let artistCredit: [ArtistCreditWire]
    let trackCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, date, country
        case artistCredit = "artist-credit"
        case trackCount = "track-count"
    }
}

private struct ReleaseDetailWire: Decodable {
    let id: String
    let title: String
    let date: String?
    let artistCredit: [ArtistCreditWire]
    let media: [MediaWire]
    let coverArtArchive: CoverArtArchiveFlagsWire?

    enum CodingKeys: String, CodingKey {
        case id, title, date, media
        case artistCredit = "artist-credit"
        case coverArtArchive = "cover-art-archive"
    }
}

private struct MediaWire: Decodable {
    let tracks: [TrackWire]
}

private struct TrackWire: Decodable {
    let position: Int
    let title: String
}

private struct CoverArtArchiveFlagsWire: Decodable {
    let front: Bool
}
