import Foundation
import GRDB
import PersistenceCore
import Experiences
import NativeAgentShared
// Blueprint: | `CognitiveSQLiteStore+LivedMoments.swift` | `CognitiveSQLiteStore`: the lived-moment journal (`lived_moments`, migration v8): record owed, save input and meaning, assign fold seq, settle lived or refused, prune settled payload-free rows; checked decoding refuses damaged rows individually with reason, preserves payloads and owes repair; reads legacy sealed requests and `folding` rows (as meant) |

// THE JOURNAL (docs/SUBCONSCIOUS.md, "Lived moments"). One table in her own
// cognition store, outside what `clear()` deletes and outside the restore
// bundle: a bad journal row can never fail her mind's restore, and forgetting
// her mind never forgets that a moment was lived. The fold seq is allocated
// from `cognitive_epochs` (domain `fold_seq`) so Clear cannot reset it either.

extension CognitiveSQLiteStore {
    static func registerLivedMomentsMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8_lived_moments") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS lived_moments (
                    id TEXT PRIMARY KEY NOT NULL,
                    life TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    lived_at REAL NOT NULL,
                    accepted_at REAL NOT NULL,
                    state TEXT NOT NULL,
                    fold_seq INTEGER,
                    mind_epoch INTEGER NOT NULL,
                    body_epoch INTEGER NOT NULL,
                    input_json TEXT,
                    sealed_json TEXT,
                    meaning_json TEXT,
                    parts_json TEXT NOT NULL DEFAULT '{}',
                    reason TEXT,
                    updated_at REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS lived_moments_state ON lived_moments(state, accepted_at)")
        }
        // Each continuity node knows the last lived moment that stamped or
        // reconsolidated its feeling. NULL (and every row an older binary
        // writes) reads as none.
        migrator.registerMigration("v9_node_lived_seq") { db in
            try db.execute(sql: "ALTER TABLE cognitive_nodes ADD COLUMN lived_seq INTEGER")
        }
    }

    private static func encoded<T: Encodable>(_ value: T?) throws -> String? {
        guard let value else { return nil }
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private enum MomentReadFailure: Error, CustomStringConvertible {
        case malformed(String)
        var description: String {
            switch self { case .malformed(let why): return why }
        }
    }

    private static func decoded<T: Decodable>(_ type: T.Type, _ text: String?, column: String) throws -> T? {
        guard let text else { return nil }
        do { return try JSONDecoder().decode(type, from: Data(text.utf8)) }
        catch { throw MomentReadFailure.malformed("\(column): \(error)") }
    }

    /// Older rows sealed a second request record. Only its caring evidence is
    /// used by a refold; care judgments already name their targets in meaning.
    private struct LegacyRequest: Decodable {
        var caring: CaringAppraisalRequest?
    }

    private static func moment(_ row: Row) throws -> CognitiveLivedMoment {
        let stateText: String = try row.decode(forColumn: "state")
        // An older binary's `folding` is a meant row whose fold began.
        guard let state = CognitiveMomentState(rawValue: stateText == "folding" ? "meant" : stateText) else {
            throw MomentReadFailure.malformed("unknown moment state: \(stateText)")
        }
        let seq: Int64? = try row.decode(forColumn: "fold_seq")
        let mind: Int64 = try row.decode(forColumn: "mind_epoch")
        let body: Int64 = try row.decode(forColumn: "body_epoch")
        guard mind >= 0, body >= 0, seq.map({ $0 >= 0 }) ?? true else {
            throw CognitiveSQLiteCounterError.outsideStorageRange("lived moment counters")
        }
        let unsettled = state == .owed || state == .meant
        let kind: String = try row.decode(forColumn: "kind")
        var input: CognitiveMomentInput?
        var meaning: JSONValue?
        if unsettled {
            input = try decoded(CognitiveMomentInput.self, row.decode(forColumn: "input_json"), column: "input_json")
            meaning = try decoded(JSONValue.self, row.decode(forColumn: "meaning_json"), column: "meaning_json")
        }
        if unsettled, kind == "turn" {
            guard input?.turn != nil else { throw MomentReadFailure.malformed("input_json: missing turn") }
            guard state != .owed || (meaning == nil && seq == nil) else {
                throw MomentReadFailure.malformed("owed row already has meaning or a begun fold")
            }
            guard state != .meant || meaning != nil else {
                throw MomentReadFailure.malformed("meaning_json: meant row has no meaning")
            }
        }
        if unsettled, let caring = try decoded(LegacyRequest.self,
            row.decode(forColumn: "sealed_json"), column: "sealed_json")?.caring {
            input?.deferred?.caring = caring
        }
        return try CognitiveLivedMoment(
            id: row.decode(forColumn: "id"), life: row.decode(forColumn: "life"), kind: kind,
            livedAt: Date(timeIntervalSince1970: row.decode(forColumn: "lived_at")),
            acceptedAt: Date(timeIntervalSince1970: row.decode(forColumn: "accepted_at")),
            state: state, foldSeq: seq.map { UInt64(max(0, $0)) },
            mindEpoch: UInt64(max(0, mind)), bodyEpoch: UInt64(max(0, body)),
            input: input,
            meaning: meaning)
    }

    private struct MomentRead: Sendable {
        var id: String
        var moment: CognitiveLivedMoment? = nil
        var failure: String? = nil
    }

    private static func readMoment(_ row: Row) throws -> MomentRead {
        let id: String = try row.decode(forColumn: "id")
        do { return MomentRead(id: id, moment: try moment(row)) }
        catch { return MomentRead(id: id, failure: String(describing: error)) }
    }

    /// Refuse a damaged row individually, preserving every payload byte and
    /// owing its repair. This is not settlement of any of its mind share.
    public func refuseUnreadableMoment(_ id: String, why: String) async throws {
        nativeLog("cognition: moment %@ unreadable, payload preserved: %@", id, why)
        await RepairOwed.owe(databaseURL.deletingLastPathComponent().deletingLastPathComponent(),
            id: "cognition.moment.read:" + id, kind: .run, evidence: [.init(source: "lived_moments", id: id)],
            operation: "cognition.moment.read:" + id, owner: "cognition",
            words: "Journal row \(id) is unavailable; its payload is preserved: \(why)",
            tap: "Settings → Doctor").value
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE lived_moments SET state = 'refused', reason = ?, updated_at = ?
                WHERE id = ? AND state NOT IN ('lived', 'refused')
                """, arguments: [why, Date().timeIntervalSince1970, id])
        }
    }

    private struct EncodedMoment: Sendable {
        let moment: CognitiveLivedMoment
        let input, meaning: String?
    }

    private static func encodedMoment(_ moment: CognitiveLivedMoment) throws -> EncodedMoment {
        EncodedMoment(moment: moment, input: try encoded(moment.input), meaning: try encoded(moment.meaning))
    }

    private static func insert(_ db: Database, _ row: EncodedMoment) throws -> Bool {
        let moment = row.moment
        try db.execute(sql: """
            INSERT OR IGNORE INTO lived_moments
            (id, life, kind, lived_at, accepted_at, state, fold_seq, mind_epoch, body_epoch,
             input_json, meaning_json, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                moment.id, moment.life, moment.kind, moment.livedAt.timeIntervalSince1970,
                moment.acceptedAt.timeIntervalSince1970, moment.state.rawValue,
                moment.foldSeq.map { try sqliteCounter($0, named: "fold_seq") },
                sqliteCounter(moment.mindEpoch, named: "mind_epoch"), sqliteCounter(moment.bodyEpoch, named: "body_epoch"),
                row.input, row.meaning, Date().timeIntervalSince1970,
            ])
        return db.changesCount > 0
    }

    /// Record a moment. An identity already recorded is left as it is (a
    /// re-delivery is inert); returns whether this call recorded it.
    @discardableResult
    public func recordMoment(_ moment: CognitiveLivedMoment) async throws -> Bool {
        let row = try Self.encodedMoment(moment)
        return try await dbQueue.write { db -> Bool in try Self.insert(db, row) }
    }

    /// Record several moments in ONE transaction: all land or none do (the
    /// held-queue import's acknowledgement).
    public func recordMoments(_ moments: [CognitiveLivedMoment]) async throws {
        let rows = try moments.map(Self.encodedMoment)
        try await dbQueue.write { db in
            for row in rows { _ = try Self.insert(db, row) }
        }
    }

    public func loadMoment(_ id: String) async throws -> CognitiveLivedMoment? {
        let read = try await dbQueue.read { db -> MomentRead? in
            try Row.fetchOne(db, sql: "SELECT * FROM lived_moments WHERE id = ?", arguments: [id])
                .map(Self.readMoment)
        }
        if let why = read?.failure {
            try await refuseUnreadableMoment(id, why: why)
            throw MomentReadFailure.malformed(why)
        }
        return read?.moment
    }

    /// Moments in these states (meant includes an older binary's `folding`),
    /// begun folds by fold seq first, the rest in the order they were accepted.
    public func loadMoments(states: [CognitiveMomentState]) async throws -> [CognitiveLivedMoment] {
        let names = states.map(\.rawValue) + (states.contains(.meant) ? ["folding"] : [])
        guard !names.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: names.count).joined(separator: ",")
        let reads = try await dbQueue.read { db -> [MomentRead] in
            try Row.fetchAll(db, sql: """
                SELECT * FROM lived_moments WHERE state IN (\(marks))
                ORDER BY fold_seq IS NULL, fold_seq, accepted_at
                """, arguments: StatementArguments(names))
                .map(Self.readMoment)
        }
        var moments: [CognitiveLivedMoment] = []
        for read in reads {
            if let why = read.failure { try await refuseUnreadableMoment(read.id, why: why) }
            else if let moment = read.moment { moments.append(moment) }
        }
        return moments
    }

    /// Save an unsettled moment's mutable half: state, input and meaning.
    public func saveMoment(_ moment: CognitiveLivedMoment) async throws {
        let input = try Self.encoded(moment.input)
        let meaning = try Self.encoded(moment.meaning)
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE lived_moments SET state = ?, input_json = ?, sealed_json = NULL, meaning_json = ?, updated_at = ?
                WHERE id = ? AND state NOT IN (?, ?)
                """, arguments: [moment.state.rawValue, input, meaning, Date().timeIntervalSince1970, moment.id,
                                 CognitiveMomentState.lived.rawValue, CognitiveMomentState.refused.rawValue])
        }
    }

    /// Settle a moment `lived` or `refused` (with its reason): payloads
    /// dropped, identity kept. A settled moment stays as it was.
    public func settleMoment(_ id: String, as state: CognitiveMomentState, reason: String? = nil) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE lived_moments SET state = ?, input_json = NULL, sealed_json = NULL, meaning_json = NULL,
                    reason = ?, updated_at = ?
                WHERE id = ? AND state NOT IN (?, ?)
                """, arguments: [state.rawValue, reason, Date().timeIntervalSince1970, id,
                                 CognitiveMomentState.lived.rawValue, CognitiveMomentState.refused.rawValue])
        }
    }

    /// The moment's fold seq: allocated once from the allocation Clear never
    /// resets. A moment whose fold began keeps the seq it had (a refold after
    /// a crash); a meant row with a seq is exactly that.
    public func beginFold(_ id: String) async throws -> UInt64? {
        try await dbQueue.write { db -> UInt64? in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT fold_seq FROM lived_moments WHERE id = ?", arguments: [id]) else { return nil }
            let existing: Int64? = try row.decode(forColumn: "fold_seq")
            if let existing {
                guard existing >= 0 else { throw CognitiveSQLiteCounterError.outsideStorageRange("fold_seq") }
                return UInt64(existing)
            }
            let seq = try Self.bumpEpoch(db, domain: "fold_seq")
            try db.execute(sql: """
                UPDATE lived_moments SET fold_seq = ?, updated_at = ? WHERE id = ?
                """, arguments: [Self.sqliteCounter(seq, named: "fold_seq"), Date().timeIntervalSince1970, id])
            return seq
        }
    }

    /// Payload-free settled rows before `date` are pruned. An unsettled row,
    /// or a damaged row whose payload is preserved for repair, is never pruned.
    @discardableResult
    public func pruneMoments(settledBefore date: Date) async throws -> Int {
        try await dbQueue.write { db -> Int in
            try db.execute(sql: """
                DELETE FROM lived_moments WHERE state IN (?, ?) AND updated_at < ?
                AND input_json IS NULL AND sealed_json IS NULL AND meaning_json IS NULL
                """,
                           arguments: [CognitiveMomentState.lived.rawValue, CognitiveMomentState.refused.rawValue,
                                       date.timeIntervalSince1970])
            return db.changesCount
        }
    }

    /// How many moments are not yet lived (owed or meant).
    public func unlivedMomentCount() async throws -> Int {
        try await dbQueue.read { db -> Int in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lived_moments WHERE kind = 'turn' AND state IN ('owed', 'meant', 'folding')") ?? 0
        }
    }
}
