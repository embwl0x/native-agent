import Foundation
// Blueprint: | `RuntimeReadProjection+Traces.swift` | `RuntimeReadError`: unreadable feed detail shared by checked runtime readers |

/// Keep owner-provided detail on feed read failures.
public enum RuntimeReadError: LocalizedError, Equatable {
    case unreadableFeed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFeed(let detail):
            return detail
        }
    }
}
