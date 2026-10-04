import Foundation
import NativeAgentCore
import PersistenceCore

/// Single source of truth for injecting the per-turn session id into tool input
/// before dispatch, so the LLM doesn't have to remember to pass it. Both the
/// structured tool loop AND the Anthropic text-compat tool loop call this — an
/// earlier divergence between the two copies bounced calls with
/// missing_session_id. Keep this the ONLY implementation.
package enum ChatToolSessionInjection {
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
