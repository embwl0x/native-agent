import AppKit
import Foundation
import NativeAgentShared
import MacControl
import NativeAgentCore
import PersistenceCore
import Desk
import StandingBots
import ChatSessionWork
import Transcripts
import ChatToolParsing
// Blueprint: | `AgentScreenRooms.swift` | owner-bound room identities; partial pages retain gaps and lock uncertainty |
// Classify helper conversations only by recorded ask/entry identity; screen coverage alone cannot establish an unlocked session.

/// Stable verbs and supplied owner reads keep rooms consistent without inventing authority.
extension AgentScreen {
    /// Unmatched locations retain their frame; owner-read failures must remain visible.
    static func room(workspace: WorkspaceOperation, _ location: AgentWorkspaceLocation, dataRoot: URL, scope: String, issue: String? = nil,
        value: JSONValue? = nil,
        projection: WorkspacePage? = nil,
                     observed: ((AgentWorld, Date, Set<String>) -> Void)? = nil) async -> String? {
        if let comms = await commsRoom(workspace: workspace, location, value: value, projection: projection, dataRoot: dataRoot, scope: scope,
            issue: issue) { return comms }
        if let read = await buildRecordRoom(workspace: workspace, location, value: value, projection: projection, dataRoot: dataRoot, scope: scope,
            issue: issue) { return read }
        let now = Date(), person = names(dataRoot).person
        switch location {
        case .record("agent_read", let input, _):
            guard case .string(let agent)? = input["agent"], Set(input.keys).isSubset(of: ["agent", "conversation"]) else { return nil }
            if let issue { return screen([agent, "unavailable"], [[issue]], verbs: []) }
            if agent.lowercased().hasPrefix("bot:"), let id = UUID(uuidString: String(agent.dropFirst(4))) {
                return helperRoom(workspace: workspace, id, dataRoot: dataRoot, person: person, issue: issue, now: now)
            }
            let label: String? = if case .string(let value)? = input["conversation"] { value } else { nil }
            return await personRoom(workspace: workspace, agent, label: label, dataRoot: dataRoot, person: person, scope: scope, issue: issue, now: now,
                observed: observed)
        case .record("desk_read", let input, _):
            guard case .string(let handle)? = input["handle"], Set(input.keys) == ["handle"] else { return nil }
            if let issue { return screen([handle, "unavailable"], [[issue]], verbs: []) }
            guard let value, let projection else { return nil }
            return deskItemRoom(workspace: workspace, value, projection: projection, dataRoot: dataRoot, scope: scope, now: now)
        case .record("chat_conversations", let input, let title):
            guard case .string(let id)? = input["conversation_session_id"], input.count == 1 else { return nil }
            return await chatRoom(workspace: workspace, id, title: title, dataRoot: dataRoot, person: person, scope: scope, issue: issue, value: value,
                now: now)
        case .area("ongoing"):
            return await deskRoom(workspace: workspace, dataRoot: dataRoot, person: person, now: now)
        case .area("computer"):
            return await macRoom(dataRoot: dataRoot, person: person, now: now)
        case .area("helpers"):
            return await helpersRoom(workspace: workspace, dataRoot: dataRoot, person: person, now: now)
        case .people(page: 0):
            return await peopleRoom(workspace: workspace, dataRoot: dataRoot, scope: scope, now: now, observed: observed)
        case .conversations(let page):
            return await conversationsRoom(workspace: workspace, dataRoot: dataRoot, person: person, scope: scope, now: now, page: page)
        case .area("files"), .area("code"): return await buildRoom(workspace: workspace, location, dataRoot: dataRoot, now: now)
        case .record("browser.chrome_snapshot", let input, _): return tabRoom(workspace: workspace, input, dataRoot: dataRoot, scope: scope, issue: issue,
            now: now)
        case .area("browser"): return browserRoom(workspace: workspace, dataRoot: dataRoot, scope: scope, person: person, now: now)
        // Research rows retain their read and Chrome actions.
        case .record(AgentWorkspaceKnowledge.webSearchTool, _, _):
            guard let value, let projection else { return nil }
            let reply = ToolResult(value)
            let failed = issue != nil || reply.carriesFailureEvidence
            if failed { return screen(["RESEARCH", value.objectValue?["status"]?.stringValue ?? "failed"],
                                      [[failureFace(value)], section("GAPS", pageGaps(projection.content))], verbs: []) }
            return textRoom(workspace: workspace, "research", place: location, projection: projection,
                            status: .string(failed ? "failed" : "ok"), dataRoot: dataRoot, scope: scope, now: now)
        default: return nil
        }
    }

    package static func names(_ dataRoot: URL) -> (agent: String, person: String) {
        let profile = (try? Data(contentsOf: dataRoot.appendingPathComponent("memory/profile.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return (clip(nonEmpty(profile["name"] as? String) ?? "Agent", 40), clip(nonEmpty(profile["userName"] as? String) ?? "Your person", 40))
    }

    static func screen(_ header: [String], _ sections: [[String]], verbs: [(String, String)], back: String = "Back: home.",
                       verbWidth: Int = 22, omitEmptyHeader: Bool = false) -> String {
        let rule = String(repeating: "─", count: 61)
        // Names, titles and states can come from outside: each field is defused and clipped here, whatever built it.
        var lines = [header.map { clip($0, 60) }.filter { !omitEmptyHeader || !$0.isEmpty }.joined(separator: " · ")]
        for part in sections where !part.isEmpty { lines.append(rule); lines += part }
        lines.append(rule)
        let width = min(verbWidth, (verbs.map(\.0.count).max() ?? 0) + 2)
        lines += section("DO", verbs.map { pad(UntrustedText.neutralized($0.0), width) + UntrustedText.neutralized($0.1) })
        lines.append(back)
        return lines.joined(separator: "\n")
    }

    private static func line(_ at: Date?, _ who: String, _ text: String, now: Date, talk: Bool = true) -> String {
        // The unattested qualifier survives the clip: the name shortens, never the word.
        let suffix = " (unattested)"
        let shown = who.hasSuffix(suffix) ? clip(String(who.dropLast(suffix.count)), 20 - suffix.count) + suffix : clip(who, 20)
        return pad(at.map { age(now.timeIntervalSince($0)) } ?? "", 5) + pad(shown, 10) + said(text, talk: talk)
    }

    private static func said(_ text: String, talk: Bool = true) -> String { clip(talk ? sentence(text) : text, 80) }

    // MARK: Helper

    private static func helperRoom(workspace: WorkspaceOperation, _ id: UUID, dataRoot: URL, person: String, issue: String?, now: Date) -> String? {
        do {
            let bot = try BotDefinitionStore(dataRoot: dataRoot).get(id)
            let slug = try withNames(workspace: workspace, dataRoot) { $0.slug(id: "bot:" + id.uuidString, name: bot.name) }
            let shelf = ShelfStore(dataRoot: dataRoot)
            let running = try BotRunQueue(dataRoot: dataRoot).activeOrQueuedIDs().contains(id)
            let state = try helperState(bot, entry: shelf.latestEntries(botIDs: [id]).first, running: running, person: person, now: now)
            let cadence = StandingBotSchedule.words(bot.cadence)
            // A conversation run is recorded by `asked` or its exact entry ID.
            let entries = try (shelf.entriesByBot()[id] ?? []).sorted { $0.runAt > $1.runAt }
            let records = try workspace.ports.conversations.records(dataRoot: dataRoot, locked: true)
                .filter { $0.agent.caseInsensitiveCompare("bot:" + id.uuidString) == .orderedSame }
            var askedIDs: Set<String> = []
            for record in records {
                let receipt = record.sendEvidence
                for value in [receipt["entry_id"], receipt["message_id"], record.readInput?["message_id"]] {
                    if case .string(let entry)? = value { askedIDs.insert(entry.uppercased()) }
                }
            }
            func asked(_ entry: ShelfEntry) -> Bool {
                entry.asked == true || askedIDs.contains(entry.id.uuidString)
            }
            let marks: [ShelfRunHealth: String] = [.ok: "✓", .nothingNew: "○", .partial: "~", .failed: "✗"]
            func rows(_ list: [ShelfEntry], _ mark: (ShelfEntry) -> String, more: String) -> [String] {
                list.prefix(4).map { pad(age(now.timeIntervalSince($0.runAt)), 7) + pad(mark($0), 3) + clip(sentence($0.headline), 78) }
                    + (list.count > 4 ? ["+\(list.count - 4) \(more)"] : [])
            }
            let runs = entries.filter { !asked($0) }, talk = entries.filter(asked)
            return screen([bot.name.uppercased(), "helper", state] + (state.contains(cadence) ? [] : [cadence]),
                [section("ABOUT", [clip(firstLine(bot.brief), 90)]),
                 section("RUNS", runs.isEmpty ? ["no runs yet"] : rows(runs, { marks[$0.runHealth] ?? "·" }, more: "earlier runs · item \"replies\"")),
                 section("TALK", rows(talk, { _ in "↩" }, more: "earlier replies")),
                 issue.map { section("READ", [$0]) } ?? []],
                verbs: [(slug + ".say", "sends a message now (text)"), (slug + ".run", "run it once now"), (slug + ".settings", "change how it works")]
                    + (bot.cadence == .manual ? [] : [bot.paused ? (slug + ".resume", "turn its schedule back on") : (slug + ".pause",
                        "stop its scheduled runs")]))
        } catch { return nameFailure(error) }
    }

    // MARK: Person

    private static func personRoom(workspace: WorkspaceOperation, _ agent: String, label: String?, dataRoot: URL, person: String, scope: String,
        issue: String?, now: Date,
                                   observed: ((AgentWorld, Date, Set<String>) -> Void)?) async -> String? {
        do {
            let world = await readWorld(workspace: workspace, dataRoot, now: now)
            if let failure = world.sourceFailure("people", "contacts") { return screen([agent, "unavailable"], [[failure]], verbs: []) }
            let (records, chats) = (world.records, world.chats)
            // Identity merging is for list rows. A room retains its selected route.
            let everyone = world.routes
            let contact = everyone.first { $0.id.caseInsensitiveCompare(agent) == .orderedSame }
                ?? Contact(id: agent, name: records.first { $0.agent == agent }?.name ?? agent, kind: nil)
            let record = try workspace.ports.conversations.find(dataRoot: dataRoot, scopeSessionID: scope, agent: agent, label: label)
            // Read all verified doors for this mind; sends retain the selected route.
            let identity = world.identity
            let members = Set(identity.members(contact.id))
            let theirs = chats.filter { members.contains($0.who) }
            let bare = Contact(id: contact.id, name: contact.name, kind: nil)
            let healthID = world.healthID(for: contact, record: record), health = world.health[healthID]
            let state = state(bare, record: record, chat: theirs.first { $0.id != scope }, answered: world.answered, now: now,
                health: health).text
            let slug = try withNames(workspace: workspace, dataRoot) { $0.slug(id: contact.id, name: contact.name) }

            let owner = contact.id.hasPrefix("peer:") ? String(contact.id.dropFirst(5)) : contact.id
            let thread: [ContactThread.Line]
            // Use the directory row's explicit association so room and list agree.
            do { thread = try ContactThread.mergedLines(dataRoot: dataRoot, owner: owner, tailBytes: 65_536, identity: identity) }
            catch {
                let repair = """
                    Tell the person: contact \(owner)'s transcript store could not be read: \(error.localizedDescription). Restore access at the named paths, \
                    preserving every conversation.
                    """
                return screen([contact.name, "History unavailable"], [[readFailure(error, reason: "contact_history_unavailable",
                    remedy: Repair.remedy(owner: "Contact history for " + owner, nextCall: nil, tap: repair, instruction: repair))]], verbs: [])
            }
            // The thread lines this room shows, each read under its own row's provenance.
            var shown = Array(thread.suffix(6))
            var labels = Dictionary(everyone.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            for member in members { labels[member] = slug }
            shown = ContactThread.project(shown, person: person, own: "me", names: labels)
            var talk = shown.map {
                line($0.at, $0.speaker + ($0.door.map { " · " + $0 } ?? ""), $0.text, now: now)
            }
            // Acknowledge only exact saved replies displayed for each send so they are not delivered twice.
            var answers: [String: String] = [:]
            for row in thread.suffix(6) where !row.mine { if let id = row.answers { answers[id] = said(row.text) } }
            if let chat = theirs.first(where: { $0.id != scope }),
               chat.at > max(thread.last?.at ?? .distantPast, record?.exchanges?.last?.sentAt ?? .distantPast) {
                // Do not quote the active chat back as outside news; show the newest other bridge conversation.
                let tail = try chatTail(chat.id, dataRoot: dataRoot).suffix(6)
                let projected = ContactThread.project(tail, person: person, own: "me",
                    names: identity.doors, contactPrefix: slug + " · ",
                    mark: { peer, _ in workspace.ports.tools.markConsumed(peer: peer) })
                talk = projected.map { line($0.date, $0.speaker, $0.text, now: now) }
                answers = [:]
                shown = []
                // Include preceding chats so a newer unrelated exchange cannot hide an earlier ask.
                for older in theirs.filter({ $0.id != scope && $0.id != chat.id }).prefix(3) {
                    if let last = try chatTail(older.id, dataRoot: dataRoot, bytes: 16_384).last(where: { !$0.mine }) {
                        let projected = ContactThread.project([last], person: person,
                            names: identity.doors, contactPrefix: slug + " · ",
                            mark: { peer, _ in workspace.ports.tools.markConsumed(peer: peer) })[0]
                        talk.insert(line(last.date, projected.speaker, "session " + older.id + " · " + last.text, now: now), at: 0)
                    }
                }
            }
            if talk.isEmpty, contact.kind == "routine" {
                // Routine replies belong to the requesting chats; outbound asks remain in the contact thread.
                let replies = try await ContactThread.project(routineReplies(workspace: workspace, dataRoot: dataRoot).suffix(6), names: labels,
                    unattested: contact.name,
                    mark: { peer, _ in workspace.ports.tools.markConsumed(peer: peer) })
                talk = replies.map { line($0.date, $0.speaker, $0.text, now: now) }
            }
            if talk.isEmpty, let record, record.retainedReply != nil {
                let replyLine = try ContactThread.project(ContactThread.mergedLines(dataRoot: dataRoot, owner: owner, identity: identity),
                    names: labels, answering: record.operationID,
                    mark: { peer, _ in workspace.ports.tools.markConsumed(peer: peer) })
                if let reply = replyLine.first {
                    talk.append(line(reply.date, reply.speaker, reply.text, now: now))
                } else {
                    talk.append("A reply record exists, but its matching conversation line is unavailable; history is incomplete.")
                }
            }
            if talk.isEmpty { talk = [record == nil ? "no messages yet" : "sent; no reply is recorded yet"] }
            for row in shown { ContactThread.consume(row, mark: { peer, _ in workspace.ports.tools.markConsumed(peer: peer) }) }
            // Show the last send's evidence and what the next `.say` will do.
            var outcome: [String] = []
            if let problem = health?.problem { outcome.append(problem) }
            if let record, record.sendFailed || health?.resolves(record) != true && record.phase == "attention" {
                let receipt = AgentConversationRecord.sendEvidence(record.sendReceipt)
                let peer = contact.id.hasPrefix("peer:") ? (try? workspace.ports.conversations.peers(dataRoot: dataRoot))?.first { "peer:" + $0
                    .id == contact.id } : nil
                outcome.append(sendFailure(bare, receipt: receipt) ?? failureFace(.object(receipt)))
                if peer?.canAnswerBack == false { outcome.append(
                    "Replies from \(contact.name) aren't connected: one comes only as an ordinary message, if it comes.") }
                outcome.append(workspace.ports.conversations.unsettledAttention(record)
                    ? slug + ".say queues behind it until settlement or cancellation: app {action:\"agent.cancel\",args:{agent:\"\(contact.id)\"}}."
                    : slug + ".say sends a new message here; it never repeats the earlier one.")
            }

            // Chats they opened with the agent over the bridge; the one the agent is in is named but never quoted.
            let listed = Array(theirs.filter { !$0.id.hasPrefix("bench-") }.prefix(3))
            let chatLines = try withNames(workspace: workspace, dataRoot) { book in
                try listed.map { chat -> String in
                    if chat.id == scope { return pad("this chat", 10) + age(now.timeIntervalSince(chat.at)) }
                    return pad("chat.\(try book.number("chat", id: chat.id) { Set(chats.map(\.id)) })", 10)
                        + clip(chat.title, 50) + " · " + age(now.timeIntervalSince(chat.at))
                }
            } + (theirs.count > listed.count ? ["+\(theirs.count - listed.count) more · item \"conversations\""] : [])
            var verbs = [(slug + ".say", "sends a message now; queues behind a pending reply (text)")]
            if members.contains("claude") {
                verbs.append(("app {action:\"claude.worklog\"}", "recent recorded work, newest first; separate from chat replies"))
            }
            if listed.contains(where: { $0.id != scope }) { verbs.append(("chat.N", "open one of those chats")) }
            let kind = contact.kind ?? "agent"
            observed?(world, now, [healthID])
            if !workspace.previewing, contact.kind == "routine", !answers.isEmpty {
                do { try workspace.ports.conversations.shown(answers: answers, peer: contact.id, scope: scope, dataRoot: dataRoot) }
                catch {
                    let repair = """
                        Contact \(owner)'s reply handover evidence could not be read: \(error.localizedDescription). Repair the named contact or \
                        agents/grok-requests file while preserving its contents.
                        """
                    return screen([contact.name, "Reply handover unavailable"], [[readFailure(error, reason: "contact_request_unavailable",
                        remedy: Repair.remedy(owner: "Contact reply handover for " + owner, nextCall: nil, tap: repair, instruction: repair))]], verbs: [])
                }
            }
            return freshness(world) + "\n" + screen([contact.name.uppercased(), kind, state],
                [section("TALK", talk), section("LAST SEND", outcome), section("CONVERSATIONS", chatLines), issue.map { section("READ", [$0]) } ?? []],
                    verbs: verbs)
        } catch { return nameFailure(error) }
    }

    // MARK: Chat

    /// Bound chat rooms to six lines from the checked owner read; never quote the active chat back to itself.
    private static func chatRoom(workspace: WorkspaceOperation, _ id: String, title: String, dataRoot: URL, person: String, scope: String, issue: String?,
        value: JSONValue?,
        now: Date) async -> String? {
        do {
            if let issue {
                return screen([clip(title, 40), "unavailable"], [section("READ", [issue])],
                              verbs: [("conversations", "every chat, both directions")])
            }
            guard case .object(let result)? = value, result["conversation_session_id"] == .string(id),
                  case .array(let messages)? = result["messages"] else { return nil }
            let world = await readWorld(workspace: workspace, dataRoot, now: now)
            if let failure = world.sourceFailure("people", "contacts") { return screen(["CONVERSATION", "unavailable"], [[failure]], verbs: []) }
            let chat = world.chats.first { $0.id == id }
            let who = try withNames(workspace: workspace, dataRoot) { book in
                chat.flatMap { chat in world.contacts.first { $0.id == chat.who || $0.name.lowercased() == chat.who } }
                    .map { book.slug(id: $0.id, name: $0.name) }
            } ?? chat?.who ?? person
            var talk: [String]
            if id == scope {
                talk = ["this is the chat you are in"]
            } else {
                talk = messages.suffix(6).compactMap { message in
                    guard case .object(let row) = message, case .string(let text)? = row["text"] else { return nil }
                    let at = if case .string(let timestamp)? = row["timestamp"] { date(timestamp) } else { Optional<Date>.none }
                    // open() consumed each contact stamp; agent_id carries only the displayed bridge label.
                    let speaker: String = if row["role"] == .string("assistant") { "me" }
                        else if case .string(let principal)? = row["agent_id"] { world.contacts.first { $0.id == principal }?.name ?? principal }
                        else { person }
                    return line(at, speaker, text, now: now)
                }
                if messages.isEmpty { talk = ["no messages yet"] }
            }
            let header = [clip(chat?.title ?? title, 40), who] + (chat.map { [age(now.timeIntervalSince($0.at))] } ?? [])
            return freshness(world) + "\n" + screen(header, [section("TALK", talk), issue.map { section("READ", [$0]) } ?? []],
                verbs: (who == person ? [] : [(who + ".say", "sends them a message now (text)")]) + [("conversations", "every chat, both directions")])
        } catch { return nameFailure(error) }
    }

    /// Bound chat-tail reads and strip transport notes without inventing speaker identity.
    static func chatTail(_ id: String, dataRoot: URL, bytes: UInt64 = 98_304) throws -> [LogLine] {
        guard NativeAgentChatSessionID.normalizedPathComponent(id) != nil else { throw CocoaError(.fileReadInvalidFileName) }
        let url = dataRoot.appendingPathComponent("chat/messages/\(id).jsonl")
        // Widen past tool results, up to 2 MiB, until the other side's message is included.
        var size = bytes, tail = try logTail(url, bytes: size)
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return tail }
        guard let file = attributes[.size] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        while !tail.contains(where: { !$0.mine }), size < 2_097_152, file.uint64Value > size {
            size = min(size * 4, 2_097_152)
            tail = try logTail(url, bytes: size)
        }
        return tail
    }

    package typealias LogLine = ContactThread.Line

    static func logTail(_ url: URL, bytes: UInt64, humanOnly: Bool = false) throws -> [LogLine] {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch let error as CocoaError where error.isFileAbsent { return [] }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard let data = try ContactThread.read(handle, from: size > bytes ? size - bytes : 0) else {
            if size == 0 { return [] }
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard UInt64(data.count) >= min(size, bytes) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let completeEnd = data.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data.startIndex
        var lines = data[..<completeEnd].split(separator: UInt8(ascii: "\n"))
        if size > bytes, !lines.isEmpty { lines.removeFirst() }
        let rows = try lines.compactMap { line -> ContactThread.Line? in
            guard case .object(let object) = try JSONValue.parse(Data(line)) else { throw CocoaError(.fileReadCorruptFile) }
            let line = ContactThread.Line(object)
            guard line.role == "user" || line.role == "assistant" else { return nil }
            guard case .string? = object["id"], case .string? = object["content"], line.date != nil,
                  line.provenanceFailure == nil else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            return !humanOnly || line.human ? line : nil
        }
        return ContactThread.project(rows, style: .log)
    }

    /// Routine replies join by request conversation and run ID; cache bounded transcript tails until their sources change.
    package static func routineReplies(workspace: WorkspaceOperation, dataRoot: URL) async throws -> [LogLine] {
        let dir = dataRoot.appendingPathComponent("agents/grok-requests", isDirectory: true)
        let requests = try workspace.ports.conversations.answeredRequests(dataRoot: dataRoot)
            .compactMap { request -> (run: String, chat: String)? in
                guard let run = request.run, let chat = request.chat, NativeAgentChatSessionID.normalizedPathComponent(chat) != nil else { return nil }
                return (run, chat)
            }.prefix(5)
        let chats = Array(Set(requests.map { $0.chat })).sorted()
        let files = chats.map { dataRoot.appendingPathComponent("chat/messages/\($0).jsonl") }
        let runs = Set(requests.map { $0.run.uppercased() })
        return try await AgentMemo.shared.value(dataRoot.standardizedFileURL.path + "\u{0}routine",
                stamp: stamps(dir) + files.map(stamp)) {
            var seen: Set<String> = []
            return try files.flatMap { try logTail($0, bytes: 262_144) }
                .filter { !$0.mine && $0.run.map { runs.contains($0.uppercased()) } == true && seen.insert($0.text).inserted }
                .sorted { $0.at < $1.at }
        }
    }

    // MARK: Desk

    private static func deskRow(_ item: DeskItem, now: Date) -> String {
        pad("desk." + item.alias, 11) + clip(item.title, 50) + " · " + deskState(item)
            + (date(item.updatedAt).map { " " + age(now.timeIntervalSince($0)) } ?? "")
    }

    package static func deskState(_ item: DeskItem) -> String {
        // A newest stopped-run note keeps nonterminal work visibly blocked.
        if !item.status.isTerminal, item.status != .blocked, let last = item.notes.last?.text, last.hasPrefix("[blocked]") {
            return "blocked: " + clip(String(last.dropFirst(9)).trimmingCharacters(in: .whitespaces), 40)
        }
        if !item.status.isTerminal, item.waitingOn?.isEmpty == false { return item.statusDescription }
        return item.spokenStatus
    }

    private static func deskItemRoom(workspace: WorkspaceOperation, _ value: JSONValue, projection: WorkspacePage, dataRoot: URL, scope: String,
        now: Date) -> String? {
        guard case .object(let owner) = value, case .object(let item)? = owner["record"], let alias = item["alias"]?.stringValue else { return nil }
        func rows(_ value: JSONValue?) -> [[String: JSONValue]] { guard case .array(let rows)? = value else { return [] }; return rows.compactMap {
            if case .object(let row) = $0 { row } else { nil } } }
        let name = "desk." + alias, children = rows(owner["items"])
        var notes = rows(owner["notes"]).prefix(3).reversed().map { line(date($0["timestamp"]?.stringValue ?? ""), "", $0["text"]?.stringValue ?? "", now: now,
            talk: false) }
        if case .int(let count)? = owner["note_count"], count > 3 { notes.insert("+\(count - 3) earlier notes · \(name).more", at: 0) }
        var parts = children.prefix(6).map { pad("desk." + ($0["alias"]?.stringValue ?? ""), 11) + clip($0["title"]?.stringValue ?? "", 50) + " · " + (
            $0["display_status"]?.stringValue ?? "") }
        if case .int(let total)? = owner["total"], total > 6 { parts.append("+\(total - 6) more parts") }
        var names: [String: AgentWorkspaceAction] = [:], taken: Set<String> = ["note", "done", "status", "more"]
        let verbs = AgentWorkspaceReadiness.filter(workspace: workspace, projection).actions.map { button -> (String, String) in
            let verb = name + "." + word(button.label, room: "desk", taken: &taken)
            names[verb] = button.action; return (verb, button.label)
        }
        if !workspace.previewing { AgentNamed.shared.keep(dataRoot, names, room: name, scope: scope) }
        return screen([name, item["display_status"]?.stringValue ?? ""],
            [section("ITEM", [item["title"], item["summary"], item["blocked_reason"]].compactMap { $0?.stringValue }.map { clip($0, 160) }),
             section("INTENTION", intentionLines(item["intention"])), section("NOTES",
                notes), section("PARTS", parts)],
            verbs: [(name + ".note", "add a note (text)"), (name + ".done", "mark it done"), (name + ".status", "set its status (text)")] + verbs,
                back: "Back: home · desk.")
    }

    private static func deskRoom(workspace: WorkspaceOperation, dataRoot: URL, person: String, now: Date) async -> String? {
        let world = await readWorld(workspace: workspace, dataRoot, now: now)
        guard let state = world.desk else {
            return freshness(world) + "\n" + screen(["DESK", "unavailable"], [[world.deskFailure ?? failureFace(.object([
                "status": .string("pending"), "reason": .string("desk_read_pending"),
                "detail": .string("The retained Desk read is not available yet; counts are unknown."),
                "remedy": Repair.terminal(instruction: "Wait for the owner read to complete; no repair cause has been observed.")]))]], verbs: [])
        }
        let split = world.split
        func rows(_ items: [DeskItem], _ cap: Int) -> [String] {
            items.prefix(cap).map { deskRow($0, now: now) }
                + (items.count > cap ? ["+\(items.count - cap) more · app {page:\"home\", find:\"<words>\"} finds one"] : [])
        }
        let parked = split.parked.isEmpty ? []
            : ["\(split.parked.count) · untouched \(split.quietDays ?? DeskParking.quietDays)d+ · app {page:\"home\", find:\"<words>\"} finds one"]
        let owed = await owedRows(dataRoot, person: person, now: now)
        let plan = DeskSequencing.compute(state, now: now)
        let intentions = MyQueue.entries(state).filter { $0.item.project == MyQueue.project }.flatMap {
            intentionLines(MyQueue.readout($0, in: state, plan: plan.byHandle[$0.item.handle]))
        }
        return freshness(world) + "\n" + screen(["DESK", "\(split.active.count) active", "\(split.parked.count) parked"] + state.boardCountSummary.components(
            separatedBy: "; ")
                + (split.waiting.isEmpty ? [] : ["\(split.waiting.count) wait on \(person)"]),
            [section("OWED", owed.agent), section("WAITING", owed.person + rows(split.waiting, 5)), section("ACTIVE", rows(split.active, 10)), section("PARKED",
                parked),
             section("MY QUEUE", intentions),
             section("ACTIONS", ["desk.wait {handle, on:\"<person>\", note?} · on:\"owner\" waits on the owner",
                 "ledger.list is the shared task ledger, a separate list from this Desk"])],
            verbs: [("desk.N", "open an item"), ("desk.N.note", "add a note (text)"), ("desk.N.done", "mark one done"), ("desk.add", "add work (form)")])
    }

    private static func intentionLines(_ value: JSONValue?) -> [String] {
        guard let value else { return [] }
        guard case .object(let row) = value, let name = row["name"]?.stringValue,
              let words = row["words"]?.stringValue, let filed = row["filed_at"]?.stringValue,
              let condition = row["when"]?.stringValue, case .array(let waits)? = row["waits_on"] else {
            return ["Intention details unavailable; read desk.read for the current record."]
        }
        return [name + " · " + words, "  filed " + filed + " · condition " + condition]
            + waits.compactMap { $0.stringValue.map { "  waits on " + $0 } }
    }

    // MARK: Helpers

    /// Busy helpers lead, then newest runs, so active work stays visible.
    private static func helpersRoom(workspace: WorkspaceOperation, dataRoot: URL, person: String, now: Date) async -> String {
        do {
            let world = await readWorld(workspace: workspace, dataRoot, now: now)
            if let failure = world.sourceFailure("bots", "running helpers") { return screen(["HELPERS", "unavailable"], [[failure]], verbs: []) }
            let botsState=world.unread.contains("bots") ? "unavailable" : world.pending.contains("bots") ? "stale" : "available"
            let runningState=world.unread.contains("running helpers") ? "unavailable" : world.pending.contains("running helpers") ? "stale" : "available"
            if botsState == "unavailable" {
                return freshness(world)+"\n"+screen(["HELPERS","unavailable"],[["Helper definitions and shelf source unavailable."]],verbs:[])
            }
            var bindings: [String:(name:String,state:String)] = [:]
            let facts: [JSONValue] = try withNames(workspace: workspace, dataRoot) { book in
                world.bots.map { bot in
                    let entry=world.latest[bot.id], running=world.running.contains(bot.id)
                    var state="idle"
                    if runningState == "unavailable" { state="run status unavailable" }
                    else if running { state="⟳ running" }
                    else if let entry {
                        switch entry.runtimeStatus {
                        case .completed:
                            state = switch entry.runHealth {
                            case .ok: "✓ ok"
                            case .nothingNew: "○ nothing new"
                            case .partial: "~ partial"
                            case .failed: "✗ failed"
                            }
                        case .failed: state="✗ failed"
                        case .stopped: state="✗ stopped"
                        case .interrupted: state="✗ interrupted"
                        case .waitingForApproval: state="waiting approval"
                        case .waitingOnPerson: state="waiting on "+person
                        }
                    }
                    if bot.paused { state += " · paused" }
                    let key=bot.id.uuidString
                    bindings[key]=(book.slug(id:"bot:"+key,name:bot.name),state)
                    return .object(["key":.string(key),"running":runningState == "unavailable" ? .null : .bool(running),"paused":.bool(bot.paused),
                        "runAt":entry.map { .double($0.runAt.timeIntervalSince1970) } ?? .null,
                        "age":entry.map { .string(age(now.timeIntervalSince($0.runAt))) } ?? .null,
                        "cadence":.string(clip(StandingBotSchedule.words(bot.cadence),40))])
                }
            }
            do {
                let result=await workspace.ports.tools.readoutFace(.object(["mode":.string("helpersRoom"),"rows":.array(facts),
                    "sources":.object(["bots":.string(botsState),"running":.string(runningState)])]),dataRoot:dataRoot)
                let face: PartFace
                switch result {
                case .success(let value): face=value
                case .failure(let error): throw error
                }
                let rows=try face.sections.filter { $0.id.hasPrefix("helpers:") }.flatMap(\.rows).map { row -> (name:String,text:String) in
                    if let bound=bindings[row.id] { return (bound.name,clip(row.title,max(0,87-bound.state.count))+" · "+bound.state) }
                    throw AgentWorkspaceFailure(message:"Helper face named an unbound helper.")
                }
                let targets=["open":"<name>","run":"<name>.run","say":"<name>.say","settings":"<name>.settings"]
                let verbs=try (face.sections.first { $0.id == "verbs" }?.rows ?? []).map { verb -> (String,String) in
                    if let target=targets[verb.id] { return (target,verb.title) }
                    throw AgentWorkspaceFailure(message:"Helper face named an unbound action.")
                }
                let width=min(20,(rows.map(\.name.count).max() ?? 0)+2)
                let availability=runningState == "unavailable" ? "\nRunning helper source unavailable." : ""
                let header=face.sections.first { $0.id == "header" }?.rows.map(\.title) ?? []
                let empty=face.sections.first { $0.id == "empty" }?.rows.map(\.title) ?? []
                return freshness(world)+availability+"\n"+screen(header,
                    [rows.isEmpty ? empty : rows.map { pad(clip($0.name,30),width)+$0.text }],verbs:verbs)
            } catch {
                return freshness(world)+"\n"+screen(["HELPERS","unavailable"],[[error.localizedDescription]],verbs:[])
            }
        } catch { return nameFailure(error) }
    }

    // MARK: People

    private static func peopleRoom(workspace: WorkspaceOperation, dataRoot: URL, scope: String, now: Date, observed: ((AgentWorld, Date,
        Set<String>) -> Void)?) async -> String {
        let world = await readWorld(workspace: workspace, dataRoot, now: now)
        if let failure = world.sourceFailure("people", "contacts") { return screen(["PEOPLE", "unavailable"], [[failure]], verbs: []) }
        let (cells, needs, _, health) = peopleRows(workspace: workspace, world, dataRoot: dataRoot, now: now, scope: scope, limit: .max)
        let width = min(20, (cells.map(\.name.count).max() ?? 0) + 2)
        observed?(world, now, health)
        return freshness(world) + "\n" + screen(["PEOPLE", "\(cells.count) contact\(cells.count == 1 ? "" : "s")"] + (needs.isEmpty ? []
            : ["\(needs.count) ask for input"]),
            [cells.isEmpty ? ["no one yet · item \"connections\" adds someone"] : cells.map { pad(clip($0.name, 30), width) + clip($0.state, 80) }],
            verbs: [("<name>", "open their conversation"), ("<name>.say", "sends a message now; queues behind a pending reply (text)"), ("conversations",
                "every chat, both directions")])
    }

    // MARK: Conversations

    /// One row per verified identity, opening its continuous contact thread.
    private static func conversationsRoom(workspace: WorkspaceOperation, dataRoot: URL, person: String, scope: String, now: Date,
        page: Int = 0) async -> String {
        do {
            let world = await readWorld(workspace: workspace, dataRoot, now: now)
            if let failure = world.sourceFailure("people", "contacts") { return screen(["CONVERSATIONS", "unavailable"], [[failure]], verbs: []) }
            func who(_ record: AgentConversationRecord) -> String {
                let agent = record.agent
                if agent.lowercased().hasPrefix("bot:"), let id = UUID(uuidString: String(agent.dropFirst(4))) { return "bot:" + id.uuidString }
                let identity = world.identity.canonical(agent)
                return world.contacts.first { world.identity.canonical($0.id) == identity }?.id ?? agent
            }
            var order: [String] = [], groups: [String: [AgentConversationRecord]] = [:]
            for record in world.records.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                let id = who(record)
                if groups[id] == nil { order.append(id) }
                groups[id, default: []].append(record)
            }
            // Twelve contacts a page; labels do not split a contact's thread.
            let shown = Array(order.dropFirst(page * 12).prefix(12))
            var named: [String: AgentWorkspaceAction] = [:]
            let rows: [(String, String)] = try withNames(workspace: workspace, dataRoot) { book in
                shown.compactMap { id in
                    guard let records = groups[id], let record = records.first else { return nil }
                    let slug = book.slug(id: id, name: record.name)
                    var state: String
                    if id.hasPrefix("bot:"), let uuid = UUID(uuidString: String(id.dropFirst(4))), let bot = world.bots.first(where: { $0.id == uuid }) {
                        state = helperState(bot, entry: world.latest[uuid], running: world.running.contains(uuid), person: person, now: now)
                    } else if id.hasPrefix("peer:"), !world.contacts.contains(where: { $0.id == id || $0.agents.contains(id) }) {
                        state = "disconnected · last send " + age(now.timeIntervalSince(record.exchanges?.last?.sentAt ?? record.operationStartedAt ?? record
                            .updatedAt)) + " ago"
                    } else {
                        let contact = Contact(id: id, name: record.name, kind: nil)
                        // The same source home uses: their newest bridge chat when it is newer.
                        let chat = world.chats.first { $0.id != scope && world.identity.canonical($0.who) == world.identity.canonical(id) }
                        state = AgentScreen.state(contact, record: record, chat: chat, answered: world.answered, now: now).text
                    }
                    return (slug, clip(record.name, 30) + " · " + state)
                }
            }
            if page > 0 { named["conversations.previous"] = .open(.conversations(page: page - 1)) }
            if order.count > (page + 1) * 12 { named["conversations.more"] = .open(.conversations(page: page + 1)) }
            if !workspace.previewing { AgentNamed.shared.keep(dataRoot, named, room: "conversations", scope: scope) }
            let width = min(20, (rows.map(\.0.count).max() ?? 0) + 2)
            var verbs = [("<name>", "open the conversation"), ("<name>.say", "sends a message now; queues behind a pending reply (text)")]
            if order.count > (page + 1) * 12 { verbs.append(("conversations.more", "the next \(min(12, order.count - (page + 1) * 12)) older")) }
            if page > 0 { verbs.append(("conversations.previous", "newer ones")) }
            verbs.append(("people", "everyone I can reach"))
            return freshness(world) + "\n" + screen(["CONVERSATIONS", "\(order.count)"] + (order.count > 12
                ? ["\(page * 12 + 1)–\(page * 12 + shown.count) shown"] : []),
                [rows.isEmpty ? ["none yet"] : rows.map { pad(clip($0.0, 30), width) + $0.1 }], verbs: verbs)
        } catch { return nameFailure(error) }
    }

    /// Use short civil timestamps for readable recency.
    static func friendly(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let calendar = Calendar.current
        formatter.dateFormat = "h:mm a"
        let time = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "today " + time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday " + time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "tomorrow " + time }
        if abs(now.timeIntervalSince(date)) < 6 * 86400 { formatter.dateFormat = "EEE"; return formatter.string(from: date) + " " + time }
        formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d yyyy"
        return formatter.string(from: date)
    }

    // MARK: Mac

    /// The person's front app, or the screensaver when the screen is covered.
    static func macFront(_ person: String, session: MacSessionState? = nil) async -> String {
        let session = session ?? defaultMacSessionStateSource().currentState()
        guard session.sessionReadable else { return "Mac screen session unavailable; restore session access before reading it again." }
        guard session.onConsole else { return "Another macOS session is active; this session's front app is not a current screen reading." }
        // Only failed wake evidence establishes a password lock; a covered session alone is the screensaver.
        if session.screenIsLocked {
            return "\(person)'s screen: " + (MacScreenLock.wakeFailed
                ? "locked (a password is up; screen work waits for \(person))"
                : "screensaver, not locked (mac.look and mac actions wake it with a harmless nudge; direct app scripts see no windows until wake)")
        }
        let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName }
        return "\(person)'s front: " + clip(front ?? "unknown", 40)
    }

    /// The Mac room lists state without AX walks; only explicit mac.look reads windows, excluding the agent's own app.
    private static func macRoom(dataRoot: URL, person: String, now: Date) async -> String {
        let front = await macFront(person), opened = AgentOpened.shared.recordedLaunches()
        let running: [String] = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && !PersonOnlyWindows.isOwnProcess($0.processIdentifier) && !$0.isTerminated }
                .compactMap { app in app.localizedName.map {
                    clip($0, 24) + (opened[app.processIdentifier] == $0 ? " (opened by me)" : "")
                } }
        }
        let names = Set(running).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var rows: [String] = [], row = ""
        for name in names.prefix(24) {
            if !row.isEmpty, row.count + name.count > 64 { rows.append(row + ","); row = "" }
            row += (row.isEmpty ? "" : ", ") + name
        }
        if !row.isEmpty { rows.append(row + (names.count > 24 ? " +\(names.count - 24) more" : "")) }
        let touchedRows: [Touched]
        do { touchedRows = try touched(dataRoot: dataRoot, now: now) }
        catch { return screen(["MAC", "recorded windows unavailable"], [[nameFailure(error)]], verbs: []) }
        let mine = touchedRows.map { window in
            pad(clip(window.app, 24), 14) + ([window.kind, window.readout.map { "reads " + clip($0, 24) }].compactMap { $0 }
                + ["\(age(now.timeIntervalSince1970 - window.at)) ago"]).joined(separator: " · ")
        }
        return screen(["MAC", front],
            [section("I READ OR ACTED IN", mine.isEmpty ? ["none in the last \(Int(touchedHours)) hours"] : mine), section("RUNNING", rows)],
            verbs: [("mac.look <app>", "read that app's window where it sits"), ("mac.go <app>", "open that app behind; front:true brings it forward")])
    }

    // MARK: My windows (data/her_screen/touched.json)

    /// Keep only app kind and short non-content readouts; window titles must not be retained.
    package struct Touched: Codable, Equatable { package var app: String; var kind: String?; var readout: String?; var at: Double }

    static let touchedHours: Double = 4

    package static func touch(dataRoot: URL, app: String, kind: String?, readouts: [String], before: [String] = [], now: Date = Date()) throws {
        let name = clip(app, 40), at = now.timeIntervalSince1970
        let word = kind.map { $0.contains("AXSheet") ? "sheet" : $0.contains("Dialog") ? "dialog" : $0.contains("Floating") ? "panel" : "window" }
        // Only digits, operators and short units qualify as readouts; strip invisible format marks and prefer changed results over expressions.
        func value(_ raw: String) -> String? {
            let text = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.properties.generalCategory != .format }))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.count <= 24 && text.range(of: #"^[\d\s.,:+\-−×÷=%$€£()/]*\d[\d\s.,:+\-−×÷=%$€£()/]*[a-zA-Z%°]{0,3}$"#,
                                                  options: .regularExpression) != nil ? text : nil
        }
        let values = readouts.compactMap(value), earlier = Set(before.compactMap(value))
        func result(_ text: String) -> Bool { text.dropFirst().range(of: #"[+\-−×÷=/]"#, options: .regularExpression) == nil }
        let changed = values.filter { !earlier.contains($0) }
        let short = changed.first(where: result) ?? changed.first ?? values.first(where: result) ?? values.first
        try AgentTouched.shared.update(dataRoot) { rows in
            rows.removeAll { ($0.app == name && $0.kind == word) || at - $0.at > touchedHours * 3600 }
            rows.insert(Touched(app: name, kind: word, readout: short, at: at), at: 0)
            if rows.count > 8 { rows.removeLast(rows.count - 8) }
        }
    }

    package static func touched(dataRoot: URL, now: Date) throws -> [Touched] {
        try AgentTouched.shared.rows(dataRoot).filter { now.timeIntervalSince1970 - $0.at <= touchedHours * 3600 }
    }

    // MARK: Places and lists as text

    static func textRoomName(_ location: AgentWorkspaceLocation) -> String? {
        switch location {
        case .arrivals: return "arrivals"
        case .openPlaces: return "windows"
        case .workOverview: return "work"
        case .conversations: return "conversations"
        case .area(let id): return id == "notify" ? id : placeNames.first { $0.value == id }?.key ?? id
        case .page(let inner, _): return textRoomName(inner)
        case .record(let tool, _, _): return commsFamily[tool] ?? coreRooms[tool]
        default: return nil
        }
    }

    private static let chrome: Set<String> = ["This work", "Workspace home", "Find", "Arrivals", "Open places",
        "Show workspace controls", "Hide workspace controls", "Conversations", "Saved workspaces", "Keep this workspace as…",
        "Find an action", "Find work", "Find a document", "People and agents", "Keep with this work", "Put selected source away"]

    /// Persist only owner read identity so display metadata cannot redirect stable names.
    static func key(_ place: AgentWorkspaceLocation) -> String? {
        guard case .record(let tool, let input, _) = place else { return nil }
        // A mail row's inbox position moves as mail arrives; its name must not.
        let stable: [String: JSONValue]
        if tool == "contacts_search", let id = input["identifier"]?.stringValue, !id.isEmpty {
            // Exact-card reads use only the Contacts owner's identifier. A query (including retained display-name queries) is not identity.
            stable = ["identifier": .string(id)]
        } else {
            stable = input.filter { $0.key != "position" }
        }
        return try? JSONValue.object(["tool": .string(tool), "input": .object(stable)]).serialize(pretty: false)
    }

    /// Compare owner locators while retaining already-issued numbers.
    static func recordIdentity(_ key: String) -> String? {
        guard case .object(let row)? = try? JSONValue.parse(Data(key.utf8)),
              let tool = row["tool"]?.stringValue, let input = row["input"]?.objectValue else { return nil }
        return self.key(.record(tool: tool, input: input, title: ""))
    }

    static func itemPlace(workspace: WorkspaceOperation, _ room: String, _ n: Int, dataRoot: URL) throws -> AgentWorkspaceLocation? {
        let retained = try withNames(workspace: workspace, dataRoot) { book in
            (book.id("item." + room, n), book.titles?["item." + room + ":" + String(n)])
        }
        guard let id = retained.0,
              case .object(let row)? = try? JSONValue.parse(Data(id.utf8)),
              case .string(let tool)? = row["tool"], case .object(let input)? = row["input"] else { return nil }
        guard let title = retained.1 ?? row["title"]?.stringValue else {
            throw NameFailure("The retained item has no display metadata: \(room).\(n)")
        }
        return .record(tool: tool, input: input, title: title)
    }

    static func textRoom(workspace: WorkspaceOperation, _ room: String, place: AgentWorkspaceLocation, projection: WorkspacePage,
                         status: JSONValue, dataRoot: URL, scope: String = "", now: Date = Date()) -> String {
        do {
            let projection = AgentWorkspaceReadiness.filter(workspace: workspace, projection)
            func text(_ value: JSONValue?) -> String? {
                switch value {
                case .string(let text)?: return nonEmpty(text)
                case .int(let n)?: return String(n)
                case .double(let n)?: return String(n)
                case .bool(let b)?: return b ? "yes" : nil
                default: return nil
                }
            }
            let fields: [(key: String, lead: String)] = [("sender", ""), ("from", ""), ("who", ""), ("with", ""), ("kind", ""), ("site", ""),
                ("startAt", ""), ("start", ""), ("date", ""), ("when", ""), ("dueAt", "due "), ("due", "due "), ("updated", ""),
                ("state", ""), ("summary", ""), ("snippet", ""), ("preview", ""), ("path", ""), ("url", ""), ("source", "")]
            func summary(_ content: JSONValue, title: String) -> String {
                if case .string(let text) = content { return firstLine(text) }
                guard case .object(let row) = content else { return "" }
                var parts = fields.compactMap { field -> String? in
                    guard var value = text(row[field.key]).map(firstLine), !value.isEmpty, value != title,
                          value != AgentWorkspaceNavigation.referenceState else { return nil }
                    // A preview that only repeats the (clipped) title says nothing new.
                    let bare = title.hasSuffix("…") ? String(title.dropLast()) : title
                    if !bare.isEmpty, value.hasPrefix(bare) || (value.count >= 20 && bare.hasPrefix(value)) { return nil }
                    if let at = date(value) { value = friendly(at, now: now) }
                    else if field.key == "sender", let angle = value.firstIndex(of: "<"), angle > value.startIndex {
                        value = value[..<angle].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    }
                    return field.lead + value
                // Allow a sentence of search snippet so selection has meaningful evidence.
                }.prefix(3).map { clip($0, room == "research" ? 110 : 40) }
                if row["unread"] == .bool(true) { parts.append("unread") }
                return parts.joined(separator: " · ")
            }
            let status = text(status) ?? "ok"
            let reply = ToolResult(projection.content)
            let fine = reply.hasReadEvidence()
            let content: [String: JSONValue] = if case .object(let row) = projection.content { row } else { [:] }
            func fieldsOf(_ item: AgentWorkspaceItem) -> [String: JSONValue] { if case .object(let row) = item.content { row } else { [:] } }

            // Only owner completion state and matching owner identities can fold rows.
            var items: [(item: AgentWorkspaceItem, times: Int)] = []
            for item in projection.items.dropFirst(projection.page * 8).prefix(8) {
                let row = fieldsOf(item)
                let showCompletedReminder = room == "reminders" && (content["includeCompleted"] == .bool(true) || content["reminder"] != nil)
                if row["completed"] == .bool(true) && !showCompletedReminder { continue }
                // Emails, notes and reminders alike still have distinct identities.
                if let last = items.last, let first = item.actions.first, let prior = last.item.actions.first,
                   case .open(.record) = first.action, case .open(.record) = prior.action,
                   identity(first.action, label: first.label) == identity(prior.action, label: prior.label) {
                    items[items.count - 1].times += 1
                }
                else { items.append((item, 1)) }
            }
            // Keep each row's stable action binding; persist only plain owner reads.
            let roomVerbs = projection.actions.map(\.label)
            var names: [String: AgentWorkspaceAction] = [:], pages: [String: String] = [:]
            var rowVerb: (String, String)?
            let trouble = try room != "connections" ? [:] : sendTrouble(workspace: workspace, agents: items.compactMap { entry -> String? in
                guard case .open(.record("agent_read", let input, _))? = entry.item.actions.first?.action, case .string(let agent)? = input["agent"] else {
                    return nil }
                return agent
            }, dataRoot: dataRoot, now: now)
            let lines: [(String, String)] = try withNames(workspace: workspace, dataRoot) { book in
                let present = Set(items.compactMap { $0.item.actions.first.map { identity($0.action, label: $0.label) } })
                return try items.enumerated().map { offset, entry in
                    let item = entry.item
                    var name = "·"
                    // A row whose first action changes state opens a page of its verbs.
                    let opens = item.actions.first.map { opening($0.action) } ?? true
                    if let first = item.actions.first {
                        let number = room == "windows" ? projection.page * 8 + offset + 1
                            : try book.number("item." + room, id: identity(first.action, label: first.label), title: item.title) { present }
                        name = room + ".\(number)"
                        if opens { names[name] = first.action }
                    }
                    // Avoid repeating room-wide verbs on every row.
                    var more = "", own: [(String, String)] = []
                    var taken: Set<String> = []
                    for (index, button) in item.actions.enumerated() where index == 0 ? !opens : !roomVerbs.contains(button.label) {
                        let verb = name + "." + word(button.label, room: room, taken: &taken)
                        names[verb] = button.action
                        more += " · " + verb + (button.needsText ? " (text)" : "")
                        own.append((verb, clip(button.label, 56) + (button.needsText ? " (text)" : "")))
                        if index == 0, rowVerb == nil { rowVerb = (room + ".N." + String(verb.split(separator: ".").last ?? ""), clip(button.label, 56)) }
                    }
                    var about = summary(item.content, title: item.title)
                    if case .open(.record("agent_read", let input, _))? = item.actions.first?.action, case .string(let agent)? = input["agent"],
                       let warning = trouble[agent.lowercased()] { about = about.isEmpty ? warning : about + " · " + warning }
                    if !opens {
                        pages[name] = screen([name, clip(item.title, 60)], [about.isEmpty ? [] : [clip(about, 110)]], verbs: own, back: "Back: \(room).")
                    }
                    if room == "notes", fieldsOf(item)["status"] == .string("unavailable") {
                        return (name, clip(item.title, 60) + "\n"
                            + wrap(failureFace(item.content), width: 100).map { "      " + $0 }.joined(separator: "\n"))
                    }
                    // A non-ok Doctor check keeps its whole recovery detail, wrapped.
                    if room == "status", !item.title.hasSuffix(" · ok"), case .string(let detail)? = fieldsOf(item)["summary"], !detail.isEmpty {
                        return (name, clip(item.title, 60) + more + "\n" + wrap(detail, width: 100).map { "      " + $0 }.joined(separator: "\n"))
                    }
                    return (name, clip(item.title, 60) + (entry.times > 1 ? " ×\(entry.times)" : "") + (about.isEmpty ? "" : " · " + about) + more)
                }
            }
            let cacheRoom = room == "windows" ? scope + "\u{0}" + room : room
            if !workspace.previewing {
                AgentItemPages.shared.keep(dataRoot, pages, room: cacheRoom, scope: room == "windows" ? scope : nil)
            }
            var taken: Set<String> = [], verbs: [(String, String)] = []
            if items.contains(where: { !$0.item.actions.isEmpty }) { verbs.append((room + ".N", "open one")) }
            if let rowVerb { verbs.append(rowVerb) }
            if room != "mail" || (!items.isEmpty && items.allSatisfy({
                guard (fieldsOf($0.item)["scope"] ?? content["scope"] ?? .string("inbox")) == .string("inbox") else { return false }
                if case .string(let expectedID)? = fieldsOf($0.item)["expected_message_id"] { return !expectedID.isEmpty } else { return false }
            })) { verbs += (commsItemVerbs[room] ?? []).filter { AgentWorkspaceReadiness.allows(workspace: workspace, tool: $0.tool) }.map { ($0.name,
                $0.about) } }
            if room == "mail", !items.isEmpty {
                if AgentWorkspaceReadiness.allows(workspace: workspace, tool: "mail.read") {
                    verbs.append(("mail.read-batch", "read 1–10 messages (append mail.N names)"))
                }
                if content["scope"] != .string("sent"), AgentWorkspaceReadiness.allows(workspace: workspace, tool: "mail.triage") {
                    verbs += [("mail.mark-read-batch", "mark selected messages read (append mail.N names)"),
                              ("mail.flag-batch", "flag selected messages (append mail.N names)"),
                              ("mail.unflag-batch", "unflag selected messages (append mail.N names)"),
                              ("mail.archive-batch", "archive selected messages (append mail.N names)")]
                }
            }
            var buttons = projection.actions.filter {
                !chrome.contains($0.label) || (room == "work" && ["Keep this workspace as…", "Saved workspaces"].contains($0.label))
            }
            let source: AgentWorkspaceLocation = if case .page(let inner, _) = place { inner } else { place }
            // One "more": the room's own pages first, the owner's older ones after the last.
            if (projection.page + 1) * 8 < projection.items.count {
                buttons.removeAll { $0.label.hasPrefix("More") }
                buttons.append(.init(label: "More", action: .open(.page(source, projection.page + 1))))
            }
            if projection.page > 0 { buttons.append(.init(label: "Previous", action: .open(.page(source, projection.page - 1)))) }
            for button in buttons.prefix(10) {
                let name = room + "." + word(button.label, room: room, taken: &taken)
                names[name] = button.action
                verbs.append((name, clip(button.label, 56) + (button.needsText ? " (text)" : "")))
            }
            if !workspace.previewing { AgentNamed.shared.keep(dataRoot, names, room: room, scope: scope) }

            let width = min(22, (lines.map(\.0.count).max() ?? 0) + 2)
            let count = projection.items.count
            let unread = projection.items.filter { fieldsOf($0)["unread"] == .bool(true) }.count
            var header = [room.uppercased()] + roomCounts(content, fine: fine, status: status, listed: count, unreadRows: unread, page: projection.page)
            if fine, content["status"] == .string("partial") { header.append("partial") }
            // Windows describe this work's retained places, not Mac apps.
            if room == "windows" { header += ["the work I'm on, drafts and pages I acted in", "a read doesn't stay open", "not Mac apps"] }
            // Bind numbers to item identities, never positions except Windows; disclose gaps so retained names cannot silently retarget.
            if room != "windows", lines.contains(where: { $0.0 != "·" }) { header.append(numbersNote) }
            // Partial-page messages name coverage gaps; clipping can hide an account.
            var about = fine ? ["message", "detail", "about", "note", "error"].compactMap { text(content[$0]) }.prefix(2).flatMap {
                content["status"] == .string("partial") ? wrap($0, width: 100) : [clip($0, 110)]
            }
                : [failureFace(.object(content))]
            if notConnected(content) {
                header = [room.uppercased(), "not connected"]
                about = [failureFace(.object(content))]
            }
            return screen(header, [lines.isEmpty && about.isEmpty ? ["nothing here"] : lines.map { pad(clip($0.0, 24), width) + $0.1 },
                                   section(fine ? "ABOUT" : "READ", about),
                                   section("GAPS", pageGaps(projection.content))], verbs: verbs)
        } catch { return nameFailure(error) }
    }

    /// Per-item and engine failures remain named beside the readable page.
    static func pageGaps(_ content: JSONValue) -> [String] {
        ["gaps", "unresponsive_engines"].flatMap { key -> [String] in
            guard case .array(let gaps)? = content.objectValue?[key] else { return [] }
            return gaps.compactMap(\.stringValue).flatMap { wrap($0) }
        }
    }

    /// Keep action identity stable across renders so issued row numbers retain their binding.
    private static func identity(_ action: AgentWorkspaceAction, label: String) -> String {
        func input(_ value: [String: JSONValue]) -> String { (try? JSONValue.object(value).serialize(pretty: false)) ?? "" }
        switch action {
        case .open(let place): return key(place) ?? "open:" + (AgentWorkspaceNavigation.placeIdentity(place) ?? place.title)
        case .window(let inner): return identity(inner, label: label)
        case .openArrival(let id): return "arrival:" + id
        case .perform(let tool, let bound, _, _, _): return "perform:" + tool + input(bound)
        case .configure(let tool, let bound, _): return "configure:" + tool + input(bound)
        case .message(let agent, let conversation, _, _): return "message:" + agent + "|" + (conversation ?? "")
        case .followUpSavedReply(let reply): return "followup:" + reply.entryID
        default: return "label:" + label
        }
    }

    /// Disambiguate colliding verbs so a label cannot overwrite another action.
    private static func word(_ label: String, room: String, taken: inout Set<String>) -> String {
        let skip: Set<String> = ["a", "an", "the", "to", "in", "my", "of", "for", "this", "that", "one", "your", "and", "or",
                                 "named", "with", "from", "items", "all", room, String(room.dropLast())]
        let words = label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 1 && !skip.contains($0) }
        var name = words.first ?? "go"
        if taken.contains(name), words.count > 1 { name += "-" + words[1] }
        var candidate = name, n = 2
        while taken.contains(candidate) { candidate = name + "\(n)"; n += 1 }
        taken.insert(candidate)
        return candidate
    }

    /// Resolve verbs from current memory, and only plain owner reads from persisted names.
    static func namedAction(workspace: WorkspaceOperation, _ name: String, dataRoot: URL, scope: String = "") throws -> AgentWorkspaceAction? {
        // Cached verbs are names too: a damaged book cannot leave a previously displayed executable alias available while new aliases are refused.
        try withNames(workspace: workspace, dataRoot) { _ in () }
        if let action = AgentNamed.shared.action(dataRoot, name, scope: scope) { return action }
        if name.hasPrefix("windows.") { return nil }
        guard let dot = name.lastIndex(of: "."), let n = Int(name[name.index(after: dot)...]),
              let place = try itemPlace(workspace: workspace, String(name[..<dot]), n, dataRoot: dataRoot) else { return nil }
        return .open(place)
    }

    // MARK: The agent's own app

    /// Refuse the agent's own app and Chat/current/script reads to protect private conversation state; execution rechecks the recipient after focus changes.
    package static func ownAppRefusal(tool: String, input: [String: JSONValue]) async -> JSONValue? {
        // The app door: a read of Chat or of the page on screen, and a script (which can read either), stay out of the workspace too.
        if tool == "app" {
            let page: String = if case .string(let text)? = input["page"] { text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } else { "" }
            let script: Bool = if case .string(let text)? = input["script"] { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } else { false }
            return script || page == "current" || page.hasPrefix("chat") ? WorkspaceMacCall.refusal : nil
        }
        guard ["screen", "go", "act"].contains(tool) else { return nil }
        let value = tool == "go" ? input["name"] : input["app"]
        let named: String? = if case .string(let text)? = value, !text.trimmingCharacters(in: .whitespaces).isEmpty { text } else { nil }
        var own = false
        if let named {
            let normalized = named.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let wanted = normalized.hasSuffix(".app") ? String(normalized.dropLast(4)) : normalized
            own = await MainActor.run {
                NSWorkspace.shared.runningApplications.contains { app in
                    PersonOnlyWindows.isOwnProcess(app.processIdentifier)
                        && [app.localizedName, app.bundleIdentifier, app.executableURL?.lastPathComponent]
                            .compactMap { $0?.lowercased() }.contains(wanted)
                }
            }
        } else if tool != "go" {
            own = await MainActor.run { PersonOnlyWindows.isOwnProcess(NSWorkspace.shared.frontmostApplication?.processIdentifier) }
        }
        return own ? WorkspaceMacCall.refusal : nil
    }
}
