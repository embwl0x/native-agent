import Foundation
// Blueprint: | `ContextFillPresentation.swift` | `ContextFillPresentation`: context usage share of a session's window; missing measurements remain unavailable |

/// Absent provider figures must stay absent so visible and accessibility readouts cannot invent zero usage.
public enum ContextFillPresentation {
    public struct Usage: Equatable, Sendable {
        public let percent: Double
        public let fillFraction: Double

        public init(percent: Double, fillFraction: Double) {
            self.percent = percent
            self.fillFraction = fillFraction
        }
    }

    /// Use the owner's measured or estimated share rather than inventing usage locally.
    public static func usage(_ status: SessionContextStatus) -> Usage {
        let percent = status.budget > 0 ? status.percent : 0
        return Usage(
            percent: percent,
            fillFraction: min(1, max(0, percent / 100))
        )
    }
}
