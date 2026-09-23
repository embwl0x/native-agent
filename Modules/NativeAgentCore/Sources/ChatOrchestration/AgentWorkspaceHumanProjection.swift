import Foundation
import PersistenceCore

enum AgentWorkspaceHumanProjection {
    static func project(input: [String: JSONValue], result: JSONValue,
                        observations: [AgentWorkspaceChanges.Stamp] = []) -> AgentWorkspaceProjection {
        guard case .object(let row) = result, row["status"] == .string("ok") else {
            return .init(title: "Conversations with you", content: result, items: [], actions: [])
        }
        if case .array(let conversations)? = row["conversations"] {
            let items = conversations.compactMap { value -> AgentWorkspaceItem? in
                guard case .object(let item) = value, case .string(let id)? = item["conversation_session_id"] else { return nil }
                let title = text(item["title"]) ?? "Conversation with you"
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
        return .init(title: text(row["title"]) ?? "Conversation with you", content: result, items: [], actions: actions)
    }

    private static func text(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value { return text }; return nil
    }
}
