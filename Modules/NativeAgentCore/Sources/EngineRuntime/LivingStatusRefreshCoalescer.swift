import Foundation

/// Bounded refresh ownership for the mounted Living Status card. File watching,
/// cognition events, and the manual button may all request while one snapshot
/// read is in flight. Each episode has one trailing pass. An invalidation
/// during that pass starts a subsequent episode after the caller's delay.
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

        trailingPassQueued = true
        return false
    }

    /// Returns true if an invalidation still needs a read. When the trailing
    /// pass was consumed, the next episode must be deferred by the caller.
    public mutating func completePass() -> Bool {
        guard isRefreshing else { return false }
        if trailingPassQueued {
            trailingPassQueued = false
            trailingPassConsumed.toggle()
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
