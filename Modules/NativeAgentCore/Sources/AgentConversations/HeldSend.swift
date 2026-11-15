import AgentWorkspace
import NativeAgentShared
import Foundation
import os
import NativeAgentCore
import PersistenceCore
import Experiences
import Transcripts
// Blueprint: | `HeldSend.swift` | `HeldSend`, `HeldSends`: one append-only record per held send (agents/held/<send>.jsonl); only its answer or the agent's withdrawal ends it |

/// A held send: the agent's message to a contact that collects its messages, owed that contact's answer. Its record is one file of lines, each
/// appended once and never rewritten, each saying the process life that wrote it: `sent`, then at most one of `answered` (the first wins) or
/// `withdrawn` (the agent's own), and `delivered` (the first wins) once a turn of the agent's has taken the answer into its input.
/// Nothing else ends what the send is owed: not another send, not a
/// restart, not a missing or unreadable file, which reads as still owed and says why.
public struct HeldSend: Sendable {
    public struct Line: Codable, Sendable {
        public var event: String
        /// The process life that wrote the line (`ExperienceStore.processID`).
        public var life: String
        public var at: Date
        // sent: who it went to, where, and where its answer's news goes.
        public var contact: String?
        public var conversation: String?
        public var row: String?
        public var scope: String?
        public var name: String?
        public var label: String?
        public var byPerson: Bool?
        public var task: String?
        // answered: the message that is the answer (its own id), who said it, and its words. delivered: what carried it into the turn's input,
        // `tool` (a tool result) or `news` (its return news).
        public var by: String?
        public var from: String?
        public var text: String?

        init(_ event: String) { self.event = event; life = ExperienceStore.processID; at = Date() }
    }

    public let id: String
    public private(set) var sent: Line?
    public private(set) var answered: Line?
    public private(set) var withdrawn: Line?
    public private(set) var delivered: Line?
    /// Why the record cannot be read; such a send is owed.
    public private(set) var unreadable: String?
    public private(set) var missing = false

    public var owed: Bool { answered == nil && withdrawn == nil }

    init(id: String, data: Data?, path: String) {
        self.id = id
        guard let data else { missing = true; unreadable = "its record \(path) is missing"; return }
        // A last line with no newline is an append that never finished: it was never part of the record.
        let committed = data.lastIndex(of: 10).map { data[...$0] } ?? Data()
        let decoder = JSONDecoder()
        for (number, bytes) in committed.split(separator: 10).enumerated() {
            guard let line = try? decoder.decode(Line.self, from: Data(bytes)) else {
                (sent, answered, withdrawn, delivered) = (nil, nil, nil, nil)
                unreadable = "line \(number + 1) of its record \(path) cannot be read"
                return
            }
            switch line.event {
            case "sent": if sent == nil { sent = line }
            case "answered": if owed { answered = line }
            case "withdrawn": if owed { withdrawn = line }
            case "delivered": if delivered == nil { delivered = line }
            default: break
            }
        }
        // A withdrawal needs no sent line: the agent can let go of a send whose record was lost.
        if sent == nil, withdrawn == nil {
            (answered, delivered) = (nil, nil)
            unreadable = "its record \(path) has no sent line"
        }
    }

    init(id: String, unreadable: String) { self.id = id; self.unreadable = unreadable }
}

/// The held sends' records, one file per send under its own lock.
public struct HeldSends: Sendable {
    public let folder: URL
    var dataRoot: URL { folder.deletingLastPathComponent().deletingLastPathComponent() }

    public init(dataRoot: URL) { folder = dataRoot.appendingPathComponent("agents/held", isDirectory: true) }

    /// A send's file; nil for anything but a send id, so an id from outside never names another path.
    func file(_ id: String) -> URL? {
        guard id.utf8.count == 36, UUID(uuidString: id) != nil else { return nil }
        return folder.appendingPathComponent(id.lowercased() + ".jsonl")
    }

    public func read(_ id: String) -> HeldSend {
        guard let url = file(id) else { return HeldSend(id: id, data: nil, path: id) }
        do { return HeldSend(id: id, data: try Data(contentsOf: url), path: url.path) }
        catch CocoaError.fileReadNoSuchFile { return HeldSend(id: id, data: nil, path: url.path) }
        catch { return HeldSend(id: id, unreadable: "its record \(url.path) cannot be read: \(error.localizedDescription)") }
    }

    /// Append one line under the send's lock, after `decide` reads the record as it is then; nil from `decide` appends nothing.
    @discardableResult
    func append<T>(_ id: String, _ decide: (HeldSend) throws -> (HeldSend.Line?, T)) throws -> T {
        guard let url = file(id) else { throw AgentConversationStore.Failure(message: "\(id) is not a send id; nothing was recorded.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try CredentialFileLock.withLock(url) {
            let (line, result) = try decide(read(id))
            guard let line else { return result }
            let created = !FileManager.default.fileExists(atPath: url.path)
            if created { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let data = try handle.readToEnd() ?? Data()
            // Cut only an append that never finished, so this line starts a line of its own.
            let committed = data.lastIndex(of: 10).map { $0 + 1 } ?? 0
            if committed != data.count { try handle.truncate(atOffset: UInt64(committed)) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try handle.seekToEnd()
            try handle.write(contentsOf: try encoder.encode(line) + Data([10]))
            try handle.synchronize()
            if created { try SwiftNativePersistenceCore.syncDirectory(folder) }
            return result
        }
    }

    /// The send is held for its contact and owed its answer: its record begins. A repeat leaves the record as it is.
    func send(_ row: AgentConversationRecord, conversation: String, task: String?) throws {
        try append(row.operationID) { record in
            guard record.missing else { return (nil, ()) }
            var line = HeldSend.Line("sent")
            line.contact = row.agent; line.conversation = conversation; line.row = row.id; line.scope = row.scopeSessionID
            line.name = row.name; line.label = row.label; line.byPerson = row.personInitiated == true; line.task = task
            return (line, ())
        }
    }

    public enum Claim: Sendable, Equatable {
        /// The message is the send's answer: now, or already (the same message claiming again).
        case answered
        /// Another message answered first, or the agent withdrew the send: this one is an ordinary message.
        case taken
        /// It names a send of another contact's: an ordinary message.
        case unmatched
    }

    /// A contact's message naming a held send (`id`, its reply_to) is its answer, once: the first `answered` line wins. `by` is the message's own
    /// id. A record that is missing or cannot be read refuses the claim: the send stays owed, and the message is not taken as ordinary work.
    public func claim(_ id: String, contact: String, by: String, text: String, from: String) throws -> Claim {
        let identity = try AgentContactIdentity(dataRoot: dataRoot)
        let claim: Claim = try append(id) { record in
            if let why = record.unreadable {
                throw AgentConversationStore.Failure(message: "Held send \(id) is still owed and was not answered: \(why). Repair it, then send again.")
            }
            guard let to = record.sent?.contact, identity.canonical(to) == identity.canonical(contact) else { return (nil, .unmatched) }
            if let answered = record.answered { return (nil, answered.by == by ? .answered : .taken) }
            if record.withdrawn != nil { return (nil, .taken) }
            var line = HeldSend.Line("answered")
            line.by = by; line.from = from; line.text = text
            return (line, .answered)
        }
        if claim == .answered {
            AgentConversationRunning.shared.changed()
            Self.publish(dataRoot: dataRoot)
        }
        return claim
    }

    /// The agent's own withdrawal: the send is owed nothing more, and its experience settles in the same step an answer's does. Only a send still
    /// owed is withdrawn; every delivery reads the record and skips it.
    func withdraw(_ id: String) async throws -> Bool {
        let withdrew: Bool = try append(id) { record in
            guard record.unreadable == nil || record.missing, record.owed else { return (nil, false) }
            return (HeldSend.Line("withdrawn"), true)
        }
        if withdrew {
            await Self.settle(id, dataRoot: dataRoot)
            AgentConversationRunning.shared.changed()
        }
        return withdrew
    }

    /// The note an answering message's task completes with.
    public static func answeredNote(_ id: String) -> String {
        "This message is your answer to the held message \(id); it reached its sender. Nothing else ran."
    }

    // MARK: Delivery: `delivered` is appended only once a turn has taken the answer into its input

    /// Answers a wait is returning in its tool result, in this process: the news waits for that result to reach its turn. A stop before it does
    /// leaves the answer undelivered for the next launch's publication.
    private static let carrying = OSAllocatedUnfairLock(initialState: Set<String>())

    /// A wait returning the send's answer in its result says so while it still watches the send; the turn's tool-result append delivers it.
    func carry(_ id: String) {
        let record = read(id)
        guard record.answered != nil, record.delivered == nil else { return }
        _ = Self.carrying.withLock { $0.insert(id) }
    }

    /// The one append of `delivered`, made where a turn takes an answer into its input: the turn's tool-result append (`via: tool`, the ids its
    /// results carry as `held_answer`) and the news's intake into a turn (`via: news`). The answer's outcome lands first; the first delivery wins.
    public static func delivered(_ ids: [String], via: String, dataRoot: URL) async {
        let sends = HeldSends(dataRoot: dataRoot)
        for id in Set(ids) where sends.file(id) != nil {
            let record = sends.read(id)
            guard record.answered != nil, record.delivered == nil else { continue }
            // The turn took the answer in: that fact is recorded first, whatever its thread row and settlement do after.
            do {
                try sends.append(id) { now in
                    guard now.delivered == nil else { return (nil, ()) }
                    var line = HeldSend.Line("delivered"); line.by = via
                    return (line, ())
                }
            } catch { nativeLog("Held send %@'s answer was taken in but not recorded delivered: %@", id, error.localizedDescription) }
            do { try await sends.outcome(record) }
            catch { nativeLog("Held send %@'s answer is delivered; its thread row or settlement waits for the next pass: %@", id, error.localizedDescription) }
            _ = carrying.withLock { $0.remove(id) }
        }
    }

    /// The held sends whose answers these happenings are the news of (`reply:<send>`).
    public static func answers(inNews happenings: [Experience]) -> [String] {
        happenings.compactMap { $0.happening?.once }.filter { $0.hasPrefix("reply:") }.map { String($0.dropFirst(6)) }
    }

    /// The held sends whose answers a tool result carries.
    public static func answers(in result: JSONValue) -> [String] {
        switch result {
        case .object(let fields):
            let own = if case .string(let id)? = fields["held_answer"] { [id] } else { [String]() }
            return own + fields.filter { $0.key != "held_answer" }.values.flatMap { answers(in: $0) }
        case .array(let values): return values.flatMap { answers(in: $0) }
        default: return []
        }
    }

    /// The answer's thread row and the send's settled experience. Each repeats safely: a thread row already answering the send is not written
    /// again, and only unsettled obligations move.
    private func outcome(_ record: HeldSend) async throws {
        guard let answer = record.answered, let text = answer.text, let sent = record.sent, let contact = sent.contact,
              contact.hasPrefix("peer:") else { return }
        let owner = String(contact.dropFirst(5)), from = answer.from ?? contact
        let identity = try AgentContactIdentity(dataRoot: dataRoot)
        if try !ContactThread.mergedLines(dataRoot: dataRoot, owner: owner, identity: identity).contains(where: { $0.answers == record.id }) {
            try await ContactThread.attempt(.reply(owner: owner, conversation: sent.conversation, name: sent.name ?? owner, text: text,
                replyID: "agent-conversation:" + record.id, at: answer.at, from: from, steeredBy: [from]), dataRoot: dataRoot)
        }
        await Self.settle(record.id, dataRoot: dataRoot)
    }

    private static let publication = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// "Answered and not delivered" is the agent's news, read from the records: after each claim, after a wait ends, on attention's wake and at launch,
    /// one pass at a time. A stop anywhere between the answer and `delivered` delivers it again, once.
    package static func publish(dataRoot: URL) {
        publication.withLock { last in
            let previous = last
            last = Task.detached {
                await previous?.value
                await HeldSends(dataRoot: dataRoot).publish()
            }
        }
    }

    /// Every answered, undelivered record gets its outcome and its news, keyed by its send id (`reply:<send>`): a news already recorded is the
    /// same news, still owed to the agent until a turn takes it in. No news while a wait watches the send or carries its answer to a turn: that wait
    /// delivers it, and publication runs again when the wait ends.
    private func publish() async {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasSuffix(".jsonl") {
            let record = read(String(name.dropLast(6)))
            guard record.answered != nil, let sent = record.sent, let contact = sent.contact, contact.hasPrefix("peer:") else { continue }
            // Delivered: only its thread row and settlement may still be owed, and both repeat safely.
            if record.delivered != nil { try? await outcome(record); continue }
            let owner = String(contact.dropFirst(5)), row = sent.row ?? record.id, once = "reply:" + record.id
            do {
                try await outcome(record)
                let current = try AgentConversationStore(dataRoot: dataRoot).records().first { $0.id == row }?.operationID
                // The person's own send's answer is theirs, in its thread: it reaches them there.
                if sent.byPerson == true { await Self.delivered([record.id], via: "person", dataRoot: dataRoot); continue }
                guard !(AgentConversationRunning.shared.watched(row) && current == record.id),
                      !Self.carrying.withLock({ $0.contains(record.id) }) else { continue }
                await ContactReturns.shared.post(Happening(.returned, subject: "conversation:" + row, door: "contact:" + owner,
                    words: (sent.name ?? owner) + " replied in \"" + String((sent.label ?? "").prefix(60)) + "\"", once: once,
                    route: sent.scope), dataRoot: dataRoot)
                // The news owner keeps its failures to itself; only its record proves the news is out.
                guard try await ExperienceStore.at(dataRoot).experience("happening:" + once) != nil else {
                    throw AgentConversationStore.Failure(message: "its news was not recorded")
                }
            } catch {
                nativeLog("The answer to held send %@ is not yet delivered; the next claim, wait, wake or launch delivers it: %@", record.id,
                    error.localizedDescription)
            }
        }
    }

    /// Settle the send's experience from its record, in order with the conversations' other experience writes.
    static func settle(_ id: String, dataRoot: URL) async {
        await ExperienceStore.record(dataRoot, "agent-conversations") { store in
            if let experience = try await store.experience(id) { try await Self.settle(experience, in: store, dataRoot: dataRoot) }
        }.value
    }

    /// A held send's experience moves only by its record: answered accepts it, withdrawn lets it go, anything else leaves it owed.
    static func settle(_ experience: Experience, in store: ExperienceStore, dataRoot: URL) async throws {
        let record = HeldSends(dataRoot: dataRoot).read(experience.id)
        guard !record.owed else { return }
        let changes: [ExperienceStore.Change] = experience.owes.compactMap { key, obligation in
            guard !obligation.phase.isSettled else { return nil }
            return record.answered != nil ? .obligation(key: key, phase: .accepted, evidence: evidence(experience.id))
                : .letGo(key: key, reason: .cancelled)
        }
        if !changes.isEmpty { try await store.append(changes, to: experience.id) }
    }

    /// The mark a held send's experience carries for life: its obligations move only by its record.
    static func evidence(_ id: String) -> Experience.Ref { .init(source: "agents/held", id: id) }
}

extension AgentConversationStore {
    public var held: HeldSends { HeldSends(dataRoot: fileURL.deletingLastPathComponent().deletingLastPathComponent()) }
}
