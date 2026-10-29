import Foundation
import NativeAgentCore
import PersistenceCore
import ChatTurnContracts
// Blueprint: | `ChatToolSessionInjection.swift` | `ChatToolSessionInjection`: explicit-input extraction, verified-session → tool-loop-session selection and shared internal/tool-specific session injection |

/// Shared session input handling; explicit caller fields confer no verified identity.
package enum ChatToolSessionInjection {
    package static func explicitSessionId(in input: [String: JSONValue]) -> String {
        for key in ["__session_id", "session_id", "sessionId"] {
            if case .string(let raw)? = input[key] {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    /// Transport-verified session first, then the direct tool loop's session.
    /// Without either, leave the caller's explicit input intact.
    package static var currentSession: String? {
        [ChatToolSessionContext.verifiedSessionId, LLMCallContext.sessionId]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    package static func apply(toolName: String, input: [String: JSONValue]) -> [String: JSONValue] {
        apply(toolName: toolName, input: input, sessionId: currentSession)
    }

    package static func apply(
        toolName: String,
        input: [String: JSONValue],
        sessionId: String?
    ) -> [String: JSONValue] {
        guard let sessionId,
              !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return input
        }
        // Always inject __session_id so the dispatcher and the app door have
        // it without the LLM having to remember to pass it.
        var out = input
        out["__session_id"] = .string(sessionId)
        if toolName == "scratchpad_read" {
            out["session_id"] = .string(sessionId)
            out["sessionId"] = .string(sessionId)
        }
        if toolName == "recent_trace_summary",
           out["view"] != .string("receipts"), out["effects_only"] != .bool(true),
           out["session_id"] == nil,
           out["sessionId"] == nil {
            out["session_id"] = .string(sessionId)
        }
        if toolName == "search_chat_history" || toolName == "session_search" {
            out["current_session_id"] = .string(sessionId)
        }
        if toolName == "tool_result_page" {
            // Auto-fill session_id so the LLM doesn't have to remember it.
            let hasSession: Bool = {
                if case .string(let s) = out["session_id"] ?? .null,
                   !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
                return false
            }()
            if !hasSession {
                out["session_id"] = .string(sessionId)
            }
        }
        return out
    }
}
