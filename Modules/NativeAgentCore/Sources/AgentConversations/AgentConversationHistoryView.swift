import AgentWorkspace
import Foundation
import PersistenceCore

/// On-demand scrollback over the conversation owner's bounded display cache.
/// It never replays messages or supplies context to a peer's model session.
enum AgentConversationHistoryView {
    static func adding(to presentation: JSONValue, row: AgentConversationRecord,
                       before: String? = nil, exchange: String? = nil, dataRoot: URL? = nil) -> JSONValue {
        guard case .object(var result) = presentation else { return presentation }
        if before != nil || exchange != nil {
            // Keep live readiness for Reply, but give the selected historical
            // moment the reading space. Recent messages restores the latest.
            for key in ["reply", "reply_state", "reply_truncated", "artifacts", "parts", "evidence", "untrusted_remote_data"] { result.removeValue(forKey: key) }
            result["viewing"] = .string("Retained session history. State and Reply controls describe the current conversation; the selected exchanges below retain their own dates and outcomes.")
        }
        let history = row.exchanges ?? []
        var metadata: [String: JSONValue] = [
            "coverage": .string("Retained exchanges since session scrollback was enabled, up to 32 exchanges / 64 KiB. Older or clipped text is not the complete peer transcript. The peer owns its continuing session."),
            "retained_exchanges": .int(Int64(history.count)), "order": .string("oldest_first"),
            "untrusted_remote_data": .bool(false)
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
        if row.agent.hasPrefix("peer:"), selected.contains(where: { !($0.reply ?? "").isEmpty }) {
            metadata["untrusted_remote_data"] = .bool(true)
        }
        // Only a problem reading history carries a status: "ok" beside a failed
        // send read as if the send were fine (walk 09-25).
        if history.isEmpty {
            metadata["status"] = .string("not_retained")
            metadata["detail"] = .string("Earlier messages were not retained by this version. The latest owner result remains above. New exchanges will appear here; no history was reconstructed.")
        }
        // An earlier send left at waiting when the next one went is settled by
        // now: answered if its answer came (here, or as a chat of its own), else no reply.
        var chats: [HerScreen.BridgeChat]?
        func answeredElsewhere(_ item: AgentConversationExchange) -> Bool {
            guard item.status == "delivered_live", let dataRoot else { return false }
            if chats == nil { chats = HerScreen.bridgeChats(dataRoot: dataRoot) }
            return chats!.contains { $0.who == row.agent && ($0.heard ?? .distantPast) > item.sentAt }
        }
        metadata["exchanges"] = .array(selected.map { item in
            let full = exchange != nil
            var state = item.phase
            var answerNote: String?
            if item.id != row.operationID, ["waiting", "sending"].contains(state) {
                if item.reply != nil { state = "answered" }
                else if answeredElsewhere(item) {
                    state = "answered"
                    answerNote = "\(row.name) answered in a chat of its own after this; that text is not kept here."
                } else { state = "no_reply" }
            }
            var value: [String: JSONValue] = [
                "exchange": .string(item.id), "state": .string(state), "outcome": .string(item.status)
            ]
            value.merge(item.timing) { current, _ in current }
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
            } else if let answerNote { value["reply_state"] = .string(answerNote)
            } else if state == "no_reply" { value["reply_state"] = .string("No reply came for this message.")
            } else { value["reply_state"] = .string("No reply retained for this exchange; status alone is not an answer.") }
            return .object(value)
        })
        result["session_history"] = .object(metadata)
        return .object(result)
    }
}
