import Foundation
import MacIntegration
import PersistenceCore
import ChatSessionWork
// Blueprint: | `AgentWorkspaceMail.swift` | `AgentWorkspaceMail` enum; `project` |

extension AgentWorkspace {
    /// Bind observed workspace names once; caller-supplied locator fields may
    /// never override the selected message. Invalid names stay as refused items.
    public static func bindMail(_ input: [String: JSONValue], dataRoot: URL) -> [String: JSONValue] {
        let batch = input["items"] != nil
        let items: [JSONValue]
        if batch {
            guard case .array(let rows)? = input["items"], (1...10).contains(rows.count) else { return input }
            items = rows
        } else { items = [.object(input)] }
        var bound = input
        bound["items"] = .array(items.map { item in
            guard case .object(let row) = item, case .string(let name)? = row["name"] else { return item }
            let action: AgentWorkspaceAction?
            do { action = try HerScreen.namedAction(name, dataRoot: dataRoot) }
            catch {
                var refused = row
                refused["binding_error"] = .string(HerScreen.nameFailure(error))
                return .object(refused)
            }
            let parts = name.split(separator: ".")
            let edits: Set<String> = batch ? ["name", "body_offset", "mark_read", "flagged", "archive"]
                : ["name", "index", "filename", "destination"]
            guard Set(row.keys).isSubset(of: edits), parts.count == 2, parts[0] == "mail", let n = Int(parts[1]),
                  n > 0, case .open(let place)? = action,
                  case .record("mail_list_recent", let locator, _) = place else {
                var refused = row
                refused["binding_error"] = .string(Set(row.keys).isSubset(of: edits)
                    ? "name must be a currently observed mail.N workspace name; refresh page:mail to obtain one."
                    : "A workspace name cannot be combined with exact locator fields. Omit name to use message_id, expected_message_id and expected_account, or use only the observed mail.N name plus edits.")
                return .object(refused)
            }
            var selected = locator.filter { MailReadLocator.fields.contains($0.key) }
            selected["scope"] = locator["scope"] ?? locator["mailbox"] ?? .string("inbox")
            selected.merge(row) { _, new in new }
            return .object(selected)
        })
        if !batch, case .array(let rows)? = bound["items"], case .object(let row)? = rows.first { return row }
        return bound
    }
}

/// Reads use exact inbox identity, with the RFC identifier when available.
/// Replies require that identifier; display text never selects a recipient.
enum AgentWorkspaceMail {
    static func itemActions(input: [String: JSONValue], title: String) -> [String: AgentWorkspaceAction] {
        let bound = input.filter { MailReadLocator.fields.union(["mailbox"]).contains($0.key) }
        guard bound["message_id"] != nil, case .string(let id)? = bound["expected_message_id"], !id.isEmpty else { return [:] }
        var actions: [String: AgentWorkspaceAction] = ["delete": .perform(tool: "mail_delete", input: bound, title: "Delete " + title, textField: nil, isEffect: true)]
        if (bound["scope"] ?? bound["mailbox"] ?? .string("inbox")) == .string("inbox") {
            actions["draft"] = .perform(tool: "mail_draft", input: bound, title: "Draft: " + title, textField: "body", isEffect: true)
            actions["reply"] = .perform(tool: "mail_reply", input: bound, title: "Reply: " + title, textField: "body", isEffect: true)
            actions["reply-all"] = .perform(tool: "mail_reply", input: bound.merging(["reply_all": .bool(true)]) { _, new in new }, title: "Reply all: " + title, textField: "body", isEffect: true)
            actions["archive"] = .perform(tool: "mail_archive", input: bound, title: "Archive " + title, textField: nil, isEffect: true)
            actions["mark-read"] = .perform(tool: "mail_mark_read", input: bound, title: "Mark read: " + title, textField: nil, isEffect: true)
        }
        return actions
    }

    static func project(input: [String: JSONValue], result: JSONValue) -> WorkspacePage {
        let open = AgentWorkspaceButton(label: "Open Mail view", action: .perform(tool: "go", input: ["name": .string("Mail")], title: "Mail view", textField: nil, isEffect: true))
        var actions: [AgentWorkspaceButton] = [open,
            .init(label: "Find email", action: .configure(tool: "mail_search", input: [:], title: "Find email")),
            .init(label: "Compose email", action: .configure(tool: "mail_send", input: [:], title: "Compose email"))]
        guard case .object(var content) = result, case .array(let rows)? = content["messages"] else {
            return .init(title: "Mail", content: result, items: [], actions: actions)
        }
        if input["message_id"] == nil, content["status"] == .string("completed"),
           let offset = content["next_offset"] {
            var next = input
            next["offset"] = offset
            let tool = ["query", "from", "since", "category", "attachment"].contains(where: { input[$0] != nil }) ? "mail_search" : "mail_list_recent"
            actions.insert(.init(label: "More email", action: .open(.record(tool: tool, input: next, title: "Mail"))), at: 0)
        }
        // The list is Primary and Transactions; the rest is one step away.
        if input["message_id"] == nil, input["query"] == nil, content["scope"] == .string("inbox"), input["all_categories"] != .bool(true) {
            actions.append(.init(label: "All categories", action: .open(.record(tool: "mail_list_recent", input: ["all_categories": .bool(true)], title: "Mail"))))
        }
        content.removeValue(forKey: "messages")
        content["preview_note"] = .string("Open a message to read its body. A moved, changed, or ambiguous message is refused; refresh the same mailbox to locate it again. Replies require an inbox message.")
        return .init(title: "Mail", content: .object(content), items: rows.map { row in
            var title = "Email preview"
            if case .object(let object) = row, case .string(let subject)? = object["subject"], !subject.isEmpty { title = subject }
            var rowActions: [AgentWorkspaceButton] = []
            if case .object(let object) = row,
               let locator = MailReadLocator.parse(object, allowMissingMessageID: true),
               content["status"] == .string("completed") {
                var bound: [String: JSONValue] = ["message_id": .int(locator.id), "expected_message_id": .string(locator.messageID)]
                bound["scope"] = object["scope"] ?? content["scope"] ?? .string("inbox")
                // Its account too: the same email in another account's inbox is never the target.
                if let account = locator.account { bound["expected_account"] = .string(account) }
                if let accountID = locator.accountID { bound["expected_account_id"] = .string(accountID) }
                // Its place in that inbox: the fast way back to it (a hint; identity still decides).
                if let position = locator.position { bound["position"] = .int(Int64(position)) }
                if input["message_id"] == .int(locator.id), input["expected_message_id"] == .string(locator.messageID), content["detail"] == .bool(true) {
                    if object["truncated"] == .bool(true), case .int(let end)? = object["body_end"], end > 0, end <= 2_000_000 {
                        rowActions.append(.init(label: "Read next part", action: .open(.record(tool: "mail_list_recent", input: bound.merging(["body_offset": .int(end)]) { _, new in new }, title: title))))
                    }
                    let actions = itemActions(input: bound, title: title)
                    if let reply = actions["reply"], case .perform(let tool, let input, let title, _, _)? = actions["reply-all"] {
                        rowActions.append(.init(label: "Reply to sender", action: reply, needsText: true))
                        rowActions.append(.init(label: "Reply to all", action: .configure(tool: tool, input: input, title: title)))
                    }
                } else if input["message_id"] == nil {
                    rowActions.append(.init(label: "Read message", action: .open(.record(tool: "mail_list_recent", input: bound, title: title))))
                }
            }
            rowActions.append(open)
            return .init(title: title, content: row, actions: rowActions)
        }, actions: actions)
    }
}
