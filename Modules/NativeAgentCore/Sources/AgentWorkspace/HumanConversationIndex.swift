import Foundation
import NativeAgentCore
import PersistenceCore
import Transcripts
// Blueprint: | `HumanConversationIndex.swift` | `HumanConversationIndex` enum; `rows`, `list` |

package enum HumanConversationIndex {
    package static func rows(dataRoot: URL) throws -> [[String: JSONValue]] {
        try ChatSessionIndexFile.loadObjectRowsForMutation(at: dataRoot.appendingPathComponent("chat/sessions.json"))
            .filter { row in
                let source = row["source"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "app"
                return ["app", "chat", "mac", "telegram", "slack", "ios", "iphone", "mobile", "icloud"].contains(source)
                    && row["archived"] != .bool(true)
                    && row["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }).flatMap(NativeAgentChatSessionID.normalizedPathComponent) != nil
            }
            .sorted { ($0["updatedAt"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "") > ($1["updatedAt"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "") }
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
                "preview": .string(String((shownPreview(row) ?? "").prefix(400)))])
        }
        let next = offset + selected.count
        return .object(["status": .string("ok"), "conversations": .array(conversations),
            "offset": .int(Int64(offset)), "has_more": .bool(next < rows.count),
            "next_offset": next < rows.count ? .int(Int64(next)) : .null,
            "note": .string("Open a conversation to read its current messages and available reply action.")])
    }

    /// The stamp the index keeps beside its preview, written from the same
    /// row the preview quotes. Nil: an older row whose preview has no stamp.
    package static func previewStamp(_ row: [String: JSONValue]) -> TranscriptRowStamp? {
        TranscriptRowStamp(json: row[TranscriptRowStamp.previewKey])
    }

    /// A preview as it is shown now: read under its stored stamp through the
    /// one per-line path first; a preview with no stamp is not shown at all.
    package static func shownPreview(_ row: [String: JSONValue]) -> String? {
        guard let text = row["lastMessagePreview"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }), let stamp = previewStamp(row) else { return nil }
        ContactThread.consume(.init(text: text, stamp: stamp), mark: { peer, _ in
            AgentWorkspacePorts.current.tools.markConsumed(peer: peer)
        })
        return text
    }

}
