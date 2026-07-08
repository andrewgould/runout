import XCTest
@testable import Runout

final class PeakCacheTests: XCTestCase {
    func testSerializationRoundTrips() throws {
        let cache = PeakCache(
            samplesPerBucketAtFinestLevel: 256,
            levels: [
                [PeakBucket(min: -100, max: 100), PeakBucket(min: -50, max: 75)],
                [PeakBucket(min: -100, max: 100)],
            ]
        )

        let data = cache.serialized()
        let decoded = try PeakCache.deserialized(from: data)

        XCTAssertEqual(decoded, cache)
    }

    func testDeserializingGarbageThrowsBadMagic() {
        let garbage = Data("not a peak cache".utf8)
        XCTAssertThrowsError(try PeakCache.deserialized(from: garbage)) { error in
            XCTAssertTrue(error is PeakCacheError)
        }
    }

    func testDeserializingTruncatedDataThrows() {
        var data = Data("RPKS".utf8)
        data.append(contentsOf: [1, 0, 0]) // an incomplete UInt32 that follows the magic
        XCTAssertThrowsError(try PeakCache.deserialized(from: data))
    }

    func testLevelSelectionPicksFinestLevelThatFitsSamplesPerPoint() {
        let cache = PeakCache(
            samplesPerBucketAtFinestLevel: 256,
            levels: [
                Array(repeating: PeakBucket(min: 0, max: 0), count: 1000), // 256 samples/bucket
                Array(repeating: PeakBucket(min: 0, max: 0), count: 500),  // 512 samples/bucket
                Array(repeating: PeakBucket(min: 0, max: 0), count: 250),  // 1024 samples/bucket
            ]
        )

        XCTAssertEqual(cache.level(forSamplesPerPoint: 100).bucketSize, 256, "should never pick a bucket coarser than requested when a finer one exists, even if that means more buckets than points")
        XCTAssertEqual(cache.level(forSamplesPerPoint: 256).bucketSize, 256)
        XCTAssertEqual(cache.level(forSamplesPerPoint: 600).bucketSize, 512)
        XCTAssertEqual(cache.level(forSamplesPerPoint: 5000).bucketSize, 1024, "should fall back to the coarsest available level even if it's still finer than requested")
    }

    func testTotalSampleCountEstimate() {
        let cache = PeakCache(
            samplesPerBucketAtFinestLevel: 256,
            levels: [Array(repeating: PeakBucket(min: 0, max: 0), count: 10)]
        )
        XCTAssertEqual(cache.totalSampleCountEstimate, 2560)
    }
}
