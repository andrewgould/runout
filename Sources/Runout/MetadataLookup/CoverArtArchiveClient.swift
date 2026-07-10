import Foundation

enum CoverArtArchiveError: Error, LocalizedError {
    case noFrontCoverAvailable
    case invalidResponse(Int)

    var errorDescription: String? {
        switch self {
        case .noFrontCoverAvailable: return "No front cover art is available for this release."
        case .invalidResponse(let status): return "Cover Art Archive returned an unexpected response (status \(status))."
        }
    }
}

/// Downloads front cover art for a MusicBrainz release. Paired with `MusicBrainzClient`, sharing
/// its rate limiter — see docs/FEATURES.md §3.
final class CoverArtArchiveClient {
    private let session: HTTPDataFetching
    private let rateLimiter: MusicBrainzRateLimiter

    init(session: HTTPDataFetching = URLSession.shared, rateLimiter: MusicBrainzRateLimiter = .shared) {
        self.session = session
        self.rateLimiter = rateLimiter
    }

    /// Fetches the front cover's image bytes for `releaseID`, if one exists on the archive.
    /// `URLSession` follows the archive's list-endpoint redirect and the final image redirect
    /// transparently, so no manual redirect handling is needed here.
    func fetchFrontCoverImageData(releaseID: String) async throws -> (data: Data, fileExtension: String) {
        let listURL = URL(string: "https://coverartarchive.org/release/\(releaseID)")!
        let listData = try await performRequest(url: listURL)

        let list: CoverArtListWire
        do {
            list = try JSONDecoder().decode(CoverArtListWire.self, from: listData)
        } catch {
            throw CoverArtArchiveError.noFrontCoverAvailable
        }
        guard let front = list.images.first(where: { $0.front }), let imageURL = Self.secureImageURL(from: front.image) else {
            throw CoverArtArchiveError.noFrontCoverAvailable
        }

        let imageData = try await performRequest(url: imageURL)
        let fileExtension = imageURL.pathExtension.isEmpty ? "jpg" : imageURL.pathExtension
        return (imageData, fileExtension)
    }

    /// The Archive.org CDN sometimes lists image URLs with an `http` scheme even though it serves
    /// the same content over `https` — App Transport Security blocks the former, so upgrade it.
    private static func secureImageURL(from raw: String) -> URL? {
        guard var components = URLComponents(string: raw) else { return nil }
        components.scheme = "https"
        return components.url
    }

    private func performRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(MusicBrainzClient.userAgent, forHTTPHeaderField: "User-Agent")

        await rateLimiter.waitIfNeeded()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CoverArtArchiveError.invalidResponse(status)
        }
        return data
    }
}

private struct CoverArtListWire: Decodable {
    let images: [CoverArtImageWire]
}

private struct CoverArtImageWire: Decodable {
    let front: Bool
    let image: String
}
