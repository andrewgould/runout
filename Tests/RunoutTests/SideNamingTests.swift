import XCTest
@testable import Runout

final class SideNamingTests: XCTestCase {
    func testSingleLetterNames() {
        XCTAssertEqual(SideNaming.slugAndLabel(forIndex: 0).slug, "side-a")
        XCTAssertEqual(SideNaming.slugAndLabel(forIndex: 0).label, "Side A")
        XCTAssertEqual(SideNaming.slugAndLabel(forIndex: 1).slug, "side-b")
        XCTAssertEqual(SideNaming.slugAndLabel(forIndex: 25).slug, "side-z")
    }

    /// The regression this type fixes (docs/IMPROVEMENT_PLAN.md P1-1): index 26 used to clamp
    /// back to "side-z", silently overwriting side 26's audio in the package.
    func testNamesContinuePastZWithoutColliding() {
        XCTAssertEqual(SideNaming.slugAndLabel(forIndex: 26).slug, "side-aa")
        XCTAssertEqual(SideNaming.slugAndLabel(forIndex: 26).label, "Side AA")
        XCTAssertEqual(SideNaming.slugAndLabel(forIndex: 27).slug, "side-ab")
        XCTAssertEqual(SideNaming.slugAndLabel(forIndex: 51).slug, "side-az")
        XCTAssertEqual(SideNaming.slugAndLabel(forIndex: 52).slug, "side-ba")

        let firstHundred = Set((0..<100).map { SideNaming.slugAndLabel(forIndex: $0).slug })
        XCTAssertEqual(firstHundred.count, 100, "every index must produce a unique slug")
    }

    func testNextAvailableSkipsPathsAlreadyInThePackage() {
        let existing: Set<String> = ["side-a.flac", "side-b.flac", "side-c.flac"]
        // startingIndex 1 ("side-b") is taken, as is 2 — the first free slot is "side-d".
        let naming = SideNaming.nextAvailable(existingMasterPaths: existing, startingIndex: 1)
        XCTAssertEqual(naming.slug, "side-d")
        XCTAssertEqual(naming.label, "Side D")
    }

    func testNextAvailableReturnsStartingIndexWhenFree() {
        let naming = SideNaming.nextAvailable(existingMasterPaths: ["side-a.flac"], startingIndex: 1)
        XCTAssertEqual(naming.slug, "side-b")
    }
}
