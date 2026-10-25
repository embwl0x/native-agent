import ChatSessionWork
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Transcripts
import NativeAgentShared
// Blueprint: | `HerScreenRooms+Elsewhere.swift` | HerScreen door lines own completed other-room exchanges for the person's Mac/phone timeline and bounded words in home-turn context; peer turns never carry the person's words |

/// One timeline across doors (Wave 2 #10, 2026-10-02): what User said on each
/// of his doors (Mac chat, Telegram, iPhone, Slack) and what agents said over
/// the bridges, read from the transcripts those doors already write. A door
/// is per message (its envelope's surface): one chat can hold several.
/// Her own wakes (ResidentWake's session) are a door of hers too: one mind,
/// so what a wake concluded reaches her other chats (User, 10-02).
/// Read-only: nothing here writes a session or changes how one is stored.
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
    static func doorFiles(dataRoot: URL, now: Date, since: Date? = nil) -> [URL] {
        let dir = dataRoot.appendingPathComponent("chat/messages", isDirectory: true).path
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".jsonl") && !$0.hasPrefix("bot-") }
            .compactMap { name -> (path: String, at: Int)? in
                var info = stat()
                guard lstat(dir + "/" + name, &info) == 0,
                      Double(info.st_mtimespec.tv_sec) + 1 >= max(since ?? .distantPast, now.addingTimeInterval(-7 * 86_400)).timeIntervalSince1970 else { return nil }
                return (dir + "/" + name, info.st_mtimespec.tv_sec)
            }
            .sorted { ($0.at, $0.path) > ($1.at, $1.path) }.prefix(12).map { URL(fileURLWithPath: $0.path) }
    }

    static func doorLines(dataRoot: URL, now: Date, since: Date? = nil) -> [DoorLine] {
        let files = doorFiles(dataRoot: dataRoot, now: now, since: since)
        let dir = dataRoot.appendingPathComponent("chat/messages", isDirectory: true).path
        DoorIndex.shared.keep(only: Set(doorFiles(dataRoot: dataRoot, now: now).map(\.path)), in: dir + "/")
        return files.flatMap { transcript($0).lines }.sorted { $0.at > $1.at }
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
            var mine: Date?
            var personSends: Set<String> = []
        }
        let lock = NSLock()
        var entries: [String: Entry] = [:]

        /// Only this week's newest transcripts stay indexed.
        func keep(only paths: Set<String>, in dir: String) {
            lock.withLock { entries = entries.filter { !$0.key.hasPrefix(dir) || paths.contains($0.key) } }
        }
    }

    private static func transcript(_ url: URL) -> (lines: [DoorLine], mine: Date?) {
        DoorIndex.shared.lock.withLock {
            var info = stat()
            guard lstat(url.path, &info) == 0, let handle = try? FileHandle(forReadingFrom: url) else {
                DoorIndex.shared.entries[url.path] = nil
                return ([], nil)
            }
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
                if let data = ContactThread.read(handle, from: entry.offset, bytes: Int(size - entry.offset)),
                   let end = data.lastIndex(of: UInt8(ascii: "\n")) {
                    // Whole rows only: a row still being written is read next time.
                    var rows = data[data.startIndex..<end].split(separator: UInt8(ascii: "\n"))
                    if partial, !rows.isEmpty { rows.removeFirst() }
                    entry.offset += UInt64(end - data.startIndex + 1)
                    read(rows, session: url.deletingPathExtension().lastPathComponent, into: &entry)
                    if entry.lines.count > 30 { entry.lines.removeFirst(entry.lines.count - 30) }
                }
            }
            DoorIndex.shared.entries[url.path] = entry
            return (entry.lines, entry.mine)
        }
    }

    /// Rows onto a transcript's index: the things said to her with a known
    /// door and her answer to each. Wake notices
    /// and other mechanical rows are not anyone speaking.
    private static func read(_ rows: [Data.SubSequence], session: String, into entry: inout DoorIndex.Entry) {
        let wake = session == ResidentWake.session
        for raw in rows {
            guard let speech = ContactThread.Line(jsonl: Data(raw)) else { continue }
            let metadata = speech.metadata
            guard let at = speech.date else { continue }
            let content = speech.text
            switch speech.role {
            case "assistant":
                if let sent = speech.sendID {
                    if speech.byPerson { entry.personSends.insert(sent) }
                    continue
                }
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                entry.mine = at
                if entry.open {
                    entry.lines[entry.lines.count - 1].reply = ChatSecretRedactor.redactText(content)
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
                let surface = HumanConversationIndex.string(HumanConversationIndex.object(metadata["origin"])["surface"])
                    ?? HumanConversationIndex.string(HumanConversationIndex.object(metadata["envelope"])["surface"])
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
    package static func otherRoomExchanges(dataRoot: URL, since: Date, now: Date = Date()) -> [OtherRoomExchange] {
        let named = peerNames(dataRoot), identity = names(dataRoot)
        return doorLines(dataRoot: dataRoot, now: now, since: since).compactMap { line in
            guard line.door == "bridge", !line.byPerson, let reply = line.reply,
                  line.active >= since, line.active <= now else { return nil }
            return OtherRoomExchange(id: line.session + ":" + line.id, sessionID: line.session,
                contactID: line.agent ?? "another agent", contact: clip(who(line, person: identity.person, peers: named), 80),
                agent: identity.agent, at: line.active, message: String(line.text.prefix(600)), reply: String(reply.prefix(600)))
        }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    /// Who spoke: User on his doors; on a bridge, the lane the bridge attested
    /// or the name User gave that peer in his contacts (agents/peers.json),
    /// never anything the message itself says.
    static func who(_ line: DoorLine, person: String, peers: [String: String]) -> String {
        if line.door == wakeDoor { return "me" }
        return ContactThread.project([.init(text: line.text, stamp: line.stamp)], person: person, names: peers, unlistedPeer: "an agent").first!.speaker
    }

    /// "peer:<id>" → the contact name User gave it.
    static func peerNames(_ dataRoot: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: dataRoot.appendingPathComponent("agents/peers.json")),
              let peers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var names: [String: String] = [:]
        for peer in peers {
            if let id = peer["id"] as? String, let name = nonEmpty(peer["name"] as? String) { names["peer:" + id] = name }
        }
        return names
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
        guard MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) else { return [] }
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
        guard MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) else {
            return screen(["ELSEWHERE", "closed"], [[failureFace(.object(["status": .string("refused"),
                "reason": .string("cross_session_recall_disabled"), "effects": .string("none"),
                "detail": .string("Remember across conversations is off; other conversations stay closed."),
                "remedy": Repair.why(owner: "Remember across conversations", tap: "Settings → Remember across conversations",
                    instruction: "Only the owner can enable Remember across conversations in Settings.")]))]], verbs: [])
        }
        let person = names(dataRoot).person
        let lines = Array(doorLines(dataRoot: dataRoot, now: now).filter { $0.session != scope }.prefix(12))
        var pages: [String: String] = [:], speech: [String: [ContactThread.Line]] = [:]
        let named = peerNames(dataRoot)
        let rows = lines.enumerated().map { index, line -> String in
            let name = "elsewhere.\(index + 1)", who = HerScreen.who(line, person: person, peers: named)
            let exchange = exchangePages(name, line, who: who, dataRoot: dataRoot, now: now)
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

    private static func exchangePages(_ name: String, _ line: DoorLine, who: String, dataRoot: URL, now: Date) -> [String: String] {
        let dir = dataRoot.appendingPathComponent("chat/messages").path
        let chat = withNames(dataRoot) { book in
            "chat.\(book.number("chat", id: line.session) { Set(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { ($0 as NSString).deletingPathExtension }) })"
        }
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
    }

    // MARK: The per-turn line

    /// Since her last reply in this chat (or within the hour, in a chat she
    /// has not answered yet): one line when User said something on another of
    /// his doors, one when one of her own wakes concluded, and on a turn he
    /// started, the newest five completed bridge exchanges with bounded words. Nil when
    /// nothing is new, when "Remember across conversations" is off, or on an
    /// unknown door. On a turn another agent steers (`peer`), User's door,
    /// count and time only: his words do not ride where she could relay them,
    /// and no bridge line rides at all. Her wake is her own thought, so it
    /// rides there too. Read from the transcripts' index (`transcript`), the
    /// same line every iteration of a turn.
    package static func elsewhere(dataRoot: URL, scope: String, surface: String, peer: Bool, turn: Date?) async -> String? {
        guard let here = door(surface), MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) else { return nil }
        let key = "elsewhere\u{0}" + scope + "\u{0}" + (turn.map { String($0.timeIntervalSince1970) } ?? "-")
        if turn != nil, let kept = HerMemo.shared.glance(key) { return kept }
        let text = elsewhereLine(dataRoot: dataRoot, scope: scope, here: here, peer: peer, now: turn ?? Date())
        if turn != nil { HerMemo.shared.keepGlance(key, text) }
        return text
    }

    private static func elsewhereLine(dataRoot: URL, scope: String, here: String, peer: Bool, now: Date) -> String? {
        let mine: Date? = NativeAgentChatSessionID.normalizedPathComponent(scope) == nil ? nil
            : transcript(dataRoot.appendingPathComponent("chat/messages/\(scope).jsonl")).mine
        let since = mine ?? now.addingTimeInterval(-3600)
        let known = doorLines(dataRoot: dataRoot, now: now)
        let all = known.filter { $0.session != scope && $0.at > since && $0.at <= now }
        var lines = [userLine(all.filter { $0.user && $0.door != here }, dataRoot: dataRoot, peer: peer, now: now)].compactMap { $0 }
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
            for exchange in otherRoomExchanges(dataRoot: dataRoot, since: since, now: now).reversed()
                .filter({ $0.sessionID != scope && $0.at > since }).prefix(5) {
                // Context assembly runs outside the app door: mark read where it is bound.
                AgentWorkspacePorts.binding?.tools.markConsumed(peer: exchange.contactID)
                lines.append(exchange.contact + " over the bridge since your last reply here:\n"
                    + "They said: \"" + clip(exchange.message, 600).replacingOccurrences(of: "\"", with: "'")
                    + "\"\nYou replied: \"" + clip(exchange.reply, 600).replacingOccurrences(of: "\"", with: "'") + "\"")
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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
