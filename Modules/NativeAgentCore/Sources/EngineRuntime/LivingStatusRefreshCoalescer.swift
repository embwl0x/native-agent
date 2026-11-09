import Foundation
// Blueprint: | `LivingStatusRefreshCoalescer.swift` | `LivingStatusRefreshCoalescer` struct; `requestRefresh`, `completePass` |

/// Coalesce invalidations while a read is running into one follow-up read.
public struct LivingStatusRefreshCoalescer: Equatable, Sendable {
    public init() {}

    public private(set) var isRefreshing = false
    public private(set) var trailingPassQueued = false

    public mutating func requestRefresh() -> Bool {
        guard isRefreshing else {
            isRefreshing = true
            trailingPassQueued = false
            return true
        }

        trailingPassQueued = true
        return false
    }

    public mutating func completePass() -> Bool {
        guard isRefreshing else { return false }
        if trailingPassQueued {
            trailingPassQueued = false
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
    }
}
