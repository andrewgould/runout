import XCTest
@testable import Runout

private final class MockHTTPDataFetching: HTTPDataFetching {
    var responsesByURL: [URL: (data: Data, statusCode: Int)] = [:]
    private(set) var requestedURLs: [URL] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        requestedURLs.append(url)
        guard let canned = responsesByURL[url] else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let response = HTTPURLResponse(url: url, statusCode: canned.statusCode, httpVersion: nil, headerFields: nil)!
        return (canned.data, response)
    }
}

final class CoverArtArchiveClientTests: XCTestCase {
    // Real shape captured from coverartarchive.org/release/05e77dbd-... (the 1969 Abbey Road
    // pressing, which genuinely has front/back cover art on the archive).
    private static let realListResponseJSON = Data(#"""
    {"images":[{"approved":true,"back":false,"comment":"","edit":112795307,"front":true,"id":39065418368,"image":"https://coverartarchive.org/release/05e77dbd-1c4f-4e5e-8461-caac6e5fbae7/39065418368.jpg","thumbnails":{"1200":"https://coverartarchive.org/release/05e77dbd-1c4f-4e5e-8461-caac6e5fbae7/39065418368-1200.jpg","250":"https://coverartarchive.org/release/05e77dbd-1c4f-4e5e-8461-caac6e5fbae7/39065418368-250.jpg","500":"https://coverartarchive.org/release/05e77dbd-1c4f-4e5e-8461-caac6e5fbae7/39065418368-500.jpg","large":"https://coverartarchive.org/release/05e77dbd-1c4f-4e5e-8461-caac6e5fbae7/39065418368-500.jpg","small":"https://coverartarchive.org/release/05e77dbd-1c4f-4e5e-8461-caac6e5fbae7/39065418368-250.jpg"},"types":["Front"]},{"approved":true,"back":true,"comment":"","edit":112795327,"front":false,"id":39065422231,"image":"https://coverartarchive.org/release/05e77dbd-1c4f-4e5e-8461-caac6e5fbae7/39065422231.jpg","thumbnails":{"1200":"https://coverartarchive.org/release/05e77dbd-1c4f-4e5e-8461-caac6e5fbae7/39065422231-1200.jpg","250":"https://coverartarchive.org/release/05e77dbd-1c4f-4e5e-8461-caac6e5fbae7/39065422231-250.jpg","500":"https://coverartarchive.org/release/05e77dbd-1c4f-4e5e-8461-caac6e5fbae7/39065422231-500.jpg","large":"https://coverartarchive.org/release/05e77dbd-1c4f-4e5e-8461-caac6e5fbae7/39065422231-500.jpg","small":"https://coverartarchive.org/release/05e77dbd-1c4f-4e5e-8461-caac6e5fbae7/39065422231-250.jpg"},"types":["Back"]}]}
    """#.utf8)

    func testFetchesFrontCoverNotBackCover() async throws {
        let mock = MockHTTPDataFetching()
        let listURL = URL(string: "https://coverartarchive.org/release/05e77dbd-1c4f-4e5e-8461-caac6e5fbae7")!
        let frontImageURL = URL(string: "https://coverartarchive.org/release/05e77dbd-1c4f-4e5e-8461-caac6e5fbae7/39065418368.jpg")!
        let fakeImageBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])

        mock.responsesByURL[listURL] = (Self.realListResponseJSON, 200)
        mock.responsesByURL[frontImageURL] = (fakeImageBytes, 200)

        let client = CoverArtArchiveClient(session: mock, rateLimiter: MusicBrainzRateLimiter(minimumInterval: 0))
        let result = try await client.fetchFrontCoverImageData(releaseID: "05e77dbd-1c4f-4e5e-8461-caac6e5fbae7")

        XCTAssertEqual(result.data, fakeImageBytes)
        XCTAssertEqual(result.fileExtension, "jpg")
        XCTAssertEqual(mock.requestedURLs, [listURL, frontImageURL], "must fetch the front image, not the back one")
    }

    func testThrowsWhenNoImagesExist() async {
        let mock = MockHTTPDataFetching()
        let releaseID = "00000000-0000-0000-0000-000000000000"
        let listURL = URL(string: "https://coverartarchive.org/release/\(releaseID)")!
        mock.responsesByURL[listURL] = (Data(#"{"images":[]}"#.utf8), 200)

        let client = CoverArtArchiveClient(session: mock, rateLimiter: MusicBrainzRateLimiter(minimumInterval: 0))
        do {
            _ = try await client.fetchFrontCoverImageData(releaseID: releaseID)
            XCTFail("Expected an error when no front image exists")
        } catch let error as CoverArtArchiveError {
            guard case .noFrontCoverAvailable = error else {
                return XCTFail("Expected .noFrontCoverAvailable, got \(error)")
            }
        } catch {
            XCTFail("Expected CoverArtArchiveError, got \(error)")
        }
    }

    func testThrows404WhenReleaseHasNoArchiveEntryAtAll() async {
        // The MockHTTPDataFetching returns a bare 404 for any unregistered URL, matching the
        // real archive's behavior for a release with no cover art at all (confirmed live).
        let mock = MockHTTPDataFetching()
        let client = CoverArtArchiveClient(session: mock, rateLimiter: MusicBrainzRateLimiter(minimumInterval: 0))
        do {
            _ = try await client.fetchFrontCoverImageData(releaseID: "no-art-release-id")
            XCTFail("Expected an error")
        } catch let error as CoverArtArchiveError {
            guard case .invalidResponse(404) = error else {
                return XCTFail("Expected .invalidResponse(404), got \(error)")
            }
        } catch {
            XCTFail("Expected CoverArtArchiveError, got \(error)")
        }
    }
}
