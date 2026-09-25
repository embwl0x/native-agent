import Foundation
import PersistenceCore

/// Bounded display history inside the routing bookmark. Never provider context,
/// replay input, settlement authority, or a replacement for the reply's owner.
public struct AgentConversationExchange: Codable, Sendable {
    public var id: String
    public var sentAt: Date
    public var prompt: String?
    public var reply: String?
    public var promptTruncated: Bool
    public var replyTruncated: Bool
    public var phase: String
    public var status: String
    /// Typed by the person in the contact's thread, not sent by the agent.
    public var byPerson: Bool?

    static let textLimit = 8 * 1024
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
        phase = Self.state(row.phase)
        let root: [String: JSONValue]
        if case .object(let fields)? = row.receipt { root = fields } else { root = [:] }
        var value = root
        if case .array(let jobs)? = root["jobs"], jobs.count == 1, case .object(let job) = jobs[0] { value = job }
        status = Self.state(Self.string(value["run_status"]) ?? Self.string(value["status"])
            ?? Self.string(value["state"]) ?? "unknown")
        let answer: String?
        let ownerTruncated: Bool
        if ["codex", "claude", "omp"].contains(row.agent), root["jobs"] != nil {
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
        replyTruncated = text.map { ownerTruncated || $0.truncated } ?? false
    }

    static func validate(_ history: [Self]?) throws {
        guard let history else { return }
        guard history.count <= countLimit, Set(history.map(\.id)).count == history.count,
              history.allSatisfy({ entry in
                  UUID(uuidString: entry.id) != nil && entry.sentAt.timeIntervalSince1970.isFinite
                    && [entry.phase, entry.status].allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }
                    && [entry.prompt, entry.reply].compactMap { $0 }.allSatisfy { $0.utf8.count <= textLimit }
                    && (entry.prompt != nil || !entry.promptTruncated)
                    && (entry.reply != nil || !entry.replyTruncated)
              }), try JSONEncoder().encode(history).count <= byteLimit else {
            throw AgentConversationStore.Failure(message: "Saved conversation history is unavailable; existing records were preserved.")
        }
    }

    static func bounded(_ history: [Self]) throws -> [Self] {
        var result = Array(history.suffix(countLimit))
        while try JSONEncoder().encode(result).count > byteLimit, result.count > 1 { result.removeFirst() }
        // JSON escaping can exceed raw UTF-8 size. Preserve the newest exchange
        // with explicit clipping even for heavily escaped source text.
        while try JSONEncoder().encode(result).count > byteLimit, !result.isEmpty {
            let last = result.count - 1
            if let reply = result[last].reply, reply.utf8.count > 0 {
                result[last].reply = clipped(reply, limit: reply.utf8.count / 2).text
                result[last].replyTruncated = true
            } else if let prompt = result[last].prompt, prompt.utf8.count > 0 {
                result[last].prompt = clipped(prompt, limit: prompt.utf8.count / 2).text
                result[last].promptTruncated = true
            } else { throw AgentConversationStore.Failure(message: "This conversation history exceeds its storage limit.") }
        }
        try validate(result)
        return result
    }

    private static func clipped(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var bytes = Data(text.utf8.prefix(limit))
        while !bytes.isEmpty {
            if let result = String(data: bytes, encoding: .utf8) { return (result, true) }
            bytes.removeLast()
        }
        return ("", true)
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
