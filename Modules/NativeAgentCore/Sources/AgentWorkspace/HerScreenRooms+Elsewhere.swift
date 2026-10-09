import ChatSessionWork
import Foundation
import MemoryV2
import NativeAgentCore

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
        let session: String
        var at: Date
        /// On a bridge, the attested source (`source`), named by `who(_:)`.
        let door: String, who: String, text: String, user: Bool
        var reply: String?
        /// A wake's authority: "self", or the agent whose words it carried.
        var agent: String? = nil
        /// What she did answering it, by name: actions that went through, and
        /// the ones she only filed for User's approval.
        var did: [String] = [], filed: [String] = []
        /// Her last reply or action on it, or when it arrived.
        var active: Date
    }

    static let wakeDoor = "my wake"

    /// User's doors by the surface each writes; any `*-bridge` is an agent's.
    static let userDoors = ["app": "Mac chat", "chat": "Mac chat", "mac": "Mac chat", "telegram": "Telegram",
                           "ios": "iPhone", "iphone": "iPhone", "mobile": "iPhone", "slack": "Slack", "signal": "Signal"]

    package static func door(_ surface: String) -> String? {
        userDoors[surface.lowercased()] ?? (surface.hasSuffix("-bridge") ? "bridge" : nil)
    }

    /// Newest first, from the 12 most recently written transcripts of the
    /// last week (helpers' own sessions left out).
    static func doorLines(dataRoot: URL, now: Date) -> [DoorLine] {
        let dir = dataRoot.appendingPathComponent("chat/messages", isDirectory: true).path
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".jsonl") && !$0.hasPrefix("bot-") }
            .compactMap { name -> (path: String, at: Int)? in
                var info = stat()
                guard lstat(dir + "/" + name, &info) == 0, now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) < 7 * 86_400 else { return nil }
                return (dir + "/" + name, info.st_mtimespec.tv_sec)
            }
            .sorted { $0.at > $1.at }.prefix(12)
        DoorIndex.shared.keep(only: Set(files.map(\.path)), in: dir + "/")
        return files.flatMap { transcript(URL(fileURLWithPath: $0.path)).lines }.sorted { $0.at > $1.at }
    }

    /// Each transcript's door lines (its last 30) and when she last answered
    /// in it, read on from where the previous read stopped: a turn parses
    /// only what was appended since. A new file, a rewrite (another inode)
    /// or a shrink starts again from its last 128 KB.
    private final class DoorIndex: @unchecked Sendable {
        static let shared = DoorIndex()
        struct Entry {
            var inode: UInt64 = 0, offset: UInt64 = 0
            var lines: [DoorLine] = [], open = false
            var mine: Date?
        }
        let lock = NSLock()
        var entries: [String: Entry] = [:]

        /// Only this week's newest transcripts (and the chat she is in) stay indexed.
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
            var partial = false
            if entry.inode != inode || size < entry.offset {
                entry = .init(inode: inode, offset: size > 131_072 ? size - 131_072 : 0)
                partial = entry.offset > 0
            }
            if size > entry.offset {
                try? handle.seek(toOffset: entry.offset)
                if let data = try? handle.read(upToCount: Int(size - entry.offset)),
                   let end = data.lastIndex(of: UInt8(ascii: "\n")) {
                    // Whole rows only: a row still being written is read next time.
                    var rows = data[data.startIndex..<end].split(separator: UInt8(ascii: "\n"))
                    if partial, !rows.isEmpty { rows.removeFirst() }
                    entry.offset += UInt64(end - data.startIndex + 1)
                    read(rows, session: url.deletingPathExtension().lastPathComponent, into: &entry)
                }
            }
            DoorIndex.shared.entries[url.path] = entry
            return (entry.lines, entry.mine)
        }
    }

    /// Rows onto a transcript's index: the things said to her with a known
    /// door, her answer to each, and what she ran answering it. Wake notices
    /// and other mechanical rows are not anyone speaking.
    private static func read(_ rows: [Data.SubSequence], session: String, into entry: inout DoorIndex.Entry) {
        let wake = session == ResidentWake.session
        for raw in rows {
            guard let row = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
                  let content = row["content"] as? String, let at = (row["createdAt"] as? String).flatMap(date) else { continue }
            let metadata = row["metadata"] as? [String: Any]
            switch row["role"] as? String {
            case "assistant":
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                entry.mine = at
                if entry.open {
                    entry.lines[entry.lines.count - 1].reply = ChatSecretRedactor.redactText(content)
                    entry.lines[entry.lines.count - 1].active = at
                    if wake { entry.lines[entry.lines.count - 1].at = at }
                }
            case "tool":
                // Her own act, by its name only: never its arguments or result.
                // A home `<agent>.say` is a message she sent, as agent.message is.
                guard entry.open, metadata?["ok"] as? Bool == true, let tool = metadata?["toolName"] as? String else { continue }
                let input = (metadata?["inputJSON"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                let say = (input?["item"] as? String).flatMap { $0.lowercased().hasSuffix(".say") ? $0 : nil }
                guard let name = tool == "app" ? input?["action"] as? String ?? say : tool, !name.isEmpty else { continue }
                // Filed is not done: an approval card waits on User (the row
                // is rewritten as a plain receipt once he decides).
                let filed = metadata?["kind"] as? String == ChatTranscriptToolMessageKind.approvalPending
                    || ["waiting_approval", "pending_approval"].contains(metadata?["resultStatus"] as? String ?? "")
                if filed { entry.lines[entry.lines.count - 1].filed.append(clip(name.lowercased(), 40)) }
                else { entry.lines[entry.lines.count - 1].did.append(clip(name.lowercased(), 40)) }
                entry.lines[entry.lines.count - 1].active = at
            case "user":
                entry.open = false
                guard metadata?["mechanicalKind"] == nil else { continue }
                // A wake is her speaking; what it says to her is the arrival list.
                if wake {
                    let agent = source(metadata)
                    entry.lines.append(.init(session: session, at: at, door: wakeDoor, who: "me",
                                             text: ChatSecretRedactor.redactText(content), user: false,
                                             agent: agent, active: at))
                    entry.open = true
                    continue
                }
                guard let surface = (metadata?["envelope"] as? [String: Any])?["surface"] as? String, let door = door(surface) else { continue }
                let agent = (metadata?["origin"] as? [String: Any])?["agent"] as? String
                var text: String
                if door == "bridge" {
                    text = ContactThread.bridgedText(content)
                } else {
                    guard agent == nil else { continue }
                    // "[Telegram voice message] Transcript: …": the words, not the note.
                    text = content.replacingOccurrences(of: #"^\[[^\]\n]{1,80}\]\s*(Transcript:\s*)?"#, with: "", options: .regularExpression)
                }
                // A token he pasted never rides into a prompt.
                text = ChatSecretRedactor.redactText(text.trimmingCharacters(in: .whitespacesAndNewlines))
                let bridged = door == "bridge" ? source(metadata) ?? "peer:unknown" : nil
                entry.lines.append(.init(session: session, at: at, door: door, who: bridged ?? "",
                                         text: text.isEmpty ? "(no text: an image or file)" : text, user: door != "bridge",
                                         agent: bridged, active: at))
                entry.open = true
            default: continue
            }
        }
        if entry.lines.count > 30 { entry.lines.removeFirst(entry.lines.count - 30) }
    }

    /// Only persisted origin and verified envelope identity attest a source.
    static func source(_ metadata: [String: Any]?) -> String? {
        let origin = metadata?["origin"] as? [String: Any]
        let envelope = metadata?["envelope"] as? [String: Any]
        guard let agent = origin?["agent"] as? String ?? envelope?["agent"] as? String,
              !agent.isEmpty else { return nil }
        if agent == "agent" || agent == "peer" {
            return "peer:" + (nonEmpty(envelope?["userId"] as? String) ?? "unknown")
        }
        return agent
    }

    /// Who spoke: User on his doors; on a bridge, the lane the bridge attested
    /// or the name User gave that peer in his contacts (agents/peers.json),
    /// never anything the message itself says.
    static func who(_ line: DoorLine, person: String, peers: [String: String]) -> String {
        if line.user { return person }
        guard line.door == "bridge", line.who.hasPrefix("peer:") else { return line.who }
        return peers[line.who] ?? "an agent"
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
    static func elsewhereRows(dataRoot: URL, scope: String, person: String, now: Date) -> [String] {
        guard MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) else { return [] }
        var doors: Set<String> = []
        let peers = peerNames(dataRoot)
        let newest = doorLines(dataRoot: dataRoot, now: now).filter {
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
            return screen(["ELSEWHERE", "closed"], [["Remember across conversations is off, so other chats stay closed."]], verbs: [])
        }
        let person = names(dataRoot).person
        let lines = Array(doorLines(dataRoot: dataRoot, now: now).filter { $0.session != scope }.prefix(12))
        var pages: [String: String] = [:], peers: [String: [String]] = [:]
        let named = peerNames(dataRoot)
        let rows = lines.enumerated().map { index, line -> String in
            let name = "elsewhere.\(index + 1)", who = HerScreen.who(line, person: person, peers: named)
            let exchange = exchangePages(name, line, who: who, dataRoot: dataRoot, now: now)
            for (item, page) in exchange { pages[scope + "\u{0}" + item] = page }
            if let agent = line.agent, agent != "self" {
                for item in exchange.keys { peers[scope + "\u{0}" + item] = [agent] }
                if !previewing { AgentWorkspacePorts.current.tools.markConsumed(peer: agent) }
            }
            return pad(name, 13) + pad(line.door, 10) + pad(clip(who, 16), 10) + pad(age(now.timeIntervalSince(line.at)), 5)
                + quoted(line.door == wakeDoor ? line.reply ?? line.text : line.text, 60)
        }
        if !previewing { HerItemPages.shared.keep(dataRoot, pages, room: scope + "\u{0}elsewhere", peers: peers) }
        return screen(["ELSEWHERE", person + "'s doors, the bridges and my wakes", "newest first"],
                      [rows.isEmpty ? ["nothing said on another door this week"] : rows],
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
    /// started, one per bridge conversation with what she did there. Nil when
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
            let hers = (wake.agent ?? "self") == "self"
            lines.append("Your own wake " + age(now.timeIntervalSince(wake.at)) + " ago"
                + (hers && !peer
                    ? ": \"" + clip(plainLines(reply).joined(separator: " ").replacingOccurrences(of: "\"", with: "'"), 200) + "\""
                    : "") + ". app {item:\"elsewhere\"}")
        }
        if !peer {
            // By her own activity there: a request that came before her last
            // reply here still counts when she answered or acted on it after.
            let bridged = known
                .filter { $0.door == "bridge" && $0.session != scope && $0.active > since && $0.at <= now }
                .sorted { $0.active > $1.active }
            let peers = peerNames(dataRoot)
            var sessions: Set<String> = []
            for latest in bridged where sessions.insert(latest.session).inserted {
                lines.append(bridgeLine(bridged.filter { $0.session == latest.session }, who: who(latest, person: "", peers: peers), now: now))
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// One bridge conversation since her last reply here: who, how many
    /// messages, what she did (replied, the actions she ran by name, the ones
    /// she only filed for User's approval) and when she last did anything.
    /// Never the agent's words, nor hers to it: those open in the room, where
    /// reading them marks the turn as the taint requires.
    private static func bridgeLine(_ fresh: [DoorLine], who: String, now: Date) -> String {
        func names(_ all: [String]) -> String {
            var counted: [(name: String, count: Int)] = []
            for name in all {
                if let i = counted.firstIndex(where: { $0.name == name }) { counted[i].count += 1 } else { counted.append((name, 1)) }
            }
            return counted.prefix(6).map { $0.name + ($0.count > 1 ? " ×\($0.count)" : "") }.joined(separator: ", ")
                + (counted.count > 6 ? ", +\(counted.count - 6) more" : "")
        }
        let ordered = Array(fresh.reversed())
        let ran = names(ordered.flatMap(\.did)), filed = names(ordered.flatMap(\.filed))
        var did = [fresh.contains { $0.reply != nil } ? "you replied" : "no reply from you yet"]
        if !ran.isEmpty { did.append("ran " + ran) }
        if !filed.isEmpty { did.append("filed for approval " + filed) }
        return clip(who, 20) + " over the bridge since your last reply here: "
            + (fresh.count == 1 ? "1 message; " : "\(fresh.count) messages; ") + did.joined(separator: "; ")
            + "; last " + age(now.timeIntervalSince(fresh[0].active)) + " ago. app {item:\"elsewhere\"}"
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
