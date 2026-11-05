import ChatSessionWork
import Experiences
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import StandingBots
import Transcripts
import NativeAgentShared
// Blueprint: | `AgentScreenRooms+Elsewhere.swift` | read-only cross-door continuity; peer turns omit person/helper words |
// Read cross-door inputs beside history; disclose them only after history establishes turn provenance.

/// Join doors into one read-only timeline without creating another conversation owner.
extension AgentScreen {
    /// A wake concludes when its answer lands, not when it starts.
    struct DoorLine: Sendable {
        var id: String = ""
        let session: String
        var at: Date
        let door: String, text: String, user: Bool
        var reply: String?
        /// Attribution comes from the source row, including every steering peer.
        var stamp: TranscriptRowStamp
        var agent: String? { stamp.source }
        var steeredBy: [String] { stamp.steeredBy }
        var byPerson = false
        var active: Date
    }

    static let wakeDoor = "my wake"

    /// Classify person doors by their written surface; `*-bridge` denotes an agent door.
    static let userDoors = ["chat": "Mac chat", "telegram": "Telegram", "ios": "iPhone", "slack": "Slack"]

    package static func door(_ surface: String) -> String? {
        userDoors[surface.lowercased()] ?? (surface.hasSuffix("-bridge") ? "bridge" : nil)
    }

    /// Bound cross-door history to twelve transcripts from the last week; exclude helper sessions.
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

    /// Read only appended transcript bytes; replacement or shrink restarts from the last 128 KB.
    private final class DoorIndex: @unchecked Sendable {
        static let shared = DoorIndex()
        struct Entry {
            var inode: UInt64 = 0, offset: UInt64 = 0
            var lines: [DoorLine] = [], open = false
            /// Runs that carried a person's or wake's row here: the agent's row answers only in one of them; any other run is its own post.
            var askedRuns: Set<String> = []
            var mine: Date?, reply: String?
            var personSends: Set<String> = []
            /// Keep unsolicited posts separate from replies so the timeline does not invent an incoming message.
            var posts: [DoorLine] = []
        }
        let lock = NSLock()
        var entries: [String: Entry] = [:]

        /// Bound retained transcript inventory to this week and helpers still on disk.
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
            // Bounded on purpose: each turn reads this, so a transcript is indexed from its last 128 KB and keeps its newest 30 lines.
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

    /// Index only speech with a known door and its answer; mechanical rows are not speakers.
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
                    instruction: "Repair the complete message from retained transcript evidence; do not guess its timestamp or skip the corrupt row.",
                        recovery: .repair)
            }
            let content = speech.text
            switch speech.role {
            case "assistant":
                if let sent = speech.sendID {
                    if speech.byPerson { entry.personSends.insert(sent) }
                    continue
                }
                guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if let run = speech.run, !entry.askedRuns.contains(run) { entry.open = false }
                if !entry.open, !wake {
                    let surface = (metadata["origin"]?.objectValue ?? [:])["surface"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
                        ?? (metadata["envelope"]?.objectValue ?? [:])["surface"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
                    if let door = surface.flatMap({ AgentScreen.door($0) }), door != "bridge" {
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
                // A wake's arrival list is its incoming context; the wake reply is outgoing speech.
                if wake {
                    entry.lines.append(.init(id: speech.id, session: session, at: at, door: wakeDoor,
                                             text: ChatSecretRedactor.redactText(content), user: false,
                                             stamp: speech.stamp, active: at))
                    entry.open = true
                    if let run = speech.run { entry.askedRuns.insert(run) }
                    continue
                }
                guard let door = spokenDoor(speech, kind: kind) else { continue }
                var text: String
                if door == "bridge" {
                    text = ContactThread.project([speech], style: .thread).first!.text
                } else {
                    guard speech.human else { continue }
                    // Voice transcripts contribute speech without transport notes.
                    text = content.replacingOccurrences(of: #"^\[[^\]\n]{1,80}\]\s*(Transcript:\s*)?"#, with: "", options: .regularExpression)
                }
                // A pasted token must never enter provider context.
                text = ChatSecretRedactor.redactText(text.trimmingCharacters(in: .whitespacesAndNewlines))
                entry.lines.append(.init(id: speech.id, session: session, at: at, door: door,
                                         text: text.isEmpty ? "(no text: an image or file)" : text, user: door != "bridge",
                                         stamp: speech.stamp,
                                         byPerson: speech.human || speech.byPerson || speech.answers.map { entry.personSends.contains($0) } == true,
                                             active: at))
                entry.open = true
                if let run = speech.run { entry.askedRuns.insert(run) }
            default: continue
            }
        }
    }

    /// Actions use the same originating row's door and eligibility as speech; a session's newer speaker cannot stand in for it.
    private static func spokenDoor(_ speech: ContactThread.Line, kind: ChatThreadKind) -> String? {
        guard speech.role == "user", speech.metadata["mechanicalKind"] == nil else { return nil }
        if kind.isOwnWork { return wakeDoor }
        if speech.contact { return "bridge" }
        guard speech.human else { return nil }
        let metadata = speech.metadata
        let surface = (metadata["origin"]?.objectValue ?? [:])["surface"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
            ?? (metadata["envelope"]?.objectValue ?? [:])["surface"]?.stringValue.flatMap({ $0.isEmpty ? nil : $0 })
        return surface.flatMap({ door($0) })
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

    /// Speaker identity comes from attested bridge metadata or saved contacts, never message text.
    static func who(_ line: DoorLine, person: String, peers: [String: String]) -> String {
        if line.door == wakeDoor { return "me" }
        return ContactThread.project([.init(text: line.text, stamp: line.stamp)], person: person, names: peers, unlistedPeer: "an agent").first!.speaker
    }

    private static func quoted(_ text: String, _ limit: Int) -> String {
        "\"" + clip(sentence(text).replacingOccurrences(of: "\"", with: "'"), limit) + "\""
    }

    // MARK: Home

    /// Home names only who and when outside the active chat; cross-conversation words require explicit opening and enabled recall.
    static func elsewhereRows(_ world: AgentWorld, dataRoot: URL, scope: String, person: String, now: Date) -> [String] {
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

    /// Bound the room to twelve exchanges outside this chat; disable it when cross-conversation recall is off.
    static func elsewhereRoom(workspace: WorkspaceOperation, dataRoot: URL, scope: String, now: Date = Date()) -> String {
        do { return try checkedElsewhereRoom(workspace: workspace, dataRoot: dataRoot, scope: scope, now: now) }
        catch { return nameFailure(error) }
    }

    private static func checkedElsewhereRoom(workspace: WorkspaceOperation, dataRoot: URL, scope: String, now: Date) throws -> String {
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
        do { named = try workspace.ports.conversations.identity(dataRoot: dataRoot).peerNames }
        catch {
            return screen(["ELSEWHERE", "Identity unavailable"], [[readFailure(error, reason: "contact_identity_unavailable",
                remedy: Repair.remedy(owner: "agents/peers.json", nextCall: nil,
                    tap: "Repair the contact address book before resolving conversation identities."))]], verbs: [])
        }
        let chats = Result { try withNames(workspace: workspace, dataRoot) { book in
            lines.map { line in Result {
                "chat.\(try book.number("chat", id: line.session) { Set(((try? FileManager.default.contentsOfDirectory(atPath: dataRoot.appendingPathComponent("chat/messages").path)) ?? []).map { ($0 as NSString).deletingPathExtension }) })"
            } }
        } }
        let rows = lines.enumerated().map { index, line -> String in
            let name = "elsewhere.\(index + 1)", who = AgentScreen.who(line, person: person, peers: named)
            let exchange = exchangePages(name, line, who: who, chat: { try chats.get()[index].get() }, now: now)
            for (item, page) in exchange { pages[scope + "\u{0}" + item] = page }
            let shown = ContactThread.Line(text: line.text, stamp: line.stamp)
            ContactThread.consume(shown, mark: { peer, _ in
                if !workspace.previewing { workspace.ports.tools.markConsumed(peer: peer) }
            })
            for item in exchange.keys { speech[scope + "\u{0}" + item] = [shown] }
            return pad(name, 13) + pad(line.door, 10) + pad(clip(who, 16), 10) + pad(age(now.timeIntervalSince(line.at)), 5)
                + quoted(line.door == wakeDoor ? line.reply ?? line.text : line.text, 60)
        }
        if !workspace.previewing { AgentItemPages.shared.keep(dataRoot, pages, room: scope + "\u{0}elsewhere", speech: speech) }
        return screen(["ELSEWHERE", person + "'s doors, the bridges and my wakes", "newest first"],
                      [rows.isEmpty ? ["no exchanges found in the recent transcript window"] : rows],
                      verbs: rows.isEmpty ? [] : [("elsewhere.N", "read that exchange and my reply; continue if needed")])
    }

    private static func exchangePages(_ name: String, _ line: DoorLine, who: String, chat: () throws -> String, now: Date) -> [String: String] {
        do {
            let chat = try chat()
            // Keep exact redacted words and formatting. List rows remain previews; opening an exchange has bounded, lossless continuation pages.
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

    fileprivate struct ElsewhereAct: Sendable {
        /// The act experience's id: a line shows an act once, however many windows read it.
        let id: String
        let door: String
        let personDoor: Bool
        let outcome: Experience.Outcome
    }

    /// Read-only inputs, gathered beside history. Disclosure remains in elsewhere, after history has established this turn's taint.
    package struct ElsewhereReading: Sendable {
        fileprivate var failure: String? = nil
        fileprivate let all: [DoorLine]
        fileprivate let posts: [DoorLine]
        fileprivate let helpers: [String]
        fileprivate let exchanges: [OtherRoomExchange]
        fileprivate var acts: [ElsewhereAct] = []
        fileprivate var actFailures: [String] = []
        fileprivate var since = Date.distantPast
        fileprivate var live: [String] = []
        /// Only the words window decides whether this reading may advance; an act that could not be read is named once and is absent.
        package var failed: Bool { failure != nil }
    }

    /// `live`: the agent's conversations with an open turn right now (the turn runtime owns that knowledge).
    /// `since`: the agent's last step on this line; nil at turn start, which reads since its last reply here.
    package static func readElsewhere(workspace: WorkspaceOperation, dataRoot: URL, scope: String, turn: Date,
                                      live: [String], since: Date?) async -> ElsewhereReading? {
        do { return try await checkedElsewhere(workspace: workspace, dataRoot: dataRoot, scope: scope, turn: turn, live: live, since: since) }
        catch { return ElsewhereReading(failure: nameFailure(error), all: [], posts: [], helpers: [], exchanges: []) }
    }

    private static func checkedElsewhere(workspace: WorkspaceOperation, dataRoot: URL, scope: String, turn: Date,
                                         live: [String], since step: Date?) async throws -> ElsewhereReading? {
        guard try MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) else { return nil }
        let mine: Date?
        if step != nil || NativeAgentChatSessionID.normalizedPathComponent(scope) == nil { mine = nil }
        else { mine = try transcript(dataRoot.appendingPathComponent("chat/messages/\(scope).jsonl")).mine }
        let identity = try workspace.ports.conversations.identity(dataRoot: dataRoot)
        let since = step ?? mine ?? turn.addingTimeInterval(-3600)
        let known = try doorLines(dataRoot: dataRoot, now: turn)
        // doorLines refreshed the shared index once. Do not enumerate and reopen all twelve transcripts again for posts and bridge exchanges.
        let sessions = try SessionConversation(dataRoot: dataRoot)
        let directory = dataRoot.appendingPathComponent("chat/messages", isDirectory: true).standardizedFileURL.path + "/"
        let posts = DoorIndex.shared.lock.withLock {
            DoorIndex.shared.entries.filter { $0.key.hasPrefix(directory) }.values.flatMap(\.posts)
        }
            .filter { $0.at > since && $0.at <= turn && $0.session != scope && !sessions.isHelper($0.session) }
            .sorted { $0.at > $1.at }
        let acts = try await elsewhereActs(dataRoot: dataRoot, scope: scope, since: since, now: turn, sessions: sessions, known: known)
        return try ElsewhereReading(all: known.filter { $0.session != scope && $0.active > since && $0.at <= turn },
            posts: posts, helpers: helperLines(dataRoot: dataRoot, scope: scope, since: since, now: turn),
            exchanges: otherRoomExchanges(dataRoot: dataRoot, identity: identity,
                since: since, now: turn, lines: known),
            acts: acts.lines, actFailures: acts.failures,
            since: since, live: live.filter { $0 != scope }.map { session in
                guard let line = known.first(where: { $0.session == session }) else { return "another conversation" }
                return line.door == wakeDoor ? "your own wake" : line.door == "bridge" ? "an agent conversation" : line.door
            })
    }

    /// Resolve only effected acts and their exact transcript evidence. The transcript owner shares each affected session's read.
    private static func elsewhereActs(dataRoot: URL, scope: String, since: Date, now: Date,
                                      sessions: SessionConversation, known: [DoorLine]) async throws -> (lines: [ElsewhereAct], failures: [String]) {
        let path = dataRoot.appendingPathComponent("experiences/experiences.sqlite").path
        func unavailable(_ detail: String) -> ToolFailureError {
            ToolFailureError("Actions elsewhere could not be read: " + detail, effects: .none, owner: path,
                instruction: "Repair the reported experience or its transcript evidence before advancing this reading.", recovery: .repair)
        }
        do {
            let store = ExperienceStore.at(dataRoot)
            let born = try await store.born(kinds: [.act], after: since, limit: Int.max)
            var causes = Dictionary(uniqueKeysWithValues: born.map { ($0.id, $0) })
            var candidates: [(act: String, reference: String, session: String, outcome: Experience.Outcome)] = []
            var failures: [String] = []
            func gap(_ error: Error) {
                let named: String
                if let typed = error as? ToolFailureError { named = nameFailure(typed) }
                else { named = nameFailure(unavailable(error.localizedDescription)) }
                if !failures.contains(named) { failures.append(named) }
            }
            for act in born {
                guard let outcome = act.outcome, outcome.effects == .occurred else { continue }
                do {
                    guard let at = NativeTimestampFormat.parseISO8601FractionalFirst(act.at) else {
                        throw unavailable("Experience " + act.id + " has an unreadable birth time.")
                    }
                    guard at <= now else { continue }
                    var cause = act, visited: Set<String> = [act.id]
                    var transcript: Experience.Ref?
                    while transcript == nil {
                        if cause.kind == .heard {
                            transcript = cause.evidence.first { $0.source.hasPrefix("chat/messages/") && $0.source.hasSuffix(".jsonl") }
                            if transcript != nil { break }
                        }
                        guard let id = cause.cause.first else { break }
                        guard visited.insert(id).inserted else { throw unavailable("Experience " + act.id + " has a circular cause.") }
                        if let kept = causes[id] { cause = kept }
                        else {
                            guard let read = try await store.experience(id) else { throw unavailable("Cause " + id + " is not recorded yet.") }
                            causes[id] = read
                            cause = read
                        }
                    }
                    guard let transcript else {
                        if cause.kind == .heard {
                            throw unavailable("Transcript evidence is unavailable for heard experience " + cause.id + ".")
                        }
                        continue
                    }
                    let session = String(transcript.source.dropFirst("chat/messages/".count).dropLast(".jsonl".count))
                    guard NativeAgentChatSessionID.normalizedPathComponent(session) == session, !transcript.id.isEmpty else {
                        throw unavailable("Experience " + cause.id + " has unreadable transcript evidence.")
                    }
                    guard session != scope, !sessions.isHelper(session) else { continue }
                    guard sessions.kind(session) != nil else {
                        throw unavailable("Conversation classification is unavailable for " + session + ".")
                    }
                    candidates.append((act.id, "message:" + session + "/" + transcript.id, session, outcome))
                } catch { gap(error) }
            }
            guard !candidates.isEmpty else { return ([], failures) }
            var indexed: [String: DoorLine] = [:]
            for line in known where !line.id.isEmpty { indexed["message:" + line.session + "/" + line.id] = line }
            let resolver = ConversationHistory.ExperienceResolver(dataRoot: dataRoot)
            var source: [String: (session: String, row: [String: JSONValue])] = [:]
            let unindexed = Dictionary(grouping: candidates.filter { indexed[$0.reference] == nil }, by: \.session)
            for (_, group) in unindexed.sorted(by: { $0.key < $1.key }) {
                do {
                    let references = group.map(\.reference)
                    let resolved = try await resolver.resolve(for: references, includingSourceRows: true).messages
                    source.merge(resolved) { _, new in new }
                } catch { gap(error) }
            }
            let lines = candidates.compactMap { candidate -> ElsewhereAct? in
                do {
                    if let line = indexed[candidate.reference] {
                        return ElsewhereAct(id: candidate.act, door: line.door, personDoor: line.user, outcome: candidate.outcome)
                    }
                    guard let origin = source[candidate.reference], let kind = sessions.kind(candidate.session) else {
                        throw unavailable("The originating transcript row is unavailable for " + candidate.reference + ".")
                    }
                    let speech = ContactThread.Line(origin.row)
                    if let failure = speech.provenanceFailure { throw unavailable(failure) }
                    guard case .string? = origin.row["content"], speech.date != nil else {
                        throw unavailable("The originating transcript row has unreadable content or time for " + candidate.reference + ".")
                    }
                    guard let door = spokenDoor(speech, kind: kind) else { return nil }
                    return ElsewhereAct(id: candidate.act, door: door, personDoor: door != "bridge" && door != wakeDoor, outcome: candidate.outcome)
                } catch { gap(error); return nil }
            }
            return (lines, failures)
        } catch let failure as ToolFailureError { throw failure }
        catch { throw unavailable(error.localizedDescription) }
    }

    /// Exchanges carried per breath; older ones are counted and the agent's elsewhere room opens them whole.
    private static let breathExchanges = 4

    /// One step's breath: the same elsewhere reading as turn start, since the agent's last step on this line.
    /// A failed read names itself and leaves `read` false, so the next step reads the same window again.
    /// `since` nil: the turn-start window (the agent's last reply here), used when the opening read failed.
    /// `shown`: act ids this line already carried; `acts` returns the ids this breath names, so an act is shown once and a repeated act is not.
    package static func breath(workspace: WorkspaceOperation, dataRoot: URL, scope: String, peer: Bool, since: Date?, shown: Set<String>,
                               now: Date) async -> (text: String?, read: Bool, acts: [String]) {
        guard let reading = await readElsewhere(workspace: workspace, dataRoot: dataRoot, scope: scope, turn: now, live: [], since: since)
        else { return (nil, true, []) }
        if let failure = reading.failure { return (failure, false, []) }
        let lines = render(reading, workspace: workspace, dataRoot: dataRoot, scope: scope, peer: peer, shown: shown, now: now)
        let acts = disclosedActs(reading, peer: peer, shown: shown).suffix(actLines).map(\.id)
        return (lines.isEmpty ? nil : "Elsewhere since your last step:\n" + lines.joined(separator: "\n"), !reading.failed, acts)
    }

    /// Acts named per reading; older ones are counted.
    private static let actLines = 8

    /// The acts a line may see: a peer-steered line only those from person doors (the word lines' taint rule), never one it was already shown.
    fileprivate static func disclosedActs(_ reading: ElsewhereReading, peer: Bool, shown: Set<String>) -> [ElsewhereAct] {
        reading.acts.filter { (!peer || $0.personDoor) && !shown.contains($0.id) }
    }

    /// The person's words on other doors and the agent's answers there since `since`, oldest first.
    /// A peer-steered line gets door, count and time only: the person's words never reach a peer.
    private static func breathLines(_ known: [DoorLine], dataRoot: URL, scope: String, peer: Bool, since: Date, now: Date) -> [String] {
        let answered = { (line: DoorLine) in line.reply != nil && line.active > since && line.active <= now }
        let fresh = known.filter { $0.user && $0.session != scope && $0.at <= now && ($0.at > since || answered($0)) }
            .sorted { $0.active > $1.active }
        guard !fresh.isEmpty else { return [] }
        let person = names(dataRoot).person
        var lines = fresh.prefix(breathExchanges).reversed().map { line -> String in
            let reply = answered(line) ? line.reply : nil
            guard line.at > since else {
                return "You answered " + person + " on " + line.door + ", " + age(now.timeIntervalSince(line.active)) + " ago"
                    + (peer ? "" : reply.map { ": " + said($0) } ?? "")
            }
            var text = person + " on " + line.door + ", " + age(now.timeIntervalSince(line.at)) + " ago"
            if !peer { text += ": " + said(line.text) }
            if let reply { text += peer ? "; you answered" : "\nYou answered: " + said(reply) }
            return text
        }
        if fresh.count > breathExchanges {
            lines.append("\(fresh.count - breathExchanges) earlier on other doors. app {item:\"elsewhere\"}")
        }
        return lines
    }

    private static func said(_ text: String) -> String {
        "\"" + clip(plainLines(text).joined(separator: " ").replacingOccurrences(of: "\"", with: "'"), 280) + "\""
    }

    /// Since the last local reply, carry bounded cross-door news only under enabled recall. Peer-steered turns receive person-door counts and times, never
    /// words; helper and bridge words stay out, and wake words require an unsteered source.
    package static func elsewhere(workspace: WorkspaceOperation, dataRoot: URL, scope: String, surface: String, peer: Bool, turn: Date?,
                                  reading: ElsewhereReading? = nil) async -> String? {
        guard door(surface) != nil else { return nil }
        do { guard try MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) else { return nil } }
        catch { return nameFailure(error) }
        let key = "elsewhere\u{0}" + dataRoot.standardizedFileURL.path + "\u{0}" + scope + "\u{0}" + (turn.map { String($0.timeIntervalSince1970) } ?? "-")
            + (peer ? "\u{0}peer" : "\u{0}person")
        if turn != nil, let kept = AgentMemo.shared.glance(key) { return kept }
        let now = turn ?? Date()
        let gathered: ElsewhereReading?
        if let reading { gathered = reading }
        else { gathered = await readElsewhere(workspace: workspace, dataRoot: dataRoot, scope: scope, turn: now, live: [], since: nil) }
        guard let reading = gathered else { return nil }
        if let failure = reading.failure { return failure }
        let lines = render(reading, workspace: workspace, dataRoot: dataRoot, scope: scope, peer: peer, now: now)
        let text = lines.isEmpty ? nil : lines.joined(separator: "\n")
        if turn != nil { AgentMemo.shared.keepGlance(key, text) }
        return text
    }

    /// Everything that changed in the agent elsewhere in the reading's window, for a person's line or (words withheld) a peer's.
    private static func render(_ reading: ElsewhereReading, workspace: WorkspaceOperation, dataRoot: URL, scope: String, peer: Bool,
                               shown: Set<String> = [], now: Date) -> [String] {
        let all = reading.all
        var lines = breathLines(all, dataRoot: dataRoot, scope: scope, peer: peer, since: reading.since, now: now)
        let acts = disclosedActs(reading, peer: peer, shown: shown)
        lines += acts.suffix(actLines).map { $0.door + " you " + $0.outcome.domain + " " + $0.outcome.status }
        if acts.count > actLines { lines.append("+\(acts.count - actLines) more actions on other doors") }
        lines += reading.actFailures
        if !reading.live.isEmpty {
            lines.append(peer ? "You are also mid-turn in \(reading.live.count) other conversation(s) right now."
                : "You are also mid-turn right now on: " + reading.live.joined(separator: ", ") + ".")
        }
        // On peer-steered turns, the person's conversations disclose only door, count and time, including the agent's replies there.
        let posts = reading.posts
        if let latest = posts.first {
            let person = names(dataRoot).person
            var line = "You posted to " + person + " on " + latest.door + " " + age(now.timeIntervalSince(latest.at)) + " ago"
            if !peer { line += ": " + quoted(latest.text, 160) }
            if posts.count > 1 { line += "; \(posts.count - 1) more since your last reply here" }
            lines.append(line + ". app {item:\"elsewhere\"}")
        }
        if let wake = all.first(where: { $0.door == wakeDoor && $0.reply != nil }), let reply = wake.reply {
            // The agent's words travel only from a wake that was the agent's alone, and never into a turn a peer steers: a wake carrying an agent's words
            // would launder them past the taint (ResidentWake.take's own rule).
            let ownWake = (wake.agent ?? "self") == "self" && wake.steeredBy.isEmpty
            lines.append("Your own wake " + age(now.timeIntervalSince(wake.at)) + " ago"
                + (ownWake && !peer
                    ? ": \"" + clip(plainLines(reply).joined(separator: " ").replacingOccurrences(of: "\"", with: "'"), 200) + "\""
                    : "") + ". app {item:\"elsewhere\"}")
        }
        if !peer {
            lines += reading.helpers
            for exchange in reading.exchanges.reversed().filter({ $0.sessionID != scope }).prefix(5) {
                lines.append(exchange.contact + " over the bridge since your last reply here:\n"
                    + "They said: \"" + clip(exchange.message, 600).replacingOccurrences(of: "\"", with: "'")
                    + "\"\nYou replied: \"" + clip(exchange.reply, 600).replacingOccurrences(of: "\"", with: "'") + "\"")
            }
        }
        return lines
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
}
