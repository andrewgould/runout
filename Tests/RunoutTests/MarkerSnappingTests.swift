import XCTest
@testable import Runout

final class MarkerSnappingTests: XCTestCase {
    func testReturnsExactIndexWhenAlreadyAZeroCrossing() {
        let samples: [Float] = [-1, -0.5, 0.5, 1, 0.5, -0.5]
        // index 2 (-0.5 -> 0.5) is a zero crossing.
        XCTAssertEqual(MarkerSnapping.nearestZeroCrossingIndex(in: samples, around: 2), 2)
    }

    func testFindsNearestCrossingWhenNotExactlyOnOne() {
        // Crossings at index 2 (neg->pos) and index 4 (pos->neg). Target 3 is equidistant;
        // the search checks "after" before "before" at each growing offset, so it finds index 4 first.
        let samples: [Float] = [-1, -0.5, 0.5, 1, -0.5, -1]
        XCTAssertEqual(MarkerSnapping.nearestZeroCrossingIndex(in: samples, around: 3), 4)
    }

    func testPrefersCloserCrossingOnEitherSide() {
        // Only crossing is at index 1 (neg->pos); target index 5 should find it despite the distance.
        let samples: [Float] = [-1, 1, 1, 1, 1, 1]
        XCTAssertEqual(MarkerSnapping.nearestZeroCrossingIndex(in: samples, around: 5), 1)
    }

    func testReturnsTargetUnchangedWhenNoCrossingExists() {
        let samples: [Float] = [1, 1, 1, 1, 1]
        XCTAssertEqual(MarkerSnapping.nearestZeroCrossingIndex(in: samples, around: 2), 2)
    }

    func testOutOfBoundsTargetReturnsUnchanged() {
        let samples: [Float] = [1, 1, 1]
        XCTAssertEqual(MarkerSnapping.nearestZeroCrossingIndex(in: samples, around: 10), 10)
    }

    func testEmptyArrayReturnsTargetUnchanged() {
        let samples: [Float] = []
        XCTAssertEqual(MarkerSnapping.nearestZeroCrossingIndex(in: samples, around: 0), 0)
    }

    func testNearestZeroCrossingFromRealFileReturnsNilForMissingFile() {
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist.flac")
        XCTAssertNil(MarkerSnapping.nearestZeroCrossing(toSample: 1000, fileURL: missingURL))
    }
}
