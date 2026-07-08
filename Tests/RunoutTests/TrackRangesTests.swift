import XCTest
@testable import Runout

final class TrackRangesTests: XCTestCase {
    func testNoMarkersProducesOneTrackSpanningTheWholeRecording() {
        let ranges = TrackRanges.compute(markers: [], totalSampleCount: 1000)
        XCTAssertEqual(ranges, [0..<1000])
    }

    func testMarkersSplitIntoConsecutiveNonOverlappingRanges() {
        let markers = [Marker(sampleOffset: 300), Marker(sampleOffset: 700)]
        let ranges = TrackRanges.compute(markers: markers, totalSampleCount: 1000)
        XCTAssertEqual(ranges, [0..<300, 300..<700, 700..<1000])
    }

    func testMarkersOutOfInputOrderAreSortedFirst() {
        let markers = [Marker(sampleOffset: 700), Marker(sampleOffset: 300)]
        let ranges = TrackRanges.compute(markers: markers, totalSampleCount: 1000)
        XCTAssertEqual(ranges, [0..<300, 300..<700, 700..<1000])
    }

    func testZeroLengthRecordingProducesOneEmptyRange() {
        let ranges = TrackRanges.compute(markers: [], totalSampleCount: 0)
        XCTAssertEqual(ranges, [0..<0])
    }
}
