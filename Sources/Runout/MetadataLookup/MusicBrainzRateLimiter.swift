import Foundation

/// Enforces MusicBrainz's documented rate limit (max 1 request/second) across all lookup calls.
/// `MusicBrainzClient` and `CoverArtArchiveClient` share one limiter instance (`.shared`).
actor MusicBrainzRateLimiter {
    static let shared = MusicBrainzRateLimiter()

    private let minimumInterval: TimeInterval
    /// The earliest time a *next* request is allowed to fire — reserved synchronously (no `await`
    /// between reading and writing it) so concurrent callers queue into a strictly increasing
    /// sequence instead of racing. Swift actors are reentrant at suspension points: without
    /// reserving the slot before `await Task.sleep`, two concurrent callers can both read the
    /// same stale `lastRequestAt`, both compute the same wait, and both sleep in parallel —
    /// silently violating the rate limit. Caught by `MusicBrainzRateLimiterTests`.
    private var nextAllowedAt: Date?

    init(minimumInterval: TimeInterval = 1.0) {
        self.minimumInterval = minimumInterval
    }

    /// Blocks until at least `minimumInterval` has passed since the last reserved slot. Call
    /// this immediately before issuing a request.
    func waitIfNeeded() async {
        let now = Date()
        let slot = (nextAllowedAt.map { max($0, now) }) ?? now
        nextAllowedAt = slot.addingTimeInterval(minimumInterval)

        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
