import Foundation
import PersistenceCore

/// Presentation only over an already-authorized read. No transcript, latest-
/// conversation lookup, semantic completion inference, or execution lives here.
public enum AgentConversationView {
    public static func read(_ receipt: JSONValue, agent: String, input: [String: JSONValue]) -> JSONValue {
        guard input["details"] != .bool(true), case .object(let raw) = receipt else { return receipt }
        // Preserve refusals and desktop interaction instructions verbatim.
        if raw["status"] == .string("requires_interaction") || raw["error"] != nil { return receipt }
        let rows: [[String: JSONValue]]
        let kind: String
        if case .array(let values)? = raw["jobs"] {
            rows = values.compactMap(object); kind = "coding"
        } else if case .array(let values)? = raw["entries"] {
            rows = values.compactMap(object); kind = "bot_preview"
        } else if agent.hasPrefix("bot:") {
            rows = [raw]; kind = "bot"
        } else if agent.hasPrefix("peer:") {
            rows = [raw]; kind = "peer"
        } else { return receipt }
        var result: [String: JSONValue] = [
            "agent": .string(agent), "status": raw["status"] ?? .string("ok"),
            "view": .string("conversation"),
            "exchanges": .array(rows.map { exchange($0, agent: agent, kind: kind) }),
            "meaning": .string("Message text is what the agent said. Execution state is recorded evidence, not proof that the requested work is correct or complete. Missing evidence never authorizes resending."),
            "order": .string(rows.count > 1 ? "newest_first" : "single_exchange")
        ]
        for key in ["source_availability", "has_more", "next_offset", "nextCursor", "truncated", "coverage", "conversation_id", "message_id", "task_id", "completed", "terminal", "untrusted_remote_data", "detail", "read_with"] {
            if let value = raw[key] { result[key] = value }
        }
        var exact = input.filter { !["session_id", "__session_id", "details"].contains($0.key) }
        exact["agent"] = .string(agent)
        var detail = exact; detail["details"] = .bool(true)
        result["inspect_receipt"] = call("agent_read", detail)
        if raw["has_more"] == .bool(true), let offset = raw["next_offset"] {
            var next = exact; next["offset"] = offset
            result["read_more"] = call("agent_read", next)
        }
        if let cursor = text(raw, "nextCursor") {
            // The bot shelf owns its opaque cursor; do not invent offset paging.
            result["read_more"] = call("shelf_read", ["bot_id": .string(String(agent.dropFirst(4))), "cursor": .string(cursor)])
        }
        if rows.isEmpty { result["summary"] = .string("No reply is present in this returned page; this does not prove no work occurred.") }
        return .object(result)
    }

    private static func exchange(_ row: [String: JSONValue], agent: String, kind: String) -> JSONValue {
        let evidence = object(row["remote_evidence"]) ?? row
        let body: String?
        switch kind {
        case "coding": body = text(row, "agent_reply_text_head") ?? text(row, "completion_text_head")
        case "bot": body = text(row, "reply") ?? text(row, "findings")
        case "bot_preview": body = text(row, "headline")
        default: body = text(row, "reply") ?? text(evidence, "reply")
        }
        let conversation: String?
        if agent.hasPrefix("bot:") { conversation = agent }
        else {
            // Codex's builder owner accepts codex:<thread>, not the bare
            // executor thread ID. Other agents have different identity rules.
            let codex = agent == "codex" ? text(row, "thread_id").map { "codex:" + $0 } : nil
            conversation = text(row, "conversation_id") ?? codex
        }
        let message = text(row, "matched_message_id") ?? text(row, "message_id") ?? text(row, "id")
        let task = text(row, "task_id")
        let assessmentOnly = kind == "coding" && row["record_kind"] == .string("delivery_receipt") && text(row, "agent_reply_text_head") == nil
        var value: [String: JSONValue] = [
            "from": .string(assessmentOnly ? "Delivery record for " + agent : text(row, "agent_name") ?? agent), "request": .string("Not included in this source receipt."),
            "reply_state": .string(body == nil ? "no_reply_observed" : assessmentOnly ? "delivery_text_only" : kind == "bot_preview" ? "preview_only" : "reply_received"),
            "work_completion": .string("Not independently verified by this reader."),
            "execution_state": evidence["original_status"] ?? row["run_status"] ?? row["status"] ?? row["state"] ?? .string("unknown")
        ]
        if let body {
            value["text"] = .string(body)
            value["text_from"] = .string(assessmentOnly ? "Delivery record; the agent's original words are not retained separately." : agent)
            value["text_kind"] = .string(kind == "bot_preview" ? "headline" : kind == "coding" ? "retained_excerpt" : "reply")
        }
        for key in ["topic_slug", "created_at", "completed_at", "runAt", "delivery_outcome", "execution_error", "recovery_note", "needs_input", "needs_authentication", "artifacts"] {
            if let field = row[key] { value[key] = field }
        }
        for key in ["has_more", "next_offset", "coverage", "original_outcome", "evidence"] {
            if let field = evidence[key] { value[key] = field }
        }
        if kind == "coding", body != nil {
            value["text_coverage"] = .string("Only the retained excerpt is available here; it may omit later text. The receipt does not establish a full answer.")
        }
        if let message { value["message_id"] = .string(message) }
        if let conversation { value["conversation_id"] = .string(conversation) }
        if let task { value["task_id"] = .string(task) }
        if let locator = AgentConversationRouting.readLocator(agent: agent, message: message.map(JSONValue.string), conversation: conversation.map(JSONValue.string), task: task.map(JSONValue.string)) {
            value["read_with"] = locator
            if evidence["has_more"] == .bool(true), let offset = evidence["next_offset"],
               case .object(let action) = locator, case .object(var next)? = action["input"] {
                next["offset"] = offset
                value["read_more"] = call("agent_read", next)
            }
        }
        if let conversation {
            var target: [String: JSONValue] = ["agent": .string(agent), "conversation_id": .string(conversation)]
            // A2A 0.3 native ingress does not support task resumption. A new
            // message in the same context works for all supported adapters.
            target["text"] = .string("<your next message>")
            if row["needs_input"] == .bool(true), let task { target["task_id"] = .string(task) }
            value["reply_with"] = call("agent_message", target)
        } else {
            value["continuation"] = .string("The source did not retain a conversation handle. Do not silently start a new conversation.")
        }
        return .object(value)
    }
    private static func text(_ row: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let value)? = row[key], !value.isEmpty else { return nil }; return value
    }
    private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let value)? = value else { return nil }; return value
    }
    private static func call(_ tool: String, _ input: [String: JSONValue]) -> JSONValue {
        .object(["tool": .string(tool), "input": .object(input)])
    }
}
