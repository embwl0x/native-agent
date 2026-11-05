import Desk
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Transcripts
// Blueprint: | `HumanConversationIndex.swift` | bounded human index; unavailable source/revision never invents provenance |

package enum HumanConversationIndex {
    package static func rows(dataRoot: URL) throws -> [[String: JSONValue]] {
        try ChatSessionIndexFile.loadObjectRowsForMutation(at: dataRoot.appendingPathComponent("chat/sessions.json"))
            .filter { row in
                // A human conversation arrives through a door the person messages from; one set, so every door has its evidence here.
                guard let source = row["source"]?.stringValue else { return false }
                return MyQueue.Door.allCases.contains { ChatThreadKind.transcriptSource(surface: $0.rawValue) == source }
                    && row["archived"] != .bool(true)
                    && row["id"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }).flatMap(NativeAgentChatSessionID.normalizedPathComponent) != nil
            }
            .sorted { ($0["updatedAt"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }) ?? "") > ($1["updatedAt"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0
                }) ?? "") }
    }

    /// Bound conversation lists to 8 rows per page, at most 16; opening reads the selected canonical owner.
    package static func list(workspace: WorkspaceOperation, _ input: [String: JSONValue], dataRoot: URL) throws -> JSONValue {
        func number(_ key: String) -> Int? { if case .int(let value)? = input[key] { Int(value) } else { nil } }
        let limit = min(16, max(1, number("limit") ?? 8))
        let rows = try rows(dataRoot: dataRoot)
        let offset = min(rows.count, max(0, number("offset") ?? 0))
        let selected = rows.dropFirst(offset).prefix(limit)
        let conversations = selected.map { row -> JSONValue in
            .object(["conversation_session_id": row["id"] ?? .null, "title": row["title"] ?? .string("Conversation"),
                "surface": row["source"]?.stringValue.map { JSONValue.string(ChatThreadKind.surface(transcriptSource: $0)) } ?? .null,
                "updated_at": row["updatedAt"] ?? .null,
                "revision": ChatSessionIndexFile.transcriptGeneration(in: row).map { .string(String($0)) } ?? .null,
                "source_revision": ChatSessionIndexFile.transcriptGeneration(in: row).map { .string(String($0)) } ?? .null,
                "preview": .string(String((shownPreview(workspace: workspace, row) ?? "").prefix(400)))])
        }
        let next = offset + selected.count
        return .object(["status": .string("ok"), "conversations": .array(conversations),
            "offset": .int(Int64(offset)), "has_more": .bool(next < rows.count),
            "next_offset": next < rows.count ? .int(Int64(next)) : .null,
            "note": .string("Open a conversation to read its current messages and available reply action.")])
    }

    /// Keep the preview's source-row stamp; a preview without one is unverified.
    package static func previewStamp(_ row: [String: JSONValue]) -> TranscriptRowStamp? {
        TranscriptRowStamp(json: row[TranscriptRowStamp.previewKey])
    }

    /// A preview as it is shown now: read under its stored stamp through the one per-line path first; a preview with no stamp is not shown at all.
    package static func shownPreview(workspace: WorkspaceOperation, _ row: [String: JSONValue]) -> String? {
        guard let text = row["lastMessagePreview"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 }), let stamp = previewStamp(row) else { return nil }
        ContactThread.consume(.init(text: text, stamp: stamp), mark: { peer, _ in
            workspace.ports.tools.markConsumed(peer: peer)
        })
        return text
    }

}
