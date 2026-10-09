import Foundation
import MacIntegration
import PersistenceCore
import ChatSessionWork

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
            let parts = name.split(separator: ".")
            let edits: Set<String> = batch ? ["name", "body_offset", "mark_read", "flagged", "archive"]
                : ["name", "index", "filename", "destination"]
            guard Set(row.keys).isSubset(of: edits), parts.count == 2, parts[0] == "mail", let n = Int(parts[1]),
                  n > 0, case .open(let place)? = HerScreen.namedAction(name, dataRoot: dataRoot),
                  case .record("mail_list_recent", let locator, _) = place else {
                var refused = row
                refused["binding_error"] = .string(Set(row.keys).isSubset(of: edits)
                    ? "name must be a currently observed mail.N workspace name; refresh page:mail to obtain one."
                    : "A workspace name cannot be combined with exact locator fields. Omit name to use message_id, expected_message_id and expected_account, or use only the observed mail.N name plus edits.")
                return .object(refused)
            }
            var selected = locator.filter { ["message_id", "expected_message_id", "expected_account", "position", "scope"].contains($0.key) }
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
    /// Home reads are frequent; the notable-mail search is slow on a big
    /// mailbox. One read per 10 minutes is fresh enough for a glance.
    private actor NotableCache {
        var value: (at: Date, text: String)?
        func fresh() -> String? { value.flatMap { Date().timeIntervalSince($0.at) < 600 ? $0.text : nil } }
        func store(_ text: String) { value = (Date(), text) }
        func clear() { value = nil }
    }
    private static let notableCache = NotableCache()

    static func notableToday(perform: AgentWorkspace.Perform) async -> String {
        guard AgentWorkspaceReadiness.allows(tool: "mail_search"), AgentWorkspaceReadiness.ready(tool: "mail_search") else {
            await notableCache.clear()
            return "unavailable — Mail Read is off or not ready"
        }
        if let cached = await notableCache.fresh() { return cached }
        let text = await readNotableToday(perform: perform)
        if !text.hasPrefix("unavailable") { await notableCache.store(text) }
        return text
    }

    private static func readNotableToday(perform: AgentWorkspace.Perform) async -> String {
        let since = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
        do {
            let result = try await perform("mail_search", ["since": .string(since), "unread": .bool(true),
                "category": .string("primary,transactions"), "limit": .int(4)])
            guard case .object(let content) = result, content["status"] == .string("completed"),
                  case .array(let rows)? = content["messages"] else {
                return "unavailable — " + (ChatToolOutcome.explanation(result) ?? "Mail did not return a completed read.")
            }
            let previews = rows.compactMap { row -> String? in
                guard case .object(let row) = row, case .string(let subject)? = row["subject"],
                      case .string(let sender)? = row["sender"] else { return nil }
                return HerScreen.clip(sender, 28) + " — " + HerScreen.clip(subject, 70)
            }
            let coverage = ChatToolOutcome.explanation(result).map { " · " + HerScreen.clip($0, 120) } ?? ""
            return (previews.isEmpty ? "no unread Mail in Primary/Transactions today"
                : previews.joined(separator: "; ") + " · open mail to read; up to 4 previews") + coverage
        } catch {
            return "unavailable — " + ChatToolOutcome.errorMessage(error)
        }
    }

    static func project(input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection {
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
                // Its place in that inbox: the fast way back to it (a hint; identity still decides).
                if let position = locator.position { bound["position"] = .int(Int64(position)) }
                if input["message_id"] == .int(locator.id), input["expected_message_id"] == .string(locator.messageID), content["detail"] == .bool(true) {
                    if object["truncated"] == .bool(true), case .int(let end)? = object["body_end"], end > 0, end <= 2_000_000 {
                        rowActions.append(.init(label: "Read next part", action: .open(.record(tool: "mail_list_recent", input: bound.merging(["body_offset": .int(end)]) { _, new in new }, title: title))))
                    }
                    if !locator.messageID.isEmpty, bound["scope"] == .string("inbox") {
                        rowActions.append(.init(label: "Reply to sender", action: .perform(tool: "mail_reply", input: bound, title: "Reply to \(title)", textField: "body", isEffect: true), needsText: true))
                        rowActions.append(.init(label: "Reply to all", action: .configure(tool: "mail_reply", input: bound.merging(["reply_all": .bool(true)]) { _, new in new }, title: "Reply to all: \(title)")))
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
