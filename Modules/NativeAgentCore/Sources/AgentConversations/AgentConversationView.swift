import AgentWorkspace
import Foundation
import PersistenceCore

/// Agent evidence and presentation over an already-authorized read. No transcript, latest-
/// conversation lookup, semantic completion inference, or execution lives here.
public enum AgentConversationView {
    public static let claudeWorklogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/state/claude-worklog.jsonl")

    public static func claudeWorklogTail(_ url: URL) throws -> [[String: Any]] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > 65_536 ? size - 65_536 : 0
        try handle.seek(toOffset: start)
        let tail = String(decoding: try handle.read(upToCount: 65_536) ?? Data(), as: UTF8.self)
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        return (start > 0 ? lines.dropFirst() : lines[...]).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    public static func claudeWorklog(input: [String: JSONValue] = [:]) -> JSONValue {
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        func date(_ text: String) -> Date? { iso.date(from: text) ?? fractional.date(from: text) }
        var since: Date?
        if case .string(let text)? = input["since"], !text.isEmpty {
            since = text == "today" ? Calendar.current.startOfDay(for: Date()) : date(text)
            guard since != nil else {
                return .object(["status": .string("failed"), "detail": .string("since must be today or an ISO 8601 timestamp with timezone.")])
            }
        }
        var limit = 10
        if let value = input["limit"], value != .null {
            guard case .int(let count) = value, (1...50).contains(count) else {
                return .object(["status": .string("failed"), "detail": .string("limit must be an integer from 1 to 50.")])
            }
            limit = Int(count)
        }
        let rows: [[String: Any]]
        do { rows = try claudeWorklogTail(claudeWorklogURL) }
        catch CocoaError.fileReadNoSuchFile {
            return .object(["status": .string("absent"), "detail": .string("Claude has no worklog.")])
        } catch {
            return .object(["status": .string("unavailable"), "detail": .string("Claude's worklog could not be read. Check its file permissions.")])
        }
        let entries = rows.compactMap { row -> (Date, JSONValue)? in
            guard let ts = row["ts"] as? String, let at = date(ts),
                  since.map({ at >= $0 }) ?? true,
                  let summary = row["summary"] as? String, let kind = row["kind"] as? String else { return nil }
            return (at, .object([
                "time": .string(ts), "kind": .string(String(kind.prefix(80))),
                "summary": .string(String(summary.prefix(600))),
                "refs": .array((row["refs"] as? [String] ?? []).prefix(5).map { .string(String($0.prefix(200))) }),
            ]))
        }.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
        return .object(["status": .string("ok"), "agent": .string("claude"),
            "entries": .array(entries), "order": .string("newest_first"),
            "coverage": .string("Recent worklog tail (up to 64 KiB), not full history."),
            "untrusted_remote_data": .bool(true),
            "detail": .string(entries.isEmpty ? "No recent worklog entries match this read." : "Claude's recorded work; not independently verified.")])
    }

    public static func dotReply(_ receipt: JSONValue, sentAt: Date?) -> JSONValue {
        guard let sentAt, case .object(var fields) = receipt else { return receipt }
        fields["status"] = .string("waiting")
        fields["reply_deadline"] = .string(ISO8601DateFormatter().string(from: sentAt.addingTimeInterval(1800)))
        return expiringReply(.object(fields))
    }

    package static func expiringReply(_ receipt: JSONValue) -> JSONValue {
        guard case .object(var fields) = receipt, fields["reply"] == nil, fields["answer"] == nil,
              fields["terminal"] != .bool(true), fields["completed"] != .bool(true),
              case .string(let status)? = fields["status"],
              ["sending", "waiting", "enqueued", "queued", "running", "working", "submitted", "accepted", "delivering", "pending", "delivered_live", "delivery_unknown", "outcome_unknown", "no_reply"].contains(status),
              case .string(let stamp)? = fields["reply_deadline"],
              let deadline = ISO8601DateFormatter().date(from: stamp), deadline <= Date() else { return receipt }
        fields["status"] = .string("no_reply_expired")
        fields["reply_state"] = .string("no_reply_expired")
        fields["terminal"] = .bool(true)
        fields["automatic_resend"] = .bool(false)
        fields["ended_at"] = .string(stamp)
        fields["detail"] = .string("No reply arrived before the reply deadline. Sending again is your choice; any late answer still arrives.")
        return .object(fields)
    }

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
            "meaning": .string("Agent replies with recorded progress; their work is not independently verified."),
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
        case "coding": body = codingReply(row).text
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
        var value: [String: JSONValue] = [
            "from": .string(text(row, "agent_name") ?? agent),
            "reply_state": body == nil ? row["reply_state"] ?? .string("no_reply_observed") : .string(kind == "bot_preview" ? "preview_only" : "reply_received"),
            "execution_state": evidence["original_status"] ?? row["run_status"] ?? row["status"] ?? row["state"] ?? .string("unknown")
        ]
        // Her side of the exchange first, so a thread reads as ask and answer.
        if let ask = text(row, "request_text_head") { value["you_asked"] = .string(ask) }
        if let body {
            value["text"] = .string(body)
            value["text_kind"] = .string(kind == "bot_preview" ? "headline" : kind == "coding" && codingReply(row).truncated ? "retained_excerpt" : "reply")
        }
        for key in ["topic_slug", "created_at", "completed_at", "runAt", "delivery_outcome", "execution_error", "recovery_note", "needs_input", "needs_authentication", "artifacts"] {
            if let field = row[key] { value[key] = field }
        }
        for key in ["has_more", "next_offset", "coverage", "original_outcome", "evidence"] {
            if let field = evidence[key] { value[key] = field }
        }
        if kind == "coding", body != nil {
            value["reply_truncated"] = .bool(codingReply(row).truncated)
            if codingReply(row).truncated {
                value["text_coverage"] = .string("Retained excerpt; later answer text may be omitted.")
            }
        } else if kind == "coding" {
            if let note = text(row, "completion_text_head") { value["delivery_note"] = .string(note) }
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

    /// Only original executor fields may become an answer. A delivery summary
    /// or stderr remains diagnostic even when the transport says completed.
    static func codingReply(_ row: [String: JSONValue]) -> (text: String?, truncated: Bool) {
        if let value = text(row, "agent_reply_text") {
            return (value, row["agent_reply_truncated"] != .bool(false))
        }
        // 2026-09-22: a head under the cap is the whole reply; only
        // DelegationStatusProjector.head's cut ends in "…".
        if let value = text(row, "agent_reply_text_head") { return (value, value.hasSuffix("…")) }
        if ["reply_job", "retained_reply_job"].contains(text(row, "record_kind") ?? ""),
           let value = text(row, "completion_text_head") { return (value, value.hasSuffix("…")) }
        return (nil, false)
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
