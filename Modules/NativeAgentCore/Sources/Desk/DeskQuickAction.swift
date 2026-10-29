import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `DeskQuickAction.swift` | `DeskQuickAction`: Desk tool names and dispatch arguments |

public enum DeskQuickAction: Equatable, Sendable {
    case close(handle: String, outcome: String)
    /// Palette closes bind to the row version observed while resolving the
    /// palette result. A later change must refuse at the store boundary rather
    /// than let Enter acknowledge a different row state as this close.
    case closeIfCurrent(handle: String, outcome: String, expectedUpdatedAt: String)
    case setStatus(handle: String, status: DeskStatus)
    case defer_(handle: String, until: String?)
    case note(handle: String, text: String)
    case nagGlobal(on: Bool)
    case nagProject(project: String, on: Bool)
    case nagItem(handle: String, on: Bool)
    case nagMute(until: String?)
    case nagUnmute

    /// The default outcome summary for a one-keystroke close. `desk_close`
    /// REFUSES an empty `outcome_summary`, and the honest thing to record is
    /// where the close came from — not an invented outcome.
    public static let deskCloseOutcome = "Closed from the desk."

    public var tool: String {
        switch self {
        case .close, .closeIfCurrent: return "desk_close"
        case .setStatus: return "desk_set_status"
        case .defer_: return "desk_defer"
        case .note: return "desk_note"
        case .nagGlobal, .nagProject, .nagItem, .nagMute, .nagUnmute: return "desk_nag_control"
        }
    }

    public var input: [String: JSONValue] {
        switch self {
        case let .close(handle, outcome):
            return ["handle": .string(handle), "outcome_summary": .string(outcome)]
        case let .closeIfCurrent(handle, outcome, expectedUpdatedAt):
            return [
                "handle": .string(handle),
                "outcome_summary": .string(outcome),
                "expected_updated_at": .string(expectedUpdatedAt),
            ]
        case let .setStatus(handle, status):
            return ["handle": .string(handle), "status": .string(status.rawValue)]
        case let .defer_(handle, until):
            // An EMPTY `until` is how desk_defer clears a park — the same
            // encoding the chat tool documents, not a second convention.
            return ["handle": .string(handle), "until": .string(until ?? "")]
        case let .note(handle, text):
            return ["handle": .string(handle), "text": .string(text)]
        case let .nagGlobal(on):
            return ["action": .string(on ? "enable" : "disable"), "scope_kind": .string("global")]
        case let .nagProject(project, on):
            return [
                "action": .string(on ? "enable" : "disable"),
                "scope_kind": .string("project"),
                "scope_id": .string(project),
            ]
        case let .nagItem(handle, on):
            return [
                "action": .string(on ? "enable" : "disable"),
                "scope_kind": .string("item"),
                "scope_id": .string(handle),
            ]
        case let .nagMute(until):
            var input: [String: JSONValue] = ["action": .string("mute")]
            if let until, !until.isEmpty { input["until"] = .string(until) }
            return input
        case .nagUnmute:
            return ["action": .string("unmute")]
        }
    }

}
