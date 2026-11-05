import Foundation
// Blueprint: | `PanelRefreshStatus.swift` | `PanelRefreshStatus` struct |

public struct PanelRefreshStatus: Equatable, Sendable {
    public var lastAttemptAt: Date
    /// A full-success stamp requires every endpoint; nil preserves unknown readiness this run.
    public var lastSuccessAt: Date?
    /// Failed endpoints leave displayed values carried from prior refreshes.
    public var failedEndpoints: [String]

    public var isStale: Bool { !failedEndpoints.isEmpty }
    public init(lastAttemptAt: Date, lastSuccessAt: Date? = nil, failedEndpoints: [String]) {
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.failedEndpoints = failedEndpoints
    }

}
