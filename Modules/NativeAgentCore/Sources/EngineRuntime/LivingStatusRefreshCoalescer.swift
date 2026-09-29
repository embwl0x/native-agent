import Foundation

/// Bounded refresh ownership for the mounted Living Status card. File watching,
/// cognition events, and the manual button may all request while one snapshot
/// read is in flight. They collapse into one trailing pass, then the episode
/// ends even if a noisy source keeps requesting during that trailing pass.
public struct LivingStatusRefreshCoalescer: Equatable, Sendable {
    public init() {}

    public private(set) var isRefreshing = false
    public private(set) var trailingPassQueued = false
    public private(set) var trailingPassConsumed = false

    /// Returns true for the caller that must begin a refresh episode.
    public mutating func requestRefresh() -> Bool {
        guard isRefreshing else {
            isRefreshing = true
            trailingPassQueued = false
            trailingPassConsumed = false
            return true
        }

        // Preserve the newest edge behind the initial pass, but do not make a
        // self-sustaining file/runtime event loop able to keep this card busy
        // forever.
        if !trailingPassConsumed {
            trailingPassQueued = true
        }
        return false
    }

    /// Call after every refresh pass. Returns true exactly once when requests
    /// arrived during the initial pass and a trailing read is still required.
    public mutating func completePass() -> Bool {
        guard isRefreshing else { return false }
        if trailingPassQueued && !trailingPassConsumed {
            trailingPassQueued = false
            trailingPassConsumed = true
            return true
        }
        reset()
        return false
    }

    public mutating func cancel() {
        reset()
    }

    private mutating func reset() {
        isRefreshing = false
        trailingPassQueued = false
        trailingPassConsumed = false
    }
}
