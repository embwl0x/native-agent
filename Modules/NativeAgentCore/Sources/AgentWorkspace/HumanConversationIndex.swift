import Foundation
import NativeAgentCore
import PersistenceCore
import Transcripts

package enum HumanConversationIndex {
    package static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value, !text.isEmpty { return text }; return nil
    }
    package static func object(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let row)? = value { return row }; return [:]
    }
    package static func rows(dataRoot: URL) throws -> [[String: JSONValue]] {
        try ChatSessionIndexFile.loadObjectRowsForMutation(at: dataRoot.appendingPathComponent("chat/sessions.json"))
            .filter { row in
                let source = string(row["source"]) ?? "app"
                return ["app", "chat", "mac", "telegram", "slack", "ios", "iphone", "mobile", "icloud"].contains(source)
                    && row["archived"] != .bool(true)
                    && string(row["id"]).flatMap(NativeAgentChatSessionID.normalizedPathComponent) != nil
            }
            .sorted { (string($0["updatedAt"]) ?? "") > (string($1["updatedAt"]) ?? "") }
    }

    /// The workspace's list of conversations with User, newest first, 8 a page
    /// (up to 16). Bounded index rows, as arrivals read them; opening one
    /// reads through the conversation owner.
    package static func list(_ input: [String: JSONValue], dataRoot: URL) throws -> JSONValue {
        func number(_ key: String) -> Int? { if case .int(let value)? = input[key] { Int(value) } else { nil } }
        let limit = min(16, max(1, number("limit") ?? 8))
        let rows = try rows(dataRoot: dataRoot)
        let offset = min(rows.count, max(0, number("offset") ?? 0))
        let selected = rows.dropFirst(offset).prefix(limit)
        let conversations = selected.map { row -> JSONValue in
            .object(["conversation_session_id": row["id"] ?? .null, "title": row["title"] ?? .string("Conversation"),
                "surface": row["source"] ?? .string("app"), "updated_at": row["updatedAt"] ?? .null,
                "revision": .string(ChatSessionIndexFile.transcriptGeneration(in: row).map(String.init) ?? "legacy"),
                "source_revision": .string(ChatSessionIndexFile.transcriptGeneration(in: row).map(String.init) ?? "legacy"),
                "preview": .string(String((string(row["lastMessagePreview"]) ?? "").prefix(400)))])
        }
        let next = offset + selected.count
        return .object(["status": .string("ok"), "conversations": .array(conversations),
            "offset": .int(Int64(offset)), "has_more": .bool(next < rows.count),
            "next_offset": next < rows.count ? .int(Int64(next)) : .null,
            "note": .string("Open a conversation to read its current messages and available reply action.")])
    }
}
