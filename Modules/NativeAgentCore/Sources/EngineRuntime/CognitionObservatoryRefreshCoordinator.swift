import Observation

/// Keeps the mounted Observatory's async read lifecycle honest. Multiple
/// controls can request a refresh at once; only the most recently requested
/// read may replace the visible snapshot, so an older completion cannot make
/// the screen look current with stale state.
@MainActor @Observable
public final class CognitionObservatoryRefreshCoordinator {
    public init() {}
    public enum Outcome: Sendable, Equatable {
        case accepted
        case superseded
    }

    private var latestGeneration: UInt64 = 0
    public private(set) var isRefreshing = false

    public func begin() -> UInt64 {
        latestGeneration &+= 1
        isRefreshing = true
        return latestGeneration
    }

    public func settle(_ generation: UInt64) -> Outcome {
        guard generation == latestGeneration else { return .superseded }
        isRefreshing = false
        return .accepted
    }
}
