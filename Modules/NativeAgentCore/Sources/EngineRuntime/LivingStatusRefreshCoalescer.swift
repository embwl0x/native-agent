import Foundation
// Blueprint: | `LivingStatusRefreshCoalescer.swift` | `LivingStatusRefreshCoalescer` struct; `requestRefresh`, `completePass` |

/// Coalesce invalidations into one read and trailing pass; changes during that pass start a delayed next episode.
public struct LivingStatusRefreshCoalescer: Equatable, Sendable {
    public init() {}

    public private(set) var isRefreshing = false
    public private(set) var trailingPassQueued = false
    public private(set) var trailingPassConsumed = false

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

    /// The caller must defer the next episode once this trailing pass is consumed.
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
