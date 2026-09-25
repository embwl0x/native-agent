import Foundation
import PersistenceCore

/// On-demand scrollback over the conversation owner's bounded display cache.
/// It never replays messages or supplies context to a peer's model session.
enum AgentConversationHistoryView {
    static func adding(to presentation: JSONValue, row: AgentConversationRecord,
                       before: String? = nil, exchange: String? = nil) -> JSONValue {
        guard case .object(var result) = presentation else { return presentation }
        if before != nil || exchange != nil {
            // Keep live readiness for Reply, but give the selected historical
            // moment the reading space. Recent messages restores the latest.
            for key in ["reply", "reply_state", "reply_truncated", "artifacts", "parts", "evidence"] { result.removeValue(forKey: key) }
            result["viewing"] = .string("Retained session history. State and Reply controls describe the current conversation; the selected exchanges below retain their own dates and outcomes.")
        }
        let history = row.exchanges ?? []
        var metadata: [String: JSONValue] = [
            "coverage": .string("Retained exchanges since session scrollback was enabled, up to 32 exchanges / 64 KiB. Older or clipped text is not the complete peer transcript. The peer owns its continuing session."),
            "retained_exchanges": .int(Int64(history.count)), "order": .string("oldest_first"),
            "untrusted_remote_data": .bool(row.agent.hasPrefix("peer:"))
        ]
        let selected: ArraySlice<AgentConversationExchange>
        if let exchange {
            guard let index = history.firstIndex(where: { $0.id == exchange }) else {
                metadata["status"] = .string("unavailable")
                metadata["detail"] = .string("That exchange is no longer in retained scrollback. The conversation is preserved; no message was repeated.")
                result["session_history"] = .object(metadata); return .object(result)
            }
            selected = history[index...index]
            metadata["selected_exchange"] = .string(exchange)
            if index > 0 { metadata["earlier_before"] = .string(exchange) }
        } else {
            let end: Int
            if let before {
                guard let index = history.firstIndex(where: { $0.id == before }) else {
                    metadata["status"] = .string("unavailable")
                    metadata["detail"] = .string("This earlier-page boundary is no longer retained. Return to recent messages; no message was repeated.")
                    result["session_history"] = .object(metadata); return .object(result)
                }
                end = index
            } else { end = history.count }
            let start = max(0, end - 4)
            selected = history[start..<end]
            if start > 0 { metadata["earlier_before"] = .string(history[start].id) }
        }
        metadata["status"] = .string(history.isEmpty ? "not_retained" : "ok")
        if history.isEmpty {
            metadata["detail"] = .string("Earlier messages were not retained by this version. The latest owner result remains above. New exchanges will appear here; no history was reconstructed.")
        }
        metadata["exchanges"] = .array(selected.map { item in
            let full = exchange != nil
            var value: [String: JSONValue] = [
                "exchange": .string(item.id), "at": .string(ISO8601DateFormatter().string(from: item.sentAt)),
                "state": .string(item.phase), "outcome": .string(item.status)
            ]
            if let prompt = item.prompt {
                value["you"] = .string(full ? prompt : String(prompt.prefix(600)))
                value["your_message_truncated"] = .bool(item.promptTruncated || (!full && prompt.count > 600))
            }
            // The person wrote this one in the contact's thread; it isn't yours to answer.
            if item.byPerson == true { value["sent_by"] = .string("the person, from the contact's thread") }
            if let reply = item.reply {
                value["peer"] = .string(row.name)
                value["reply"] = .string(full ? reply : String(reply.prefix(800)))
                value["reply_truncated"] = .bool(item.replyTruncated || (!full && reply.count > 800))
            } else { value["reply_state"] = .string("No reply retained for this exchange; status alone is not an answer.") }
            return .object(value)
        })
        result["session_history"] = .object(metadata)
        return .object(result)
    }
}
