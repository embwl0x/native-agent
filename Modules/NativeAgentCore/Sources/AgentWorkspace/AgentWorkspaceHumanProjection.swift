import Foundation
import PersistenceCore

enum AgentWorkspaceHumanProjection {
    static func project(input: [String: JSONValue], result: JSONValue,
                        observations: [AgentWorkspaceChanges.Stamp] = []) -> AgentWorkspaceProjection {
        guard case .object(let row) = result, row["status"] == .string("ok") else {
            return .init(title: "Conversations with you", content: result, items: [], actions: [])
        }
        if case .array(let conversations)? = row["conversations"] {
            // 2026-09-23 (her screen): titles from content, not raw bridge
            // text; two that read the same get who and when.
            let rows = conversations.compactMap { value -> [String: JSONValue]? in
                guard case .object(let item) = value, item["conversation_session_id"] != nil else { return nil }
                return item
            }
            let named = rows.map { HerScreen.humanTitle(text($0["title"]) ?? "Conversation with you", agentName: nil) }
            let titles = HerScreen.disambiguate(named.map(\.title), who: named.map(\.who),
                at: rows.map { text($0["updated_at"]).flatMap(HerScreen.date) })
            let items = zip(rows, titles).compactMap { item, title -> AgentWorkspaceItem? in
                guard case .string(let id)? = item["conversation_session_id"] else { return nil }
                let location = AgentWorkspaceLocation.record(tool: "chat_conversations",
                    input: ["conversation_session_id": .string(id)], title: title)
                let previous = AgentWorkspaceChanges.identity(location: location).flatMap { key in observations.first { $0.identity == key } }
                let change = AgentWorkspaceChanges.evaluateHumanListing(location: location, row: item, previous: previous)
                var content = item
                content["change"] = change?.metadata
                return .init(title: title, content: .object(content), actions: [
                    .init(label: change?.state == .changed ? "Open updated conversation" : "Open conversation", action: .open(location))
                ])
            }
            var actions: [AgentWorkspaceButton] = []
            if row["has_more"] == .bool(true), let offset = row["next_offset"] {
                actions.append(.init(label: "More conversations", action: .open(.record(tool: "chat_conversations",
                    input: ["offset": offset], title: "Conversations with you"))))
            }
            return .init(title: "Conversations with you", content: .object(row.filter { $0.key != "conversations" }), items: items, actions: actions)
        }
        var actions: [AgentWorkspaceButton] = []
        if row["reply_available"] == .bool(true), let session = input["conversation_session_id"],
           row["conversation_session_id"] == session, case .string(let message)? = row["last_message_id"], !message.isEmpty {
            actions.append(.init(label: "Reply", action: .perform(tool: "chat_reply", input: [
                "conversation_session_id": session, "last_message_id": .string(message)
            ], title: "Reply to this conversation", textField: "text", isEffect: true), needsText: true))
        }
        actions.append(.init(label: "Read latest exchange", action: .open(.record(tool: "chat_conversations",
            input: input, title: text(row["title"]) ?? "Conversation with you"))))
        return .init(title: text(row["title"]).map { HerScreen.humanTitle($0, agentName: nil).title } ?? "Conversation with you",
                     content: result, items: [], actions: actions)
    }

    private static func text(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { return text }; return nil
    }
}
