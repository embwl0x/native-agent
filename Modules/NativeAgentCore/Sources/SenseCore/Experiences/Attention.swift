import Synchronization
import Foundation
import GRDB
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `Attention.swift` | Committed happening intake and settled thoughts carry birth steering in the one record |

/// What takes a written happening into the agent's attention: the cognition runtime, installed at launch. A happening written before it is installed
/// waits in the record and is taken when it opens.
public protocol AttentionIntake: Sendable {
    /// A committed happening is offered to attention, including a checked return that is still owed.
    func took(_ experience: Experience) async
    /// A message or a return was admitted to one of the agent's conversations.
    func arrived() async
}

extension ExperienceStore {
    package func committedHappenings(matching waits: [(kind: Happening.Kind, subject: String, since: String)]) throws -> [Experience] {
        guard let earliest = waits.map({ $0.since }).min() else { return [] }
        let selectors = try JSONValue.array(waits.map {
            .object(["kind": .string($0.kind.rawValue), "subject": .string($0.subject), "since": .string($0.since)])
        }).serialize(pretty: false)
        let ids = try database().read { db in
            try String.fetchAll(db, sql: """
                SELECT e.id FROM experience e
                WHERE e.kind = 'happening' AND e.at > ? AND EXISTS (
                    SELECT 1 FROM json_each(?) AS wait
                    WHERE json_extract(e.born, '$.happening.kind') = json_extract(wait.value, '$.kind')
                      AND json_extract(e.born, '$.happening.subject') = json_extract(wait.value, '$.subject')
                      AND e.at > json_extract(wait.value, '$.since')
                ) ORDER BY e.at, e.rowid
                """, arguments: [earliest, selectors])
        }
        return try ids.map { id in
            guard let row = try experience(id) else { throw Attention.RecordError.missingHappening(id) }
            return row
        }
    }

    fileprivate func beginCausalMoment(_ born: Experience, prefix: String, result: String, baseline: String?) throws -> Bool {
        let previous = try recordedExperiences(idPrefix: prefix, kind: .happening, limit: 1)
        if let unread = previous.unreadable.first { throw unread.cause }
        let last = previous.items.first?.evidence.first { $0.source == "causal-result" }?.id
        guard result != (last ?? baseline) else { return false }
        return try begin(born, durable: true)
    }

    package func consumeCausalMoment(_ moment: Experience, thought: String) throws -> Bool {
        try Task.checkCancellation()
        guard let route = moment.happening?.destination,
              let live = try experience(moment.id), live.owes[route]?.phase == .owed else { return false }
        try append([.obligation(key: route, phase: .accepted, evidence: .init(source: "thought", id: thought))],
                   to: live.id, durable: true)
        return true
    }

    /// Only committed weighing of this watch on this subject consumes its first-news floor.
    public func weighed(watch: String, subject: String) throws -> Bool {
        try database().read { db in
            guard let found = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM detail d JOIN experience e ON e.id = d.subject
                    WHERE d.source = ? AND d.kind = ? AND json_extract(e.born, '$.happening.subject') = ?
                      AND json_extract(e.born, '$.happening.watch') = ?)
                """, arguments: [Attention.detailSource, Attention.weighKind, subject, watch]) else { throw CocoaError(.coderReadCorrupt) }
            return found
        }
    }
}

/// One intake. Every change the agent's attention takes in is a `Happening` posted here: it is written once under its key, then owed ones open a thought
/// and the rest are weighed. The record is the truth of what happened, what was weighed and what each thought attended.
public enum Attention {
    /// The agent's own mind stream: one conversation of thoughts, never replayed as history.
    public static let stream = Happening.stream
    public static let streamTitle = "Thoughts"
    /// The record's detail source for what attention noticed: `attention.weigh`, `attention.ignite`, `attention.restore`, `attention.wake`,
    /// and `attention.night`: subject "night" holds admission; subject "sleep" holds part accounting, whose `through` is the next `since`.
    public static let detailSource = "attention"
    public static let weighKind = "attention.weigh", igniteKind = "attention.ignite", restoreKind = "attention.restore",
        wakeKind = "attention.wake", nightKind = "attention.night"
    public static let batchKind = "attention.batch", batchEndKind = "attention.batch.terminal"
    /// What attention reads back: the record's own horizon for details.
    public static let horizon = ExperienceStore.detailHorizon
    public static let thoughtRecordLimit = 4_096
    private static let intake = Mutex<(any AttentionIntake)?>(nil)
    private static let pendingPosts = WorkDrain()
    private static let log = ModuleLog(category: "Attention")

    /// The mind takes happenings while it runs; with none installed they stay recorded and owed for the next mind to open on.
    public static func install(_ taker: (any AttentionIntake)?) { intake.withLock { $0 = taker } }
    static var installed: (any AttentionIntake)? { intake.withLock { $0 } }

    /// Hand attention only the committed happening. A repeat writes and hands nothing; a failed record owes repair.
    @discardableResult
    public static func post(_ happening: Happening, dataRoot: URL) -> Task<Void, Never> {
        pendingPosts.launch {
            _ = try? await commit(happening, dataRoot: dataRoot, checked: false)
        }
    }

    public static func joinPendingPosts() async {
        await pendingPosts.drain()
    }

    /// Confirm the committed return and reoffer it while it is owed, including after a failed readback.
    public static func postChecked(_ happening: Happening, dataRoot: URL) async throws {
        try await commit(happening, dataRoot: dataRoot, checked: true)
    }

    package static func postCausalMoment(_ happening: Happening, prefix: String, result: String, baseline: String?,
                                         source: String?, dataRoot: URL) -> Task<Void, Never> {
        pendingPosts.launch {
            _ = try? await commit(happening, dataRoot: dataRoot, checked: false, causal: (prefix, result, baseline, source))
        }
    }

    @concurrent private static func commit(_ happening: Happening, dataRoot: URL, checked: Bool,
                                           causal: (prefix: String, result: String, baseline: String?, source: String?)? = nil) async throws {
        let store = ExperienceStore.at(dataRoot)
        let operation = "attention.post:" + happening.id
        let born = Experience(id: happening.id, kind: .happening, cause: [happening.door] + (causal?.source.map { [$0] } ?? []),
            evidence: causal.map { [.init(source: "causal-result", id: $0.result)] } ?? [], addressedTo: [happening.destination],
            owes: happening.owed ? [happening.destination: .init(to: happening.destination)] : [:], happening: happening,
            steeredBy: Array(Set((happening.peers ?? []) + (happening.elevated ?? []))).sorted())
        do {
            let inserted: Bool
            if let causal {
                inserted = try await store.beginCausalMoment(born, prefix: "happening:" + causal.prefix, result: causal.result,
                                                             baseline: causal.baseline)
            } else {
                inserted = try await store.begin(born, durable: checked)
            }
            guard inserted || checked else { return }
            guard let saved = try await store.experience(happening.id), let committed = saved.happening else {
                throw RecordError.missingHappening(happening.id)
            }
            // The store checks the once key, destination and authority. A checked return also proves what it carried.
            if checked {
                guard committed.shows?.count != Happening.showsLimit || committed.showsDigest != nil else {
                    throw RecordError.missingReturnDigest(happening.id)
                }
                guard committed.shows == happening.shows, committed.showsDigest == happening.showsDigest else {
                    throw ExperienceStore.LawError.reused(happening.id)
                }
            }
            if inserted || saved.owes[committed.destination]?.phase.isSettled == false {
                await installed?.took(saved)
            }
        } catch {
            log("happening %@ handoff did not complete: %@", happening.id, error.localizedDescription)
            await RepairOwed.owe(dataRoot, id: happening.id, kind: .act, operation: operation,
                owner: happening.id, words: "The happening was not handed to attention: " + error.localizedDescription,
                lever: "Repair the experience record, then have this happening's source publish its unresolved input.").value
            throw error
        }
        if checked {
            try await RepairOwed.settleChecked(dataRoot, operation: operation, owner: happening.id,
                evidence: .init(source: "experiences/experiences.sqlite", id: happening.id))
        }
    }

    /// A door admitted a message or a return: attention wakes from sleep for it.
    public static func arrived() {
        guard let taker = installed else { return }
        Task.detached { await taker.arrived() }
    }

    // MARK: - The record attention reads

    /// Happenings still owed: to the agent (its stream) and to conversations (returns not yet delivered).
    public static func owed(dataRoot: URL) async throws -> [Experience] {
        try await ExperienceStore.at(dataRoot).open(kind: .happening).filter { $0.happening?.owed == true }
    }

    /// A happening attended: its obligation is accepted, with the thought (or the conversation turn) that took it as evidence.
    public static func settle(_ happenings: [Experience], by evidence: Experience.Ref, dataRoot: URL) async {
        for experience in happenings {
            guard let destination = experience.happening?.destination, experience.owes[destination] != nil else { continue }
            await ExperienceStore.record(dataRoot, experience.id) { store in
                try await store.append([.obligation(key: destination, phase: .accepted, evidence: evidence)], to: experience.id)
            }.value
        }
    }

    /// The acceptance of a whole return, before admission or model work. Its members and words never change.
    public struct Batch: Codable, Sendable, Equatable {
        public let route: String
        public let deliveryID: String
        public let members: [String]
        public let digest: String

        public init(route: String, deliveryID: String, members: [String], digest: String) {
            self.route = route; self.deliveryID = deliveryID; self.members = members; self.digest = digest
        }
    }

    public struct BatchEnd: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable { case completed, stopped }
        public let deliveryID: String
        public let status: Status
        public let evidence: Experience.Ref

        public init(deliveryID: String, status: Status, evidence: Experience.Ref) {
            self.deliveryID = deliveryID; self.status = status; self.evidence = evidence
        }
    }

    /// The saved row wins a repeated acceptance. A once-key collision cannot substitute newly offered members.
    @concurrent public static func accept(_ batch: Batch, dataRoot: URL) async throws -> Batch {
        try await note(batchKind, subject: batch.route, row: JSONEncoder().encode(batch), once: batch.deliveryID, dataRoot: dataRoot)
        guard let saved = try await batches(on: batch.route, dataRoot: dataRoot).first(where: { $0.batch.deliveryID == batch.deliveryID }) else {
            throw RecordError.missingHappening(batch.deliveryID)
        }
        return saved.batch
    }

    /// Open batches are recovered as themselves, including members whose older per-member acceptance already landed.
    @concurrent public static func batches(on route: String, dataRoot: URL) async throws -> [(batch: Batch, end: BatchEnd?)] {
        let rows = try await ExperienceStore.at(dataRoot).details(.init(sources: [detailSource], subjects: [route],
            kinds: [batchKind, batchEndKind]))
        var batches: [Batch] = []
        var ends: [String: BatchEnd] = [:]
        for row in rows {
            do {
                if row.kind == batchKind {
                    let batch = try JSONDecoder().decode(Batch.self, from: row.row)
                    guard batch.route == route, row.once == batch.deliveryID, !batch.deliveryID.isEmpty, !batch.digest.isEmpty,
                          !batch.members.isEmpty, batch.members.allSatisfy({ !$0.isEmpty }),
                          Set(batch.members).count == batch.members.count,
                          !batches.contains(where: { $0.deliveryID == batch.deliveryID }) else {
                        throw RecordError.malformedDetail(row.seq, "Invalid batch identity or membership")
                    }
                    batches.append(batch)
                } else {
                    let end = try JSONDecoder().decode(BatchEnd.self, from: row.row)
                    guard row.once == batchEndKind + ":" + end.deliveryID, ends[end.deliveryID] == nil,
                          batches.contains(where: { $0.deliveryID == end.deliveryID }) else {
                        throw RecordError.malformedDetail(row.seq, "Terminal record has no unique batch")
                    }
                    ends[end.deliveryID] = end
                }
            } catch let error as RecordError { throw error }
            catch { throw RecordError.malformedDetail(row.seq, error.localizedDescription) }
        }
        return batches.map { ($0, ends[$0.deliveryID]) }
    }

    public static func members(of batch: Batch, dataRoot: URL) async throws -> [Experience] {
        var members: [Experience] = []
        for id in batch.members {
            guard let experience = try await ExperienceStore.at(dataRoot).experience(id), let happening = experience.happening,
                  (happening.route ?? stream) == batch.route else { throw RecordError.missingHappening(id) }
            members.append(experience)
        }
        return members
    }

    /// Settlement is derived from the batch's one terminal record, never from claim-time member writes.
    public static func finish(_ batch: Batch, status: BatchEnd.Status, by evidence: Experience.Ref, dataRoot: URL) async throws {
        let end = BatchEnd(deliveryID: batch.deliveryID, status: status, evidence: evidence)
        try await ExperienceStore.at(dataRoot).finishAttentionBatch(batch, end: end)
    }

    /// Every happening not yet weighed remains pending until its attention record commits.
    public static func waiting(dataRoot: URL) async throws -> [Experience] {
        try await ExperienceStore.at(dataRoot).unweighedHappenings()
    }

    /// Whether this happening was already weighed.
    public static func weighed(_ id: String, dataRoot: URL) async throws -> Bool {
        !(try await ExperienceStore.at(dataRoot).details(.init(sources: [detailSource], subjects: [id], kinds: [weighKind], limit: 1))).isEmpty
    }

    /// Let owed happenings go: what they waited on can no longer come (a job's return superseded by its newer outcome).
    public static func letGo(_ happenings: [Experience], reason: ObligationPhase.LetGo, dataRoot: URL) async {
        for experience in happenings {
            guard let destination = experience.happening?.destination, experience.owes[destination] != nil else { continue }
            await ExperienceStore.record(dataRoot, experience.id) { store in
                try await store.append([.letGo(key: destination, reason: reason)], to: experience.id)
            }.value
        }
    }

    public enum RecordError: Error, LocalizedError {
        case malformedDetail(Int64, String)
        case malformedNodeDetail(Int64, String, String)
        case missingNode(String)
        case missingHappening(String)
        case missingReturnDigest(String)
        case missingMembership(String)

        public var errorDescription: String? {
            switch self {
            case .malformedDetail(let seq, let cause): "Attention detail \(seq) is unreadable: \(cause)."
            case .malformedNodeDetail(let seq, let node, let cause):
                "Attention detail \(seq) for \(node) is unreadable: \(cause). This node's drive remains unclaimed."
            case .missingNode(let node): "Attention node \(node) disappeared before its recorded crossing could be claimed."
            case .missingHappening(let id): "Attention's happening \(id) has no committed body; repair its experience record before attending it."
            case .missingReturnDigest(let id): "Attention's return \(id) reached the display limit with no digest of its full material; its receipt cannot be verified."
            case .missingMembership(let node):
                "Attention node \(node) has incomplete drive provenance; restore its named happenings before claiming its drive."
            }
        }
    }

    private struct LandingRow: Decodable {
        let node: String?
        let worth: Double?
        let drive: Double?
        let happenings: [String]?
        let earlierDrive: EarlierDrive?
        let accounted: Bool?
    }

    private struct LandingNode: Decodable {
        let node: String
    }

    /// Explicit provenance carried by a thought's drive.
    public struct EarlierDrive: Codable, Sendable {
        public var happenings: [String]
        public var fromBeforeRecord: Bool

        public var words: String {
            var lines = ["Earlier drive on this node."]
            if !happenings.isEmpty { lines.append("Earlier recorded happening references: " + happenings.joined(separator: ", ") + ".") }
            if fromBeforeRecord { lines.append("Some drive is from before this record; its happenings can no longer be named.") }
            return lines.joined(separator: " ")
        }
    }

    public struct Landed: Sendable {
        public let happenings: [Experience]
        public let earlierDrive: EarlierDrive?
        public let weighRows: [ExperienceStore.Detail]
    }

    /// The latest ignition closes consumed membership; later committed landings and returns own the outstanding drive.
    @concurrent public static func landed(on node: String, dataRoot: URL) async throws -> Landed {
        let store = ExperienceStore.at(dataRoot)
        let rows = try await store.details(.init(sources: [detailSource], kinds: [weighKind, igniteKind, restoreKind]))
        var ids: [String] = []
        var earlier: EarlierDrive?
        let boundary = rows.last { $0.kind == igniteKind && $0.subject == node }
        if let boundary {
            let row: LandingRow
            do { row = try JSONDecoder().decode(LandingRow.self, from: boundary.row) }
            catch { throw RecordError.malformedNodeDetail(boundary.seq, node, error.localizedDescription) }
            guard row.accounted == true, let carried = row.happenings, carried.allSatisfy({ !$0.isEmpty }),
                  !carried.isEmpty || row.earlierDrive?.fromBeforeRecord == true else {
                throw RecordError.malformedNodeDetail(boundary.seq, node, "An ignition requires accounted: true and its recorded happening ids")
            }
            if let consumed = row.earlierDrive {
                guard consumed.happenings.allSatisfy({ !$0.isEmpty && carried.contains($0) }),
                      !consumed.happenings.isEmpty || consumed.fromBeforeRecord else {
                    throw RecordError.malformedNodeDetail(boundary.seq, node, "An ignition must include its earlier drive's named happenings")
                }
            }
        }
        for detail in rows {
            if let boundary, detail.seq <= boundary.seq { continue }
            // Ignitions and returns name the node as their subject; other nodes' rows cannot affect this one.
            if detail.kind != weighKind, detail.subject != node { continue }
            if detail.kind == weighKind {
                let landing: LandingNode
                do { landing = try JSONDecoder().decode(LandingNode.self, from: detail.row) }
                catch { throw RecordError.malformedDetail(detail.seq, error.localizedDescription) }
                guard landing.node == node else { continue }
                let row: LandingRow
                do { row = try JSONDecoder().decode(LandingRow.self, from: detail.row) }
                catch { throw RecordError.malformedNodeDetail(detail.seq, node, error.localizedDescription) }
                guard let drive = row.drive, drive.isFinite, drive >= 0,
                      let worth = row.worth, worth.isFinite, worth >= 0 else {
                    throw RecordError.malformedNodeDetail(detail.seq, node, "A landing requires finite, nonnegative drive and worth")
                }
                if ids.isEmpty, earlier == nil, drive > worth { throw RecordError.missingMembership(node) }
                if !ids.contains(detail.subject) { ids.append(detail.subject) }
            } else {
                let row: LandingRow
                do { row = try JSONDecoder().decode(LandingRow.self, from: detail.row) }
                catch { throw RecordError.malformedNodeDetail(detail.seq, node, error.localizedDescription) }
                guard let carried = row.happenings, carried.allSatisfy({ !$0.isEmpty }),
                      !carried.isEmpty || row.earlierDrive != nil else {
                    throw RecordError.malformedNodeDetail(detail.seq, node, "A return requires its recorded happening ids")
                }
                for id in carried where !ids.contains(id) { ids.append(id) }
                if let returned = row.earlierDrive {
                    guard returned.happenings.allSatisfy({ !$0.isEmpty }), !returned.happenings.isEmpty || returned.fromBeforeRecord else {
                        throw RecordError.malformedNodeDetail(detail.seq, node, "A return's earlier drive requires named happenings or an explicit record gap")
                    }
                    if var combined = earlier {
                        for id in returned.happenings where !combined.happenings.contains(id) { combined.happenings.append(id) }
                        combined.fromBeforeRecord = combined.fromBeforeRecord || returned.fromBeforeRecord
                        earlier = combined
                    } else { earlier = returned }
                }
            }
        }
        guard !ids.isEmpty || earlier != nil else { throw RecordError.missingMembership(node) }
        var found: [Experience] = []
        for id in ids {
            guard let experience = try await store.experience(id), experience.happening != nil else { throw RecordError.missingHappening(id) }
            found.append(experience)
        }
        let membership = Set(ids)
        return Landed(happenings: found, earlierDrive: earlier,
                      weighRows: rows.filter { $0.kind == weighKind && membership.contains($0.subject) })
    }

    /// The agent's thoughts within the horizon, oldest first; a thought that will not fold is this read's failure.
    public static func thoughts(dataRoot: URL, now: Date = Date()) async throws -> [Experience] {
        let read = try await ExperienceStore.at(dataRoot).born(kinds: [.thought], after: now.addingTimeInterval(-horizon), limit: thoughtRecordLimit)
        if let first = read.unreadable.first { throw first.cause }
        return read.experiences
    }

    /// Write one detail of what attention noticed; the caller owns an unsuccessful recording.
    public static func note(_ kind: String, subject: String, row: Data, once: String? = nil, dataRoot: URL) async throws {
        try await ExperienceStore.at(dataRoot).note([.init(source: detailSource, at: Date(), subject: subject, kind: kind, row: row, once: once)])
    }

    /// Write a settled thought once.
    public static func record(thought: Thought, id: String, status: String, cause: [String], dataRoot: URL, steeredBy: [String]) async {
        let experience = Experience(id: id, kind: .thought, cause: cause, evidence: thought.run.map { [.init(source: "turn", id: $0)] } ?? [],
            outcome: .init(domain: "attention", status: status, effects: status == "hit" ? .occurred : Experience.Effects.none),
            addressedTo: ["conversation:" + stream], thought: thought, steeredBy: steeredBy)
        await ExperienceStore.record(dataRoot, id) { store in
            _ = try await store.begin(experience)
            // A thought that read and settled proves the stream reads: every repair the stream owes is met, including per-run debts.
            if ["hit", "empty", "withheld"].contains(status) {
                await RepairOwed.settle(dataRoot, owner: stream, after: "thought.read", evidence: .init(source: "thought", id: id)).value
            }
        }.value
    }

    /// A care moving after a thought about it amends that thought: it mattered.
    public static func amend(thought id: String, dataRoot: URL) async throws {
        try await ExperienceStore.at(dataRoot).append([.claim(.init(claim: Thought.careMoved, evidence: []))], to: id)
    }
}
