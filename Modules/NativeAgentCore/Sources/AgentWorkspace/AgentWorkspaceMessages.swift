import Foundation
import PersistenceCore

/// Navigation over Messages-owned identities. Never derive recipients from a
/// display name, chat ID, preview text, or embedded action-looking content.
enum AgentWorkspaceMessages {
    static func project(input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection {
        let compose = AgentWorkspaceButton(label: "Compose message", action: .configure(tool: "messages_send", input: [:], title: "Compose message"))
        let openApp = AgentWorkspaceButton(label: "Open Messages view", action: .perform(tool: "go", input: ["name": .string("Messages")], title: "Messages view", textField: nil, isEffect: true))
        guard case .object(var content) = result, content["status"] == .string("completed"),
              case .array(let rows)? = content["threads"] else {
            var failure: [String: JSONValue]
            if case .object(let value) = result { failure = value } else { failure = ["result": result] }
            failure["history_note"] = .string("The conversation reader is unavailable. Open Messages view remains available; it does not itself select a particular thread.")
            return .init(title: "Messages", content: .object(failure), items: [], actions: [openApp, compose])
        }
        content.removeValue(forKey: "threads")
        let requested = text(input["thread_id"])
        var items = rows.map { value -> AgentWorkspaceItem in
            guard case .object(let row) = value else { return .init(title: "Conversation", content: value, actions: []) }
            let participants: [[String: JSONValue]]
            let completeParticipants: Bool
            if case .array(let values)? = row["participants"] {
                participants = values.compactMap { if case .object(let p) = $0 { return p }; return nil }
                completeParticipants = participants.count == values.count
            } else { participants = []; completeParticipants = false }
            let people = participants.compactMap { text($0["name"]) ?? text($0["handle"]) }
            let title = text(row["name"]) ?? (people.isEmpty ? "Conversation" : people.joined(separator: ", "))
            var actions: [AgentWorkspaceButton] = []
            if let id = text(row["thread_id"]), requested == nil || requested == id {
                let location = AgentWorkspaceLocation.record(tool: "messages_recent_threads", input: ["thread_id": .string(id)], title: title)
                if requested == nil {
                    actions.append(.init(label: "Open conversation", action: .open(location)))
                } else {
                    let handles = participants.compactMap { text($0["handle"]) }
                    if completeParticipants, !handles.isEmpty, handles.count == participants.count, Set(handles).count == handles.count {
                        actions.append(.init(label: "Reply to this conversation", action: .perform(tool: "messages_send", input: ["thread_id": .string(id), "expected_participants": .array(handles.map(JSONValue.string))], title: "Reply to \(title)", textField: "body", isEffect: true), needsText: true))
                    }
                }
            }
            actions.append(openApp)
            return .init(title: String(title.prefix(160)), content: value, actions: actions)
        }
        let conversationTitle = requested != nil && items.count == 1 ? items[0].title : "Messages"
        if requested != nil, case .array(let messages)? = content.removeValue(forKey: "messages") {
            for value in messages {
                guard case .object(var message) = value else { continue }
                let sender = message["from_me"] == .bool(true) ? "You" : (text(message["sender"]) ?? "Participant")
                let status = text(message["text_status"])
                if status == "archived_text_not_decoded" {
                    message["display_note"] = .string("Message text is stored in a format this reader cannot decode. Open Messages view to read it; this is not an empty message.")
                } else if status == "no_plain_text" {
                    message["display_note"] = .string(message["has_attachments"] == .bool(true) ? "Attachment content is available in Messages view." : "No plain text is available for this record; it may be a reaction or other special message.")
                }
                let title = text(message["date"]).map { "\(sender) · \($0)" } ?? sender
                items.append(.init(title: String(title.prefix(200)), content: .object(message), actions: []))
            }
        }
        content["conversation_note"] = .string(requested == nil
            ? "Open a conversation to read recent messages. Each conversation keeps its exact identity."
            : "This window keeps the exact conversation and its participants. Unavailable message formats are labeled explicitly. Replies recheck participants before sending.")
        var actions = [openApp, compose]
        if let requested {
            if case .int(let cursor)? = content.removeValue(forKey: "older_before_message_id"), cursor > 0 {
                actions.append(.init(label: "Older messages", action: .open(.record(tool: "messages_recent_threads", input: ["thread_id": .string(requested), "before_message_id": .int(cursor)], title: conversationTitle))))
            }
            if input["before_message_id"] != nil {
                actions.append(.init(label: "Recent messages", action: .open(.record(tool: "messages_recent_threads", input: ["thread_id": .string(requested)], title: conversationTitle))))
            }
            actions.append(.init(label: "All Messages conversations", action: .open(.record(tool: "messages_recent_threads", input: ["limit": .int(16)], title: "Messages"))))
        }
        return .init(title: conversationTitle, content: .object(content), items: items, actions: actions)
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != "missing value" else { return nil }
        return text
    }
}
