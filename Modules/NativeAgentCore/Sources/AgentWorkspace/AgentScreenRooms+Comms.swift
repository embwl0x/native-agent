import Foundation
import MacIntegration
import PersistenceCore
import Transcripts
// Blueprint: | `AgentScreenRooms+Comms.swift` | `AgentScreen`: `sendTrouble`, `roomCounts`, `notConnected` |

/// Comms items open by stable name, reuse the owner's read and expose verbs without reading on home.
extension AgentScreen {
    // MARK: Places

    static let commsDestinations: [AgentWorkspaceDestination] = [
        .init(id: "notes", title: "Notes", summary: "Apple Notes: recent notes, find, read, add.",
              tool: "notes.search", input: ["limit": .int(12)], tools: ["notes.create"]),
        .init(id: "contacts", title: "Contacts", summary: "Mac Contacts: someone's number or email.",
              tool: "contacts_search", searchField: "query", tools: ["contacts_create_or_update"]),
    ]
    static let commsFamily: [String: String] = [
        "mail.recent": "mail", "mail.search": "mail", "messages.recent": "messages",
        "notes.search": "notes", "contacts_search": "contacts",
    ]
    static let commsReadTools: Set<String> = ["notes.search", "contacts_search"]

    static let commsItemVerbs: [String: [(name: String, about: String, tool: String)]] = [
        "mail": [("mail.N.draft", "saves an unsent reply in Mail → Drafts (text)", "mail.draft"), (
            "mail.N.reply", "sends a reply now (text)", "mail.reply"), (
            "mail.N.archive", "archive it", "mail.archive"), ("mail.N.mark-read", "mark it read", "mail.mark_read")],
        "notes": [("notes.N.append", "add to it (text)", "notes.update")],
    ]
    /// Bind numbers to message/contact identity, never row position; references from prior reads must still select the same item.
    static let numbersNote = "numbers stay with each item, gaps are normal"

    /// Warn on failed sends only while no newer inbound evidence is available at render.
    static func sendTrouble(workspace: WorkspaceOperation, agents: [String], dataRoot: URL, now: Date) throws -> [String: String] {
        guard !agents.isEmpty else { return [:] }
        do { return try checkedSendTrouble(workspace: workspace, agents: agents, dataRoot: dataRoot, now: now) }
        catch { return Dictionary(Set(agents).map { ($0.lowercased(), "Send status unavailable: " + error.localizedDescription
            + ". Repair conversation storage before interpreting the previous send.") }, uniquingKeysWith: { first, _ in first }) }
    }

    private static func checkedSendTrouble(workspace: WorkspaceOperation, agents: [String], dataRoot: URL, now: Date) throws -> [String: String] {
        let records: [AgentConversationRecord] = try AgentMemo.shared.cached(dataRoot.standardizedFileURL.path + "\u{0}sendTrouble.records", stamp: [stamp(
            dataRoot.appendingPathComponent("agents/conversations.json"))]) {
            try workspace.ports.conversations.records(dataRoot: dataRoot, locked: true).filter { !$0.agent.hasPrefix("bot") }
        }
        let chats = try bridgeChats(dataRoot: dataRoot)
        let identity = try workspace.ports.conversations.identity(dataRoot: dataRoot)
        let contacts = contacts(identity: identity)
        let transcripts = try ChatSessionRetention.transcriptFiles(dataRoot: dataRoot, archived: [:])
        var out: [String: String] = [:]
        let health = try workspace.ports.conversations.liveHealth(dataRoot: dataRoot)
        for agent in Set(agents.map { $0.lowercased() }) {
            if let problem = health[agent]?.problem { out[agent] = problem; continue }
            guard let contact = contacts.first(where: { $0.id == agent || $0.agents.contains(agent) }),
                  let record = latest(contact, records: records),
                  record.phase == "attention" else { continue }
            if health[agent]?.resolves(record) == true { continue }
            let receipt = record.sendEvidence
            if receipt["needs_input"] == .bool(true) || receipt["needs_authentication"] == .bool(true) { continue }
            let heard = try thread(contact, dataRoot: dataRoot, identity: identity, transcripts: transcripts)?.heard
            let inbound = chats.filter { $0.who == contact.id || contact.agents.contains($0.who) || $0.who == record.name.lowercased() }
                .compactMap(\.heard).max()
            if max(heard ?? .distantPast, inbound ?? .distantPast) > record.updatedAt { continue }
            let what = receipt["status"] == .string("outcome_unknown") ? "unconfirmed" : "failed"
            out[agent] = "⚠ last send \(what) \(age(now.timeIntervalSince(record.updatedAt)))"
        }
        return out
    }

    // MARK: Counts and connections, for every text room

    /// Use owner totals when supplied; otherwise disclose the listed rows and partial-page count.
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

    /// Normalize connection presentation without changing the owner's availability verdict.
    static func notConnected(_ row: [String: JSONValue]) -> Bool {
        row["connected"] == .bool(false)
            || ["reason", "failure_code", "error_code", "status"].contains { key in
                ["not_connected", "not_configured"].contains(row[key]?.stringValue ?? "")
            }
    }

    // MARK: Lists

    /// Stable row names reopen the selected owner item.
    static func commsProjection(tool: String, input: [String: JSONValue], result: JSONValue) -> WorkspacePage? {
        func rows(_ key: String) -> [[String: JSONValue]] {
            guard case .object(let root) = result, case .array(let list)? = root[key] else { return [] }
            return list.compactMap { if case .object(let row) = $0 { row } else { nil } }
        }
        let content: JSONValue = if case .object(let root) = result {
            .object(root.filter { !["messages", "notes", "contacts"].contains($0.key) })
        } else { result }
        switch tool {
        case "notes.search":
            // The header carries complete counts; partial reads retain their repair notice.
            let noteContent: JSONValue = if case .object(let root) = content {
                .object(root.filter { $0.key != "message" || root["status"] == .string("partial") })
            } else { content }
            return .init(title: "Notes", content: noteContent, items: rows("notes").compactMap { row in
                guard let name = text(row["name"]) else { return nil }
                // By the note's own id: two notes can share a title.
                guard case .string(let id)? = row["id"], nonEmpty(id) != nil, id != "missing value" else {
                    return .init(title: name, content: .object([
                        "status": .string("unavailable"), "reason": .string("note_identity_unavailable"),
                        "detail": .string("This Notes row has no recorded ID; it cannot be opened by title."),
                        "source": .object(row), "effects": .string("none"),
                        "remedy": Repair.remedy(owner: "notes.search", nextCall: nil, tap: nil,
                            instruction: "Repair the Notes source's missing identifier, then refresh Notes.")
                    ]), actions: [])
                }
                let by: [String: JSONValue] = ["id": .string(id)]
                let about: [String: JSONValue] = ["kind": row["folder"] ?? .null, "date": row["modified_at"] ?? .null,
                                                  "snippet": row["body_preview"] ?? row["body"] ?? .null]
                return .init(title: name, content: .object(about),
                    actions: [.init(label: "Read", action: .open(.record(tool: "notes.search", input: by, title: name)))])
            }, actions: [
                .init(label: "Find a note", action: .perform(tool: "notes.search", input: [:], title: "Find a note", textField: "query", isEffect: false),
                    needsText: true),
                .init(label: "New note", action: .configure(tool: "notes.create", input: [:], title: "New note")),
            ])
        case "contacts_search":
            return .init(title: "Contacts", content: content, items: rows("contacts").compactMap { row in
                guard let id = text(row["identifier"]), let name = text(row["name"]) ?? text(row["organizationName"]) else { return nil }
                // Keep card contents behind explicit selection.
                let phones = values(row["phones"]).count, emails = values(row["emails"]).count
                let holds = phones + emails == 0 ? "no phone or email"
                    : [phones > 0 ? "\(phones) phone\(phones == 1 ? "" : "s")" : nil, emails > 0 ? "\(emails) email\(emails == 1 ? "" : "s")" : nil]
                        .compactMap { $0 }.joined(separator: ", ")
                return .init(title: name, content: .object(["kind": row["organizationName"] ?? .null, "summary": .string(holds)]),
                    actions: [.init(label: "Open", action: .open(.record(tool: "contacts_search",
                        input: ["identifier": .string(id)], title: name)))])
            }, actions: [.init(label: "Search contacts", action: .perform(tool: "contacts_search", input: [:], title: "Contacts search", textField: "query",
                isEffect: false), needsText: true)])
        default: return nil
        }
    }

    // MARK: Rooms

    static func noteAppend(id: String, title: String) -> AgentWorkspaceAction {
        .perform(tool: "notes.update", input: ["id": .string(id)], title: "Add to " + title, textField: "append", isEffect: true)
    }

    /// Preserve list and item room names; leave the current frame when no room applies.
    static func commsRoom(workspace: WorkspaceOperation, _ location: AgentWorkspaceLocation, value: JSONValue?, projection: WorkspacePage?, dataRoot: URL,
        scope: String,
        issue: String?) async -> String? {
        do {
            if let batch = mailBatchRoom(workspace: workspace, location, value: value, dataRoot: dataRoot, scope: scope) { return batch }
            guard case .record(let tool, let input, let title) = location, let value, let projection else { return nil }
            let now = Date()
            guard let family = commsFamily[tool] else { return nil }
            let object: [String: JSONValue] = if case .object(let row) = value { row } else { [:] }
            let single: Bool = switch tool {
            case "mail.recent": input["message_id"] != nil
            case "messages.recent": input["thread_id"] != nil
            case "notes.search": input["title"] != nil || input["id"] != nil
            case "contacts_search": input["identifier"] != nil
            default: false
            }
            // Keep the connector owner's fix visible.
            if notConnected(object) {
                return screen([family.uppercased(), "not connected"], [[failureFace(value)]],
                              verbs: [], back: "Back: home.", verbWidth: 24, omitEmptyHeader: true)
            }
            if let issue { return screen([family.uppercased(), text(object["status"]) ?? "failed"], [[issue]], verbs: []) }
            guard single else {
                let status = issue == nil ? (text(object["status"]) ?? "ok") : "failed"
                return textRoom(workspace: workspace, family, place: location, projection: projection,
                                status: .string(status), dataRoot: dataRoot, scope: scope, now: now)
            }
            // The item's name is the one its list row minted: a next page of the same message or thread keeps it.
            let identity = input.filter { !["body_offset", "text_offset", "before_message_id", "limit", "position"].contains($0.key) }
            let itemKey = key(.record(tool: tool, input: identity, title: title)) ?? title
            let name = family
                + ".\(try withNames(workspace: workspace, dataRoot) { book in try book.number("item." + family, id: itemKey, title: title) { [itemKey] } })"
            func rowsOf(_ key: String) -> [[String: JSONValue]] {
                guard case .array(let list)? = object[key] else { return [] }
                return list.compactMap { if case .object(let row) = $0 { row } else { nil } }
            }
            var verbs: [(String, String)] = [], keep: [String: AgentWorkspaceAction] = [:]
            func verb(_ word: String, _ about: String, _ action: AgentWorkspaceAction) {
                guard AgentWorkspaceReadiness.allows(workspace: workspace, action) else { return }
                verbs.append((name + "." + word, about)); keep[name + "." + word] = action
            }
            var header: [String] = [name], sections: [[String]] = []
            switch tool {
            case "mail.recent":
                guard let row = rowsOf("messages").first else { return nil }
                let bound = input.filter { MailReadLocator.fields.union(["mailbox"]).contains($0.key) }
                header += [who(text(row["sender"])), when(text(row["date"]), now: now)] + (row["unread"] == .bool(true) ? ["unread"] : [])
                let (lines, used) = bodyLines(text(row["body"]) ?? "")
                let start = int(row["body_offset"]) ?? 0, total = int(row["body_total"]) ?? 0
                let body = tabled(lines, row["body_tables"])
                sections = [section("SUBJECT", [clip(text(row["subject"]) ?? "(no subject)", 100)]), section("BODY", body.isEmpty ? ["(empty)"] : body)]
                let attachments = mailAttachmentLines(row)
                if !attachments.isEmpty { sections.append(section("ATTACHMENTS", attachments)) }
                if start + used < total {
                    sections.append(["+\(total - start - used) more characters · \(name).more"])
                    keep[name + ".more"] = .open(.record(tool: "mail.recent", input: bound.merging(["body_offset": .int(Int64(start + used))]) { _,
                        new in new }, title: title))
                }
                let actions = AgentWorkspaceMail.itemActions(input: bound, title: title)
                for (word, about) in [("draft", "saves an unsent reply in Mail → Drafts (text)"), ("reply", "sends a reply now to the sender (text)"),
                    ("reply-all", "sends a reply now to everyone (text)"), ("archive", "archive it"), ("mark-read", "mark it read"), ("delete",
                        "move it to Trash")] {
                    if let action = actions[word] { verb(word, about, action) }
                }
            case "messages.recent":
                guard let thread = rowsOf("threads").first else { return nil }
                let people: [[String: JSONValue]] = if case .array(let list)? = thread["participants"] {
                    list.compactMap { if case .object(let row) = $0 { row } else { nil } }
                } else { [] }
                header += [clip(text(thread["name"]) ?? people.compactMap { text($0["name"]) ?? text($0["handle"]) }.joined(separator: ", "), 50)]
                let talk = rowsOf("messages").suffix(10).map { row -> String in
                    let prefix = pad(when(text(row["date"]), now: now, short: true), 7)
                        + pad(row["from_me"] == .bool(true) ? "me" : clip(text(row["sender_name"]) ?? who(text(row["sender"])), 16), 12)
                    if text(row["text"]) == nil, row["text_status"] == .string("archived_text_not_decoded") {
                        return prefix + failureFace(.object(["status": .string("unavailable"), "reason": .string("message_format_unsupported"),
                            "detail": .string("This reader does not decode the message's archived text format."), "effects": .string("none"),
                            "remedy": Repair.reconcile(instruction: "Read the original conversation in Messages with mac.look.",
                                nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("mac.look"), "args": .object(["app": .string(
                                    "Messages")])])]))]))
                    }
                    let said = text(row["text"]) ?? (row["has_attachments"] == .bool(true) ? "(attachment)" : "(no text retained)")
                    return prefix + clip(said, 90)
                }
                sections = [section("TALK", talk.isEmpty ? [clip(text(object["history_note"]) ?? "no messages to show", 110)] : talk)]
                if let older = object["older_before_message_id"], let id = text(thread["thread_id"]) {
                    keep[name + ".older"] = .open(.record(tool: "messages.recent", input: ["thread_id": .string(id), "before_message_id": older],
                        title: title))
                    sections.append(["earlier messages · \(name).older"])
                }
                if let reply = AgentWorkspaceMessages.replyAction(thread, requested: text(input["thread_id"]), title: title) {
                    verb("reply", "sends a reply now in this thread (text)", reply)
                }
            case "notes.search":
                guard let note = rowsOf("notes").first else { return nil }
                header += [text(note["folder"]), when(text(note["modified_at"]), now: now)].compactMap { $0 }.filter { !$0.isEmpty }
                // The Notes reader already elides the stored title line and returns raw offsets.
                let body = if case .string(let value)? = note["body"] ?? note["body_preview"] { value } else { "" }
                let (lines, used) = bodyLines(body)
                let start = int(note["body_offset"]) ?? 0
                sections = [section("TITLE", [clip(text(note["name"]) ?? title, 100)]), section("TEXT", lines.isEmpty ? ["(no text on this page)"] : lines)]
                if let total = int(object["total"]), total > 1 {
                    sections.append(["\(total) notes have this title; this is one · notes.find (text) to pick another"])
                }
                // Only by the note's id: a title can belong to two notes.
                if let id = text(note["id"]) {
                    let next = start + body.prefix(used).utf16.count
                    if let total = int(note["body_total"]), next < total {
                        sections.append(["more text · \(name).more"])
                        keep[name + ".more"] = .open(.record(tool: "notes.search", input: ["id": .string(id), "body_offset": .int(Int64(next))], title: title))
                    }
                    verb("append", "add a line to it (text)", noteAppend(id: id, title: title))
                }
            case "contacts_search":
                guard let card = rowsOf("contacts").first else { return nil }
                let phones = values(card["phones"]), emails = values(card["emails"])
                header += [clip(text(card["name"]) ?? title, 40)] + (text(card["organizationName"]).map { [$0] } ?? [])
                sections = [section("PHONES", phones.isEmpty ? ["none"] : phones.prefix(4).map { clip($0, 40) }),
                            section("EMAILS", emails.isEmpty ? ["none"] : emails.prefix(4).map { clip($0, 60) })]
                if let phone = values(card["phones"], labels: false).first {
                    verb("text", "sends a text now to \(phones.count > 1 ? "the first number" : "them") (text)", .perform(tool: "messages.send", input: ["to"
                        : .string(phone)],
                        title: "Text " + title, textField: "body", isEffect: true))
                }
                if let email = values(card["emails"], labels: false).first {
                    verb("email", "sends an email now (form)", .configure(tool: "mail.send", input: ["to": .string(email)], title: "Email " + title))
                }
                if let id = text(card["identifier"]) {
                    verb("edit", "add a number or email (form)", .configure(tool: "contacts_create_or_update", input: ["identifier": .string(id)],
                        title: "Edit " + title))
                }
            default: return nil
            }
            sections.append(section("GAPS", pageGaps(projection.content)))
            if !workspace.previewing { AgentNamed.shared.keep(dataRoot, keep.filter { AgentWorkspaceReadiness.allows(workspace: workspace, $0.value) },
                room: name, scope: scope) }
            return screen(header, sections, verbs: verbs, back: "Back: home · \(family).", verbWidth: 24, omitEmptyHeader: true)
        } catch { return nameFailure(error) }
    }

    /// After restart, rebuild mail verbs from the selected item's read; other items redraw their own verbs.
    static func commsTarget(workspace: WorkspaceOperation, _ raw: String, dataRoot: URL) -> Target? {
        do {
            let selection = raw.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
            if let verb = selection.first, ["mail.read-batch", "mail.mark-read-batch", "mail.flag-batch", "mail.unflag-batch", "mail.archive-batch"].contains(
                verb),
               (1...10).contains(selection.count - 1) {
                let items: [JSONValue] = selection.dropFirst().map { name in
                    var row: [String: JSONValue] = ["name": .string(name)]
                    switch verb {
                    case "mail.mark-read-batch": row["mark_read"] = .bool(true)
                    case "mail.flag-batch": row["flagged"] = .bool(true)
                    case "mail.unflag-batch": row["flagged"] = .bool(false)
                    case "mail.archive-batch": row["archive"] = .bool(true)
                    default: break
                    }
                    return .object(row)
                }
                let input: [String: JSONValue] = ["items": .array(items)]
                if verb == "mail.read-batch" { return .action(.open(.record(tool: "mail.read", input: input, title: "Selected email"))) }
                return .action(.perform(tool: "mail.triage", input: input, title: "Triage selected email", textField: nil, isEffect: true))
            }
            let parts = raw.split(separator: ".").map(String.init)
            guard parts.count == 3, let n = Int(parts[1]), commsItemVerbs.keys.contains(parts[0]) || parts[0] == "messages",
                  let place = try itemPlace(workspace: workspace, parts[0], n, dataRoot: dataRoot), case .record(let tool, let input,
                      let title) = place else { return nil }
            if tool == "mail.recent", let action = AgentWorkspaceMail.itemActions(input: input, title: title)[parts[2]] {
                return .action(action)
            }
            if tool == "notes.search", parts[2] == "append", case .string(let id)? = input["id"] {
                return .action(noteAppend(id: id, title: title))
            }
            return .action(.window(AgentWorkspaceNavigation.windowAction(place)))
        } catch { return .page(nameFailure(error)) }
    }

    private static func mailBatchRoom(workspace: WorkspaceOperation, _ location: AgentWorkspaceLocation, value: JSONValue?, dataRoot: URL,
        scope: String) -> String? {
        let tool: String, result: JSONValue
        switch location {
        case .record(let name, _, _):
            guard let value else { return nil }
            tool = name; result = value
        case .receipt(let name, _, let receipt, _): tool = name; result = receipt
        default: return nil
        }
        guard ["mail.read", "mail.triage"].contains(tool), case .object(let root) = result,
              case .array(let items)? = root["items"] else { return nil }
        var keep: [String: AgentWorkspaceAction] = [:], verbs: [(String, String)] = []
        let sections: [[String]] = items.compactMap { item in
            guard case .object(let row) = item else { return nil }
            let name = text(row["name"]) ?? "message " + (text(row["message_id"]) ?? "?")
            var lines = [name + " · " + (text(row["status"]) ?? "unknown")]
            for key in ["subject", "sender", "reason", "error"] { if let value = text(row[key]), !value.isEmpty { lines.append(value) } }
            if case .object(let actions)? = row["actions"] {
                for action in ["mark_read", "flagged", "archive"] {
                    if case .object(let outcome)? = actions[action] {
                        let label: String
                        if action == "flagged", case .object(let requested)? = row["requested"] {
                            label = action + "=" + (requested[action] == .bool(false) ? "false" : "true")
                        } else { label = action }
                        lines.append(label + ": " + (text(outcome["status"]) ?? "unknown")
                            + (text(outcome["message"] ?? outcome["error"] ?? outcome["reason"]).map { " · " + $0 } ?? ""))
                    }
                }
            }
            if let body = text(row["body"]) { lines += tabled(wrap(body, width: 100), row["body_tables"]) }
            lines += mailAttachmentLines(row)
            if row["truncated"] == .bool(true), let end = row["body_end"], AgentWorkspaceReadiness.allows(workspace: workspace, tool: "mail.recent") {
                lines.append("Body continues at " + (text(end) ?? "?"))
                let bound = row.filter { MailReadLocator.fields.contains($0.key) }
                    .merging(["body_offset": end]) { _, new in new }
                let more = name + ".more"
                keep[more] = .open(.record(tool: "mail.recent", input: bound, title: text(row["subject"]) ?? "Email"))
                verbs.append((more, "read next body part"))
            }
            return lines.map { UntrustedText.neutralized($0) }
        }
        if !workspace.previewing { AgentNamed.shared.keep(dataRoot, keep, room: "mail-batch", scope: scope) }
        return screen(["MAIL BATCH", text(root["status"]) ?? "unknown"], sections, verbs: verbs, back: "Back: mail.", verbWidth: 24, omitEmptyHeader: true)
    }

    // MARK: Home's mail line

    private static func mailAttachmentLines(_ row: [String: JSONValue]) -> [String] {
        guard case .array(let attachments)? = row["attachments"] else { return text(row["attachments_status"]).map { [$0] } ?? [] }
        return attachments.compactMap {
            guard case .object(let part) = $0 else { return nil }
            return (text(part["index"]) ?? "?") + ": " + (text(part["filename"]) ?? "?")
                + " · " + (text(part["content_type"]) ?? "?") + " · "
                + (text(part["size"]).map { $0 + " bytes" } ?? "not downloaded")
        }
    }

    // MARK: Pieces

    /// Bound message pages to 30 lines and 2400 characters; prefer whole paragraphs and defuse each line.
    private static func bodyLines(_ body: String) -> (lines: [String], used: Int) {
        let cap = 2400
        var lines: [String] = [], used = 0, shown = 0
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if lines.count >= 40 { break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || (line.hasPrefix(">") && lines.last?.hasPrefix(">") == true) { used += raw.count + 1; continue }
            if shown + line.count > cap {
                if lines.isEmpty {
                    lines.append(clip(String(line.prefix(cap)), cap + 1))
                    let leading = raw.prefix { $0.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) }.count
                    used += leading + cap
                }
                break
            }
            lines.append(clip(line, cap + 1)); shown += line.count; used += raw.count + 1
        }
        return (lines, min(used, body.count))
    }

    /// Reconstruct `body_tables` only where consecutive body lines exactly match the table's cells in order; preserve all unmatched body text.
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

    private static func text(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let text)?: return nonEmpty(text) == nil || text == "missing value" ? nil : text
        case .int(let n)?: return String(n)
        default: return nil
        }
    }

    private static func int(_ value: JSONValue?) -> Int? { if case .int(let n)? = value { Int(n) } else { nil } }

    private static func values(_ value: JSONValue?, labels: Bool = true) -> [String] {
        guard case .array(let list)? = value else { return [] }
        return list.compactMap { entry in
            guard case .object(let row) = entry, let value = text(row["value"]) else { return nil }
            if !labels { return value }
            return text(row["label"]).map { $0 == "other" ? value : value + " (" + $0 + ")" } ?? value
        }
    }
}

/// Root-scoped in-memory badges let Home display read age without integration reads.
package final class AgentReadBadges: @unchecked Sendable {
    package static let shared = AgentReadBadges()
    private let lock = NSLock()
    private var rows: [String: [String: (words: String, at: Date)]] = [:]

    func note(_ name: String, _ words: String, dataRoot: URL) {
        lock.withLock { rows[dataRoot.standardizedFileURL.path, default: [:]][name] = (words, Date()) }
        NotificationCenter.default.post(name: AgentWorkspaceScreenPreview.didChange, object: nil)
    }

    func latest(_ name: String, dataRoot: URL) -> (words: String, at: Date)? {
        lock.withLock { rows[dataRoot.standardizedFileURL.path]?[name] }
    }

    package func note(_ result: JSONValue, dataRoot: URL) {
        guard case .object(let row) = result, row["status"] == .string("completed") else { return }
        if case .array(let messages)? = row["messages"] {
            let text = messages.prefix(4).compactMap { message -> String? in
                guard case .object(let message) = message, case .string(let subject)? = message["subject"],
                      case .string(let sender)? = message["sender"] else { return nil }
                return AgentScreen.clip(sender, 28) + " — " + AgentScreen.clip(subject, 70)
            }.joined(separator: "; ")
            note("mail.previews", text, dataRoot: dataRoot)
        }
        guard case .int(let total)? = row["inbox_total"] else { return }
        let words = if case .int(let unread)? = row["inbox_unread"] { "\(unread) unread of \(total)" } else { "\(total)" }
        note("mail", words, dataRoot: dataRoot)
    }

    func pulse(dataRoot: URL, now: Date) -> String {
        guard let last = latest("mail", dataRoot: dataRoot) else { return "mail" }
        return "mail " + last.words + " (\(AgentScreen.age(now.timeIntervalSince(last.at))) ago)"
    }

    func notable(workspace: WorkspaceOperation, dataRoot: URL, now: Date) -> String? {
        guard AgentWorkspaceReadiness.allows(workspace: workspace, tool: "mail.search"),
              let previews = latest("mail.previews", dataRoot: dataRoot), !previews.words.isEmpty else { return nil }
        return "Last Mail read (\(AgentScreen.age(now.timeIntervalSince(previews.at))) ago); up to 4 previews, not a current inbox scan: " + previews.words
    }
}
