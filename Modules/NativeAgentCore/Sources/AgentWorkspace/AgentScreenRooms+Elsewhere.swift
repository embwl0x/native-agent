import ChatSessionWork
import ChatTurnContracts
import Experiences
import Foundation
import MemoryV2
import NativeAgentCore
import PersistenceCore
import Transcripts
import TurnTrace
import NativeAgentShared
// Blueprint: | `AgentScreenRooms+Elsewhere.swift` | One record reading and rendering of recent life; retained home/contact door index and effected acts |

extension AgentScreen {
    /// An exchange concludes when its answer lands, not when it starts.
    struct DoorLine: Sendable {
        var id: String = ""
        var run: String? = nil
        let session: String
        var at: Date
        let door: String, text: String
        var reply: String?
        /// Attribution comes from the source row, including every steering peer.
        var stamp: TranscriptRowStamp
        var agent: String? { stamp.source }
        var byPerson = false
        var active: Date
    }

    /// The agent's own work (its lines, and conversations it opened for itself) read as a door; its thoughts are the record's, never a door.
    static let ownDoor = "my own work"

    /// Classify person doors by their written surface; `*-bridge` denotes an agent door.
    static let userDoors = ["chat": "Mac chat", "telegram": "Telegram", "ios": "iPhone", "slack": "Slack"]

    package static func door(_ surface: String) -> String? {
        userDoors[surface.lowercased()] ?? (surface.hasSuffix("-bridge") ? "bridge" : nil)
    }

    static func doorLines(dataRoot: URL, now: Date, since: Date? = nil, sessions: SessionConversation? = nil) throws -> [DoorLine] {
        let dir = dataRoot.appendingPathComponent("chat/messages", isDirectory: true).path
        let sessions = try sessions ?? SessionConversation(dataRoot: dataRoot)
        let entries: [String]
        do { entries = try FileManager.default.contentsOfDirectory(atPath: dir) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { entries = [] }
        let names = entries.filter { $0.hasSuffix(".jsonl") }
        let helpers = Set(names.filter { sessions.isHelper(String($0.dropLast(6))) }).union([Attention.stream + ".jsonl"])
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
                return try transcript(URL(fileURLWithPath: file.path))
            }.sorted { $0.at > $1.at }
    }

    /// Read only appended transcript bytes; replacement or shrink restarts from the last 128 KB.
    private final class DoorIndex: @unchecked Sendable {
        static let shared = DoorIndex()
        struct Entry {
            var inode: UInt64 = 0, offset: UInt64 = 0
            var lines: [DoorLine] = []
            var adjacentInput = false
            var personSends: Set<String> = []
        }
        let lock = NSLock()
        var entries: [String: Entry] = [:]

        /// Bound retained transcript inventory to this week and helpers still on disk.
        func keep(only paths: Set<String>, in dir: String) {
            lock.withLock { entries = entries.filter { !$0.key.hasPrefix(dir) || paths.contains($0.key) } }
        }
    }

    private static func transcript(_ url: URL) throws -> [DoorLine] {
        try DoorIndex.shared.lock.withLock {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                DoorIndex.shared.entries[url.path] = nil
                if errno == ENOENT { return [] }
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
            return entry.lines
        }
    }

    /// Index only speech with a known door and its answer; mechanical rows are not speakers.
    private static func read(_ rows: [Data.SubSequence], session: String, dataRoot: URL, into entry: inout DoorIndex.Entry) throws {
        guard let kind = try SessionConversation(dataRoot: dataRoot).kind(session) else {
            throw ToolFailureError("Conversation classification is unavailable for " + session, effects: .none,
                owner: dataRoot.appendingPathComponent("chat/sessions.json").path,
                instruction: "Reconcile this transcript with its owning session index before projecting it into other rooms.", recovery: .repair)
        }
        let own = kind.isOwnWork
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
                let index: Int?
                if let run = speech.run {
                    index = entry.lines.lastIndex { $0.run == run }
                } else if entry.adjacentInput {
                    index = entry.lines.indices.last
                } else {
                    index = nil
                }
                entry.adjacentInput = false
                guard let index else { continue }
                entry.lines[index].reply = ChatSecretRedactor.redactText(content)
                entry.lines[index].active = at
                if own { entry.lines[index].at = at }
            case "user":
                let previousCount = entry.lines.count
                defer { entry.adjacentInput = entry.lines.count > previousCount }
                guard metadata["mechanicalKind"] == nil else { continue }
                // The agent's own work opens with its incoming context; its reply is outgoing speech.
                if own {
                    entry.lines.append(.init(id: speech.id, run: speech.run, session: session, at: at, door: ownDoor,
                                             text: ChatSecretRedactor.redactText(content),
                                             stamp: speech.stamp, active: at))
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
                entry.lines.append(.init(id: speech.id, run: speech.run, session: session, at: at, door: door,
                                         text: text.isEmpty ? "(no text: an image or file)" : text,
                                         stamp: speech.stamp,
                                         byPerson: speech.human || speech.byPerson || speech.answers.map { entry.personSends.contains($0) } == true,
                                             active: at))
            default: continue
            }
        }
    }

    /// Actions use the same originating row's door and eligibility as speech; a session's newer speaker cannot stand in for it.
    private static func spokenDoor(_ speech: ContactThread.Line, kind: ChatThreadKind) -> String? {
        guard speech.role == "user", speech.metadata["mechanicalKind"] == nil else { return nil }
        if kind.isOwnWork { return ownDoor }
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
                  line.active > since, line.active <= now else { return nil }
            return OtherRoomExchange(id: line.session + ":" + line.id, sessionID: line.session,
                contactID: line.agent ?? "another agent", contact: clip(who(line, person: profile.person, peers: named), 80),
                agent: profile.agent, at: line.active, message: String(line.text.prefix(600)), reply: String(reply.prefix(600)))
        }.sorted { ($0.at, $0.id) < ($1.at, $1.id) }
    }

    /// Speaker identity comes from attested bridge metadata or saved contacts, never message text.
    static func who(_ line: DoorLine, person: String, peers: [String: String]) -> String {
        if line.door == ownDoor { return "me" }
        return ContactThread.project([.init(text: line.text, stamp: line.stamp)], person: person, names: peers, unlistedPeer: "an agent").first!.speaker
    }

    static func elsewhereRoom(workspace: WorkspaceOperation, dataRoot: URL, scope: String, now: Date = Date()) async -> String {
        guard let reading = await readElsewhere(dataRoot: dataRoot, scope: scope, turn: now, since: nil) else {
            return screen(["ELSEWHERE", "closed"], [["Remember across conversations is off."]], verbs: [])
        }
        if let failure = reading.failure { return failure }
        let peer = workspace.turn?.steeringStamp().isEmpty == false
        return screen(["ELSEWHERE", "newest first"], [lifeLines(reading, scope: scope, peer: peer, now: now)], verbs: [])
    }

    fileprivate struct ElsewhereAct: Sendable {
        let id: String
        let door: String
        let personDoor: Bool
        let outcome: Experience.Outcome
        let at: Date
    }

    package struct ElsewhereReading: Sendable {
        fileprivate var failure: String? = nil
        fileprivate var rows: [Experience] = []
        fileprivate var acts: [ElsewhereAct] = []
        fileprivate var actFailures: [String] = []
        fileprivate var since = Date.distantPast
        package var lastThought: String? = nil
        package var failed: Bool { failure != nil }
    }

    package static func readElsewhere(dataRoot: URL, scope: String?, turn: Date,
                                      since: Date?) async -> ElsewhereReading? {
        do {
            guard try MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) else { return nil }
            let read = try await ExperienceStore.at(dataRoot).conversationLife(in: scope, since: since, through: turn)
            let rows = read.rows.experiences
            let indexed = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let lastThought = rows.lazy.compactMap { row -> String? in
                guard row.kind == .thought, ["hit", "empty"].contains(row.outcome?.status ?? ""), row.steeredBy == [],
                      let run = row.thought?.run, let answer = indexed[Experience.answer(run: run)], answer.steeredBy == [],
                      let words = answer.face?.words, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return words
            }.first
            let acts: (lines: [ElsewhereAct], failures: [String])
            if let scope {
                do {
                    acts = try await elsewhereActs(dataRoot: dataRoot, scope: scope, since: read.since, now: turn,
                        sessions: SessionConversation(dataRoot: dataRoot))
                } catch {
                    return ElsewhereReading(failure: nameFailure(error), since: read.since, lastThought: lastThought)
                }
            } else { acts = ([], []) }
            let failures = read.rows.unreadable.map { nameFailure($0.cause) }
            return ElsewhereReading(failure: failures.isEmpty ? nil : failures.joined(separator: "\n"), rows: rows,
                acts: acts.lines, actFailures: acts.failures, since: read.since, lastThought: lastThought)
        } catch { return ElsewhereReading(failure: nameFailure(error)) }
    }

    private static func elsewhereActs(dataRoot: URL, scope: String, since: Date, now: Date,
                                      sessions: SessionConversation) async throws -> (lines: [ElsewhereAct], failures: [String]) {
        let path = dataRoot.appendingPathComponent("experiences/experiences.sqlite").path
        func unavailable(_ detail: String) -> ToolFailureError {
            ToolFailureError("Actions elsewhere could not be read: " + detail, effects: .none, owner: path,
                instruction: "Repair the reported experience or its transcript evidence before advancing this reading.", recovery: .repair)
        }
        do {
            let store = ExperienceStore.at(dataRoot)
            let read = try await store.born(kinds: [.act], after: since, limit: Int.max)
            let born = read.experiences
            let subjects = Array(Set(born.filter { $0.outcome?.effects == .occurred }.flatMap(\.cause)))
            var dispatchUnreadable = 0
            var mindActs: Set<String> = []
            if !subjects.isEmpty {
                let dispatches = try await TurnTracePersistLane(dataRootOverride: dataRoot).events(
                    .init(subjects: subjects, kinds: ["tool.dispatch"], from: since, through: now))
                dispatchUnreadable = dispatches.unreadable
                for event in dispatches.events where event.sessionId == Attention.stream {
                    guard let payload = event.payload.objectValue, payload["phase"] == .string("end"),
                          let id = payload["receipt"]?.objectValue?["id"]?.stringValue else { continue }
                    mindActs.insert(id)
                }
            }
            var causes = Dictionary(uniqueKeysWithValues: born.map { ($0.id, $0) })
            var candidates: [(act: String, reference: String, session: String, outcome: Experience.Outcome, at: Date)] = []
            var native: [ElsewhereAct] = []
            var failures: [String] = []
            func gap(_ error: Error) {
                let named: String
                if let typed = error as? ToolFailureError { named = nameFailure(typed) }
                else { named = nameFailure(unavailable(error.localizedDescription)) }
                if !failures.contains(named) { failures.append(named) }
            }
            if dispatchUnreadable > 0 { gap(unavailable("\(dispatchUnreadable) closing dispatch rows are unreadable.")) }
            // An act that will not fold is named by id with why; the readable acts are still read.
            for record in read.unreadable { gap(unavailable(record.words)) }
            for act in born {
                guard let outcome = act.outcome, outcome.effects == .occurred else { continue }
                do {
                    guard let at = NativeTimestampFormat.parseISO8601FractionalFirst(act.at) else {
                        throw unavailable("Experience " + act.id + " has an unreadable birth time.")
                    }
                    guard at <= now else { continue }
                    // Native part calls have no heard row. Their own closing dispatch attests the mind stream instead.
                    if mindActs.contains(act.id) {
                        if scope != Attention.stream {
                            native.append(ElsewhereAct(id: act.id, door: ownDoor, personDoor: false, outcome: outcome, at: at))
                        }
                        continue
                    }
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
                    // A turn that began with no message row (hidden input, a wake) has no speaker, so its acts have no door here:
                    // the same class as a mechanical row, and nothing to repair.
                    guard let transcript else { continue }
                    let session = String(transcript.source.dropFirst("chat/messages/".count).dropLast(".jsonl".count))
                    guard NativeAgentChatSessionID.normalizedPathComponent(session) == session, !transcript.id.isEmpty else {
                        throw unavailable("Experience " + cause.id + " has unreadable transcript evidence.")
                    }
                    guard session != scope, !sessions.isHelper(session) else { continue }
                    guard sessions.kind(session) != nil else {
                        throw unavailable("Conversation classification is unavailable for " + session + ".")
                    }
                    candidates.append((act.id, "message:" + session + "/" + transcript.id, session, outcome, at))
                } catch { gap(error) }
            }
            guard !candidates.isEmpty else { return (native, failures) }
            let resolver = ConversationHistory.ExperienceResolver(dataRoot: dataRoot)
            var source: [String: (session: String, row: [String: JSONValue])] = [:]
            let unindexed = Dictionary(grouping: candidates, by: \.session)
            for (_, group) in unindexed.sorted(by: { $0.key < $1.key }) {
                do {
                    let references = group.map(\.reference)
                    let resolved = try await resolver.resolve(for: references, includingSourceRows: true).messages
                    source.merge(resolved) { _, new in new }
                } catch { gap(error) }
            }
            let lines = candidates.compactMap { candidate -> ElsewhereAct? in
                do {
                    guard let origin = source[candidate.reference], let kind = sessions.kind(candidate.session) else {
                        throw unavailable("The originating transcript row is unavailable for " + candidate.reference + ".")
                    }
                    let speech = ContactThread.Line(origin.row)
                    if let failure = speech.provenanceFailure { throw unavailable(failure) }
                    guard case .string? = origin.row["content"], speech.date != nil else {
                        throw unavailable("The originating transcript row has unreadable content or time for " + candidate.reference + ".")
                    }
                    guard let door = spokenDoor(speech, kind: kind) else { return nil }
                    return ElsewhereAct(id: candidate.act, door: door, personDoor: door != "bridge" && door != ownDoor,
                        outcome: candidate.outcome, at: candidate.at)
                } catch { gap(error); return nil }
            }
            return ((native + lines).sorted { ($0.at, $0.id) < ($1.at, $1.id) }, failures)
        } catch let failure as ToolFailureError { throw failure }
        catch { throw unavailable(error.localizedDescription) }
    }

    private static let actLines = 8

    fileprivate static func disclosedActs(_ reading: ElsewhereReading, peer: Bool, shown: Set<String>) -> [ElsewhereAct] {
        reading.acts.filter { (!peer || $0.personDoor) && !shown.contains($0.id) }
    }

    package static func breath(dataRoot: URL, scope: String, peer: Bool, since: Date?, shown: Set<String>,
                               now: Date) async -> (text: String?, read: Bool, acts: [String]) {
        guard let reading = await readElsewhere(dataRoot: dataRoot, scope: scope, turn: now, since: since)
        else { return (nil, true, []) }
        if let failure = reading.failure { return (failure, false, []) }
        let lines = lifeLines(reading, scope: scope, peer: peer, shown: shown, now: now)
        let acts = disclosedActs(reading, peer: peer, shown: shown).suffix(actLines).map(\.id)
        return (lines.isEmpty ? nil : "Elsewhere since your last step:\n" + lines.joined(separator: "\n"), !reading.failed, acts)
    }

    package static func elsewhere(dataRoot: URL, scope: String, surface: String, peer: Bool, turn: Date?,
                                  reading: ElsewhereReading? = nil, shown: Set<String> = []) async -> String? {
        guard door(surface) != nil else { return nil }
        do { guard try MemoryPolicyGate.crossSessionRecallEnabled(dataRoot: dataRoot) else { return nil } }
        catch { return nameFailure(error) }
        let now = turn ?? Date()
        let gathered: ElsewhereReading?
        if let reading { gathered = reading }
        else { gathered = await readElsewhere(dataRoot: dataRoot, scope: scope, turn: now, since: nil) }
        guard let reading = gathered else { return nil }
        if let failure = reading.failure { return failure }
        let lines = lifeLines(reading, scope: scope, peer: peer, shown: shown, now: now)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func lifeLines(_ reading: ElsewhereReading, scope: String, peer: Bool, shown: Set<String> = [], now: Date) -> [String] {
        let indexed = Dictionary(uniqueKeysWithValues: reading.rows.map { ($0.id, $0) })
        let thoughts = Set(reading.rows.compactMap { $0.thought?.run }.map { Experience.answer(run: $0) })
        let answered = Set(reading.rows.filter { $0.kind == .answer && !thoughts.contains($0.id) }.flatMap(\.cause))
        func session(_ row: Experience) -> String? {
            let destinations = row.addressedTo + row.owes.sorted { $0.key < $1.key }.map { $0.value.to }
            if let to = destinations.first(where: { $0.hasPrefix("conversation:") }) { return String(to.dropFirst(13)) }
            if let ref = row.evidence.first(where: { $0.source.hasPrefix("chat/messages/") && $0.source.hasSuffix(".jsonl") }) {
                return String(ref.source.dropFirst(14).dropLast(6))
            }
            return nil
        }
        func clean(_ row: Experience) -> Bool {
            if let happening = row.happening { return (happening.peers ?? []).isEmpty && (happening.elevated ?? []).isEmpty }
            return row.steeredBy == []
        }
        func words(_ row: Experience) -> String {
            guard !peer, clean(row) else { return "" }
            return clip(ChatSecretRedactor.redactText(row.face?.words ?? row.happening?.words ?? ""), 2_000)
        }
        func owed(_ rows: [Experience]) -> String {
            let open = rows.filter(clean).flatMap { row in row.owes.sorted { $0.key < $1.key }.filter { !$0.value.phase.isSettled }
                .map { $0.key + " to " + $0.value.to } }
            return open.isEmpty ? "" : "; still owe " + open.joined(separator: ", ")
        }
        var lines: [(at: Date, text: String)] = []
        for row in reading.rows {
            guard let at = NativeTimestampFormat.parseISO8601FractionalFirst(row.at), at > reading.since, at <= now,
                  !thoughts.contains(row.id), !(row.kind == .heard && answered.contains(row.id)) else { continue }
            let ask = row.kind == .answer ? row.cause.compactMap { indexed[$0] }.first(where: { $0.kind == .heard }) : nil
            let source = ask ?? row
            let conversation = session(source) ?? session(row)
            guard conversation != scope, conversation != nil || ![.heard, .answer].contains(row.kind) else { continue }
            if conversation == Attention.stream && row.kind != .thought && row.kind != .happening { continue }
            let door = row.happening?.door
                ?? (row.kind == .message ? row.addressedTo.first { $0.hasPrefix("agent:") } : nil)
                ?? source.evidence.first(where: { $0.source == "door" }).map { AgentScreen.door($0.id) ?? $0.id }
                ?? conversation.map { "conversation:" + $0 } ?? row.addressedTo.first ?? "self"
            var line = door + ", " + row.kind.rawValue + ", " + age(now.timeIntervalSince(at)) + " ago"
            if row.kind == .thought {
                guard ["hit", "empty"].contains(row.outcome?.status ?? ""), let run = row.thought?.run, let answer = indexed[Experience.answer(run: run)],
                      let prose = answer.face?.words, !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                line += ", I thought"
                if clean(row), !words(answer).isEmpty { line += ": " + words(answer) }
                if !peer && clean(row) { line += owed([row, answer]) }
            } else {
                if let ask {
                    line += ", " + (!peer && clean(ask) ? ask.face?.from ?? "person" : "speaker") + " asked"
                    if !words(ask).isEmpty { line += ": " + words(ask) }
                    line += "; I answered"
                } else if !peer && clean(row) {
                    line += ", " + (row.face?.from ?? row.happening?.who ?? (row.kind == .heard ? "person" : "I"))
                }
                if !words(row).isEmpty { line += ": " + words(row) }
                if !peer && clean(row) { line += owed([row] + (ask.map { [$0] } ?? [])) }
            }
            lines.append((at, clip(line, 4_200)))
        }
        let acts = disclosedActs(reading, peer: peer, shown: shown)
        lines += acts.suffix(actLines).map { ($0.at, $0.door + " you " + $0.outcome.domain + " " + $0.outcome.status) }
        if acts.count > actLines { lines.append((reading.since, "+\(acts.count - actLines) more actions on other doors")) }
        lines += reading.actFailures.map { (now, $0) }
        var result: [String] = [], remaining = 12_000
        for line in lines.sorted(by: { $0.at > $1.at }) {
            guard line.text.count + 1 <= remaining else { break }
            result.append(line.text)
            remaining -= line.text.count + 1
        }
        return result
    }
}
