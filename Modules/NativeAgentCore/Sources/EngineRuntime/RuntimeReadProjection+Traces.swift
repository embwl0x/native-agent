import Foundation
// Blueprint: | `RuntimeReadProjection+Traces.swift` | `RuntimeReadError`: unreadable feed detail shared by checked runtime readers |

/// A feed read failure with its owner-provided detail.
public enum RuntimeReadError: LocalizedError, Equatable {
    case unreadableFeed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFeed(let detail):
            return detail
        }
    }
}
