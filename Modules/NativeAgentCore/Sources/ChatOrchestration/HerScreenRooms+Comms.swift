import Foundation
import PersistenceCore

/// Her comms on her screen (2026-09-24): Mail, Messages, Gmail, AgentMail,
/// Notes and Contacts are places, their items stable names (`mail.3`,
/// `gmail.2`, `notes.1`, `contacts.4`) that open as short text rooms, and
/// each item's verbs take its name (`mail.3.archive`, `notes.1.append`).
/// Lists are the owners' own reads laid out by `textRoom`; the rooms here are
/// one item each, from the read that opened it. Nothing is read on home.
extension HerScreen {
    // MARK: Places

    static let commsDestinations: [AgentWorkspaceDestination] = [
        .init(id: "gmail", title: "Gmail", summary: "The connected Gmail inbox: newest mail, search, read.",
              tool: "gmail_search", input: ["query": .string("in:inbox"), "limit": .int(12)]),
        .init(id: "agentmail", title: "AgentMail", summary: "My own AgentMail inbox: read and write.",
              tool: "agentmail_list", input: ["limit": .int(12)], tools: ["agentmail_send"]),
        .init(id: "notes", title: "Notes", summary: "Apple Notes: recent notes, find, read, add.",
              tool: "notes_search", input: ["limit": .int(12)], tools: ["notes_create"]),
        .init(id: "contacts", title: "Contacts", summary: "Mac Contacts: someone's number or email.",
              tool: "contacts_search", searchField: "query", tools: ["contacts_create_or_update"]),
    ]
    /// The room a comms read shows under.
    static let commsFamily: [String: String] = [
        "mail_list_recent": "mail", "mail_search": "mail", "messages_recent_threads": "messages",
        "gmail_search": "gmail", "gmail_read": "gmail", "gmail_status": "gmail", "agentmail_list": "agentmail", "agentmail_read": "agentmail",
        "notes_search": "notes", "contacts_search": "contacts",
    ]
    static let commsReadTools: Set<String> = ["gmail_search", "gmail_read", "gmail_status", "agentmail_list", "agentmail_read", "notes_search", "contacts_search"]

    /// Item verbs a list room names under its DO line.
    static let commsItemVerbs: [String: [(String, String)]] = [
        "mail": [("mail.N.reply", "reply (text)"), ("mail.N.archive", "archive it"), ("mail.N.mark-read", "mark it read")],
        "notes": [("notes.N.append", "add to it (text)")],
    ]
    static var commsRooms: Set<String> { Set(commsFamily.values) }
    /// Rooms whose numbers stay with each item (by its message or contact
    /// identity), never its row: a `mail.3.reply` kept from an older look
    /// still reaches the same email, not whatever is third now.
    static let numbersNote = "numbers stay with each item"

    /// A warning for each shown contact whose last send went wrong and
    /// nothing newer came from them since, by agent id (walk 4: omp's 403s
    /// showed nothing in connections). The people room's rule, worked out
    /// once per record state: the records by file stamp, each verdict by
    /// the record's id and time, the bridge chats only on a miss.
    static func sendTrouble(agents: [String], dataRoot: URL, now: Date) -> [String: String] {
        guard !agents.isEmpty else { return [:] }
        let root = dataRoot.standardizedFileURL.path + "\u{0}sendTrouble."
        let records: [AgentConversationRecord] = HerMemo.shared.cached(root + "records", stamp: [stamp(dataRoot.appendingPathComponent("agents/conversations.json"))]) {
            ((try? AgentConversationStore(dataRoot: dataRoot).records()) ?? []).filter { !$0.agent.hasPrefix("bot") }
        }
        var chats: [BridgeChat]?
        var out: [String: String] = [:]
        for agent in Set(agents.map { $0.lowercased() }) {
            guard let record = records.filter({ $0.agent.lowercased() == agent }).max(by: { $0.updatedAt < $1.updatedAt }),
                  record.phase == "attention" else { continue }
            let what: String? = HerMemo.shared.cached(root + record.id, stamp: [String(record.updatedAt.timeIntervalSince1970)]) {
                let receipt = unwrap(record.receipt)
                if receipt["needs_input"] == .bool(true) || receipt["needs_authentication"] == .bool(true) { return nil }
                if chats == nil { chats = bridgeChats(dataRoot: dataRoot) }
                let name = record.name.lowercased()
                if let heard = chats?.first(where: { $0.who == agent || $0.who == name })?.heard, heard > record.updatedAt { return nil }
                return receipt["status"] == .string("outcome_unknown") ? "unconfirmed" : "failed"
            }
            if let what { out[agent] = "⚠ last send \(what) \(age(now.timeIntervalSince(record.updatedAt)))" }
        }
        return out
    }

    // MARK: Counts and connections, for every text room

    /// A room's header counts: the owner's own totals when it gave them
    /// ("133,468 unread of 141,153", notes' "20"), else the rows it listed,
    /// and the rows on this page when that is not all of them.
    static func roomCounts(_ content: [String: JSONValue], fine: Bool, status: String, listed: Int, unreadRows: Int, page: Int) -> [String] {
        guard fine else { return [status] }
        func int(_ value: JSONValue?) -> Int? { if case .int(let n)? = value { Int(n) } else { nil } }
        let number = NumberFormatter()
        number.numberStyle = .decimal
        func grouped(_ n: Int) -> String { number.string(from: NSNumber(value: n)) ?? String(n) }
        let total = int(content["inbox_total"]) ?? int(content["total"]) ?? listed
        var parts: [String]
        if let unread = int(content["inbox_unread"]) { parts = ["\(grouped(unread)) unread of \(grouped(total))"] }
        else { parts = [total == 0 ? "ready" : grouped(total)] + (unreadRows > 0 ? ["\(unreadRows) unread"] : []) }
        if listed > 0, listed > 8 || total > listed { parts.append("\(page * 8 + 1)–\(min(listed, page * 8 + 8)) shown") }
        return parts
    }

    static let notConnectedLine = "Not connected — request_interaction (kind connector) puts the connect card in this chat; or he opens Settings (the gear, bottom-left), then Connectors."

    /// A service that is not connected reads the same everywhere, whatever
    /// its owner called it (a connect card, "failed", "not set up").
    static func notConnected(_ row: [String: JSONValue]) -> Bool {
        if row["connected"] == .bool(false) || row["kind"] == .string("connector") { return true }
        let words = ["detail", "error", "message", "reason"].compactMap { key -> String? in
            if case .string(let text)? = row[key] { text.lowercased() } else { nil }
        }.joined(separator: " ")
        return ["so i can read", "not connected", "needs connecting", "not set up yet", "not_connected", "not_configured"].contains { words.contains($0) }
    }

    // MARK: Lists

    /// Rows for the places above; each row opens its item by a stable read.
    static func commsProjection(tool: String, input: [String: JSONValue], result: JSONValue) -> AgentWorkspaceProjection? {
        func rows(_ key: String) -> [[String: JSONValue]] {
            guard case .object(let root) = result, case .array(let list)? = root[key] else { return [] }
            return list.compactMap { if case .object(let row) = $0 { row } else { nil } }
        }
        let content: JSONValue = if case .object(let root) = result {
            .object(root.filter { !["messages", "notes", "contacts"].contains($0.key) })
        } else { result }
        switch tool {
        case "gmail_search":
            return .init(title: "Gmail", content: content, items: rows("messages").compactMap { row in
                guard let id = text(row["id"]) else { return nil }
                let title = text(row["subject"]) ?? "(no subject)"
                return .init(title: title, content: .object(["sender": row["from"] ?? .null, "date": .string(rfc822(text(row["date"]))),
                        "snippet": row["snippet"] ?? .null, "unread": row["unread"] ?? .null]),
                    actions: [.init(label: "Read", action: .open(.record(tool: "gmail_read", input: ["id": .string(id)], title: title)))])
            }, actions: [
                .init(label: "Search Gmail", action: .perform(tool: "gmail_search", input: [:], title: "Gmail search", textField: "query", isEffect: false), needsText: true),
                .init(label: "Unread", action: .open(.record(tool: "gmail_search", input: ["query": .string("in:inbox is:unread"), "limit": .int(12)], title: "Gmail unread"))),
                // Beside home, not under whatever room was open before.
                .init(label: "Status", action: .window(.open(.record(tool: "gmail_status", input: [:], title: "Gmail status")))),
            ])
        case "agentmail_list":
            return .init(title: "AgentMail", content: content, items: rows("messages").compactMap { row in
                guard let id = text(row["message_id"]) else { return nil }
                let title = text(row["subject"]) ?? "(no subject)"
                return .init(title: title, content: .object(["sender": row["sender"] ?? .null, "date": row["date"] ?? .null,
                        "snippet": row["snippet"] ?? .null, "unread": row["unread"] ?? .null]),
                    actions: [.init(label: "Read", action: .open(.record(tool: "agentmail_read", input: ["message_id": .string(id)], title: title)))])
            }, actions: [.init(label: "Write email", action: .configure(tool: "agentmail_send", input: [:], title: "Write email"))])
        case "notes_search":
            // The header carries the counts; the tool's "Showing 12 of 20" would say it twice.
            let noteContent: JSONValue = if case .object(let root) = content { .object(root.filter { $0.key != "message" }) } else { content }
            return .init(title: "Notes", content: noteContent, items: rows("notes").compactMap { row in
                guard let name = text(row["name"]) else { return nil }
                // By the note's own id: two notes can share a title.
                let by: [String: JSONValue] = if let id = text(row["id"]) { ["id": .string(id)] } else { ["title": .string(name)] }
                let about: [String: JSONValue] = ["kind": row["folder"] ?? .null, "date": row["modified_at"] ?? .null,
                                                  "snippet": row["body_preview"] ?? row["body"] ?? .null]
                return .init(title: name, content: .object(about),
                    actions: [.init(label: "Read", action: .open(.record(tool: "notes_search", input: by, title: name)))])
            }, actions: [
                .init(label: "Find a note", action: .perform(tool: "notes_search", input: [:], title: "Find a note", textField: "query", isEffect: false), needsText: true),
                .init(label: "New note", action: .configure(tool: "notes_create", input: [:], title: "New note")),
            ])
        case "contacts_search":
            return .init(title: "Contacts", content: content, items: rows("contacts").compactMap { row in
                guard let id = text(row["identifier"]), let name = text(row["name"]) ?? text(row["organizationName"]) else { return nil }
                // What the card holds, not the numbers themselves: open it for those.
                let phones = values(row["phones"]).count, emails = values(row["emails"]).count
                let holds = phones + emails == 0 ? "no phone or email"
                    : [phones > 0 ? "\(phones) phone\(phones == 1 ? "" : "s")" : nil, emails > 0 ? "\(emails) email\(emails == 1 ? "" : "s")" : nil]
                        .compactMap { $0 }.joined(separator: ", ")
                return .init(title: name, content: .object(["kind": row["organizationName"] ?? .null, "summary": .string(holds)]),
                    actions: [.init(label: "Open", action: .open(.record(tool: "contacts_search",
                        input: ["identifier": .string(id), "query": .string(name)], title: name)))])
            }, actions: [.init(label: "Search contacts", action: .perform(tool: "contacts_search", input: [:], title: "Contacts search", textField: "query", isEffect: false), needsText: true)])
        case "gmail_read", "agentmail_read":
            return .init(title: text(input["title"]) ?? "Message", content: content, items: [], actions: [])
        default: return nil
        }
    }

    // MARK: Rooms

    /// A comms record as text: one item's room, or a list read (a search, a
    /// next page) laid out like its place. Nil leaves the old view.
    static func commsRoom(_ location: AgentWorkspaceLocation, value: JSONValue?, dataRoot: URL, issue: String?) -> String? {
        guard case .record(let tool, let input, let title) = location, let value else { return nil }
        let now = Date()
        guard let family = commsFamily[tool] else { return nil }
        let object: [String: JSONValue] = if case .object(let row) = value { row } else { [:] }
        let single: Bool = switch tool {
        case "mail_list_recent": input["message_id"] != nil
        case "messages_recent_threads": input["thread_id"] != nil
        case "gmail_read", "agentmail_read", "gmail_status": true
        case "notes_search": input["title"] != nil || input["id"] != nil
        case "contacts_search": input["identifier"] != nil
        default: false
        }
        // Not connected: one line, the same for every service.
        if notConnected(object) {
            return commsScreen([family.uppercased(), "not connected"], [[notConnectedLine]], verbs: [], back: "Back: home.")
        }
        if tool == "gmail_status", issue == nil {
            func int(_ value: JSONValue?) -> Int? { if case .int(let n)? = value { Int(n) } else { nil } }
            let counts = int(object["inbox_unread"]).map { "\($0) unread of \(int(object["inbox_total"]) ?? 0) in the inbox" }
            return commsScreen(["GMAIL", "connected", text(object["email"]) ?? ""] + (counts.map { [$0] } ?? []), [], verbs: [], back: "Back: home · gmail.")
        }
        guard single, issue == nil else {
            let status = issue == nil ? (text(object["status"]) ?? "ok") : "failed"
            return textRoom(family, place: location, projection: .project(location: location, result: value),
                            frame: .object(["status": .string(status)]), dataRoot: dataRoot, now: now)
        }
        // The item's name is the one its list row minted: a next page of the
        // same message or thread keeps it.
        let identity = input.filter { !["body_offset", "before_message_id", "limit", "position"].contains($0.key) }
        let itemKey = key(.record(tool: tool, input: identity, title: title)) ?? title
        let name = family + ".\(withNames(dataRoot) { book in book.number("item." + family, id: itemKey) { [itemKey] } })"
        func rowsOf(_ key: String) -> [[String: JSONValue]] {
            guard case .array(let list)? = object[key] else { return [] }
            return list.compactMap { if case .object(let row) = $0 { row } else { nil } }
        }
        var verbs: [(String, String)] = [], keep: [String: AgentWorkspaceAction] = [:]
        func verb(_ word: String, _ about: String, _ action: AgentWorkspaceAction) {
            verbs.append((name + "." + word, about)); keep[name + "." + word] = action
        }
        var header: [String] = [name], sections: [[String]] = []
        switch tool {
        case "mail_list_recent":
            guard let row = rowsOf("messages").first else { return nil }
            let bound = input.filter { ["message_id", "expected_message_id", "expected_account", "position"].contains($0.key) }
            header += [who(text(row["sender"])), when(text(row["date"]), now: now)] + (row["unread"] == .bool(true) ? ["unread"] : [])
            let (lines, used) = bodyLines(text(row["body"]) ?? "")
            let start = int(row["body_offset"]) ?? 0, total = int(row["body_total"]) ?? 0
            let body = tabled(lines, row["body_tables"])
            sections = [section("SUBJECT", [clip(text(row["subject"]) ?? "(no subject)", 100)]), section("BODY", body.isEmpty ? ["(empty)"] : body)]
            if start + used < total {
                sections.append(["+\(total - start - used) more characters · \(name).more"])
                keep[name + ".more"] = .open(.record(tool: "mail_list_recent", input: bound.merging(["body_offset": .int(Int64(start + used))]) { _, new in new }, title: title))
            }
            verb("reply", "reply to the sender (text)", .perform(tool: "mail_reply", input: bound, title: "Reply: " + title, textField: "body", isEffect: true))
            verb("reply-all", "reply to everyone (text)", .perform(tool: "mail_reply", input: bound.merging(["reply_all": .bool(true)]) { _, new in new },
                                                                  title: "Reply all: " + title, textField: "body", isEffect: true))
            verb("archive", "archive it", .perform(tool: "mail_archive", input: bound, title: "Archive " + title, textField: nil, isEffect: true))
            verb("mark-read", "mark it read", .perform(tool: "mail_mark_read", input: bound, title: "Mark read: " + title, textField: nil, isEffect: true))
            verb("delete", "move it to Trash", .perform(tool: "mail_delete", input: bound, title: "Delete " + title, textField: nil, isEffect: true))
        case "messages_recent_threads":
            guard let thread = rowsOf("threads").first else { return nil }
            let people: [[String: JSONValue]] = if case .array(let list)? = thread["participants"] {
                list.compactMap { if case .object(let row) = $0 { row } else { nil } }
            } else { [] }
            header += [clip(text(thread["name"]) ?? people.compactMap { text($0["name"]) ?? text($0["handle"]) }.joined(separator: ", "), 50)]
            let talk = rowsOf("messages").suffix(10).map { row -> String in
                let said = text(row["text"]) ?? (row["text_status"] == .string("archived_text_not_decoded") ? "(a format I can't read here; it's in Messages)"
                    : row["has_attachments"] == .bool(true) ? "(attachment)" : "(no text: a reaction or special message)")
                return pad(when(text(row["date"]), now: now, short: true), 7) + pad(row["from_me"] == .bool(true) ? "me" : clip(text(row["sender_name"]) ?? who(text(row["sender"])), 16), 12) + clip(said, 90)
            }
            sections = [section("TALK", talk.isEmpty ? [clip(text(object["history_note"]) ?? "no messages to show", 110)] : talk)]
            if let older = object["older_before_message_id"], let id = text(thread["thread_id"]) {
                keep[name + ".older"] = .open(.record(tool: "messages_recent_threads", input: ["thread_id": .string(id), "before_message_id": older], title: title))
                sections.append(["earlier messages · \(name).older"])
            }
            let handles = people.compactMap { text($0["handle"]) }
            if let id = text(thread["thread_id"]), !handles.isEmpty, handles.count == people.count {
                verb("reply", "send in this thread (text)", .perform(tool: "messages_send", input: ["thread_id": .string(id),
                    "expected_participants": .array(handles.map(JSONValue.string))], title: "Reply: " + title, textField: "body", isEffect: true))
            }
        case "gmail_read", "agentmail_read":
            let sender = text(object["from"]) ?? text(object["sender"])
            header += [who(sender), tool == "gmail_read" ? when(rfc822(text(object["date"])), now: now) : when(text(object["date"]), now: now)]
            sections = [section("SUBJECT", [clip(text(object["subject"]) ?? "(no subject)", 100)]),
                        section("BODY", bodyLines(text(object["body"]) ?? text(object["snippet"]) ?? "").lines)]
            if tool == "agentmail_read", let sender, let address = sender.split(whereSeparator: { "<> ".contains($0) }).first(where: { $0.contains("@") }) {
                let subject = text(object["subject"]) ?? ""
                verb("reply", "reply from my inbox (text; the person approves the send)", .perform(tool: "agentmail_send",
                    input: ["to": .string(String(address)), "subject": .string(subject.lowercased().hasPrefix("re:") ? subject : "Re: " + subject)],
                    title: "Reply: " + title, textField: "body", isEffect: true))
            }
        case "notes_search":
            guard let note = rowsOf("notes").first else { return nil }
            header += [text(note["folder"]), when(text(note["modified_at"]), now: now)].compactMap { $0 }.filter { !$0.isEmpty }
            // A note's text starts with its title; the room shows what comes after it.
            var (lines, _) = bodyLines(text(note["body"]) ?? text(note["body_preview"]) ?? "")
            if let first = lines.first, first == clip(text(note["name"]) ?? "", 110) { lines.removeFirst() }
            sections = [section("TITLE", [clip(text(note["name"]) ?? title, 100)]), section("TEXT", lines.isEmpty ? ["(empty: the note has only its title)"] : lines)]
            if let total = int(object["total"]), total > 1 {
                sections.append(["\(total) notes have this title; this is one · notes.find (text) to pick another"])
            }
            // Only by the note's id: a title can belong to two notes.
            if let id = text(note["id"]) {
                verb("append", "add a line to it (text)", .perform(tool: "notes_update", input: ["id": .string(id)], title: "Add to " + title, textField: "append", isEffect: true))
            }
        case "contacts_search":
            guard let card = rowsOf("contacts").first else { return nil }
            let phones = values(card["phones"]), emails = values(card["emails"])
            header += [clip(text(card["name"]) ?? title, 40)] + (text(card["organizationName"]).map { [$0] } ?? [])
            sections = [section("PHONES", phones.isEmpty ? ["none"] : phones.prefix(4).map { clip($0, 40) }),
                        section("EMAILS", emails.isEmpty ? ["none"] : emails.prefix(4).map { clip($0, 60) })]
            if let phone = phones.first {
                verb("text", "text \(phones.count > 1 ? "the first number" : "them") (text)", .perform(tool: "messages_send", input: ["to": .string(phone)],
                    title: "Text " + title, textField: "body", isEffect: true))
            }
            if let email = emails.first {
                verb("email", "write them an email (form)", .configure(tool: "mail_send", input: ["to": .string(email)], title: "Email " + title))
            }
            if let id = text(card["identifier"]) {
                verb("edit", "add a number or email (form)", .configure(tool: "contacts_create_or_update", input: ["identifier": .string(id)], title: "Edit " + title))
            }
        default: return nil
        }
        HerNamed.shared.keep(dataRoot, keep)
        return commsScreen(header, sections, verbs: verbs, back: "Back: home · \(family).")
    }

    /// `mail.3.archive` from names.json when the room that named it was shown
    /// before a restart: mail verbs rebuild from the item's own read; the
    /// others reopen the item, which names its verbs again.
    static func commsTarget(_ raw: String, dataRoot: URL) -> Target? {
        let parts = raw.split(separator: ".").map(String.init)
        guard parts.count == 3, let n = Int(parts[1]), commsItemVerbs.keys.contains(parts[0]) || ["messages", "gmail", "agentmail"].contains(parts[0]),
              let place = itemPlace(parts[0], n, dataRoot: dataRoot), case .record(let tool, let input, let title) = place else { return nil }
        let bound = input.filter { ["message_id", "expected_message_id", "expected_account", "position"].contains($0.key) }
        if tool == "mail_list_recent", bound["message_id"] != nil, bound["expected_message_id"] != nil {
            switch parts[2] {
            case "reply": return .action(.perform(tool: "mail_reply", input: bound, title: "Reply: " + title, textField: "body", isEffect: true))
            case "archive": return .action(.perform(tool: "mail_archive", input: bound, title: "Archive " + title, textField: nil, isEffect: true))
            case "mark-read": return .action(.perform(tool: "mail_mark_read", input: bound, title: "Mark read: " + title, textField: nil, isEffect: true))
            case "delete": return .action(.perform(tool: "mail_delete", input: bound, title: "Delete " + title, textField: nil, isEffect: true))
            default: break
            }
        }
        if tool == "notes_search", parts[2] == "append", case .string(let id)? = input["id"] {
            return .action(.perform(tool: "notes_update", input: ["id": .string(id)], title: "Add to " + title, textField: "append", isEffect: true))
        }
        return .action(.window(AgentWorkspaceNavigation.windowAction(place)))
    }

    // MARK: Home's mail line

    /// "mail 3 unread of 12 (4m ago)" from the last inbox read anyone made; bare "mail" before one.
    static func mailPulse(now: Date) -> String { HerMailStatus.shared.pulse(now: now) }

    // MARK: Pieces

    private static func commsScreen(_ header: [String], _ sections: [[String]], verbs: [(String, String)], back: String) -> String {
        let rule = String(repeating: "─", count: 61)
        var lines = [header.map { clip($0, 60) }.filter { !$0.isEmpty }.joined(separator: " · ")]
        for part in sections where !part.isEmpty { lines.append(rule); lines += part }
        lines.append(rule)
        let width = min(24, (verbs.map(\.0.count).max() ?? 0) + 2)
        lines += section("DO", verbs.map { pad(clip($0.0, 40), width) + clip($0.1, 60) })
        lines.append(back)
        return lines.joined(separator: "\n")
    }

    /// Up to 30 lines / 2400 characters of a message, each defused; and how
    /// many characters of the source those lines cover.
    /// Whole paragraphs, never cut mid-line, until 2400 characters; the
    /// paragraph that would pass the cap starts the `.more` page instead. Only
    /// a single paragraph longer than the cap is cut. Each line is defused.
    private static func bodyLines(_ body: String) -> (lines: [String], used: Int) {
        let cap = 2400
        var lines: [String] = [], used = 0, shown = 0
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if lines.count >= 40 { break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || (line.hasPrefix(">") && lines.last?.hasPrefix(">") == true) { used += raw.count + 1; continue }
            if shown + line.count > cap {
                if lines.isEmpty { lines.append(clip(String(line.prefix(cap)), cap + 1)); used += min(raw.count, cap) }
                break
            }
            lines.append(clip(line, cap + 1)); shown += line.count; used += raw.count + 1
        }
        return (lines, min(used, body.count))
    }

    /// A mail body's simple HTML tables (the owner's `body_tables`) row by
    /// row. Mail's plain text puts every cell on its own line, so labels over
    /// values read as all the labels, then all the values (desk walk 4). Only
    /// a run of lines that is exactly a table's cells, in order, is replaced;
    /// anything else stays as the body said it.
    static func tabled(_ lines: [String], _ tables: JSONValue?) -> [String] {
        guard case .array(let list)? = tables else { return lines }
        func norm(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        func pair(_ label: String, _ value: String) -> String? { value.isEmpty ? nil : label.isEmpty ? value : label + ": " + value }
        var out = lines
        for case .object(let table) in list {
            guard case .array(let raw)? = table["rows"] else { continue }
            let rows: [[String]] = raw.compactMap { row in
                guard case .array(let cells) = row else { return nil }
                return cells.map { if case .string(let cell) = $0 { norm(cell) } else { "" } }
            }
            guard rows.count >= 2, let width = rows.first?.count, width >= 2, rows.allSatisfy({ $0.count == width }) else { continue }
            let cells = rows.flatMap { $0.filter { !$0.isEmpty } }
            let shown = out.map(norm)
            guard cells.count >= 4, cells.count <= shown.count,
                  let at = (0...(shown.count - cells.count)).first(where: { Array(shown[$0..<($0 + cells.count)]) == cells }) else { continue }
            let head = rows[0], data = rows.dropFirst()
            let laid: [String]
            if table["header"] == .bool(true) || (width > 2 && rows.count == 2) {
                // A header row: one line per column when it heads one row, else "label: value · …" per row.
                laid = rows.count == 2 ? zip(head, rows[1]).compactMap(pair)
                    : data.map { zip(head, $0).compactMap(pair).joined(separator: " · ") }.filter { !$0.isEmpty }
            } else if width == 2 {
                laid = rows.map { $0[1].isEmpty ? $0[0] : $0[0].isEmpty ? $0[1] : $0[0] + ": " + $0[1] }.filter { !$0.isEmpty }
            } else {
                laid = rows.map { $0.filter { !$0.isEmpty }.joined(separator: " · ") }.filter { !$0.isEmpty }
            }
            out.replaceSubrange(at..<(at + cells.count), with: laid.map { clip($0, 240) })
        }
        return out
    }

    private static func who(_ sender: String?) -> String {
        guard var name = nonEmpty(sender) else { return "unknown" }
        if let angle = name.firstIndex(of: "<"), angle > name.startIndex {
            name = name[..<angle].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        return clip(name, 30)
    }

    private static func when(_ raw: String?, now: Date, short: Bool = false) -> String {
        guard let raw = nonEmpty(raw) else { return "" }
        guard let at = date(raw) else { return clip(raw, 24) }
        return short ? age(now.timeIntervalSince(at)) : friendly(at, now: now)
    }

    /// Gmail's RFC 822 Date header as ISO, so rows read like the others.
    private static func rfc822(_ raw: String?) -> String {
        guard let raw = nonEmpty(raw) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz"] {
            formatter.dateFormat = format
            if let at = formatter.date(from: raw.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)) {
                return ISO8601DateFormatter().string(from: at)
            }
        }
        return raw
    }

    private static func text(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let text)?: return nonEmpty(text) == nil || text == "missing value" ? nil : text
        case .int(let n)?: return String(n)
        default: return nil
        }
    }

    private static func int(_ value: JSONValue?) -> Int? { if case .int(let n)? = value { Int(n) } else { nil } }

    /// Contact phones/emails: `[{label, value}]` as "value (label)".
    private static func values(_ value: JSONValue?) -> [String] {
        guard case .array(let list)? = value else { return [] }
        return list.compactMap { entry in
            guard case .object(let row) = entry, let value = text(row["value"]) else { return nil }
            return text(row["label"]).map { $0 == "other" ? value : value + " (" + $0 + ")" } ?? value
        }
    }
}

/// The last inbox count any Mail read returned (a tool call or her mail
/// room), in memory only: home shows it with its age and never reads Mail.
final class HerMailStatus: @unchecked Sendable {
    static let shared = HerMailStatus()
    private let lock = NSLock()
    private var last: (at: Date, total: Int64, unread: Int64?)?

    func note(_ result: JSONValue) {
        guard case .object(let row) = result, row["status"] == .string("completed"), case .int(let total)? = row["inbox_total"] else { return }
        let unread: Int64? = if case .int(let n)? = row["inbox_unread"] { n } else { nil }
        lock.withLock { last = (Date(), total, unread) }
    }

    func pulse(now: Date) -> String {
        guard let last = lock.withLock({ last }) else { return "mail" }
        return "mail " + (last.unread.map { "\($0) unread of \(last.total)" } ?? "\(last.total)") + " (\(HerScreen.age(now.timeIntervalSince(last.at))) ago)"
    }
}
