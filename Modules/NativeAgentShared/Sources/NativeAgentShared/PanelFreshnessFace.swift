import Foundation
// Blueprint: | `PanelFreshnessFace.swift` | Shared panel refresh receipts and selected panel reading state |

public struct PanelRefreshStatus: Equatable, Sendable, Codable {
    public var lastAttemptAt: Date
    /// A full-success stamp requires every endpoint; nil preserves unknown readiness this run.
    public var lastSuccessAt: Date?
    public var failedEndpoints: [String]

    public var isStale: Bool { !failedEndpoints.isEmpty }

    public init(lastAttemptAt: Date, lastSuccessAt: Date? = nil, failedEndpoints: [String]) {
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.failedEndpoints = failedEndpoints
    }
}

public struct PanelFreshnessFace: FaceValue {
    public struct Panel: Equatable, Sendable, Codable {
        public var receipt: PanelRefreshStatus?
        public var isReading: Bool
        public var staleNotice: String?

        public init(receipt: PanelRefreshStatus? = nil, isReading: Bool = false, staleNotice: String? = nil) {
            self.receipt = receipt
            self.isReading = isReading
            self.staleNotice = staleNotice
        }
    }

    public var panels: [String: Panel]
    public var sidebar: PanelRefreshStatus?
    public var detached: [String: PanelRefreshStatus]

    public init(panels: [String: Panel] = [:], sidebar: PanelRefreshStatus? = nil,
                detached: [String: PanelRefreshStatus] = [:]) {
        self.panels = panels
        self.sidebar = sidebar
        self.detached = detached
    }
}
