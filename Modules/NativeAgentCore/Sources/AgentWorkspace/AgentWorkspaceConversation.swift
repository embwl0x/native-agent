import Foundation
import PersistenceCore
// Blueprint: | `AgentWorkspaceConversation.swift` | `AgentWorkspaceConversation` enum; `project` |

/// Conversation controls retain the navigation owner's selected contact and
/// conversation. Remote text/locators never choose a recipient or replay a send.
enum AgentWorkspaceConversation {
    static func project(input: [String: JSONValue], title: String, result: JSONValue) -> WorkspacePage {
        guard case .string(let agent)? = input["agent"], !agent.isEmpty else {
            return .init(title: title, content: result, items: [], actions: [])
        }
        var content: [String: JSONValue]
        if case .object(let row) = result { content = row }
        else { content = ["result": result] }
        let phase: String
        if case .string(let state)? = content["state"] { phase = state }
        else if case .string(let status)? = content["status"] { phase = status }
        else { phase = "unknown" }
        let waiting = ["sending", "waiting", "queued", "running", "working", "pending", "delivering", "accepted"].contains(phase)
        let needsAttention = ["attention", "failed", "unavailable", "outcome_unknown", "reconnect_required", "needs_setup", "blocked", "denied", "blocked_by_trust", "session_unavailable", "no_outbound_route"].contains(phase)
            || content["error"] != nil || content["last_send_error"] != nil
            || (content["last_send_needs_authentication"] ?? content["needs_authentication"]) == .bool(true)
        var latest = input
        latest.removeValue(forKey: "details")
        latest.removeValue(forKey: "history_before")
        latest.removeValue(forKey: "history_exchange")
        let source = AgentWorkspaceLocation.record(tool: "agent_read", input: latest, title: title)
        if input["details"] == .bool(true) {
            return .init(title: title + " — Details", content: result, items: [], actions: [
                .init(label: "Back to conversation", action: .open(source))
            ])
        }
        var actions: [AgentWorkspaceButton] = [
            .init(label: waiting ? "Check for the reply" : "Refresh conversation", action: .open(source))
        ]
        var detail = latest
        detail["details"] = .bool(true)
        actions.append(.init(label: needsAttention ? "Inspect what needs attention" : "Conversation details",
            action: .open(.record(tool: "agent_read", input: detail, title: title))))
        // A contact with no saved exchange has nothing to refresh or diagnose.
        // Keep the one useful action rather than offering empty reply readers.
        if ["not_opened", "no_history", "unknown_contact"].contains(phase) { actions.removeAll() }
        var items: [AgentWorkspaceItem] = []
        if case .object(var history)? = content["session_history"] {
            if let boundary = history.removeValue(forKey: "earlier_before")?.stringValue, ContactThread.isMessageID(boundary) {
                var earlier = latest; earlier["history_before"] = .string(boundary)
                actions.append(.init(label: "Earlier messages", action: .open(.record(tool: "agent_read", input: earlier, title: title))))
            }
            if input["history_before"] != nil || input["history_exchange"] != nil {
                actions.append(.init(label: "Recent messages", action: .open(source)))
            }
            if case .array(let messages)? = history.removeValue(forKey: "messages") {
                items = messages.compactMap { value in
                    guard case .object(var message) = value, let id = message.removeValue(forKey: "message")?.stringValue,
                          ContactThread.isMessageID(id) else { return nil }
                    var selected = latest; selected["history_exchange"] = .string(id)
                    return .init(title: (message["from"]?.stringValue ?? title) + " — " + (message["at"]?.stringValue ?? ""),
                        content: .object(message), actions: input["history_exchange"] == .string(id) ? [] : [
                            .init(label: "Read message", action: .open(.record(tool: "agent_read", input: selected, title: title)))
                        ])
                }
            }
            history.removeValue(forKey: "selected_message")
            history.removeValue(forKey: "coverage"); history.removeValue(forKey: "order")
            content["session_history"] = .object(history)
        }
        // Exact-protocol readers are not the current named conversation. Do
        // not offer a Reply that would silently use another selected thread.
        let advanced = ["conversation_id", "message_id", "task_id"].contains { input[$0] != nil }
        let unknown = ["outcome_unknown", "session_unavailable"].contains(phase)
            || content["status"] == .string("outcome_unknown")
        if phase != "unknown_contact", !waiting && !unknown && content["can_reply"] != .bool(false) && (!advanced || agent.hasPrefix("bot:")) {
            let conversation: String?
            if case .string(let value)? = input["conversation"] { conversation = value }
            else { conversation = nil }
            actions.insert(.init(label: ["not_opened", "no_history"].contains(phase) ? "Start talking" : "Reply",
                action: .message(agent: agent, conversation: conversation, name: title), needsText: true), at: 0)
        }
        if waiting || needsAttention {
            content["workspace_recovery"] = .string(waiting
                ? "Waiting here; the answer returns through the saved connection. No resend needed."
                : "Your conversation is preserved. Check its saved result before sending anything again.")
        }
        if needsAttention && ((content["last_send_needs_authentication"] ?? content["needs_authentication"]) == .bool(true)
            || ["reconnect_required", "needs_setup", "unavailable", "no_outbound_route"].contains(content["status"]?.stringValue ?? phase)) {
            actions.append(.init(label: "Check connections", action: .open(.area("connections"))))
        }
        // The same exact selection backs both actions. Diagnostics are one
        // explicit click away instead of requiring protocol IDs from Agent.
        content.removeValue(forKey: "reply_with")
        content.removeValue(forKey: "inspect_receipt")
        // Navigation holds identities and source references. Keep their exact
        // values in Details, without making Agent parse them around each reply.
        for key in ["agent", "agent_id", "can_reply", "conversation_id", "message_id", "task_id", "read_with", "meaning", "order"] {
            content.removeValue(forKey: key)
        }
        if case .array(let exchanges)? = content["exchanges"] {
            // A clipped reply keeps its exact reader one click away.
            for (index, exchange) in exchanges.enumerated() {
                guard case .object(let row) = exchange, row["reply_truncated"] == .bool(true),
                      case .object(let locator)? = row["read_with"], locator["tool"] == .string("agent_read"),
                      case .object(let read)? = locator["input"] else { continue }
                actions.append(.init(label: "Read full reply" + (exchanges.count > 1 ? " \(index + 1)" : ""),
                    action: .open(.record(tool: "agent_read", input: read, title: title))))
            }
            content["exchanges"] = .array(exchanges.map { exchange in
                guard case .object(var row) = exchange else { return exchange }
                for key in ["conversation_id", "message_id", "task_id", "read_with", "reply_with", "work_completion"] {
                    row.removeValue(forKey: key)
                }
                // With the words present, the bookkeeping around them is noise.
                if row["text"] != nil {
                    for key in ["reply_state", "execution_state", "text_kind", "text_coverage", "delivery_outcome", "from"] {
                        row.removeValue(forKey: key)
                    }
                }
                return .object(row)
            })
        }
        return .init(title: title, content: .object(content), items: items, actions: actions)
    }
}
