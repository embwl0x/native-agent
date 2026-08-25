import Observation

/// Keeps the mounted Observatory's async read lifecycle honest. Multiple
/// controls can request a refresh at once; only the most recently requested
/// read may replace the visible snapshot, so an older completion cannot make
/// the screen look current with stale state.
@MainActor @Observable
final class CognitionObservatoryRefreshCoordinator {
    enum Outcome: Sendable, Equatable {
        case accepted
        case superseded
    }

    private var latestGeneration: UInt64 = 0
    private(set) var isRefreshing = false

    func begin() -> UInt64 {
        latestGeneration &+= 1
        isRefreshing = true
        return latestGeneration
    }

    func settle(_ generation: UInt64) -> Outcome {
        guard generation == latestGeneration else { return .superseded }
        isRefreshing = false
        return .accepted
    }
}
