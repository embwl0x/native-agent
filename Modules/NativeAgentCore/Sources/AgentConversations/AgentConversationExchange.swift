import AgentWorkspace
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentConversationExchange.swift` | `AgentConversationExchange`: `started`, `absorb`, `validate`; partial text is retained separately from a finished reply; each exchange retains its receipt's shelf result UUID across subsequent sends |

extension AgentConversationExchange {
    package static let textLimit = 8 * 1024
    static let byteLimit = 64 * 1024
    static let countLimit = 32

    static func started(operationID: String, at date: Date, message: String?, byPerson: Bool = false) -> Self {
        let text = message.map { clipped($0, limit: textLimit) }
        return .init(id: operationID, sentAt: date, prompt: text?.text, reply: nil,
                     promptTruncated: text?.truncated ?? false, replyTruncated: false,
                     phase: "sending", status: "outcome_unknown", byPerson: byPerson ? true : nil)
    }

    mutating func absorb(_ row: AgentConversationRecord) {
        guard row.phase != "sending", row.operationID == id else { return }
        let hadReply = reply != nil
        let observing = if case .object(let fields)? = row.receipt { fields["reply_observation"] == .string("running") } else { false }
        defer {
            // Stamped when it settles, and again if a reply lands after that.
            // A route that watched the answer finish says when (`replied_at`, the
            // last change it saw), not when it noticed it had stopped changing.
            if !observing, row.phase != "waiting", settledAt == nil || (!hadReply && reply != nil) {
                settledAt = Self.repliedAt(row.receipt, after: sentAt, key: reply == nil ? "ended_at" : "replied_at") ?? Date()
            }
        }
        phase = Self.state(row.phase)
        let root: [String: JSONValue]
        if case .object(let fields)? = row.receipt { root = fields } else { root = [:] }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        resultID = Self.string(value["entry_id"]).flatMap(UUID.init(uuidString:))
        status = Self.state(Self.string(value["run_status"]) ?? Self.string(value["status"])
            ?? Self.string(value["state"]) ?? "unknown")
        if let card = Self.string(root["approvalId"]) { approvalId = card }
        let answer: String?
        let ownerTruncated: Bool
        if root["jobs"] != nil {
            let original = AgentConversationView.codingReply(value)
            answer = original.text
            ownerTruncated = original.truncated
        } else {
            let original = AgentConversationView.codingReply(value)
            answer = Self.string(value["reply"]) ?? Self.string(value["answer"])
                ?? original.text ?? Self.string(value["findings"])
            ownerTruncated = value["reply_truncated"] == .bool(true)
                || (Self.string(value["reply"]) == nil && Self.string(value["answer"]) == nil
                    && original.text != nil && original.truncated)
        }
        // Replace, never carry an older answer through a failed/unknown read.
        let text = answer.map { Self.clipped($0, limit: Self.textLimit) }
        reply = text?.text
        partialReply = Self.string(value["partial_reply"]).map { Self.clipped($0, limit: Self.textLimit).text }
        replyTruncated = text.map { ownerTruncated || $0.truncated } ?? false
    }

    /// sent_at, first_activity_at, replied_at (or ended_at with no reply) and
    /// elapsed_ms between sending and that moment: measured, never inferred.
    var timing: [String: JSONValue] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var fields: [String: JSONValue] = ["sent_at": .string(iso.string(from: sentAt))]
        if let firstActivityAt { fields["first_activity_at"] = .string(iso.string(from: firstActivityAt)) }
        if let settledAt {
            fields[reply != nil ? "replied_at" : "ended_at"] = .string(iso.string(from: settledAt))
            fields["elapsed_ms"] = .int(Int64(max(0, settledAt.timeIntervalSince(sentAt)) * 1000))
        }
        return fields
    }

    static func validate(_ history: [Self]?, file: URL) throws {
        guard let history else { return }
        guard history.count <= countLimit, Set(history.map(\.id)).count == history.count,
              history.allSatisfy({ entry in
                  UUID(uuidString: entry.id) != nil && entry.sentAt.timeIntervalSince1970.isFinite
                    && [entry.phase, entry.status].allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }
                    && [entry.prompt, entry.reply, entry.partialReply].compactMap { $0 }.allSatisfy { $0.utf8.count <= textLimit }
                    && (entry.prompt != nil || !entry.promptTruncated)
                    && (entry.reply != nil || !entry.replyTruncated)
              }), try JSONEncoder().encode(history).count <= byteLimit else {
            throw historyFailure("Saved conversation history is invalid; existing records were preserved.", code: "agent_conversation_history_invalid", file: file)
        }
    }

    static func bounded(_ history: [Self], file: URL) throws -> [Self] {
        var result = history
        let encoder = JSONEncoder()
        var sizes = try result.map { try encoder.encode($0).count }
        var size = 2 + sizes.reduce(0, +) + max(0, sizes.count - 1)
        // Oldest first, never a held message (or one being handed over): it is
        // the only copy of what her contact has not yet taken (`takeHeld`).
        while result.count > 1, result.count > countLimit || size > byteLimit {
            guard let oldest = result.indices.dropLast().first(where: { !["held", "delivering"].contains(result[$0].status) }) else {
                throw ToolFailureError("Conversation capacity is held by queued messages awaiting the contact's check-in.", effects: .unknown,
                    nextCall: ToolFailureError.call("app", ["action": .string("agent.contacts")]),
                    code: "agent_conversation_capacity", instruction: "Wait for the contact's check-in; read contacts for delivery state. Preserve queued messages.", recovery: .inspect)
            }
            size -= sizes.remove(at: oldest) + 1
            result.remove(at: oldest)
        }
        // JSON escaping can exceed raw UTF-8 size. Preserve the newest exchange
        // with explicit clipping even for heavily escaped source text.
        while size > byteLimit, !result.isEmpty {
            let last = result.count - 1
            if let reply = result[last].reply, reply.utf8.count > 0 {
                result[last].reply = clipped(reply, limit: reply.utf8.count / 2).text
                result[last].replyTruncated = true
            } else if let prompt = result[last].prompt, prompt.utf8.count > 0 {
                result[last].prompt = clipped(prompt, limit: prompt.utf8.count / 2).text
                result[last].promptTruncated = true
            } else { throw historyFailure("Conversation history exceeds its 65536-byte storage limit.", code: "agent_conversation_history_limit", file: file) }
            size = try encoder.encode(result).count
        }
        try validate(result, file: file)
        return result
    }

    private static func historyFailure(_ message: String, code: String, file: URL) -> ToolFailureError {
        ToolFailureError(message, effects: .unknown, owner: file.path,
            code: code, instruction: ToolFailureError.fileRepairInstruction(file,
                shape: "Preserve conversation records and queued messages. Each exchange history has at most 32 unique UUID entries and 65536 encoded bytes; prompt, reply and partialReply are at most 8192 UTF-8 bytes each.") + " Repair the saved history from retained evidence without discarding queued messages.")
    }

    static func clipped(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var bytes = Data(text.utf8.prefix(limit))
        while !bytes.isEmpty {
            if let result = String(data: bytes, encoding: .utf8) { return (result, true) }
            bytes.removeLast()
        }
        return ("", true)
    }

    private static func repliedAt(_ receipt: JSONValue?, after sent: Date, key: String) -> Date? {
        guard case .object(let fields)? = receipt, let text = string(fields[key]) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = key == "ended_at" ? [.withInternetDateTime] : [.withInternetDateTime, .withFractionalSeconds]
        guard let at = iso.date(from: text), at >= sent, at <= Date() else { return nil }
        return at
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func state(_ text: String) -> String {
        let value = clipped(text.replacingOccurrences(of: "\0", with: ""), limit: 256).text
        return value.isEmpty ? "unknown" : value
    }
}
