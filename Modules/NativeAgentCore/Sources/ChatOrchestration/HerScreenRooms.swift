import AppKit
import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import StandingBots

/// Rooms (her-screen Phase 1, 2026-09-23, Agent's first read): opening a name
/// shows a text screen in home's style. A header line (name · kind · state),
/// the room's own lines, then its verbs addressed by stable names, and
/// "Back: home." Never the old JSON or the places list. Everything is the
/// owners' own records, read after the ordinary owner read has run.
extension HerScreen {
    /// A room for this location, or nil where the old view still applies.
    /// `issue` is the owner read's failure, shown rather than hidden.
    static func room(_ location: AgentWorkspaceLocation, dataRoot: URL, scope: String, issue: String? = nil, value: JSONValue? = nil) async -> String? {
        if let comms = commsRoom(location, value: value, dataRoot: dataRoot, issue: issue) { return comms }
        if let read = buildRecordRoom(location, value: value, dataRoot: dataRoot, issue: issue) { return read }
        let now = Date(), person = names(dataRoot).person
        switch location {
        case .record("agent_read", let input, _):
            guard case .string(let agent)? = input["agent"], Set(input.keys).isSubset(of: ["agent", "conversation"]) else { return nil }
            if agent.lowercased().hasPrefix("bot:"), let id = UUID(uuidString: String(agent.dropFirst(4))) {
                return helperRoom(id, dataRoot: dataRoot, person: person, issue: issue, now: now)
            }
            let label: String? = if case .string(let value)? = input["conversation"] { value } else { nil }
            return await personRoom(agent, label: label, dataRoot: dataRoot, person: person, scope: scope, issue: issue, now: now)
        case .record("desk_read", let input, _):
            guard case .string(let handle)? = input["handle"], Set(input.keys).isSubset(of: ["handle", "structured"]) else { return nil }
            return await deskItemRoom(handle, dataRoot: dataRoot, person: person, now: now)
        case .record("chat_conversations", let input, let title):
            guard case .string(let id)? = input["conversation_session_id"], input.count == 1 else { return nil }
            return await chatRoom(id, title: title, dataRoot: dataRoot, person: person, scope: scope, issue: issue, now: now)
        case .area("ongoing"):
            return await deskRoom(dataRoot: dataRoot, person: person, now: now)
        case .area("computer"):
            return await macRoom(dataRoot: dataRoot, person: person, now: now)
        case .area("helpers"):
            return await helpersRoom(dataRoot: dataRoot, person: person, now: now)
        case .people(page: 0):
            return await peopleRoom(dataRoot: dataRoot, scope: scope, now: now)
        case .conversations(let page):
            return await conversationsRoom(dataRoot: dataRoot, person: person, scope: scope, now: now, page: page)
        case .area("files"), .area("code"), .area("github"): return await buildRoom(location, dataRoot: dataRoot, now: now)
        case .record("browser.chrome_snapshot", let input, _): return tabRoom(input, dataRoot: dataRoot, scope: scope, issue: issue, now: now)
        case .area("browser"): return browserRoom(dataRoot: dataRoot, scope: scope, person: person, now: now)
        case .area("x"): return xRoom(dataRoot: dataRoot)
        // Desk walk 4: a search came back as the raw frame. Its results are
        // the research room's rows (research.N reads one, .chrome opens it).
        case .record(AgentWorkspaceKnowledge.webSearchTool, _, _):
            guard let value else { return nil }
            // Failed whether the read said so (issue) or the result did (status, ok:false, error).
            let row: [String: JSONValue] = if case .object(let object) = value { object } else { [:] }
            let failed = issue != nil || row["ok"] == .bool(false) || (row["error"] != nil && row["error"] != .null)
                || [JSONValue.string("failed"), .string("error"), .string("unavailable")].contains(row["status"] ?? .null)
            return textRoom("research", place: location, projection: .project(location: location, result: value),
                            frame: .object(["status": .string(failed ? "failed" : "ok")]), dataRoot: dataRoot, now: now)
        default: return nil
        }
    }

    /// The agent's name and her person's, from the persona profile.
    static func names(_ dataRoot: URL) -> (agent: String, person: String) {
        let profile = (try? Data(contentsOf: dataRoot.appendingPathComponent("memory/profile.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return (clip(nonEmpty(profile["name"] as? String) ?? "Agent", 40), clip(nonEmpty(profile["userName"] as? String) ?? "Your person", 40))
    }

    static func screen(_ header: [String], _ sections: [[String]], verbs: [(String, String)], back: String = "Back: home.") -> String {
        let rule = String(repeating: "─", count: 61)
        // Names, titles and states can come from outside: each field is
        // defused and clipped here, whatever built it.
        var lines = [header.map { clip($0, 60) }.joined(separator: " · ")]
        for part in sections where !part.isEmpty { lines.append(rule); lines += part }
        lines.append(rule)
        let width = min(22, (verbs.map(\.0.count).max() ?? 0) + 2)
        lines += section("DO", verbs.map { pad(clip($0.0, 40), width) + clip($0.1, 60) })
        lines.append(back)
        return lines.joined(separator: "\n")
    }

    /// A TALK line: chat text as its first meaningful sentence, markdown off.
    private static func line(_ at: Date?, _ who: String, _ text: String, now: Date, talk: Bool = true) -> String {
        pad(at.map { age(now.timeIntervalSince($0)) } ?? "", 5) + pad(clip(who, 20), 10) + clip(talk ? sentence(text) : text, 80)
    }

    // MARK: Helper

    private static func helperRoom(_ id: UUID, dataRoot: URL, person: String, issue: String?, now: Date) -> String? {
        guard let bot = try? BotDefinitionStore(dataRoot: dataRoot).get(id) else { return nil }
        let slug = withNames(dataRoot) { $0.slug(id: "bot:" + id.uuidString, name: bot.name) }
        let shelf = ShelfStore(dataRoot: dataRoot)
        let running = (try? BotRunQueue(dataRoot: dataRoot).activeOrQueuedIDs())?.contains(id) == true
        let state = helperState(bot, entry: (try? shelf.latestEntries(botIDs: [id]))?.first, running: running, person: person, now: now)
        let cadence = StandingBotSchedule.words(bot.cadence)
        // A message to the helper (its .say / bot_ask) settles as a shelf entry
        // too. The entry says so (`asked`); older entries are known by the
        // conversation owner's own record of the ask: its entry id, or the
        // exchange whose send the entry started with.
        let entries = ((try? shelf.entriesByBot())?[id] ?? []).sorted { $0.runAt > $1.runAt }
        let records = ((try? AgentConversationStore(dataRoot: dataRoot).records()) ?? [])
            .filter { $0.agent.caseInsensitiveCompare("bot:" + id.uuidString) == .orderedSame }
        var askedIDs: Set<String> = [], sent: [Date] = []
        for record in records {
            let receipt = unwrap(record.receipt)
            for value in [receipt["entry_id"], receipt["message_id"], record.readInput?["message_id"]] {
                if case .string(let entry)? = value { askedIDs.insert(entry.uppercased()) }
            }
            sent += (record.exchanges ?? []).map(\.sentAt)
        }
        func asked(_ entry: ShelfEntry) -> Bool {
            entry.asked == true || askedIDs.contains(entry.id.uuidString)
                || sent.contains { entry.runAt >= $0 && entry.runAt.timeIntervalSince($0) < 3 }
        }
        let marks: [ShelfRunHealth: String] = [.ok: "✓", .nothingNew: "○", .partial: "~", .failed: "✗"]
        func rows(_ list: [ShelfEntry], _ mark: (ShelfEntry) -> String, more: String) -> [String] {
            list.prefix(4).map { pad(age(now.timeIntervalSince($0.runAt)), 7) + pad(mark($0), 3) + clip(sentence($0.headline), 78) }
                + (list.count > 4 ? ["+\(list.count - 4) \(more)"] : [])
        }
        let runs = entries.filter { !asked($0) }, talk = entries.filter(asked)
        return screen([bot.name.uppercased(), "helper", state] + (state.contains(cadence) ? [] : [cadence]),
            [section("ABOUT", [clip(firstLine(bot.brief), 90)]),
             section("RUNS", runs.isEmpty ? ["no runs yet"] : rows(runs, { marks[$0.runHealth] ?? "·" }, more: "earlier runs · action \"replies\"")),
             section("TALK", rows(talk, { _ in "↩" }, more: "earlier replies")),
             issue.map { section("READ", [clip($0, 100)]) } ?? []],
            verbs: [(slug + ".say", "ask it something (text)"), (slug + ".run", "run it once now"), (slug + ".settings", "change how it works")]
                + (bot.cadence == .manual ? [] : [bot.paused ? (slug + ".resume", "turn its schedule back on") : (slug + ".pause", "stop its scheduled runs")]))
    }

    // MARK: Person

    private static func personRoom(_ agent: String, label: String?, dataRoot: URL, person: String, scope: String, issue: String?, now: Date) async -> String? {
        let world = await readWorld(dataRoot, now: now)
        let (records, chats, everyone) = (world.records, world.chats, world.contacts)
        let oldName = records.first { $0.agent == agent }?.name
        let contact = everyone.first { $0.id.caseInsensitiveCompare(agent) == .orderedSame }
            ?? everyone.first { !$0.builtIn && oldName.map($0.name.caseInsensitiveCompare) == .orderedSame }
            ?? Contact(id: agent, name: records.first { $0.agent == agent }?.name ?? agent, builtIn: builtIns.contains(agent), kind: nil)
        let record = latest(contact, records: records, contacts: everyone, label: label)
        let theirs = chats.filter { $0.who == contact.id || $0.who == contact.name.lowercased() }
        let bare = Contact(id: contact.id, name: contact.name, builtIn: contact.builtIn, kind: nil)
        let state = state(bare, record: record, chat: theirs.first { $0.id != scope }, answered: world.answered, now: now).text
        let slug = withNames(dataRoot) { $0.slug(id: contact.id, name: contact.name) }

        var talk: [String] = []
        if let chat = theirs.first(where: { $0.id != scope }), chat.at > (record?.updatedAt ?? .distantPast) {
            // Its newest bridge chat other than the one she is in: that one is
            // already in front of her, so quoting it back only sent her on to
            // open the chat before it (chat.N) for what was actually going on.
            talk = chatTail(chat.id, dataRoot: dataRoot).suffix(6).map { line($0.at, $0.mine ? "me" : slug, $0.text, now: now) }
        }
        if talk.isEmpty, contact.kind == "routine" {
            // Its answers come back as chat turns, not in the send record:
            // her asks from the record, its replies from the chat, by time.
            let asks = (record?.exchanges ?? []).compactMap { exchange in exchange.prompt.map { (at: Optional(exchange.sentAt), text: $0, who: exchange.byPerson == true ? person : "me") } }
            let replies = await routineReplies(dataRoot: dataRoot).map { (at: $0.at, text: $0.text, who: slug) }
            if !replies.isEmpty { PeerDataTaint.markConsumed(peer: contact.id) }
            talk = (asks + replies).sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }.suffix(6)
                .map { line($0.at, $0.who, $0.text, now: now) }
        }
        let exchanges = talk.isEmpty ? record?.exchanges ?? [] : []
        if exchanges.count > 3 { talk.append("+\(exchanges.count - 3) earlier exchanges") }
        for exchange in exchanges.suffix(3) {
            // Typed by the person in the contact's thread: theirs, not mine.
            if let prompt = exchange.prompt, !prompt.isEmpty { talk.append(line(exchange.sentAt, exchange.byPerson == true ? person : "me", prompt, now: now)) }
            if let reply = exchange.reply, !reply.isEmpty { talk.append(line(nil, slug, reply, now: now)) }
        }
        if talk.isEmpty, exchanges.isEmpty, contact.builtIn { talk = laneTalk(contact.id, slug: slug, now: now) }
        if talk.isEmpty, exchanges.isEmpty, let record, let reply = replyText(unwrap(record.receipt)) {
            // An older record kept only the answer; say so rather than show a reply to nothing.
            talk.append(line(record.operationStartedAt, "me", "(my message isn't kept in this older record)", now: now, talk: false))
            // Untimed like any exchange's reply: this record's updatedAt may be a later look.
            talk.append(line(nil, slug, reply, now: now))
        }
        if talk.isEmpty { talk = [record == nil ? "no messages yet" : "sent; no reply is recorded yet"] }
        // What became of the last send, and what `.say` does now (desk walk 4:
        // grok read only "send unconfirmed 2d"; omp's two 403s read as "no reply").
        var outcome: [String] = []
        // A live hand-off saved before 09-25 reads as attention; it landed.
        if let record, record.phase == "attention", (unwrap(record.receipt)["run_status"] ?? unwrap(record.receipt)["status"]) != .string("delivered_live") {
            let receipt = unwrap(record.receipt)
            let peer = contact.id.hasPrefix("peer:") ? (try? AgentPeerStore(dataRoot: dataRoot).list())?.first { "peer:" + $0.id == contact.id } : nil
            let transport = peer?.transport
            let ago = age(now.timeIntervalSince(record.updatedAt))
            if receipt["status"] == .string("outcome_unknown") {
                outcome.append("My last message may not have reached \(contact.name): the send stopped before it could be checked, \(ago) ago. It is never resent by itself.")
            } else if let reason = sendFailure(bare, receipt: receipt, now: now) {
                outcome.append("Sends are failing: " + reason)
            } else if case .string(let detail)? = receipt["detail"] {
                outcome.append(clip(detail, 140))
            }
            if peer?.canAnswerBack == false { outcome.append("Replies from \(contact.name) aren't connected: one comes only as an ordinary message, if it comes.") }
            outcome.append(AgentConversationSession.resumable(record, transport)
                ? slug + ".say sends a new message in this same thread; the earlier one is not repeated."
                : slug + ".say can't continue this thread until it settles; a new conversation can start fresh.")
        }

        // Chats they opened with her over the bridge; the one she is in is
        // named but never quoted.
        let listed = Array(theirs.filter { !$0.id.hasPrefix("bench-") }.prefix(3))
        let chatLines = withNames(dataRoot) { book in
            listed.map { chat -> String in
                if chat.id == scope { return pad("this chat", 10) + age(now.timeIntervalSince(chat.at)) }
                return pad("chat.\(book.number("chat", id: chat.id) { Set(chats.map(\.id)) })", 10)
                    + clip(chat.title, 50) + " · " + age(now.timeIntervalSince(chat.at))
            }
        } + (theirs.count > listed.count ? ["+\(theirs.count - listed.count) more · action \"conversations\""] : [])
        var verbs = [(slug + ".say", "send a message (text)")]
        if listed.contains(where: { $0.id != scope }) { verbs.append(("chat.N", "open one of those chats")) }
        let kind = contact.builtIn ? "built-in agent" : contact.kind ?? "agent"
        return screen([contact.name.uppercased(), kind, state] + (label.map { $0 == "Main" ? [] : ["thread " + clip($0, 30)] } ?? []),
            [section("TALK", talk), section("LAST SEND", outcome), section("CHATS", chatLines), issue.map { section("READ", [clip($0, 100)]) } ?? []], verbs: verbs)
    }

    // MARK: Chat

    /// One chat (chat.N): its last six lines in the person room's TALK
    /// format and an honest count of the rest. The chat she is in is named,
    /// never quoted back.
    private static func chatRoom(_ id: String, title: String, dataRoot: URL, person: String, scope: String, issue: String?, now: Date) async -> String? {
        let world = await readWorld(dataRoot, now: now)
        let chat = world.chats.first { $0.id == id }
        let who = withNames(dataRoot) { book in
            chat.flatMap { chat in world.contacts.first { $0.id == chat.who || $0.name.lowercased() == chat.who } }
                .map { book.slug(id: $0.id, name: $0.name) }
        } ?? chat?.who ?? person
        var talk: [String]
        if id == scope {
            talk = ["this is the chat you are in"]
        } else {
            let tail = chatTail(id, dataRoot: dataRoot)
            let size = (try? FileManager.default.attributesOfItem(atPath: dataRoot.appendingPathComponent("chat/messages/\(id).jsonl").path)[.size] as? Int) ?? 0
            let earlier = max(0, tail.count - 6)
            talk = (earlier > 0 || size > 98_304 ? ["+\(earlier) earlier" + (size > 98_304 ? ", older not counted" : "")] : [])
                + tail.suffix(6).map { line($0.at, $0.mine ? "me" : who, $0.text, now: now) }
            if tail.isEmpty { talk = ["no messages yet"] }
        }
        let header = [clip(chat?.title ?? title, 40), who] + (chat.map { [age(now.timeIntervalSince($0.at))] } ?? [])
        return screen(header, [section("TALK", talk), issue.map { section("READ", [clip($0, 100)]) } ?? []],
            verbs: (who == person ? [] : [(who + ".say", "send them a message (text)")]) + [("conversations", "every chat, both directions")])
    }

    /// The last messages of a chat, from the final 96 KB of its log: who
    /// said it, when, and the words without the bridge's bracketed notes.
    static func chatTail(_ id: String, dataRoot: URL, bytes: UInt64 = 98_304) -> [(mine: Bool, text: String, at: Date?, run: String?)] {
        guard NativeAgentChatSessionID.normalizedPathComponent(id) != nil else { return [] }
        let url = dataRoot.appendingPathComponent("chat/messages/\(id).jsonl")
        // Tool results can fill the whole window (the desk walk: 140 KB of them
        // after the last message from the other side), which read as "no reply".
        // Widen, up to 2 MB, until the other side is in it.
        var size = bytes, tail = logTail(url, bytes: size)
        let file = UInt64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        while !tail.contains(where: { !$0.mine }), size < 2_097_152, file > size {
            size = min(size * 4, 2_097_152)
            tail = logTail(url, bytes: size)
        }
        return tail
    }

    static func logTail(_ url: URL, bytes: UInt64) -> [(mine: Bool, text: String, at: Date?, run: String?)] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if size > bytes, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { line in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let role = row["role"] as? String, ["user", "assistant"].contains(role),
                  let content = row["content"] as? String else { return nil }
            var said = content.split(separator: "\n", omittingEmptySubsequences: false)[...]
            while let first = said.first?.trimmingCharacters(in: .whitespaces),
                  first.isEmpty || (first.hasPrefix("[") && first.hasSuffix("]")) { said = said.dropFirst() }
            // Lines kept, so a room can take markdown off (sentence(_:)).
            var text = said.joined(separator: "\n")
            if text.hasPrefix("[from: "), let end = text.range(of: "]") { text = String(text[end.upperBound...]) }
            text = text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : (role == "assistant", text, (row["createdAt"] as? String).flatMap(date), row["runId"] as? String)
        }
    }

    /// A routine's answers (Grok Bot's): each arrives as its own turn in the
    /// chat that asked (the request's `conversationID`), carrying the
    /// request's run id. The newest five answered requests, found in bounded
    /// (256 KB) tails of that chat's log and its three newest compacted copies; kept until the
    /// request folder or those logs change. Newest last.
    static func routineReplies(dataRoot: URL) async -> [(at: Date?, text: String)] {
        let dir = dataRoot.appendingPathComponent("agents/grok-requests", isDirectory: true)
        let requests = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(20).compactMap { (url, _) -> (run: String, chat: String)? in
                guard let data = try? Data(contentsOf: url), let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      row["state"] as? String == "answered", let run = row["runID"] as? String,
                      let chat = row["conversationID"] as? String, NativeAgentChatSessionID.normalizedPathComponent(chat) != nil else { return nil }
                return (run, chat)
            }.prefix(5)
        let chats = Array(Set(requests.map { $0.chat })).sorted()
        func logs(_ chat: String) -> [URL] {
            let folder = dataRoot.appendingPathComponent("chat/sessions/\(chat)", isDirectory: true)
            // Compaction moves older turns into dated copies; the newest three
            // cover the last few answers.
            let compact = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix("messages.compact.") && $0.hasSuffix(".jsonl") }.sorted().suffix(3)
            return [dataRoot.appendingPathComponent("chat/messages/\(chat).jsonl")] + compact.map { folder.appendingPathComponent($0) }
        }
        let files = chats.flatMap(logs)
        let runs = Set(requests.map { $0.run.uppercased() })
        let found: [ReplyLine] = await HerMemo.shared.value(dataRoot.standardizedFileURL.path + "\u{0}routine",
                stamp: stamps(dir) + files.map(stamp)) {
            var seen: Set<String> = []
            return files.flatMap { logTail($0, bytes: 262_144) }
                .filter { !$0.mine && $0.run.map { runs.contains($0.uppercased()) } == true && seen.insert($0.text).inserted }
                .map { ReplyLine(at: $0.at, text: $0.text) }
                .sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
        }
        return found.map { ($0.at, $0.text) }
    }

    private struct ReplyLine { let at: Date?; let text: String }

    // MARK: Desk

    private static func deskRow(_ item: DeskItem, person: String, now: Date) -> String {
        pad("desk." + item.alias, 11) + clip(item.title, 50) + " · " + deskState(item, person: person)
            + (date(item.updatedAt).map { " " + age(now.timeIntervalSince($0)) } ?? "")
    }

    private static func deskState(_ item: DeskItem, person: String) -> String {
        // A run that stopped writes "[blocked] …" as a note, not a status: while
        // it is the newest note, blocked is the one state (walk 4: "watching · blocked").
        if !item.status.isTerminal, item.status != .blocked, let last = item.notes.last?.text, last.hasPrefix("[blocked]") {
            return "blocked: " + clip(String(last.dropFirst(9)).trimmingCharacters(in: .whitespaces), 40)
        }
        return OwnerAttentionPolicy.waitsOnOwner(item) ? "waits on " + person : item.status == .now ? "in progress" : item.status.displayLabel
    }

    private static func deskItemRoom(_ handle: String, dataRoot: URL, person: String, now: Date) async -> String? {
        guard let state = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState(),
              let item = state.items.first(where: { $0.handle == handle }) else { return nil }
        let name = "desk." + item.alias
        var about = [clip(item.title, 110)]
        if let summary = nonEmpty(item.summary) { about.append(clip(summary, 160)) }
        if let reason = nonEmpty(item.blockedReason) { about.append("blocked: " + clip(reason, 100)) }
        var notes = item.notes.suffix(3).map { line(date($0.ts), "", $0.text, now: now, talk: false) }
        if item.notes.count > 3 { notes.insert("+\(item.notes.count - 3) earlier notes · workspace query \"\(name)\"", at: 0) }
        let children = state.children(of: handle).sorted { ($0.status.isTerminal ? 1 : 0, $1.updatedAt) < ($1.status.isTerminal ? 1 : 0, $0.updatedAt) }
        var parts = children.prefix(6).map { deskRow($0, person: person, now: now) }
        if children.count > 6 { parts.append("+\(children.count - 6) more parts") }
        return screen([name, item.kind.rawValue, deskState(item, person: person)]
                + (date(item.updatedAt).map { ["updated " + age(now.timeIntervalSince($0))] } ?? []),
            [section("ITEM", about), section("NOTES", notes), section("PARTS", parts)],
            verbs: [(name + ".note", "add a note (text)"), (name + ".done", "mark it done"), (name + ".status", "set its status (text: now, next, todo, watch, blocked, done)")],
            back: "Back: home · desk.")
    }

    private static func deskRoom(dataRoot: URL, person: String, now: Date) async -> String? {
        let split = await readWorld(dataRoot, now: now).split
        func rows(_ items: [DeskItem], _ cap: Int) -> [String] {
            items.prefix(cap).map { deskRow($0, person: person, now: now) }
                + (items.count > cap ? ["+\(items.count - cap) more · workspace query \"<words>\" finds one"] : [])
        }
        let parked = split.parked.isEmpty ? [] : ["\(split.parked.count) · untouched \(split.quietDays ?? DeskParking.quietDays)d+ · workspace query \"<words>\" finds one"]
        return screen(["DESK", "\(split.active.count) active", "\(split.parked.count) parked", "\(split.open) open of \(split.total)"]
                + (split.waiting.isEmpty ? [] : ["\(split.waiting.count) wait on \(person)"]),
            [section("WAITING", rows(split.waiting, 5)), section("ACTIVE", rows(split.active, 10)), section("PARKED", parked)],
            verbs: [("desk.N", "open an item"), ("desk.N.note", "add a note (text)"), ("desk.N.done", "mark one done"), ("desk.add", "add work (form)")])
    }

    // MARK: Helpers

    /// Every helper, one line: name · schedule (the Bots page's words) · last
    /// run · state. Busy ones first, then by newest run.
    private static func helpersRoom(dataRoot: URL, person: String, now: Date) async -> String {
        let world = await readWorld(dataRoot, now: now)
        let (bots, latest, running) = (world.bots, world.latest, world.running)
        let ordered = bots.sorted {
            (running.contains($0.id) ? 1 : 0, latest[$0.id]?.runAt ?? .distantPast)
                > (running.contains($1.id) ? 1 : 0, latest[$1.id]?.runAt ?? .distantPast)
        }
        let marks: [ShelfRunHealth: String] = [.ok: "✓ ok", .nothingNew: "○ nothing new", .partial: "~ partial", .failed: "✗ failed"]
        let rows: [(name: String, text: String)] = withNames(dataRoot) { book in
            ordered.map { bot in
                let entry = latest[bot.id]
                var state = "idle"
                if running.contains(bot.id) { state = "⟳ running" }
                else if let entry {
                    switch entry.runtimeStatus {
                    case .completed: state = marks[entry.runHealth] ?? "✓ ok"
                    case .failed: state = "✗ failed"
                    case .interrupted: state = "✗ interrupted"
                    case .waitingForApproval: state = "waiting approval"
                    case .waitingOnPerson: state = "waiting on " + person
                    }
                }
                if bot.paused { state += " · paused" }
                let last = entry.map { "ran " + age(now.timeIntervalSince($0.runAt)) + " ago" } ?? "never run"
                return (book.slug(id: "bot:" + bot.id.uuidString, name: bot.name),
                        clip(StandingBotSchedule.words(bot.cadence), 40) + " · " + last + " · " + state)
            }
        }
        let width = min(20, (rows.map(\.name.count).max() ?? 0) + 2)
        let busy = ordered.filter { running.contains($0.id) }.count, paused = bots.filter(\.paused).count
        return screen(["HELPERS", "\(bots.count) helper\(bots.count == 1 ? "" : "s")"]
                + (busy > 0 ? ["\(busy) running"] : []) + (paused > 0 ? ["\(paused) paused"] : []),
            [rows.isEmpty ? ["no helpers yet"] : rows.map { pad(clip($0.name, 30), width) + clip($0.text, 90) }],
            verbs: [("<name>", "open its room"), ("<name>.run", "run it once now"), ("<name>.say", "ask it something (text)"),
                    ("<name>.settings", "change how it works")])
    }

    // MARK: People

    private static func peopleRoom(dataRoot: URL, scope: String, now: Date) async -> String {
        let world = await readWorld(dataRoot, now: now)
        let (cells, needs, _) = peopleRows(world, dataRoot: dataRoot, now: now, scope: scope, limit: .max)
        let width = min(20, (cells.map(\.name.count).max() ?? 0) + 2)
        return screen(["PEOPLE", "\(cells.count) contact\(cells.count == 1 ? "" : "s")"] + (needs.isEmpty ? [] : ["\(needs.count) ask for input"]),
            [cells.isEmpty ? ["no one yet · action \"connections\" adds someone"] : cells.map { pad(clip($0.name, 30), width) + clip($0.state, 80) }],
            verbs: [("<name>", "open their conversation"), ("<name>.say", "send a message (text)"), ("conversations", "every chat, both directions")])
    }

    // MARK: Conversations

    /// One row per who she talks with: the newest thread, why it stands where
    /// it does (the same words home uses), and how many older threads.
    private static func conversationsRoom(dataRoot: URL, person: String, scope: String, now: Date, page: Int = 0) async -> String {
        let world = await readWorld(dataRoot, now: now)
        func who(_ record: AgentConversationRecord) -> String {
            let agent = record.agent
            if agent.lowercased().hasPrefix("bot:"), let id = UUID(uuidString: String(agent.dropFirst(4))) { return "bot:" + id.uuidString }
            // A contact connected again got a new id; its older records are the same person (home's rule).
            if agent.hasPrefix("peer:"), !world.contacts.contains(where: { $0.id == agent }) {
                let same = world.contacts.filter { !$0.builtIn && $0.name.caseInsensitiveCompare(record.name) == .orderedSame }
                if same.count == 1 { return same[0].id }
            }
            return agent
        }
        var order: [String] = [], groups: [String: [AgentConversationRecord]] = [:]
        for record in ((try? AgentConversationStore(dataRoot: dataRoot).records()) ?? []).sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let id = who(record)
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(record)
        }
        // Twelve a page (desk walk 2: 17 counted, 12 shown, no way on), and
        // older threads by name: `cursor-cli.t2` opens its second-newest thread.
        let shown = Array(order.dropFirst(page * 12).prefix(12))
        var named: [String: AgentWorkspaceAction] = [:]
        let rows: [(String, String)] = withNames(dataRoot) { book in
            shown.compactMap { id in
                guard let records = groups[id], let record = records.first else { return nil }
                let slug = book.slug(id: id, name: record.name)
                var state: String
                if id.hasPrefix("bot:"), let uuid = UUID(uuidString: String(id.dropFirst(4))), let bot = world.bots.first(where: { $0.id == uuid }) {
                    state = helperState(bot, entry: world.latest[uuid], running: world.running.contains(uuid), person: person, now: now)
                } else {
                    let contact = Contact(id: id, name: record.name, builtIn: builtIns.contains(id), kind: nil)
                    // The same source home uses: their newest bridge chat when it is newer.
                    let chat = world.chats.first { $0.id != scope && ($0.who == id || $0.who == record.name.lowercased()) }
                    state = HerScreen.state(contact, record: record, chat: chat, answered: world.answered, now: now).text
                }
                var labels: [String] = []
                for other in records where !labels.contains(where: { $0.caseInsensitiveCompare(other.label) == .orderedSame }) { labels.append(other.label) }
                let older = labels.dropFirst().prefix(4).enumerated().map { index, label -> String in
                    let name = slug + ".t\(index + 2)"
                    named[name] = .open(.record(tool: "agent_read", input: ["agent": .string(id), "conversation": .string(label)], title: record.name))
                    return name + " " + clip(label, 20)
                }
                let thread = id.hasPrefix("bot:") || record.label == "Main" ? "" : " — " + clip(record.label, 24)
                return (slug, clip(record.name, 30) + thread + " · " + state
                    + (older.isEmpty ? "" : " · older: " + older.joined(separator: ", ")
                        + (labels.count > 5 ? " +\(labels.count - 5)" : "")))
            }
        }
        if page > 0 { named["conversations.previous"] = .open(.conversations(page: page - 1)) }
        if order.count > (page + 1) * 12 { named["conversations.more"] = .open(.conversations(page: page + 1)) }
        HerNamed.shared.keep(dataRoot, named)
        let width = min(20, (rows.map(\.0.count).max() ?? 0) + 2)
        var verbs = [("<name>", "open the conversation"), ("<name>.say", "send a message (text)")]
        if order.count > (page + 1) * 12 { verbs.append(("conversations.more", "the next \(min(12, order.count - (page + 1) * 12)) older")) }
        if page > 0 { verbs.append(("conversations.previous", "newer ones")) }
        verbs.append(("people", "everyone I can reach"))
        return screen(["CONVERSATIONS", "\(order.count)"] + (order.count > 12 ? ["\(page * 12 + 1)–\(page * 12 + shown.count) shown"] : []),
            [rows.isEmpty ? ["none yet"] : rows.map { pad(clip($0.0, 30), width) + $0.1 }], verbs: verbs)
    }

    /// "today 4:19 AM", "yesterday 9:05 PM", "Tue 8:00 AM", "Sep 14".
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

    /// Her person's front app, or the screensaver when the screen is covered.
    static func macFront(_ person: String) async -> String {
        // The session flag the reads and acts answer `mac_locked` on: locked
        // only when a wake already failed, otherwise it's the screensaver.
        if MacScreenLock.isLocked() { return "\(person)'s screen: " + (MacScreenLock.wakeFailed ? "locked" : "screensaver") }
        let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName }
        return "\(person)'s front: " + clip(front ?? "unknown", 40)
    }

    /// The Mac as a room: who is in front, the windows she worked in lately,
    /// what is running (names only, no accessibility walk). It never reads a
    /// window itself: `mac.look <app>` does that, and never her own app.
    private static func macRoom(dataRoot: URL, person: String, now: Date) async -> String {
        let front = await macFront(person), me = getpid()
        let running: [String] = await MainActor.run {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
                .compactMap(\.localizedName)
        }
        let names = Set(running).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { clip($0, 24) }
        var rows: [String] = [], row = ""
        for name in names.prefix(24) {
            if !row.isEmpty, row.count + name.count > 64 { rows.append(row + ","); row = "" }
            row += (row.isEmpty ? "" : ", ") + name
        }
        if !row.isEmpty { rows.append(row + (names.count > 24 ? " +\(names.count - 24) more" : "")) }
        let mine = touched(dataRoot: dataRoot, now: now).map { window in
            pad(clip(window.app, 24), 14) + ([window.kind, window.readout.map { "reads " + clip($0, 24) }].compactMap { $0 }
                + ["\(age(now.timeIntervalSince1970 - window.at)) ago"]).joined(separator: " · ")
        }
        return screen(["MAC", front],
            [section("I ACTED IN", mine.isEmpty ? ["none in the last \(Int(touchedHours)) hours"] : mine), section("RUNNING", rows)],
            verbs: [("mac.look <app>", "read that app's window where it sits"), ("mac.go <app>", "bring that app to the front")])
    }

    // MARK: My windows (data/her_screen/touched.json)

    /// A window she acted in or read by name: app, its kind (never a title),
    /// and a short readout (Calculator's display).
    struct Touched: Codable, Equatable { var app: String; var kind: String?; var readout: String?; var at: Double }

    static let touchedHours: Double = 4

    static func touch(dataRoot: URL, app: String, kind: String?, readouts: [String], before: [String] = [], now: Date = Date()) {
        let name = clip(app, 40), at = now.timeIntervalSince1970
        let word = kind.map { $0.contains("AXSheet") ? "sheet" : $0.contains("Dialog") ? "dialog" : $0.contains("Floating") ? "panel" : "window" }
        // A display value only (digits, operators, a short unit: "42", "3:05",
        // "12.5 kg", "80%"); words or codes could be someone's content.
        // Invisible format marks (Calculator's display carries
        // left-to-right marks) come off first. The ranked first readout can be
        // a word ("Standard"), so every readout is a candidate: one the act
        // changed first, a result (no operator) before an expression ("5+5").
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
        HerTouched.shared.update(dataRoot) { rows in
            rows.removeAll { ($0.app == name && $0.kind == word) || at - $0.at > touchedHours * 3600 }
            rows.insert(Touched(app: name, kind: word, readout: short, at: at), at: 0)
            if rows.count > 8 { rows.removeLast(rows.count - 8) }
        }
    }

    static func touched(dataRoot: URL, now: Date) -> [Touched] {
        HerTouched.shared.rows(dataRoot).filter { now.timeIntervalSince1970 - $0.at <= touchedHours * 3600 }
    }

    // MARK: Places and lists as text

    /// The room name a view shows under, or nil where the old frame stays.
    static func textRoomName(_ location: AgentWorkspaceLocation) -> String? {
        switch location {
        case .arrivals: return "arrivals"
        case .openPlaces: return "windows"
        case .workOverview: return "work"
        case .conversations: return "conversations"
        case .area(let id): return placeNames.first { $0.value == id }?.key ?? id
        case .page(let inner, _): return textRoomName(inner)
        case .record(let tool, _, _): return commsFamily[tool] ?? coreRooms[tool]
        default: return nil
        }
    }

    /// Workspace controls every frame carries; home and names already do these.
    private static let chrome: Set<String> = ["This work", "Workspace home", "Find", "Arrivals", "Open places",
        "Show workspace controls", "Hide workspace controls", "Conversations", "Saved workspaces", "Keep this workspace as…",
        "Find an action", "Find work", "Find a document", "People and agents", "Keep with this work", "Put selected source away"]

    /// A plain owner read's identity; also what names.json keeps for `mail.3`.
    static func key(_ place: AgentWorkspaceLocation) -> String? {
        guard case .record(let tool, let input, let title) = place else { return nil }
        // A mail row's inbox position moves as mail arrives; its name must not.
        let stable = input.filter { $0.key != "position" }
        return try? JSONValue.object(["tool": .string(tool), "input": .object(stable), "title": .string(title)]).serialize(pretty: false)
    }

    /// `mail.3` back to the reading it names.
    static func itemPlace(_ room: String, _ n: Int, dataRoot: URL) -> AgentWorkspaceLocation? {
        guard let id = withNames(dataRoot, { $0.id("item." + room, n) }),
              case .object(let row)? = try? JSONValue.parse(Data(id.utf8)),
              case .string(let tool)? = row["tool"], case .object(let input)? = row["input"], case .string(let title)? = row["title"] else { return nil }
        return .record(tool: tool, input: input, title: title)
    }

    /// One room from an owner's read: header · state, one line per item (its
    /// stable name, or the action id it was offered under), the place's own
    /// verbs, "Back: home." Nothing is read here that the owner didn't return.
    static func textRoom(_ room: String, place: AgentWorkspaceLocation, projection: AgentWorkspaceProjection,
                         frame: JSONValue, dataRoot: URL, now: Date = Date()) -> String {
        guard case .object(let shown) = frame else { return room.uppercased() + " · unavailable\nBack: home." }
        func text(_ value: JSONValue?) -> String? {
            switch value {
            case .string(let text)?: return nonEmpty(text)
            case .int(let n)?: return String(n)
            case .double(let n)?: return String(n)
            case .bool(let b)?: return b ? "yes" : nil
            default: return nil
            }
        }
        // Fields worth a glance, in order; dates read as people say them.
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
            // A search result's snippet is how she judges it: room for a sentence.
            }.prefix(3).map { clip($0, room == "research" ? 110 : 40) }
            if row["unread"] == .bool(true) { parts.append("unread") }
            return parts.joined(separator: " · ")
        }
        let status = text(shown["status"]) ?? "ok"
        let fine = ["ok", "completed", "success", "succeeded"].contains(status)
        let content: [String: JSONValue] = if case .object(let row) = projection.content { row } else { [:] }
        func fieldsOf(_ item: AgentWorkspaceItem) -> [String: JSONValue] { if case .object(let row) = item.content { row } else { [:] } }

        // Done items off (a completed reminder, a "✅" nag); near-identical
        // titles in a row fold into one ("Codex reset ×4").
        var items: [(item: AgentWorkspaceItem, times: Int)] = []
        func fold(_ title: String) -> String {
            String(title.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " }.map(Character.init))
                .split(separator: " ").joined(separator: " ")
        }
        for item in projection.items.dropFirst(projection.page * 8).prefix(8) {
            let row = fieldsOf(item)
            // A ✅ in a title means done only where the owner gives no state (a
            // reminder says completed:false, so it stays and the count matches).
            if row["completed"] == .bool(true) || (row["completed"] == nil && (item.title.contains("✅") || item.title.contains("✔"))) { continue }
            // Two emails or notes alike are still two things to act on: never folded.
            if let last = items.last, !commsRooms.contains(room), !fold(item.title).isEmpty, fold(last.item.title) == fold(item.title) { items[items.count - 1].times += 1 }
            else { items.append((item, 1)) }
        }
        // Every row and verb gets a stable name; the action behind it is kept
        // for the name (and plain owner reads also in names.json).
        let roomVerbs = projection.actions.map(\.label)
        var names: [String: AgentWorkspaceAction] = [:], pages: [String: String] = [:]
        var rowVerb: (String, String)?
        let trouble = room != "connections" ? [:] : sendTrouble(agents: items.compactMap { entry -> String? in
            guard case .open(.record("agent_read", let input, _))? = entry.item.actions.first?.action, case .string(let agent)? = input["agent"] else { return nil }
            return agent
        }, dataRoot: dataRoot, now: now)
        let lines: [(String, String)] = withNames(dataRoot) { book in
            // Windows come and go: number them as shown (windows.1 is the top row).
            if room == "windows" { book.numbers["item." + room] = [:]; book.next["item." + room] = projection.page * 8 + 1 }
            let present = Set(items.compactMap { $0.item.actions.first.map { identity($0.action, label: $0.label) } })
            return items.map { entry in
                let item = entry.item
                var name = "·"
                // A name opens, like a window: a row whose first action changes
                // something opens as a short page of its verbs instead (User).
                let opens = item.actions.first.map { opening($0.action) } ?? true
                if let first = item.actions.first {
                    name = room + ".\(book.number("item." + room, id: identity(first.action, label: first.label)) { present })"
                    if opens { names[name] = first.action }
                }
                // A row's own further verbs, not ones the whole room already offers.
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
                return (name, clip(item.title, 60) + (entry.times > 1 ? " ×\(entry.times)" : "") + (about.isEmpty ? "" : " · " + about) + more)
            }
        }
        if !previewing { HerItemPages.shared.keep(dataRoot, pages) }
        var taken: Set<String> = [], verbs: [(String, String)] = []
        if items.contains(where: { !$0.item.actions.isEmpty }) { verbs.append((room + ".N", "open one")) }
        if let rowVerb { verbs.append(rowVerb) }
        verbs += commsItemVerbs[room] ?? []
        var buttons = projection.actions.filter { !chrome.contains($0.label) }
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
        if !previewing { HerNamed.shared.keep(dataRoot, names) }

        let width = min(22, (lines.map(\.0.count).max() ?? 0) + 2)
        let count = projection.items.count
        let unread = projection.items.filter { fieldsOf($0)["unread"] == .bool(true) }.count
        // A launcher (create, research) lists nothing: it is its verbs.
        var header = [room.uppercased()] + roomCounts(content, fine: fine, status: status, listed: count, unreadRows: unread, page: projection.page)
        // Not the Mac's windows (home's MAC line counts those): walk 3 read "none" there and 7 here.
        if room == "windows" { header += ["the work I'm on, drafts and pages I acted in", "a read doesn't stay open", "not Mac apps"] }
        // Numbers are per item, never by position (windows aside): a name kept
        // from an older look still reaches the same one, and a gap is the
        // price, said on every numbered list so it doesn't read as a bug.
        if room != "windows", lines.contains(where: { $0.0 != "·" }) { header.append(numbersNote) }
        var about = ["message", "detail", "about", "note", "error"].compactMap { text(content[$0]) }.prefix(2).map { clip($0, 110) }
        // Not connected: its search/unread/status verbs cannot work, so none are offered (desk walk 3).
        if notConnected(content) { header = [room.uppercased(), "not connected"]; about = [notConnectedLine]; verbs = [] }
        return screen(header, [lines.isEmpty && about.isEmpty ? ["nothing here"] : lines.map { pad(clip($0.0, 24), width) + $0.1 },
                               section(fine ? "ABOUT" : "READ", about)], verbs: verbs)
    }

    /// What an action is, stably across renders: the number behind `today.3`.
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

    /// A verb's name from its label: "Find email" in mail is `find`, "More"
    /// is `more`; a second "open" becomes `open-view`.
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

    /// A name from a text room back to its action: kept in memory, then (for
    /// a plain owner read) from names.json.
    static func namedAction(_ name: String, dataRoot: URL) -> AgentWorkspaceAction? {
        if let action = HerNamed.shared.action(dataRoot, name) { return action }
        guard let dot = name.lastIndex(of: "."), let n = Int(name[name.index(after: dot)...]),
              let place = itemPlace(String(name[..<dot]), n, dataRoot: dataRoot) else { return nil }
        return .open(place)
    }

    // MARK: Her own app

    /// The workspace never reads NativeAgent through the Mac verbs: `screen`
    /// on it (named, or in front with none named) and `go` to it are handed to
    /// the app's own page reader, whose Chat page is her private conversation.
    /// Nor does it read the Chat page (or `current`, which may be it) directly.
    /// This is the early check; the app dispatcher refuses the self route
    /// again at execution (WorkspaceMacCall), whatever came to the front since.
    static func ownAppRefusal(tool: String, input: [String: JSONValue]) async -> JSONValue? {
        if ["app_page_read", "app_page_screenshot"].contains(tool) {
            let page: String = if case .string(let text)? = input["page"] { text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } else { "" }
            return page.isEmpty || page == "current" || page.hasPrefix("chat") ? WorkspaceMacCall.refusal : nil
        }
        guard ["screen", "go", "act"].contains(tool) else { return nil }
        let value = tool == "go" ? input["name"] ?? input["target"] : input["app"]
        let named: String? = if case .string(let text)? = value, !text.trimmingCharacters(in: .whitespaces).isEmpty { text } else { nil }
        var own = false
        if let named {
            var wanted = named.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if wanted.hasSuffix(".app") { wanted = String(wanted.dropLast(4)) }
            let mine: [String?] = [ProcessInfo.processInfo.processName, Bundle.main.bundleIdentifier,
                                   NSRunningApplication.current.localizedName, "NativeAgent"]
            own = mine.compactMap { $0?.lowercased() }.contains(wanted)
        } else if tool != "go" {
            own = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier } == getpid()
        }
        return own ? WorkspaceMacCall.refusal : nil
    }
}

/// Her-screen 09-24: whether a call runs on the workspace's behalf. The app
/// dispatcher refuses its in-process self-read route (NativeAgent's own
/// pages, the Chat page among them) for such calls, at execution time.
public enum WorkspaceMacCall {
    public static var active: Bool { AgentWorkspaceArrivals.insideWorkspaceDispatch }

    public static let refusal: JSONValue = .object(["ok": .bool(false), "status": .string("unavailable"), "error": .string("own_app"),
        "detail": .string("That's my own app; the workspace does not read it or its chat. Name another app: mac.look <app>.")])
}

/// Names a text room showed (`today.3`, `mail.find`) and the actions behind
/// them, per data root, for the life of the app. Replaced room by room.
final class HerNamed: @unchecked Sendable {
    static let shared = HerNamed()
    private let lock = NSLock()
    private var byRoot: [String: [String: AgentWorkspaceAction]] = [:]

    func keep(_ root: URL, _ names: [String: AgentWorkspaceAction]) {
        lock.withLock { byRoot[root.standardizedFileURL.path, default: [:]].merge(names) { _, new in new } }
    }

    func action(_ root: URL, _ name: String) -> AgentWorkspaceAction? {
        lock.withLock { byRoot[root.standardizedFileURL.path]?[name] }
    }
}

/// Her recent windows, in memory and in data/her_screen/touched.json.
final class HerTouched: @unchecked Sendable {
    static let shared = HerTouched()
    private let lock = NSLock()
    private var byRoot: [String: [HerScreen.Touched]] = [:]

    private func file(_ root: URL) -> URL { root.appendingPathComponent("her_screen/touched.json") }

    private func load(_ root: URL) -> [HerScreen.Touched] {
        if let rows = byRoot[root.standardizedFileURL.path] { return rows }
        let rows = (try? Data(contentsOf: file(root))).flatMap { try? JSONDecoder().decode([HerScreen.Touched].self, from: $0) } ?? []
        byRoot[root.standardizedFileURL.path] = rows
        return rows
    }

    func rows(_ root: URL) -> [HerScreen.Touched] { lock.withLock { load(root) } }

    func update(_ root: URL, _ body: (inout [HerScreen.Touched]) -> Void) {
        lock.withLock {
            var rows = load(root)
            body(&rows)
            byRoot[root.standardizedFileURL.path] = rows
            try? FileManager.default.createDirectory(at: file(root).deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(rows).write(to: file(root), options: .atomic)
        }
    }
}
