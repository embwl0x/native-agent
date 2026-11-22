import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DeskQuickAction.swift` | `DeskQuickAction`: Desk tool names and dispatch arguments |

public enum DeskQuickAction: Equatable, Sendable {
    case close(handle: String, outcome: String)
    /// Bind palette closes to the observed row revision so Enter cannot acknowledge a later state.
    case closeIfCurrent(handle: String, outcome: String, expectedUpdatedAt: String)
    case setStatus(handle: String, status: DeskStatus)
    case note(handle: String, text: String)

    /// Record the close’s source because the required reason must not invent an outcome.
    public static let deskCloseOutcome = "Closed from the desk."

    public var tool: String {
        switch self {
        case .close, .closeIfCurrent: return "desk_close"
        case .setStatus: return "desk_set_status"
        case .note: return "desk_note"
        }
    }

    public var input: [String: JSONValue] {
        switch self {
        case let .close(handle, outcome):
            return ["handle": .string(handle), "reason": .string(outcome)]
        case let .closeIfCurrent(handle, outcome, expectedUpdatedAt):
            return [
                "handle": .string(handle),
                "reason": .string(outcome),
                "expected_updated_at": .string(expectedUpdatedAt),
            ]
        case let .setStatus(handle, status):
            return ["handle": .string(handle), "status": .string(status.rawValue)]
        case let .note(handle, text):
            return ["handle": .string(handle), "text": .string(text)]
        }
    }

}
