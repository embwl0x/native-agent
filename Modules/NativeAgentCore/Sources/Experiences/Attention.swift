import Foundation
import NativeAgentCore
import os
// Blueprint: | `Attention.swift` | `Attention`: committed happening intake and checked membership, weighing and thought records |

/// What takes a written happening into the agent's attention: the cognition runtime, installed at launch. A happening written before it is installed
/// waits in the record and is taken when it opens.
public protocol AttentionIntake: Sendable {
    /// A happening was written for the first time.
    func took(_ experience: Experience) async
    /// A message or a return was admitted to one of the agent's conversations.
    func arrived() async
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
    private static let intake = OSAllocatedUnfairLock<(any AttentionIntake)?>(initialState: nil)
    private static let log = ModuleLog(category: "Attention")

    public static func install(_ taker: any AttentionIntake) { intake.withLock { $0 = taker } }
    static var installed: (any AttentionIntake)? { intake.withLock { $0 } }

    /// Hand attention only the committed happening. A repeat writes and hands nothing; a failed record owes repair.
    @discardableResult
    public static func post(_ happening: Happening, dataRoot: URL) -> Task<Void, Never> {
        Task.detached {
            let store = ExperienceStore.at(dataRoot)
            let born = Experience(id: happening.id, kind: .happening, cause: [happening.door], addressedTo: [happening.destination],
                owes: happening.owed ? [happening.destination: .init(to: happening.destination)] : [:], happening: happening)
            do {
                guard try await store.begin(born) else { return }
                guard let taken = try await store.experience(happening.id) else { throw RecordError.missingHappening(happening.id) }
                await installed?.took(taken)
            } catch {
                log("happening %@ handoff did not complete: %@", happening.id, error.localizedDescription)
                if !(error is ExperienceStore.LawError) { await store.failed(error) }
                await RepairOwed.owe(dataRoot, id: happening.id, kind: .act, operation: "attention.post:" + happening.id,
                    owner: happening.id, words: "The happening was not handed to attention: " + error.localizedDescription,
                    lever: "Repair the experience record, then have this happening's source publish its unresolved input.").value
            }
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
        try await ExperienceStore.at(dataRoot).open().filter { $0.kind == .happening && $0.happening?.owed == true }
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
    public static func accept(_ batch: Batch, dataRoot: URL) async throws -> Batch {
        try await note(batchKind, subject: batch.route, row: JSONEncoder().encode(batch), once: batch.deliveryID, dataRoot: dataRoot)
        guard let saved = try await batches(on: batch.route, dataRoot: dataRoot).first(where: { $0.batch.deliveryID == batch.deliveryID }) else {
            throw RecordError.missingHappening(batch.deliveryID)
        }
        return saved.batch
    }

    /// Open batches are recovered as themselves, including members whose older per-member acceptance already landed.
    public static func batches(on route: String, dataRoot: URL) async throws -> [(batch: Batch, end: BatchEnd?)] {
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
        case missingMembership(String)

        public var errorDescription: String? {
            switch self {
            case .malformedDetail(let seq, let cause): "Attention detail \(seq) is unreadable: \(cause)."
            case .malformedNodeDetail(let seq, let node, let cause):
                "Attention detail \(seq) for \(node) is unreadable: \(cause). This node's drive remains unclaimed."
            case .missingNode(let node): "Attention node \(node) disappeared before its recorded crossing could be claimed."
            case .missingHappening(let id): "Attention's happening \(id) has no committed body; repair its experience record before attending it."
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
    }

    /// The latest ignition closes consumed membership; later committed landings and returns own the outstanding drive.
    public static func landed(on node: String, dataRoot: URL) async throws -> Landed {
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
        return Landed(happenings: found, earlierDrive: earlier)
    }

    /// The agent's thoughts within the horizon, oldest first.
    public static func thoughts(dataRoot: URL, now: Date = Date()) async throws -> [Experience] {
        try await ExperienceStore.at(dataRoot).born(kinds: [.thought], after: now.addingTimeInterval(-horizon), limit: 4_096)
    }

    /// Write one detail of what attention noticed; the caller owns an unsuccessful recording.
    public static func note(_ kind: String, subject: String, row: Data, once: String? = nil, dataRoot: URL) async throws {
        try await ExperienceStore.at(dataRoot).note([.init(source: detailSource, at: Date(), subject: subject, kind: kind, row: row, once: once)])
    }

    /// Write a settled thought once.
    public static func record(thought: Thought, id: String, status: String, cause: [String], dataRoot: URL) async {
        let experience = Experience(id: id, kind: .thought, cause: cause, evidence: thought.run.map { [.init(source: "turn", id: $0)] } ?? [],
            outcome: .init(domain: "attention", status: status, effects: status == "hit" ? .occurred : Experience.Effects.none),
            addressedTo: ["conversation:" + stream], thought: thought)
        await ExperienceStore.record(dataRoot, id) { store in _ = try await store.begin(experience) }.value
    }

    /// A care moving after a thought about it amends that thought: it mattered.
    public static func amend(thought id: String, dataRoot: URL) async throws {
        try await ExperienceStore.at(dataRoot).append([.claim(.init(claim: Thought.careMoved, evidence: []))], to: id)
    }
}
