import ChatSessionWork
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import StandingBots
import Transcripts
import NativeAgentShared
// Blueprint: | `HerScreenRooms+Elsewhere.swift` | HerScreen's shared transcript index owns completed other-room exchanges for the person's Mac/phone timeline and bounded per-turn continuity, including the newest three helpers' replies; one read-only turn reading serves door lines, posts and exchanges beside history, with late peer disclosure and consumption; peer turns carry neither the person's words nor helper replies |

/// Transcript message surfaces join person, bridge and wake exchanges into one read-only timeline.
extension HerScreen {
    /// One thing said to her on a door, and her last answer after it there.
    /// A wake's is when her answer landed: that is when it concluded.
    struct DoorLine: Sendable {
        var id: String = ""
        let session: String
        var at: Date
        let door: String, text: String, user: Bool
        var reply: String?
        /// Who said it as its own row's stamp says (a wake's: "self", or the
        /// agent whose words it carried), and the peers that steered it.
        var stamp: TranscriptRowStamp
        var agent: String? { stamp.source }
        var steeredBy: [String] { stamp.steeredBy }
        var byPerson = false
        /// Her last reply on it, or when it arrived.
        var active: Date
    }

    static let wakeDoor = "my wake"

    /// User's doors by the surface each writes; any `*-bridge` is an agent's.
    static let userDoors = ["app": "Mac chat", "chat": "Mac chat", "mac": "Mac chat", "telegram": "Telegram",
                           "ios": "iPhone", "iphone": "iPhone", "mobile": "iPhone", "slack": "Slack", "signal": "Signal"]

    package static func door(_ surface: String) -> String? {
        userDoors[surface.lowercased()] ?? (surface.hasSuffix("-bridge") ? "bridge" : nil)
    }

    /// Newest first: the 12 most recently written transcripts of the last week
    /// (no earlier than `since` when given); helpers' own sessions stay out.
    static func doorLines(dataRoot: URL, now: Date, since: Date? = nil) throws -> [DoorLine] {
        let dir = dataRoot.appendingPathComponent("chat/messages", isDirectory: true).path
        let sessions = try SessionConversation(dataRoot: dataRoot)
        let entries: [String]
        do { entries = try FileManager.default.contentsOfDirectory(atPath: dir) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { entries = [] }
        let names = entries.filter { $0.hasSuffix(".jsonl") }
        let helpers = Set(names.filter { sessions.isHelper(String($0.dropLast(6))) })
        let files = try names.filter { !helpers.contains($0) }
            .compactMap { name -> (path: String, at: Int)? in
                var info = stat()
                guard lstat(dir + "/" + name, &info) == 0 else {
                    if errno == ENOENT { return nil }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: dir + "/" + name])
                }
                guard Double(info.st_mtimespec.tv_sec) + 1 >= now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970 else { return nil }
                return (dir + "/" + name, info.st_mtimespec.tv_sec)
            }
            .sorted { ($0.at, $0.path) > ($1.at, $1.path) }.prefix(12)
        DoorIndex.shared.keep(only: Set(files.map(\.path)).union(helpers.map { dir + "/" + $0 }), in: dir + "/")
        return try files.filter { Double($0.at) + 1 >= (since ?? .distantPast).timeIntervalSince1970 }
            .flatMap { file in
                guard sessions.kind(URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent) != nil else {
                    throw ToolFailureError("Conversation classification is unavailable for " + file.path, effects: .none,
                        owner: dataRoot.appendingPathComponent("chat/sessions.json").path,
                        instruction: "Reconcile this transcript with its owning session index before projecting it into other rooms.", recovery: .repair)
                }
                return try transcript(URL(fileURLWithPath: file.path)).lines
            }.sorted { $0.at > $1.at }
    }

    /// Each transcript's door lines and when she last answered
    /// in it, read on from where the previous read stopped: a turn parses
    /// only what was appended since. A new file, a rewrite (another inode)
    /// or a shrink starts again from its last 128 KB.
    private final class DoorIndex: @unchecked Sendable {
        static let shared = DoorIndex()
        struct Entry {
            var inode: UInt64 = 0, offset: UInt64 = 0
            var lines: [DoorLine] = [], open = false
            var mine: Date?, reply: String?
            var personSends: Set<String> = []
            /// What she said first on one of his doors (a post of hers, not a
            /// reply): kept apart from the lines, which are who spoke to her.
            var posts: [DoorLine] = []
        }
        let lock = NSLock()
        var entries: [String: Entry] = [:]

        /// Keep this week's newest door transcripts and helpers still on disk.
        func keep(only paths: Set<String>, in dir: String) {
            lock.withLock { entries = entries.filter { !$0.key.hasPrefix(dir) || paths.contains($0.key) } }
        }
    }

    private static func transcript(_ url: URL) throws -> (lines: [DoorLine], mine: Date?, reply: String?) {
        try DoorIndex.shared.lock.withLock {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                DoorIndex.shared.entries[url.path] = nil
                if errno == ENOENT { return ([], nil, nil) }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = UInt64(info.st_size), inode = UInt64(info.st_ino)
            var entry = DoorIndex.shared.entries[url.path] ?? .init()
            // Bounded on purpose: each turn reads this, so a transcript is indexed
            // from its last 128 KB and keeps its newest 30 lines.
            var partial = false
            if entry.inode != inode || size < entry.offset {
                entry = .init(inode: inode, offset: size > 131_072 ? size - 131_072 : 0)
                partial = entry.offset > 0
            }
            if size > entry.offset {
                try handle.seek(toOffset: entry.offset)
                let data = try handle.read(upToCount: Int(size - entry.offset)) ?? Data()
                guard data.count == Int(size - entry.offset) else { throw CocoaError(.fileReadUnknown) }
                if let end = data.lastIndex(of: UInt8(ascii: "\n")) {
                    // Whole rows only: a row still being written is read next time.
                    var rows = data[data.startIndex..<end].split(separator: UInt8(ascii: "\n"))
                    if partial, !rows.isEmpty { rows.removeFirst() }
                    entry.offset += UInt64(end - data.startIndex + 1)
                    try read(rows, session: url.deletingPathExtension().lastPathComponent,
                         dataRoot: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), into: &entry)
                    if entry.lines.count > 30 { entry.lines.removeFirst(entry.lines.count - 30) }
                }
            }
            DoorIndex.shared.entries[url.path] = entry
            return (entry.lines, entry.mine, entry.reply)
        }
    }

    /// Rows onto a transcript's index: the things said to her with a known
    /// door and her answer to each. Wake notices
    /// and other mechanical rows are not anyone speaking.
    private static func read(_ rows: [Data.SubSequence], session: String, dataRoot: URL, into entry: inout DoorIndex.Entry) throws {
        guard let kind = try SessionConversation(dataRoot: dataRoot).kind(session) else {
            throw ToolFailureError("Conversation classification is unavailable for " + session, effects: .none,
                owner: dataRoot.appendingPathComponent("chat/sessions.json").path,
                instruction: "Reconcile this transcript with its owning session index before projecting it into other rooms.", recovery: .repair)
        }
        let wake = kind.isOwnWork
        for raw in rows {
            guard case .object(let row) = try JSONValue.parse(Data(raw)) else { throw CocoaError(.fileReadCorruptFile) }
            let speech = ContactThread.Line(row)
            let metadata = speech.metadata
            guard speech.role == "user" || speech.role == "assistant" else { continue }
            if let failure = speech.provenanceFailure {
                throw ToolFailureError(failure, effects: .none,
                    owner: dataRoot.appendingPathComponent("chat/messages/\(session).jsonl").path,
                    instruction: "Repair the retained row's provenance before reading this conversation.", recovery: .repair)
            }
            guard case .string? = row["id"], case .string? = row["content"], let at = speech.date else {
                throw ToolFailureError("A complete transcript message has unreadable identity, content or time in " + session, effects: .none,
                    owner: dataRoot.appendingPathComponent("chat/messages/\(session).jsonl").path,
                    instruction: "Repair the complete message from retained transcript evidence; do not guess its timestamp or skip the corrupt row.", recovery: .repair)
            }
            let content = speech.text
            switch speech.role {
            case "assistant":
                if let sent = speech.sendID {
                    if speech.byPerson { entry.personSends.insert(sent) }
                    continue
                }
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if !entry.open, !wake {
                    let surface = (metadata["origin"]?.objectValue ?? [:])["surface"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
                        ?? (metadata["envelope"]?.objectValue ?? [:])["surface"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
                    if let door = surface.flatMap({ HerScreen.door($0) }), door != "bridge" {
                        entry.posts.append(.init(id: speech.id, session: session, at: at, door: door,
                            text: ChatSecretRedactor.redactText(content), user: false, stamp: speech.stamp, active: at))
                        if entry.posts.count > 10 { entry.posts.removeFirst(entry.posts.count - 10) }
                    }
                }
                entry.mine = at
                entry.reply = ChatSecretRedactor.redactText(content)
                if entry.open {
                    entry.lines[entry.lines.count - 1].reply = entry.reply
                    entry.lines[entry.lines.count - 1].active = at
                    if wake { entry.lines[entry.lines.count - 1].at = at }
                }
            case "user":
                entry.open = false
                guard metadata["mechanicalKind"] == nil else { continue }
                // A wake is her speaking; what it says to her is the arrival list.
                if wake {
                    entry.lines.append(.init(session: session, at: at, door: wakeDoor,
                                             text: ChatSecretRedactor.redactText(content), user: false,
                                             stamp: speech.stamp, active: at))
                    entry.open = true
                    continue
                }
                let surface = (metadata["origin"]?.objectValue ?? [:])["surface"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
                    ?? (metadata["envelope"]?.objectValue ?? [:])["surface"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
                guard let door = speech.contact ? "bridge" : surface.flatMap({ HerScreen.door($0) }) else { continue }
                var text: String
                if door == "bridge" {
                    text = ContactThread.project([speech], style: .thread).first!.text
                } else {
                    guard speech.human else { continue }
                    // "[Telegram voice message] Transcript: …": the words, not the note.
                    text = content.replacingOccurrences(of: #"^\[[^\]\n]{1,80}\]\s*(Transcript:\s*)?"#, with: "", options: .regularExpression)
                }
                // A token he pasted never rides into a prompt.
                text = ChatSecretRedactor.redactText(text.trimmingCharacters(in: .whitespacesAndNewlines))
                entry.lines.append(.init(id: speech.id, session: session, at: at, door: door,
                                         text: text.isEmpty ? "(no text: an image or file)" : text, user: door != "bridge",
                                         stamp: speech.stamp,
                                         byPerson: speech.human || speech.byPerson || speech.answers.map { entry.personSends.contains($0) } == true, active: at))
                entry.open = true
            default: continue
            }
        }
    }

    /// A reading copy only: never appended to the person's session or fed as chat.
    package static func otherRoomExchanges(dataRoot: URL, identity: AgentContactIdentity, since: Date, now: Date = Date()) throws -> [OtherRoomExchange] {
        try otherRoomExchanges(dataRoot: dataRoot, identity: identity, since: since, now: now,
                           lines: doorLines(dataRoot: dataRoot, now: now, since: since))
    }

    private static func otherRoomExchanges(dataRoot: URL, identity: AgentContactIdentity, since: Date, now: Date,
                                           lines: [DoorLine]) -> [OtherRoomExchange] {
        let named = identity.peerNames, profile = names(dataRoot)
        return lines.compactMap { line in
            guard line.door == "bridge", !line.byPerson, let reply = line.reply,
                  line.active >= since, line.active <= now else { return nil }
            return OtherRoomExchange(id: line.session + ":" + line.id, sessionID: line.session,
                contactID: line.agent ?? "another agent", contact: clip(who(line, person: profile.person, peers: named), 80),
                agent: profile.agent, at: line.active, message: String(line.text.prefix(600)), reply: String(reply.prefix(600)))
        }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    /// Who spoke: User on his doors; on a bridge, the lane the bridge attested
    /// or the name User gave that peer in his contacts (agents/peers.json),
    /// never anything the message itself says.
    static func who(_ line: DoorLine, person: String, peers: [String: String]) -> String {
        if line.door == wakeDoor { return "me" }
        return ContactThread.project([.init(text: line.text, stamp: line.stamp)], person: person, names: peers, unlistedPeer: "an agent").first!.speaker
    }

    private static func quoted(_ text: String, _ limit: Int) -> String {
        "\"" + clip(sentence(text).replacingOccurrences(of: "\"", with: "'"), limit) + "\""
    }

    // MARK: Home

    /// Home's ELSEWHERE: who spoke last on each of User's doors and on each
    /// bridge conversation, and when, one line each, the chat she is in left
    /// out. The words open in the room, not here: home rides turns another
    /// agent steers too. Nothing when "Remember across conversations" is off.
    static func elsewhereRows(_ world: HerWorld, dataRoot: URL, scope: String, person: String, now: Date) -> [String] {
        do { guard try MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) else { return [] } }
        catch { return [nameFailure(error)] }
        var doors: Set<String> = []
        let peers = Dictionary(uniqueKeysWithValues: world.routes.map { ($0.id, $0.name) })
        let newest = world.doors.filter {
            $0.session != scope && doors.insert($0.door == "bridge" ? $0.session : $0.door).inserted
        }.prefix(5)
        var rows = newest.map { line in
            pad(line.door, 10) + clip(who(line, person: person, peers: peers), 20) + " · " + age(now.timeIntervalSince(line.at))
        }
        if !rows.isEmpty { rows[rows.count - 1] += " · item \"elsewhere\"" }
        return rows
    }

    // MARK: The room

    /// `app {item:"elsewhere"}`: the newest 12 exchanges across doors, the
    /// chat she is in left out; `elsewhere.N` opens one whole, with her reply
    /// (kept per chat). Closed when "Remember across conversations" is off.
    static func elsewhereRoom(dataRoot: URL, scope: String, now: Date = Date()) -> String {
        do { return try checkedElsewhereRoom(dataRoot: dataRoot, scope: scope, now: now) }
        catch { return nameFailure(error) }
    }

    private static func checkedElsewhereRoom(dataRoot: URL, scope: String, now: Date) throws -> String {
        guard try MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) else {
            return screen(["ELSEWHERE", "closed"], [[failureFace(.object(["status": .string("refused"),
                "reason": .string("cross_session_recall_disabled"), "effects": .string("none"),
                "detail": .string("Remember across conversations is off; other conversations stay closed."),
                "remedy": Repair.why(owner: "Remember across conversations", tap: "Settings → Remember across conversations",
                    instruction: "Only the owner can enable Remember across conversations in Settings.")]))]], verbs: [])
        }
        let person = names(dataRoot).person
        let lines: [DoorLine]
        do { lines = Array(try doorLines(dataRoot: dataRoot, now: now).filter { $0.session != scope }.prefix(12)) }
        catch { return nameFailure(error) }
        var pages: [String: String] = [:], speech: [String: [ContactThread.Line]] = [:]
        let named: [String: String]
        do { named = try AgentWorkspacePorts.current.conversations.identity(dataRoot: dataRoot).peerNames }
        catch {
            return screen(["ELSEWHERE", "Identity unavailable"], [[readFailure(error, reason: "contact_identity_unavailable",
                remedy: Repair.remedy(owner: "agents/peers.json", nextCall: nil,
                    tap: "Repair the contact address book before resolving conversation identities."))]], verbs: [])
        }
        let chats = Result { try withNames(dataRoot) { book in
            lines.map { line in Result {
                "chat.\(try book.number("chat", id: line.session) { Set(((try? FileManager.default.contentsOfDirectory(atPath: dataRoot.appendingPathComponent("chat/messages").path)) ?? []).map { ($0 as NSString).deletingPathExtension }) })"
            } }
        } }
        let rows = lines.enumerated().map { index, line -> String in
            let name = "elsewhere.\(index + 1)", who = HerScreen.who(line, person: person, peers: named)
            let exchange = exchangePages(name, line, who: who, chat: { try chats.get()[index].get() }, now: now)
            for (item, page) in exchange { pages[scope + "\u{0}" + item] = page }
            let shown = ContactThread.Line(text: line.text, stamp: line.stamp)
            ContactThread.consume(shown, mark: { peer, _ in
                if !previewing { AgentWorkspacePorts.binding?.tools.markConsumed(peer: peer) }
            })
            for item in exchange.keys { speech[scope + "\u{0}" + item] = [shown] }
            return pad(name, 13) + pad(line.door, 10) + pad(clip(who, 16), 10) + pad(age(now.timeIntervalSince(line.at)), 5)
                + quoted(line.door == wakeDoor ? line.reply ?? line.text : line.text, 60)
        }
        if !previewing { HerItemPages.shared.keep(dataRoot, pages, room: scope + "\u{0}elsewhere", speech: speech) }
        return screen(["ELSEWHERE", person + "'s doors, the bridges and my wakes", "newest first"],
                      [rows.isEmpty ? ["no exchanges found in the recent transcript window"] : rows],
                      verbs: rows.isEmpty ? [] : [("elsewhere.N", "read that exchange and my reply; continue if needed")])
    }

    private static func exchangePages(_ name: String, _ line: DoorLine, who: String, chat: () throws -> String, now: Date) -> [String: String] {
        do {
            let chat = try chat()
            // Keep exact redacted words and formatting. List rows remain previews;
            // opening an exchange has bounded, lossless continuation pages.
            let text = "SAID\n" + line.text + "\n\nME\n" + (line.reply ?? "no reply from me there yet")
            let pageCharacters = 8_000
            var chunks: [String] = [], cursor = text.startIndex
            while cursor < text.endIndex {
                let end = text.index(cursor, offsetBy: pageCharacters, limitedBy: text.endIndex) ?? text.endIndex
                chunks.append(String(text[cursor..<end]))
                cursor = end
            }
            func item(_ index: Int) -> String { index == 0 ? name : name + ".more.\(index + 1)" }
            return Dictionary(uniqueKeysWithValues: chunks.enumerated().map { index, chunk in
                let read = chunks.count == 1 ? "Complete exchange · \(text.count) characters"
                    : "Exchange part \(index + 1) of \(chunks.count) · \(chunk.count) of \(text.count) characters"
                var verbs: [(String, String)] = []
                if index + 1 < chunks.count { verbs.append((item(index + 1), "continue this exact exchange")) }
                verbs.append((chat, "open the conversation"))
                return (item(index), screen([item(index), line.door, who, when(line.at, now: now)],
                    [[read], [chunk]], verbs: verbs, back: "Back: elsewhere · home."))
            })
        } catch { return [name: nameFailure(error)] }
    }

    // MARK: The per-turn line

    /// Read-only inputs, gathered beside history. Disclosure and markConsumed
    /// remain in elsewhere, after history has established this turn's taint.
    package struct ElsewhereReading: Sendable {
        fileprivate var failure: String? = nil
        fileprivate let all: [DoorLine]
        fileprivate let posts: [DoorLine]
        fileprivate let helpers: [String]
        fileprivate let exchanges: [OtherRoomExchange]
    }

    package static func readElsewhere(dataRoot: URL, scope: String, turn: Date) -> ElsewhereReading? {
        do { return try checkedElsewhere(dataRoot: dataRoot, scope: scope, turn: turn) }
        catch { return ElsewhereReading(failure: nameFailure(error), all: [], posts: [], helpers: [], exchanges: []) }
    }

    private static func checkedElsewhere(dataRoot: URL, scope: String, turn: Date) throws -> ElsewhereReading? {
        guard try MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) else { return nil }
        let mine: Date?
        if NativeAgentChatSessionID.normalizedPathComponent(scope) == nil { mine = nil }
        else { mine = try transcript(dataRoot.appendingPathComponent("chat/messages/\(scope).jsonl")).mine }
        let identity = try AgentWorkspacePorts.current.conversations.identity(dataRoot: dataRoot)
        let since = mine ?? turn.addingTimeInterval(-3600)
        let known = try doorLines(dataRoot: dataRoot, now: turn)
        // doorLines refreshed the shared index once. Do not enumerate and
        // reopen all twelve transcripts again for posts and bridge exchanges.
        let sessions = try SessionConversation(dataRoot: dataRoot)
        let directory = dataRoot.appendingPathComponent("chat/messages", isDirectory: true).standardizedFileURL.path + "/"
        let posts = DoorIndex.shared.lock.withLock {
            DoorIndex.shared.entries.filter { $0.key.hasPrefix(directory) }.values.flatMap(\.posts)
        }
            .filter { $0.at > since && $0.at <= turn && $0.session != scope && !sessions.isHelper($0.session) }
            .sorted { $0.at > $1.at }
        return try ElsewhereReading(all: known.filter { $0.session != scope && $0.at > since && $0.at <= turn },
            posts: posts, helpers: helperLines(dataRoot: dataRoot, scope: scope, since: since, now: turn),
            exchanges: otherRoomExchanges(dataRoot: dataRoot, identity: identity,
                since: since, now: turn, lines: known))
    }

    /// Since her last reply in this chat (or within the hour, in a chat she
    /// has not answered yet): one line when User said something on another of
    /// his doors, one when one of her own wakes concluded, and on a turn he
    /// started, the newest five completed bridge exchanges and up to three
    /// helpers' newest replies, with bounded words. Nil when nothing is new,
    /// when "Remember across conversations" is off, or on an unknown door.
    /// On a turn another agent steers (`peer`), User's door,
    /// count and time only: his words do not ride where she could relay them,
    /// and neither bridge nor helper words ride. A wake's words ride only
    /// when hers alone and not peer-steered. Read from the transcripts' index
    /// (`transcript`), the same line every iteration of a turn.
    package static func elsewhere(dataRoot: URL, scope: String, surface: String, peer: Bool, turn: Date?,
                                  reading: ElsewhereReading? = nil) async -> String? {
        guard let here = door(surface) else { return nil }
        do { guard try MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) else { return nil } }
        catch { return nameFailure(error) }
        let key = "elsewhere\u{0}" + dataRoot.standardizedFileURL.path + "\u{0}" + scope + "\u{0}" + (turn.map { String($0.timeIntervalSince1970) } ?? "-")
            + (peer ? "\u{0}peer" : "\u{0}person")
        if turn != nil, let kept = HerMemo.shared.glance(key) { return kept }
        let now = turn ?? Date()
        guard let reading = reading ?? readElsewhere(dataRoot: dataRoot, scope: scope, turn: now) else { return nil }
        if let failure = reading.failure { return failure }
        let all = reading.all
        var lines = [userLine(all.filter { $0.user && $0.door != here }, dataRoot: dataRoot, peer: peer, now: now)].compactMap { $0 }
        // What she told him elsewhere: on a turn a peer steers, door, count and
        // time only — her words to him are his, as his are.
        let posts = reading.posts
        if let latest = posts.first {
            let person = names(dataRoot).person
            var line = "You posted to " + person + " on " + latest.door + " " + age(now.timeIntervalSince(latest.at)) + " ago"
            if !peer { line += ": " + quoted(latest.text, 160) }
            if posts.count > 1 { line += "; \(posts.count - 1) more since your last reply here" }
            lines.append(line + ". app {item:\"elsewhere\"}")
        }
        if let wake = all.first(where: { $0.door == wakeDoor && $0.reply != nil }), let reply = wake.reply {
            // Her words travel only from a wake that was hers alone, and never
            // into a turn a peer steers: a wake carrying an agent's words would
            // launder them past the taint (ResidentWake.take's own rule).
            let hers = (wake.agent ?? "self") == "self" && wake.steeredBy.isEmpty
            lines.append("Your own wake " + age(now.timeIntervalSince(wake.at)) + " ago"
                + (hers && !peer
                    ? ": \"" + clip(plainLines(reply).joined(separator: " ").replacingOccurrences(of: "\"", with: "'"), 200) + "\""
                    : "") + ". app {item:\"elsewhere\"}")
        }
        if !peer {
            lines += reading.helpers
            for exchange in reading.exchanges.reversed().filter({ $0.sessionID != scope }).prefix(5) {
                // Context assembly runs outside the app door: mark read where it is bound.
                AgentWorkspacePorts.binding?.tools.markConsumed(peer: exchange.contactID)
                lines.append(exchange.contact + " over the bridge since your last reply here:\n"
                    + "They said: \"" + clip(exchange.message, 600).replacingOccurrences(of: "\"", with: "'")
                    + "\"\nYou replied: \"" + clip(exchange.reply, 600).replacingOccurrences(of: "\"", with: "'") + "\"")
            }
        }
        let text = lines.isEmpty ? nil : lines.joined(separator: "\n")
        if turn != nil { HerMemo.shared.keepGlance(key, text) }
        return text
    }

    private static func helperLines(dataRoot: URL, scope: String, since: Date, now: Date) throws -> [String] {
        let sessions = try SessionConversation(dataRoot: dataRoot)
        let helpers = try BotDefinitionStore(dataRoot: dataRoot).list()
        return try helpers.compactMap { bot -> (name: String, session: String, at: Date, reply: String)? in
            guard bot.sessionID != scope, sessions.isHelper(bot.sessionID) else { return nil }
            let read = try transcript(dataRoot.appendingPathComponent("chat/messages/\(bot.sessionID).jsonl"))
            guard let at = read.mine, at > since, at <= now, let reply = read.reply else { return nil }
            return (bot.name, bot.sessionID, at, reply)
        }.sorted { ($0.at, $0.session) > ($1.at, $1.session) }.prefix(3).map { helper in
            let flat = plainLines(helper.reply).joined(separator: " ")
            let end = flat.range(of: #"[.!?](\s|$)"#, options: .regularExpression)?.upperBound ?? flat.endIndex
            let first = String(flat[..<end]).trimmingCharacters(in: .whitespaces)
            return clip(helper.name, 80) + " (my helper) since your last reply here: " + quoted(first, 200)
        }
    }

    private static func userLine(_ fresh: [DoorLine], dataRoot: URL, peer: Bool, now: Date) -> String? {
        guard let latest = fresh.first else { return nil }
        let count = fresh.filter { $0.door == latest.door }.count
        var line = names(dataRoot).person + " on " + latest.door + " since your last reply here: "
            + (count == 1 ? "1 message, " : "\(count) messages, latest ") + age(now.timeIntervalSince(latest.at)) + " ago"
        if !peer { line += ": " + quoted(latest.text, 80) }
        var others: [(door: String, count: Int)] = []
        for item in fresh where item.door != latest.door {
            if let i = others.firstIndex(where: { $0.door == item.door }) { others[i].count += 1 } else { others.append((item.door, 1)) }
        }
        if !others.isEmpty { line += "; also " + others.map { "\($0.count) on \($0.door)" }.joined(separator: ", ") }
        return line + ". app {item:\"elsewhere\"}"
    }
}
