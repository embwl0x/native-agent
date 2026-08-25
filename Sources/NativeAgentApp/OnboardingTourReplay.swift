import Observation

/// A Settings window is not the main-content scene that mounts the tour
/// overlay. This in-process request channel carries an explicit replay edge
/// to every current or later main-content mount, rather than hoping separate
/// `@AppStorage` wrappers invalidate each other at the right moment.
@MainActor
@Observable
final class OnboardingTourReplayCoordinator {
    static let shared = OnboardingTourReplayCoordinator()

    private(set) var requestID = 0
    private var deliveredRequestID = 0

    @discardableResult
    func requestReplay() -> Int {
        requestID += 1
        return requestID
    }

    /// Claims the newest replay once. The persisted `showTour` preference is
    /// still the recovery route for a main window that mounts after Settings;
    /// this method only delivers the immediate cross-window edge.
    func claim(_ requestID: Int) -> Bool {
        guard requestID == self.requestID,
              requestID > deliveredRequestID,
              requestID > 0 else { return false }
        deliveredRequestID = requestID
        return true
    }
}
