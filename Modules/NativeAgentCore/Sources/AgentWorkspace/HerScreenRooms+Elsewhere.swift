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
        let door: String, who: String, text: String, user: Bool
        var reply: String?
        /// A wake's authority: "self", or the agent whose words it carried.
        var agent: String? = nil
    }

    static let wakeDoor = "my wake"

    /// User's doors by the surface each writes; any `*-bridge` is an agent's.
    static let userDoors = ["app": "Mac chat", "chat": "Mac chat", "mac": "Mac chat", "telegram": "Telegram",
                           "ios": "iPhone", "iphone": "iPhone", "mobile": "iPhone", "slack": "Slack", "signal": "Signal"]

    package static func door(_ surface: String) -> String? {
        userDoors[surface.lowercased()] ?? (surface.hasSuffix("-bridge") ? "bridge" : nil)
    }

    /// Newest first, from the 12 most recently written transcripts of the
    /// last week (helpers' own sessions left out), the last 128 KB of each,
    /// each kept until its file changes.
    static func doorLines(dataRoot: URL, now: Date) -> [DoorLine] {
        let dir = dataRoot.appendingPathComponent("chat/messages", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" && !$0.lastPathComponent.hasPrefix("bot-") }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .filter { now.timeIntervalSince($0.1) < 7 * 86_400 }
            .sorted { $0.1 > $1.1 }.prefix(12)
        let root = dataRoot.standardizedFileURL.path + "\u{0}doors."
        return files.flatMap { url, _ in
            HerMemo.shared.cached(root + url.lastPathComponent, stamp: [stamp(url)]) { doorLines(url) }
        }.sorted { $0.at > $1.at }
    }

    /// A transcript's last 30 things said to her with a known door. Wake
    /// notices and other mechanical rows are not anyone speaking.
    private static func doorLines(_ url: URL) -> [DoorLine] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 131_072 ? size - 131_072 : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        var rows = data.split(separator: UInt8(ascii: "\n"))
        if size > 131_072, !rows.isEmpty { rows.removeFirst() }
        let session = url.deletingPathExtension().lastPathComponent
        let wake = session == ResidentWake.session
        var found: [DoorLine] = [], open = false
        for raw in rows {
            guard let row = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
                  let content = row["content"] as? String, let at = (row["createdAt"] as? String).flatMap(date) else { continue }
            let metadata = row["metadata"] as? [String: Any]
            switch row["role"] as? String {
            case "assistant":
                if open, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    found[found.count - 1].reply = ChatSecretRedactor.redactText(String(content.prefix(1200)))
                    if wake { found[found.count - 1].at = at }
                }
            case "user":
                open = false
                guard metadata?["mechanicalKind"] == nil else { continue }
                // A wake is her speaking; what it says to her is the arrival list.
                if wake {
                    let agent = source(metadata)
                    found.append(.init(session: session, at: at, door: wakeDoor, who: "me",
                                       text: ChatSecretRedactor.redactText(String(content.prefix(1200))), user: false,
                                       agent: agent))
                    open = true
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
                found.append(.init(session: session, at: at, door: door, who: door == "bridge" ? bridgeWho(agent, content) : "",
                                   text: text.isEmpty ? "(no text: an image or file)" : String(text.prefix(1200)), user: door != "bridge",
                                   agent: door == "bridge" ? source(metadata) ?? "peer:unknown" : nil))
                open = true
            default: continue
            }
        }
        return Array(found.suffix(30))
    }

    /// Only persisted origin and verified envelope identity attest a source.
    private static func source(_ metadata: [String: Any]?) -> String? {
        let origin = metadata?["origin"] as? [String: Any]
        let envelope = metadata?["envelope"] as? [String: Any]
        guard let agent = origin?["agent"] as? String ?? envelope?["agent"] as? String,
              !agent.isEmpty else { return nil }
        if agent == "agent" || agent == "peer" {
            return "peer:" + (nonEmpty(envelope?["userId"] as? String) ?? "unknown")
        }
        return agent
    }

    /// Who spoke on the bridge: a built-in lane by its id, a peer by the
    /// label the bridge put on its turn.
    private static func bridgeWho(_ agent: String?, _ content: String) -> String {
        if let agent, agent != "agent" { return agent }
        for (open, close) in [("[from: ", ", via bridge]"), ("came from ", ", another agent"), ("[", "'s reply to")] {
            if let start = content.range(of: open), let end = content.range(of: close, range: start.upperBound..<content.endIndex),
               content.distance(from: start.upperBound, to: end.lowerBound) <= 40 { return String(content[start.upperBound..<end.lowerBound]) }
        }
        return "an agent"
    }

    private static func quoted(_ text: String, _ limit: Int) -> String {
        "\"" + clip(sentence(text).replacingOccurrences(of: "\"", with: "'"), limit) + "\""
    }

    // MARK: Home

    /// Home's ELSEWHERE: who spoke last on each door and when, one line each,
    /// the chat she is in left out. The words open in the room, not here:
    /// home rides turns another agent steers too. Nothing when "Remember
    /// across conversations" is off.
    static func elsewhereRows(dataRoot: URL, scope: String, person: String, now: Date) -> [String] {
        guard MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) else { return [] }
        var doors: Set<String> = []
        let newest = doorLines(dataRoot: dataRoot, now: now).filter { $0.session != scope && doors.insert($0.door).inserted }.prefix(5)
        var rows = newest.map { line in
            pad(line.door, 10) + (line.user ? person : clip(line.who, 20)) + " · " + age(now.timeIntervalSince(line.at))
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
        let rows = lines.enumerated().map { index, line -> String in
            let name = "elsewhere.\(index + 1)", who = line.user ? person : line.who
            pages[scope + "\u{0}" + name] = exchangePage(name, line, who: who, dataRoot: dataRoot, now: now)
            if let agent = line.agent, agent != "self" {
                peers[scope + "\u{0}" + name] = [agent]
                if !previewing { AgentWorkspacePorts.current.tools.markConsumed(peer: agent) }
            }
            return pad(name, 13) + pad(line.door, 10) + pad(clip(who, 16), 10) + pad(age(now.timeIntervalSince(line.at)), 5)
                + quoted(line.door == wakeDoor ? line.reply ?? line.text : line.text, 60)
        }
        if !previewing { HerItemPages.shared.keep(dataRoot, pages, room: scope + "\u{0}elsewhere", peers: peers) }
        return screen(["ELSEWHERE", person + "'s doors, the bridges and my wakes", "newest first"],
                      [rows.isEmpty ? ["nothing said on another door this week"] : rows],
                      verbs: rows.isEmpty ? [] : [("elsewhere.N", "that exchange whole, with my reply")])
    }

    private static func exchangePage(_ name: String, _ line: DoorLine, who: String, dataRoot: URL, now: Date) -> String {
        let dir = dataRoot.appendingPathComponent("chat/messages").path
        let chat = withNames(dataRoot) { book in
            "chat.\(book.number("chat", id: line.session) { Set(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { ($0 as NSString).deletingPathExtension }) })"
        }
        func body(_ text: String) -> [String] { plainLines(text).prefix(12).map { clip($0, 200) } }
        return screen([name, line.door, who, when(line.at, now: now) + " (" + age(now.timeIntervalSince(line.at)) + " ago)"],
                      [section("SAID", body(line.text)), section("ME", line.reply.map(body) ?? ["no reply from me there yet"])],
                      verbs: [(chat, "the whole conversation")], back: "Back: elsewhere · home.")
    }

    // MARK: The per-turn line

    /// At most two lines a turn, one per source, since her last reply in this
    /// chat (or within the hour, in a chat she has not answered yet): User said
    /// something on another of his doors, and one of her own wakes concluded.
    /// Bridges never. Nil when nothing is new, when "Remember across
    /// conversations" is off, or on an unknown door. On a turn another agent
    /// steers (`peer`), User's door, count and time only: his words do not ride
    /// where she could relay them. Her wake is her own thought, so it rides
    /// there too. One read under a 150 ms budget, the same line every
    /// iteration of a turn.
    package static func elsewhere(dataRoot: URL, scope: String, surface: String, peer: Bool, turn: Date?) async -> String? {
        guard let here = door(surface), MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) else { return nil }
        let key = "elsewhere\u{0}" + scope + "\u{0}" + (turn.map { String($0.timeIntervalSince1970) } ?? "-")
        if turn != nil, let kept = HerMemo.shared.glance(key) { return kept }
        let now = turn ?? Date()
        let done: GlanceText? = await withCheckedContinuation { continuation in
            let once = OnceResume<GlanceText>(continuation)
            Task.detached(priority: .userInitiated) {
                once.resume(GlanceText(text: elsewhereLine(dataRoot: dataRoot, scope: scope, here: here, peer: peer, now: now)))
            }
            Task.detached { try? await Task.sleep(for: .milliseconds(150)); once.resume(nil) }
        }
        if turn != nil { HerMemo.shared.keepGlance(key, done?.text) }
        return done?.text
    }

    private static func elsewhereLine(dataRoot: URL, scope: String, here: String, peer: Bool, now: Date) -> String? {
        let mine: Date? = NativeAgentChatSessionID.normalizedPathComponent(scope) == nil ? nil
            : logTail(dataRoot.appendingPathComponent("chat/messages/\(scope).jsonl"), bytes: 65_536).last { $0.mine }?.at ?? nil
        let since = mine ?? now.addingTimeInterval(-3600)
        let all = doorLines(dataRoot: dataRoot, now: now).filter { $0.session != scope && $0.at > since && $0.at <= now }
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
