import Foundation
import PersistenceCore

/// Exact inbox identity is paired with the RFC message identifier and checked
/// by the owner on both read and reply; display text never selects a recipient.
enum AgentWorkspaceMail {
    static func project(input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection {
        let open = AgentWorkspaceButton(label: "Open Mail view", action: .perform(tool: "go", input: ["name": .string("Mail")], title: "Mail view", textField: nil, isEffect: true))
        var actions: [AgentWorkspaceButton] = [open,
            .init(label: "Find email", action: .configure(tool: "mail_search", input: [:], title: "Find email")),
            .init(label: "Compose email", action: .configure(tool: "mail_send", input: [:], title: "Compose email"))]
        guard case .object(var content) = result, case .array(var rows)? = content["messages"] else {
            return .init(title: "Mail", content: result, items: [], actions: actions)
        }
        if input["message_id"] == nil, content["status"] == .string("completed"),
           case .int(let offset)? = content["next_offset"], offset > 0, offset <= 10000 {
            var next = input
            next["offset"] = .int(offset)
            let tool = input["query"] == nil ? "mail_list_recent" : "mail_search"
            actions.insert(.init(label: "More email", action: .open(.record(tool: tool, input: next, title: "Mail"))), at: 0)
        }
        // Newest first, whatever order the inbox handed them over in.
        func received(_ row: JSONValue) -> Date {
            if case .object(let object) = row, case .string(let text)? = object["date"], let at = HerScreen.date(text) { return at }
            return .distantPast
        }
        rows = rows.enumerated().sorted { (received($0.element), -$0.offset) > (received($1.element), -$1.offset) }.map(\.element)
        content.removeValue(forKey: "messages")
        content["preview_note"] = .string("Open an inbox message to read its body and reply to that exact message. A moved, changed, or ambiguous message is refused; refresh the inbox to locate it again.")
        return .init(title: "Mail", content: .object(content), items: rows.map { row in
            var title = "Email preview"
            if case .object(let object) = row, case .string(let subject)? = object["subject"], !subject.isEmpty { title = subject }
            var rowActions: [AgentWorkspaceButton] = []
            if case .object(let object) = row, case .int(let id)? = object["message_id"], id > 0,
               case .string(let expected)? = object["expected_message_id"], !expected.isEmpty,
               content["status"] == .string("completed") {
                var bound: [String: JSONValue] = ["message_id": .int(id), "expected_message_id": .string(expected)]
                // Its account too: the same email in another account's inbox is never the target.
                if case .string(let account)? = object["expected_account"], !account.isEmpty { bound["expected_account"] = .string(account) }
                // Its place in that inbox: the fast way back to it (a hint; identity still decides).
                if case .int(let position)? = object["position"], position > 0 { bound["position"] = .int(position) }
                if input["message_id"] == .int(id), input["expected_message_id"] == .string(expected), content["detail"] == .bool(true) {
                    if object["truncated"] == .bool(true), case .int(let end)? = object["body_end"], end > 0, end <= 2_000_000 {
                        rowActions.append(.init(label: "Read next part", action: .open(.record(tool: "mail_list_recent", input: bound.merging(["body_offset": .int(end)]) { _, new in new }, title: title))))
                    }
                    rowActions.append(.init(label: "Reply to sender", action: .perform(tool: "mail_reply", input: bound, title: "Reply to \(title)", textField: "body", isEffect: true), needsText: true))
                    rowActions.append(.init(label: "Reply to all", action: .configure(tool: "mail_reply", input: bound.merging(["reply_all": .bool(true)]) { _, new in new }, title: "Reply to all: \(title)")))
                } else if input["message_id"] == nil {
                    rowActions.append(.init(label: "Read message", action: .open(.record(tool: "mail_list_recent", input: bound, title: title))))
                }
            }
            rowActions.append(open)
            return .init(title: title, content: row, actions: rowActions)
        }, actions: actions)
    }
}
