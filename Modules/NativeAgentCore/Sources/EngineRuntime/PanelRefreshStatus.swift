import Foundation

public struct PanelRefreshStatus: Equatable, Sendable {
    /// When the panel last attempted a refresh.
    public var lastAttemptAt: Date
    /// When the panel last completed a refresh with *every* endpoint OK.
    /// nil means it has never had a fully-successful refresh this run.
    public var lastSuccessAt: Date?
    /// Endpoints that returned nil on the last attempt. Non-empty means at
    /// least one value on screen is carried over from an earlier refresh.
    public var failedEndpoints: [String]

    public var isStale: Bool { !failedEndpoints.isEmpty }
    public init(lastAttemptAt: Date, lastSuccessAt: Date? = nil, failedEndpoints: [String]) {
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.failedEndpoints = failedEndpoints
    }

}
