import XCTest
@testable import Runout

final class MusicBrainzRateLimiterTests: XCTestCase {
    func testFirstCallDoesNotWait() async {
        let limiter = MusicBrainzRateLimiter(minimumInterval: 1.0)
        let start = Date()
        await limiter.waitIfNeeded()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
    }

    func testSecondCallWaitsOutTheRemainingInterval() async {
        let limiter = MusicBrainzRateLimiter(minimumInterval: 0.3)
        await limiter.waitIfNeeded()

        let start = Date()
        await limiter.waitIfNeeded()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(elapsed, 0.29, "must wait out close to the full interval")
        XCTAssertLessThan(elapsed, 0.6, "shouldn't wait dramatically longer than needed")
    }

    func testCallAfterIntervalHasAlreadyElapsedDoesNotWaitAgain() async {
        let limiter = MusicBrainzRateLimiter(minimumInterval: 0.2)
        await limiter.waitIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000) // sleep past the interval ourselves

        let start = Date()
        await limiter.waitIfNeeded()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
    }

    func testConcurrentCallersAreSerializedNotParallel() async {
        // Three concurrent callers against a 0.2s interval should take ~0.4-0.6s total if truly
        // serialized (actor isolation), not ~0.2s if they raced past the check concurrently.
        let limiter = MusicBrainzRateLimiter(minimumInterval: 0.2)
        let start = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { await limiter.waitIfNeeded() }
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.35)
    }
}
