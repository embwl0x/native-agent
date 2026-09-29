import Foundation
import CryptoKit
import PersistenceCore

/// Small comparison receipts, never another content store or unread-message
/// owner. The caller records a stamp only after presenting a successful read.
enum AgentWorkspaceChanges {
    struct Stamp: Sendable, Equatable, Codable {
        let identity: String
        let fingerprint: String
        var replyFingerprint: String? = nil
        var ownerRevisionFingerprint: String? = nil

        var isValid: Bool {
            ([identity, fingerprint] + [replyFingerprint, ownerRevisionFingerprint].compactMap { $0 }).allSatisfy { value in
                value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }
        }
    }

    enum State: String, Sendable, Equatable {
        case firstSeen = "first_seen"
        case changed, unchanged, unavailable
    }

    struct Observation: Sendable, Equatable {
        let state: State
        /// Remains the earlier successful stamp when the owner read fails.
        let nextStamp: Stamp?
        let detail: String
        var kind: String? = nil

        var metadata: JSONValue {
            var value: [String: JSONValue] = [
                "state": .string(state.rawValue),
                "change": kind.map(JSONValue.string) ?? .null
            ]
            if !detail.isEmpty { value["detail"] = .string(detail) }
            return .object(value)
        }
    }

    /// Returns nil for navigation, effects and unsupported owners. An unreadable
    /// supported source is explicitly unavailable and never resets its baseline.
    static func evaluate(location: AgentWorkspaceLocation, result: JSONValue, previous: Stamp?) -> Observation? {
        guard let source = source(location) else { return nil }
        guard let identity = identity(location: location),
              let evidence = evidence(tool: source.tool, result: result),
              var digestInput = object(evidence),
              !digestInput.isEmpty else {
            return .init(state: .unavailable, nextStamp: previous,
                         detail: "A successful comparable read is unavailable; the previous successful view is retained.")
        }
        // A contact's latest conversation may change between reads. Keep that
        // owner-supplied identity distinct even when the open locator is broad.
        if source.tool == "agent_read", let row = object(result) {
            digestInput["source_conversation"] = row["conversation"] ?? row["conversation_id"]
        }
        guard let fingerprint = hash(.object(digestInput)) else {
            return .init(state: .unavailable, nextStamp: previous, detail: "Comparison evidence exceeded its bounds; the previous successful view is retained.")
        }
        let replyFingerprint: String?
        if source.tool == "agent_read" {
            if case .array(let exchanges)? = digestInput["exchanges"] {
                replyFingerprint = hash(.array(exchanges.map { selected(object($0) ?? [:], ["text", "message_id", "conversation_id", "task_id", "artifacts"]) }))
            } else {
                replyFingerprint = hash(selected(digestInput, ["reply", "parts", "artifacts"]))
            }
        } else if source.tool == "chat_conversations" {
            replyFingerprint = hash(digestInput["messages"] ?? .array([]))
        } else { replyFingerprint = nil }
        let revisionValue = source.tool == "chat_conversations" ? object(result)?["source_revision"] : nil
        let ownerRevision = revisionValue.flatMap(hash)
        let stamp = Stamp(identity: identity, fingerprint: fingerprint, replyFingerprint: replyFingerprint, ownerRevisionFingerprint: ownerRevision)
        guard let previous, previous.isValid, previous.identity == stamp.identity else {
            return .init(state: .firstSeen, nextStamp: stamp, detail: "First successful workspace view of this source; no earlier comparable view is recorded.")
        }
        let kind: String
        if let oldReply = previous.replyFingerprint, let newReply = stamp.replyFingerprint {
            kind = oldReply == newReply ? "state_changed" : "reply_changed"
        } else { kind = "source_changed" }
        return previous.fingerprint == stamp.fingerprint
            ? .init(state: .unchanged, nextStamp: stamp, detail: "Returned evidence matches the last successful workspace view.")
            // 2026-09-22: no fixed prose per read; state + change carry it.
            : .init(state: .changed, nextStamp: stamp, detail: "", kind: kind)
    }

    /// An index revision is enough to flag changed recorded activity, but not
    /// enough to claim a new message or mark the conversation read. Only an
    /// actual successful transcript view can update the comparison baseline.
    static func evaluateHumanListing(location: AgentWorkspaceLocation, row: [String: JSONValue], previous: Stamp?) -> Observation? {
        guard let source = source(location), source.tool == "chat_conversations", let identity = identity(location: location),
              row["conversation_session_id"] == source.input["conversation_session_id"] else { return nil }
        guard successful(row), let revision = row["source_revision"], revision != .string("legacy"),
              revision != .null, let current = hash(revision) else {
            return .init(state: .unavailable, nextStamp: previous, detail: "The conversation index has no comparable current revision; open it to read current messages.")
        }
        guard let previous, previous.isValid, previous.identity == identity, let old = previous.ownerRevisionFingerprint else {
            return .init(state: .firstSeen, nextStamp: previous, detail: "This conversation has not been successfully opened in this workspace yet.")
        }
        return .init(state: old == current ? .unchanged : .changed, nextStamp: previous,
            detail: old == current ? "The recorded conversation revision matches the last successful open; open it for current messages."
                : "Recorded conversation activity changed since the last successful open; this index alone does not establish a new reply.",
            kind: old == current ? nil : "source_changed")
    }

    /// Storage index only: raw paths, queries, identities and content stay out
    /// of the comparison receipt. Exact input pages remain separate baselines.
    static func identity(location: AgentWorkspaceLocation) -> String? {
        guard let source = source(location) else { return nil }
        var input = source.input.filter { !["__session_id", "details"].contains($0.key) }
        // Details and conversation views can expose different owner fields or
        // coverage for the same exchange. Compare each with its own prior view,
        // so switching presentation never manufactures a changed reply. Omitted
        // and false remain the same normal-view baseline; routing is unchanged.
        if source.tool == "agent_read", source.input["details"] == .bool(true) {
            input["details"] = .bool(true)
        }
        return hash(.object(["tool": .string(source.tool), "input": .object(input)]))
    }

    private static func source(_ location: AgentWorkspaceLocation) -> (tool: String, input: [String: JSONValue])? {
        switch location {
        case .work(let query): return ("work_context", ["query": .string(query)])
        case .page(let source, _): return self.source(source)
        case .record(let tool, let input, _):
            guard ["read_file", "read_page", "agent_read", "work_context", "desk_read", "read_chat_message", "shelf_read", "chat_conversations"].contains(tool) else { return nil }
            // Details is an owner-specific diagnostic receipt (for coding
            // agents, a jobs collection), not the comparable conversation
            // projection. Its availability is reported by that receipt itself.
            if tool == "agent_read", input["details"] == .bool(true) { return nil }
            return (tool, input)
        default: return nil
        }
    }

    private static func evidence(tool: String, result: JSONValue) -> JSONValue? {
        if case .string(let text) = result, tool == "read_file" {
            return .object(["content": .string(text)])
        }
        if tool == "shelf_read" {
            // A successful history page can contain failed/interrupted jobs
            // and shortened headlines. Those are recorded outcomes, not a
            // failure to read this page. Compare only its disclosed index.
            guard let row = object(result), row["status"] == .string("ok"),
                  row["ok"] != .bool(false), row["error"] == nil, row["error_code"] == nil,
                  case .array(let entries)? = row["entries"],
                  entries.allSatisfy({ value in
                      guard let entry = object(value), case .string? = entry["id"], case .string? = entry["bot"] else { return false }
                      return true
                  }) else { return nil }
            return .object(["entries": .array(entries.map {
                selected(object($0) ?? [:], ["id", "bot", "agent_name", "runAt", "headline", "status", "changedSinceLastGood"])
            }), "truncated": row["truncated"] ?? .bool(false), "order": row["order"] ?? .string("oldest_first")])
        }
        guard let row = object(result), successful(row) else { return nil }
        switch tool {
        case "read_file":
            guard case .string? = row["content"] else { return nil }
            return selected(row, ["content", "has_more"])
        case "read_page":
            guard row["content"] != nil || row["text"] != nil || row["markdown"] != nil else { return nil }
            return selected(row, ["url", "title", "content", "text", "markdown"])
        case "agent_read":
            if case .array(let exchanges)? = row["exchanges"] {
                // Lean excerpts (reply_truncated) and aborted earlier jobs are
                // recorded history, not a failed read; excerpts are stable, so
                // they compare cleanly (2026-09-22: every Codex window read
                // "comparison unavailable"). Same rule as shelf_read.
                guard exchanges.allSatisfy({ object($0) != nil }) else { return nil }
                return .object(["exchanges": .array(exchanges.map { exchange in
                    selected(object(exchange) ?? [:], ["from", "text", "message_id", "conversation_id", "task_id", "reply_state", "execution_state", "needs_input", "needs_authentication", "artifacts"])
                }), "state": row["state"] ?? row["status"] ?? .null])
            }
            guard row["reply"] != nil || row["state"] != nil else { return nil }
            return selected(row, ["agent", "conversation", "state", "status", "reply", "completed", "terminal", "needs_input", "needs_authentication", "artifacts", "parts"])
        case "chat_conversations":
            guard row["conversation_session_id"] != nil, case .array(let messages)? = row["messages"],
                  messages.allSatisfy({ object($0).map(successful) == true }),
                  row["coverage"] != .string("incomplete_transcript") else { return nil }
            return .object(["conversation_session_id": row["conversation_session_id"] ?? .null,
                "last_message_id": row["last_message_id"] ?? .null,
                "messages": .array(messages.map { selected(object($0) ?? [:], ["role", "text", "message_id"]) }),
                "reply_available": row["reply_available"] ?? .null])
        case "read_chat_message":
            guard row["content"] != nil || row["text"] != nil else { return nil }
            return selected(row, ["session_id", "message_id", "role", "content", "text", "has_more"])
        case "work_context":
            guard let current = object(row["current_work"]), successful(current),
                  let history = object(row["supporting_history"]), successful(history) else { return nil }
            return .object([
                "current_work": selected(current, ["items", "matched_count", "has_more"]),
                "supporting_history": selected(history, ["excerpts", "hit_count", "has_more"])
            ])
        case "desk_read":
            // Never derive semantic work state by parsing rendered board text.
            guard row["items"] != nil || row["item"] != nil || row["record"] != nil || row["matches"] != nil else { return nil }
            return selected(row, ["items", "item", "record", "matches"])
        default: return nil
        }
    }

    private static func successful(_ row: [String: JSONValue]) -> Bool {
        if row["ok"] == .bool(false) || row["success"] == .bool(false) { return false }
        if ["error", "error_code"].contains(where: { row[$0] != nil && row[$0] != .null }) { return false }
        if ["partial", "truncated", "reply_truncated"].contains(where: { row[$0] == .bool(true) }) { return false }
        if let coverage = object(row["coverage"]), coverage["complete"] == .bool(false) { return false }
        let failures: Set<String> = ["partial", "error", "failed", "unavailable", "blocked", "denied", "blocked_by_trust", "approval_required", "approval_filed", "needs_setup", "needs_topic", "no_outbound_route", "requires_interaction", "outcome_unknown", "not_found"]
        for key in ["status", "source_availability"] {
            if case .string(let state)? = row[key], failures.contains(state) { return false }
        }
        return true
    }

    private static func selected(_ row: [String: JSONValue], _ keys: Set<String>) -> JSONValue {
        // Recursively remove transport/read-time decoration only. Never modify
        // or interpret strings: quoted JSON and status words remain evidence.
        scrub(.object(row.filter { keys.contains($0.key) }))
    }

    private static func scrub(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let row):
            let transient: Set<String> = ["as_of", "generated_at", "generated_ts", "read_at", "fetched_at", "observed_at", "updated_at", "read_locator", "read_with", "read_more", "reply_with", "inspect_receipt", "actions", "organism_posture", "duration_ms", "elapsed_ms"]
            return .object(row.filter { !transient.contains($0.key) }.mapValues(scrub))
        case .array(let rows): return .array(rows.map(scrub))
        default: return value
        }
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        if case .object(let row)? = value { return row }; return nil
    }

    private static func hash(_ value: JSONValue) -> String? {
        guard let data = try? value.serializedData(pretty: false), data.count <= 512 * 1024 else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
