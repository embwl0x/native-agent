import Foundation
@_exported import NativeAgentShared
import GRDB
import NativeAgentCore
import os
// Blueprint: | `Experience.swift` | `ExperienceStore`: append-only experiences, newest-first conversation life, obligations and write-fed changes |


/// Keep births and changes in one experience store, validating each transaction through the same law.
/// Read collection births and ordered events together so projections use one observation.
public actor ExperienceStore {
    public enum Change: Codable, Sendable, Equatable {
        case cause(String)
        case evidence(Experience.Ref)
        case face(Experience.Face)
        case claim(Experience.Claim)
        /// Record a terminal outcome once; refuse conflicting repetition.
        case outcome(Experience.Outcome)
        case progress(String)
        case obligation(key: String, phase: ObligationPhase, attempt: String? = nil, evidence: Experience.Ref? = nil)
        /// Giving up outstanding work cannot alter already-settled obligations.
        case letGo(key: String, reason: ObligationPhase.LetGo)
    }

    public enum LawError: Error, LocalizedError {
        case reused(String)
        case unknown(String)
        case secondOutcome(String)
        case unknownObligation(String, String)
        case refusedStep(String, String, ObligationPhase, ObligationPhase)
        case otherAttempt(String, String)
        case unreadable(String, Int64, String)

        public var errorDescription: String? {
            switch self {
            case .reused(let id): "Experience \(id) was already written with different content; mint a new id."
            case .unknown(let id): "No experience \(id); its owner must write it before anything appends to it."
            case .secondOutcome(let id): "Experience \(id) already has a different outcome; an experience has one."
            case .unknownObligation(let id, let key): "Experience \(id) owes nothing named \(key); obligations are declared by its owner."
            case .refusedStep(let id, let key, let from, let to):
                "Experience \(id)'s \(key) cannot move from \(from.rawValue) to \(to.rawValue)."
            case .otherAttempt(let id, let key): "Experience \(id)'s \(key) belongs to another attempt."
            case .unreadable(let id, let seq, let cause): "Experience \(id)'s event \(seq) is unreadable: \(cause)."
            }
        }
    }

    private static let owners = OSAllocatedUnfairLock(initialState: [URL: ExperienceStore]())
    /// Order writes per experience without making unrelated experiences wait.
    private static let pending = OSAllocatedUnfairLock(initialState: [String: (token: UUID, task: Task<Void, Never>)]())
    private static let log = ModuleLog(category: "Experiences")

    static func recordIdentity(_ dataRoot: URL, _ id: String) -> String {
        at(dataRoot).path.path + "#" + id
    }

    public static func at(_ dataRoot: URL) -> ExperienceStore {
        let path = dataRoot.appendingPathComponent("experiences/experiences.sqlite").standardizedFileURL
        return owners.withLock { owners in
            if let owner = owners[path] { return owner }
            let owner = ExperienceStore(path: path)
            owners[path] = owner
            return owner
        }
    }

    /// Queue records per experience without retry; only persistence failures create gaps.
    /// Join recording and gap accounting before retiring work so recording itself never throws into the producing result.
    @discardableResult
    public static func record(_ dataRoot: URL, _ id: String,
                              _ write: @escaping @Sendable (ExperienceStore) async throws -> Void) -> Task<Void, Never> {
        let store = at(dataRoot)
        let key = recordIdentity(dataRoot, id), token = UUID()
        return pending.withLock { tails in
            let previous = tails[key]?.task
            let task = Task.detached {
                await previous?.value
                do { try await write(store) } catch let refused as LawError {
                    log("experience write refused: %@", refused.localizedDescription)
                } catch {
                    log("experience write failed: %@", error.localizedDescription)
                }
                pending.withLock { if $0[key]?.token == token { $0[key] = nil } }
            }
            tails[key] = (token, task)
            return task
        }
    }

    let path: URL
    private var opened: DatabasePool?
    var detailsForgottenAt = Date.distantPast
    private var gap: String?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var addressees: [UUID: (to: String, continuation: AsyncStream<Experience>.Continuation)] = [:]
    public nonisolated static let processID = UUID().uuidString

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(())
            continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    /// Every experience addressed to `to`, as it stands after each committed birth or change: what an owner reading "everything for the person" (or for
    /// a conversation) keeps in memory, fed at the write instead of read back.
    public func written(addressedTo to: String) -> AsyncStream<Experience> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            addressees[id] = (to, continuation)
            continuation.onTermination = { _ in Task { await self.removeAddressee(id) } }
        }
    }

    private func removeAddressee(_ id: UUID) { addressees[id] = nil }
    private func wrote(_ experience: Experience) {
        for (to, continuation) in addressees.values where experience.addressedTo.contains(to) { continuation.yield(experience) }
    }

    /// The newest `limit` experiences addressed to `to` born after `after`, returned oldest first: the one launch read of an owner that then
    /// follows `written`.
    public func addressed(to: String, after: Date, limit: Int) throws -> [Experience] {
        try database().read {
            try Self.fold($0, matching: """
                experience.id IN (SELECT experience.id FROM experience, json_each(experience.born, '$.addressedTo') AS addressee
                                  WHERE addressee.value = ? AND experience.at > ? ORDER BY experience.at DESC LIMIT ?)
                """, arguments: [to, NativeTimestampFormat.fractionalZulu(after), max(0, limit)], order: "experience.at, experience.rowid")
        }
    }
    private func changed() { for observer in observers.values { observer.yield(()) } }
    func committed() { guard gap != nil else { return }; gap = nil; changed() }
    func failed(_ error: DatabaseError) {
        guard gap != error.localizedDescription else { return }
        gap = error.localizedDescription
        changed()
    }

    private init(path: URL) {
        self.path = path
    }

    /// A repeated birth cannot create another experience.
    @discardableResult
    public func begin(_ new: Experience, durable: Bool = false) throws -> Bool {
        let inserted = try write(durable: durable) { db -> Experience? in
            if let born = try String.fetchOne(db, sql: "SELECT born FROM experience WHERE id = ?", arguments: [new.id]) {
                var existing = try Self.decoder.decode(Experience.self, from: Data(born.utf8))
                var proposed = new
                // One happening per key (`Happening.once`): a second post from the same door about the same subject, owed to the same place
                // with the same authority, is that happening, whatever it read this time. What it carried the first time stands. A different
                // door, subject, destination or authority under one key is a reused id, refused below so the change is never dropped unseen.
                if let was = existing.happening, let now = proposed.happening,
                   was.once == now.once, was.kind == now.kind, was.door == now.door, was.subject == now.subject, was.who == now.who,
                   was.route == now.route, was.reply == now.reply, was.peers == now.peers, was.elevated == now.elevated { return nil }
                (existing.at, proposed.at) = ("", "")
                (existing.sequence, proposed.sequence) = (nil, nil)
                guard existing == proposed else { throw LawError.reused(new.id) }
                return nil
            }
            var born = new
            born.sequence = nil
            born.at = NativeTimestampFormat.fractionalZulu(Date())
            try db.execute(sql: "INSERT INTO experience (id, kind, at, born, open, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [born.id, born.kind.rawValue, born.at, try Self.json(born), born.isOpen, born.at])
            return born
        }
        guard let inserted else { return false }
        changed()
        var published = inserted
        published.updatedAt = inserted.at
        published.sequence = 0
        wrote(published)
        return true
    }

    /// Validate every post-birth change through the same law.
    public func append(_ changes: [Change], to id: String, durable: Bool = false) throws {
        let moved = try write(durable: durable) { try Self.append(changes, to: id, in: $0) }
        guard let moved else { return }
        changed()
        wrote(moved)
    }

    private static func append(_ changes: [Change], to id: String, in db: Database) throws -> Experience? {
        guard var current = try Self.fold(db, matching: "experience.id = ?", arguments: [id]).first else { throw LawError.unknown(id) }
        let at = NativeTimestampFormat.fractionalZulu(Date())
        var moved = false
        for change in changes {
            if case .progress(let progress) = change, current.progress == progress { continue }
            guard try Self.apply(change, to: &current) else { continue }
            try db.execute(sql: "INSERT INTO event (experience_id, at, event) VALUES (?, ?, ?)",
                           arguments: [id, at, try Self.json(change)])
            current.sequence = db.lastInsertedRowID
            moved = true
        }
        guard moved else { return nil }
        try db.execute(sql: "UPDATE experience SET open = ?, updated_at = ? WHERE id = ?", arguments: [current.isOpen, at, id])
        current.updatedAt = at
        return current
    }

    /// The terminal record and all member projections commit together. Stop leaves owed happenings owed.
    func finishAttentionBatch(_ batch: Attention.Batch, end: Attention.BatchEnd) throws {
        let detail = Detail(source: Attention.detailSource, at: Date(), subject: batch.route, kind: Attention.batchEndKind,
            row: try Self.encoder.encode(end), once: Attention.batchEndKind + ":" + batch.deliveryID)
        guard detail.row.count <= Self.maxRowBytes else { throw DetailError.tooLarge(detail.kind, detail.row.count) }
        let moved = try write { db -> [Experience] in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM detail WHERE once = ?", arguments: [batch.deliveryID]),
                  row["source"] as String == Attention.detailSource, row["kind"] as String == Attention.batchKind,
                  row["subject"] as String == batch.route,
                  try Self.decoder.decode(Attention.Batch.self, from: Data((row["row"] as String).utf8)) == batch,
                  end.deliveryID == batch.deliveryID else { throw LawError.reused(batch.deliveryID) }
            if let row = try Row.fetchOne(db, sql: "SELECT row FROM detail WHERE once = ?", arguments: [detail.once]) {
                guard try Self.decoder.decode(Attention.BatchEnd.self, from: Data((row["row"] as String).utf8)) == end else {
                    throw LawError.secondOutcome(batch.deliveryID)
                }
            }
            var moved: [Experience] = []
            for id in batch.members {
                guard let member = try Self.fold(db, matching: "experience.id = ?", arguments: [id]).first,
                      let happening = member.happening, (happening.route ?? Attention.stream) == batch.route,
                      let obligation = member.owes[happening.destination] else { throw LawError.unknown(id) }
                guard end.status == .completed, !obligation.phase.isSettled else { continue }
                if let settled = try Self.append([.obligation(key: happening.destination, phase: .accepted,
                    attempt: obligation.attempt, evidence: end.evidence)], to: id, in: db) { moved.append(settled) }
            }
            _ = try Self.insert(detail, db)
            return moved
        }
        if !moved.isEmpty { changed() }
        for member in moved { wrote(member) }
    }

    public func experience(_ id: String) throws -> Experience? {
        try database().read { try Self.fold($0, matching: "experience.id = ?", arguments: [id]).first }
    }

    /// Synchronous recovery reads only committed records through the same fold, without creating or migrating a store.
    public nonisolated func recordedExperience(_ id: String) throws -> Experience? {
        do { _ = try FileManager.default.attributesOfItem(atPath: path.path) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        return try readRecorded { try Self.fold($0, matching: "experience.id = ?", arguments: [id]).first }
    }

    /// Committed history is read without initializing storage or entering its write connection.
    nonisolated func readRecorded<T>(_ body: (Database) throws -> T) throws -> T {
        var config = Configuration()
        config.readonly = true
        config.busyMode = .immediateError
        let reader = try DatabaseQueue(path: path.path, configuration: config)
        return try reader.read(body)
    }

    /// The count and newest births share one committed snapshot; each birth is folded through the owner's event law. A record that will not fold
    /// is named in `unreadable` and the rest are returned.
    public func recordedExperiences(id: String? = nil, idPrefix: String? = nil, kind: Experience.Kind? = nil,
                                    openOnly: Bool = false, limit: Int = 20) throws -> (total: Int, items: [Experience], unreadable: [Unreadable]) {
        var clauses: [String] = [], arguments = StatementArguments()
        if let id { clauses.append("experience.id = ?"); arguments += [id] }
        if let idPrefix {
            clauses.append("substr(experience.id, 1, length(?)) = ?")
            arguments += [idPrefix, idPrefix]
        }
        if let kind { clauses.append("experience.kind = ?"); arguments += [kind.rawValue] }
        if openOnly { clauses.append("experience.open") }
        let matching = clauses.isEmpty ? "1" : clauses.joined(separator: " AND ")
        return try readRecorded { db in
            guard let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM experience WHERE \(matching)", arguments: arguments) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var pageArguments = arguments
            pageArguments += [max(0, limit)]
            let page = try Self.foldReadable(db, matching: """
                experience.id IN (SELECT experience.id FROM experience WHERE \(matching)
                                  ORDER BY experience.at DESC, experience.rowid DESC LIMIT ?)
                """, arguments: pageArguments, order: "experience.at DESC, experience.rowid DESC")
            return (total, page.experiences, page.unreadable)
        }
    }

    public func conversationLife(in conversation: String?, since step: Date?, through now: Date) throws -> (since: Date, rows: Folded) {
        try readRecorded { db in
            let end = NativeTimestampFormat.fractionalZulu(now)
            let reply = try String.fetchOne(db, sql: """
                SELECT MAX(at) FROM experience WHERE kind = 'answer' AND at <= ?
                  AND json_extract(born, '$.face.words') != ''
                  AND EXISTS (SELECT 1 FROM json_each(born, '$.addressedTo') WHERE value = ?)
                """, arguments: [end, conversation.map { "conversation:" + $0 }])
            let since = step ?? reply.flatMap(NativeTimestampFormat.parseISO8601FractionalFirst) ?? now.addingTimeInterval(-3600)
            let rows = try Self.foldReadable(db, matching: """
                experience.id IN (
                    WITH recent AS (
                        SELECT id, kind, born FROM experience WHERE at > ? AND at <= ?
                          AND kind IN ('heard', 'answer', 'message', 'thought', 'happening')
                        UNION
                        SELECT id, kind, born FROM experience WHERE id = (
                            SELECT t.id FROM experience t JOIN experience a ON a.id = 'answer:' || json_extract(t.born, '$.thought.run')
                            WHERE t.kind = 'thought' AND t.at <= ?
                              AND json_extract(t.born, '$.outcome.status') IN ('hit', 'empty')
                              AND json_extract(t.born, '$.steeredBy') = '[]' AND json_extract(a.born, '$.steeredBy') = '[]'
                              AND json_extract(a.born, '$.face.words') != ''
                            ORDER BY t.at DESC, t.rowid DESC LIMIT 1)
                    )
                    SELECT id FROM recent
                    UNION SELECT value FROM recent, json_each(recent.born, '$.cause') WHERE recent.kind = 'answer'
                    UNION SELECT 'answer:' || json_extract(born, '$.thought.run') FROM recent WHERE kind = 'thought'
                )
                AND (experience.kind != 'happening'
                     OR (json_extract(experience.born, '$.happening.kind') IS NOT 'world'
                         AND json_extract(experience.born, '$.happening.kind') IS NOT 'self'))
                """, arguments: [NativeTimestampFormat.fractionalZulu(since), end, end],
                order: "experience.at DESC, experience.rowid DESC")
            return (since, rows)
        }
    }

    /// Experiences of these kinds born after `after`, oldest first: what happened since then. A record that will not fold is named in
    /// `unreadable`; it never hides the rest.
    public func born(kinds: [Experience.Kind], after: Date, limit: Int) throws -> Folded {
        guard !kinds.isEmpty else { return Folded() }
        let marks = Array(repeating: "?", count: kinds.count).joined(separator: ",")
        var arguments = StatementArguments(kinds.map(\.rawValue))
        arguments += [NativeTimestampFormat.fractionalZulu(after), max(0, limit)]
        return try database().read {
            // A capped read keeps the newest births in the window (still returned oldest first): the latest thought is never the one dropped.
            try Self.foldReadable($0, matching: "experience.id IN (SELECT id FROM experience WHERE kind IN (\(marks)) AND at > ? ORDER BY at DESC LIMIT ?)",
                                  arguments: arguments, order: "experience.at, experience.rowid")
        }
    }

    /// Recent life follows the last change, so an older act settling between replies is still in the window.
    /// Reads what is already written: this runs ahead of a first word, and queued writes after a launch can take half a minute.
    public func recentLife(after: Date?, through: Date, limit: Int) async throws -> [Experience] {
        if let gap { throw NSError(domain: "Experiences", code: 1, userInfo: [NSLocalizedDescriptionKey: gap]) }
        var arguments: StatementArguments = [NativeTimestampFormat.fractionalZulu(through)]
        var window = "updated_at <= ?"
        if let after {
            window += " AND updated_at > ?"
            arguments += [NativeTimestampFormat.fractionalZulu(after)]
        }
        arguments += [max(0, limit)]
        let matching = """
            experience.id IN (SELECT id FROM experience WHERE kind IN ('act', 'decision', 'run') AND \(window)
                              ORDER BY updated_at DESC, rowid DESC LIMIT ?)
            """
        let bound = arguments
        return try await database().read {
            try Self.fold($0, matching: matching, arguments: bound, order: "experience.updated_at DESC, experience.rowid DESC")
        }
    }

    /// Only the destination's recorded delivery acceptance establishes when an answer was spoken.
    public func lastSpoken(in conversation: String, through: Date) async throws -> Date? {
        if let gap { throw NSError(domain: "Experiences", code: 1, userInfo: [NSLocalizedDescriptionKey: gap]) }
        return try await database().read { db in
            let answers = try Row.fetchAll(db, sql: """
                SELECT DISTINCT experience.id, experience.born, experience.updated_at
                FROM experience, json_each(experience.born, '$.addressedTo') AS destination
                WHERE experience.kind = 'answer' AND experience.at <= ? AND destination.value = ?
                  AND json_extract(experience.born, '$.face.words') != ''
                ORDER BY experience.updated_at DESC, experience.rowid DESC
                """, arguments: [NativeTimestampFormat.fractionalZulu(through), "conversation:" + conversation])
            var latest: Date?
            for row in answers {
                let id: String = row["id"]
                if let latest {
                    guard let changed = NativeTimestampFormat.parseISO8601FractionalFirst(row["updated_at"] as String) else {
                        throw LawError.unreadable(id, 0, "the answer's last-change time is unreadable")
                    }
                    // Last-change order bounds every delivery acceptance time.
                    if changed <= latest { break }
                }
                guard let answer = try Self.fold(db, matching: "experience.id = ?", arguments: [id]).first else {
                    throw LawError.unknown(id)
                }
                let deliveries = answer.owes.filter { $0.key.hasPrefix("deliver:") }
                guard !deliveries.isEmpty, deliveries.values.allSatisfy({ $0.phase == .accepted }) else { continue }
                var accepted: [String: Date] = [:]
                let born = try Self.decoder.decode(Experience.self, from: Data((row["born"] as String).utf8))
                for (key, delivery) in born.owes where key.hasPrefix("deliver:") && delivery.phase == .accepted {
                    guard delivery.evidence != nil, let time = NativeTimestampFormat.parseISO8601FractionalFirst(born.at) else {
                        throw LawError.unreadable(id, 0, "delivery acceptance at birth lacks its evidence or readable time")
                    }
                    accepted[key] = time
                }
                for row in try Row.fetchAll(db, sql: "SELECT seq, at, event FROM event WHERE experience_id = ? ORDER BY seq", arguments: [id]) {
                    let change = try Self.decoder.decode(Change.self, from: Data((row["event"] as String).utf8))
                    guard case .obligation(let key, .accepted, _, _) = change, deliveries[key] != nil else { continue }
                    guard let time = NativeTimestampFormat.parseISO8601FractionalFirst(row["at"] as String) else {
                        throw LawError.unreadable(id, row["seq"], "the delivery acceptance time is unreadable")
                    }
                    accepted[key] = time
                }
                guard accepted.count == deliveries.count, let at = accepted.values.max() else {
                    throw LawError.unreadable(id, answer.sequence ?? 0, "delivery acceptance has no recorded event; repair its experience")
                }
                guard at <= through else { continue }
                latest = latest.map { max($0, at) } ?? at
            }
            return latest
        }
    }

    /// Pending input is retained by its committed weighing, never by its age or position in a page.
    func unweighedHappenings() throws -> [Experience] {
        try database().read {
            try Self.fold($0, matching: """
                experience.id IN (
                    SELECT pending.id FROM experience AS pending
                    WHERE pending.kind = ?
                      AND json_extract(pending.born, '$.happening.kind') IN (?, ?)
                      AND NOT EXISTS (SELECT 1 FROM detail
                                      WHERE detail.source = ? AND detail.subject = pending.id AND detail.kind = ?)
                    ORDER BY pending.at, pending.rowid)
                """, arguments: [Experience.Kind.happening.rawValue,
                                 Happening.Kind.world.rawValue, Happening.Kind.`self`.rawValue,
                                 Attention.detailSource, Attention.weighKind], order: "experience.at, experience.rowid")
        }
    }

    public func open() throws -> [Experience] {
        try database().read { try Self.fold($0, matching: "experience.open", order: "experience.at, experience.rowid") }
    }

    /// Open records addressed to one reader, selected before folding: a damaged record addressed elsewhere never closes this reader's view.
    public func open(addressedTo who: String) throws -> [Experience] {
        try database().read {
            try Self.fold($0, matching: """
                experience.open AND experience.id IN (SELECT experience.id FROM experience, json_each(experience.born, '$.addressedTo') AS addressee
                                                      WHERE addressee.value = ?)
                """, arguments: [who], order: "experience.at, experience.rowid")
        }
    }

    /// Open records of one kind, selected before folding, for the same reason.
    public func open(kind: Experience.Kind) throws -> [Experience] {
        try database().read {
            try Self.fold($0, matching: "experience.open AND experience.kind = ?", arguments: [kind.rawValue], order: "experience.at, experience.rowid")
        }
    }

    /// An exact repair retry needs the debt for its operation, independent of other open records.
    func openRepair(operation: String) throws -> [Experience] {
        try database().read {
            try Self.fold($0, matching: """
                experience.open AND CASE WHEN json_valid(experience.born)
                    THEN json_extract(experience.born, '$.outcome.domain') END = ?
                """, arguments: [operation])
        }
    }

    /// Drain queued writes before reading newly issued IDs so the owner observes its own recorded work.
    public func drained() async {
        let queued = Self.pending.withLock { tails in tails.filter { $0.key.hasPrefix(path.path + "#") }.map(\.value.task) }
        for write in queued { await write.value }
    }

    /// A reader joins queued writes before publication; gaps invalidate projections without changing the producing reply.
    public func projection() async throws -> [Experience] {
        await drained()
        if let gap { throw NSError(domain: "Experiences", code: 1, userInfo: [NSLocalizedDescriptionKey: gap]) }
        return try await database().read { db in
            try Self.fold(db, matching: "experience.open OR experience.id IN (SELECT id FROM experience ORDER BY updated_at DESC LIMIT 64)")
                .sorted { ($0.updatedAt ?? $0.at) > ($1.updatedAt ?? $1.at) }
        }
    }

    /// Replay through the admission law and report unreadable rows.
    /// A record a read could not fold: its id, its birth time as the row holds it, the event that failed (0 for its birth) and why, with the
    /// field that failed named.
    public struct Unreadable: Sendable {
        public let id: String
        public let at: String
        public let seq: Int64
        public let cause: any Error
        public var words: String { cause.localizedDescription }
    }

    /// What a read folded, and each record it could not, named.
    public struct Folded: Sendable {
        public var experiences: [Experience] = []
        public var unreadable: [Unreadable] = []
    }

    /// A birth that will not decode, named by its id and failed field.
    public struct UnreadableBirth: Error, LocalizedError, Sendable {
        public let id: String
        public let detail: String
        public var errorDescription: String? { "Experience \(id)'s birth is unreadable: \(detail)." }
    }

    /// Strict readers and writes: the first record that will not fold is the read's failure.
    private static func fold(_ db: Database, matching: String, arguments: StatementArguments = [],
                             order: String = "experience.id") throws -> [Experience] {
        let read = try foldReadable(db, matching: matching, arguments: arguments, order: order)
        if let first = read.unreadable.first { throw first.cause }
        return read.experiences
    }

    /// Every record that folds, and each one that does not, named by id with its cause; one bad record never hides the others.
    private static func foldReadable(_ db: Database, matching: String, arguments: StatementArguments = [],
                                     order: String = "experience.id") throws -> Folded {
        let decoder = JSONDecoder()
        var folded = Folded()
        var current: Experience?
        var currentID: String?
        for row in try Row.fetchAll(db, sql: """
            SELECT experience.id, experience.at AS born_at, born, updated_at, seq, event FROM experience
            LEFT JOIN event ON event.experience_id = experience.id
            WHERE \(matching) ORDER BY \(order), event.seq
            """, arguments: arguments) {
            let id: String = row["id"]
            if currentID != id {
                if let current { folded.experiences.append(current) }
                currentID = id
                current = nil
                do {
                    var birth = try decoder.decode(Experience.self, from: Data((row["born"] as String).utf8))
                    birth.updatedAt = row["updated_at"]
                    birth.sequence = 0
                    current = birth
                } catch {
                    folded.unreadable.append(.init(id: id, at: (row["born_at"] as String?) ?? "", seq: 0,
                                                   cause: UnreadableBirth(id: id, detail: decodeFailure(error))))
                    continue
                }
            }
            guard var next = current, let event: String = row["event"] else { continue }
            let seq: Int64 = row["seq"]
            do {
                let change: Change
                do { change = try decoder.decode(Change.self, from: Data(event.utf8)) } catch {
                    throw LawError.unreadable(id, seq, decodeFailure(error))
                }
                _ = try apply(change, to: &next)
                next.sequence = seq
                current = next
            } catch {
                // The record stops at its first event that will not fold; a partial record is never handed on as whole.
                current = nil
                folded.unreadable.append(.init(id: id, at: (row["born_at"] as String?) ?? "", seq: seq, cause: error))
            }
        }
        if let current { folded.experiences.append(current) }
        return folded
    }

    /// A decode error with the field that failed, as a path from the record's top (`owes.repair.phase`, `evidence[0].id`).
    static func decodeFailure(_ error: Error) -> String {
        guard let failure = error as? DecodingError else { return error.localizedDescription }
        func field(_ path: [any CodingKey]) -> String {
            var named = ""
            for key in path {
                if let index = key.intValue { named += "[\(index)]" } else { named += (named.isEmpty ? "" : ".") + key.stringValue }
            }
            return named.isEmpty ? "the record itself" : "field " + named
        }
        switch failure {
        case .keyNotFound(let key, let context): return field(context.codingPath + [key]) + " is missing"
        case .valueNotFound(let type, let context): return field(context.codingPath) + " is null where \(type) is required"
        case .typeMismatch(let type, let context): return field(context.codingPath) + " is not \(type): " + context.debugDescription
        case .dataCorrupted(let context): return field(context.codingPath) + " is unreadable: " + context.debugDescription
        @unknown default: return failure.localizedDescription
        }
    }

    /// Keep change admission and replay under one law.
    private static func apply(_ change: Change, to experience: inout Experience) throws -> Bool {
        let id = experience.id
        switch change {
        case .cause(let cause):
            guard !experience.cause.contains(cause) else { return false }
            experience.cause.append(cause)
        case .face(let face):
            guard experience.face != face else { return false }
            experience.face = face
        case .evidence(let ref):
            guard !experience.evidence.contains(ref) else { return false }
            experience.evidence.append(ref)
        case .claim(let claim):
            guard !experience.claims.contains(claim) else { return false }
            experience.claims.append(claim)
        case .outcome(let outcome):
            guard experience.outcome != outcome else { return false }
            guard experience.outcome == nil else { throw LawError.secondOutcome(id) }
            experience.outcome = outcome
        case .progress(let progress):
            experience.progress = progress
        case .obligation(let key, let phase, let attempt, let evidence):
            guard var obligation = experience.owes[key] else { throw LawError.unknownObligation(id, key) }
            switch obligation.phase.step(to: phase) {
            case .already: return false
            case .refused: throw LawError.refusedStep(id, key, obligation.phase, phase)
            case .allowed: break
            }
            guard phase == .reserved || obligation.attempt == attempt else { throw LawError.otherAttempt(id, key) }
            (obligation.phase, obligation.attempt, obligation.evidence) = (phase, attempt, evidence)
            experience.owes[key] = obligation
        case .letGo(let key, let reason):
            guard var obligation = experience.owes[key] else { throw LawError.unknownObligation(id, key) }
            guard !obligation.phase.isSettled else { return false }
            (obligation.phase, obligation.reason) = (.letGo, reason)
            experience.owes[key] = obligation
        }
        return true
    }

    /// Create the bounded WAL store in an owner-only folder so sidecars stay private from their first byte.
    func database() throws -> DatabasePool {
        if let opened { return opened }
        let newStore: Bool
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path.path)
            newStore = false
        } catch CocoaError.fileReadNoSuchFile { newStore = true }
        let folder = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: folder.path)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .immediateError
        // A written terminal must survive a power loss before its turn's restart checkpoint goes.
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_size_limit = 4194304; PRAGMA synchronous = FULL") }
        let pool = try DatabasePool(path: path.path, configuration: config)
        try pool.write { db in
            if try db.tableExists("experience") {
                let columns = Set(try db.columns(in: "experience").map(\.name))
                guard columns.isSuperset(of: ["id", "kind", "at", "born", "open", "updated_at"]),
                      try db.tableExists("event") else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path.path])
                }
            } else {
                guard newStore else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path.path])
                }
                try db.execute(sql: """
                    CREATE TABLE experience (id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, at TEXT NOT NULL,
                                             born TEXT NOT NULL, open INTEGER NOT NULL, updated_at TEXT NOT NULL);
                    CREATE INDEX experience_open ON experience(at) WHERE open;
                    CREATE INDEX experience_recent ON experience(updated_at DESC);
                    CREATE TABLE event (seq INTEGER PRIMARY KEY AUTOINCREMENT,
                                        experience_id TEXT NOT NULL REFERENCES experience(id),
                                        at TEXT NOT NULL, event TEXT NOT NULL);
                    CREATE INDEX event_experience ON event(experience_id, seq);
                    """)
            }
            try db.execute(sql: Self.detailSchema)
        }
        committed()
        // Planner statistics improve reads but are not required for record correctness.
        do { try pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA optimize=0x10002") } }
        catch { Self.log("experience planner statistics unavailable: %@", error.localizedDescription) }
        opened = pool
        return pool
    }

    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
