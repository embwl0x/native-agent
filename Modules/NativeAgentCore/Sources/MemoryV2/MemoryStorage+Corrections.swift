import Foundation
import GRDB
import PersistenceCore
// Blueprint: | `MemoryStorage+Corrections.swift` | `MemoryStorage`, `correctionMoments`: idempotent canonical correction occurrences; session-and-time read |

/// When and in which session the person corrected the agent; the ledger's own record, without the memory's words.
public struct CorrectionMoment: Sendable, Equatable {
    public let session: String?
    public let at: Date
}

extension MemoryStorage {
    struct CorrectionOccurrence: Sendable {
        let memory: StoredMemory
        let originID: String
        let at: String
        let date: Date
        let sessionID: String?
        let history: String?
    }

    /// Called inside the memory write, before any turn payload is settled. Replaying the same origin on the same correction adds no second miss.
    static func recordCorrectionOccurrence(metadata: JSONValue?, rowID: String, createdAt: String, on id: String,
                                           proposal: Bool = false, in db: Database) throws {
        guard case .object(let metadata)? = metadata,
              metadata["kind"] == .string("correction") else { return }
        let at: String
        if let supplied = metadata["turn_at"] {
            guard case .string(let value) = supplied else {
                throw MemoryStorageError.invalidTemporalEvidence("correction turn_at must be an ISO-8601 timestamp")
            }
            at = value
        } else {
            // A save without a turn has its own row identity and insert time.
            at = createdAt
        }
        guard let date = MemoryDataProvenance.parseTimestamp(at) else {
            throw MemoryStorageError.invalidTemporalEvidence("correction occurrence time is not ISO-8601")
        }
        func string(_ key: String) throws -> String? {
            guard let supplied = metadata[key] else { return nil }
            guard case .string(let value) = supplied, !value.isEmpty else {
                throw MemoryStorageError.invalidTemporalEvidence("correction \(key) must be a nonempty string")
            }
            return value
        }
        let session = try string("session_id")
        let history = try string("history")
        let turn = try string("turn_id")
        let identity: [String]
        if let session, let history { identity = ["message", session, history] }
        else if let turn { identity = ["turn", turn] }
        else if metadata["turn_at"] != nil {
            throw MemoryStorageError.invalidTemporalEvidence("dated correction requires its message or turn identity")
        } else { identity = ["memory", rowID] }
        let origin = identity.map { "\($0.utf8.count):\($0)" }.joined()
        // These are the two canonical transaction owners, never input SQL.
        let table = proposal ? "correction_proposal_occurrences" : "correction_occurrences"
        let owner = proposal ? "proposal_id" : "memory_id"
        if let prior = try Row.fetchOne(db, sql: """
            SELECT occurred_at, session_id, history FROM \(table)
            WHERE \(owner) = ? AND origin_id = ?
            """, arguments: [id, origin]) {
            let priorDate: Double = try prior.decode(forColumn: "occurred_at")
            let priorSession: String? = try prior.decode(forColumn: "session_id")
            let priorHistory: String? = try prior.decode(forColumn: "history")
            guard priorDate == date.timeIntervalSince1970, priorSession == session, priorHistory == history else {
                throw MemoryStorageError.invalidTemporalEvidence("correction origin already has different occurrence evidence")
            }
            return
        }
        try db.execute(sql: """
            INSERT INTO \(table) (\(owner), origin_id, at, occurred_at, session_id, history)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [id, origin, at, date.timeIntervalSince1970, session, history])
    }

    static func recordProposedCorrection(_ proposal: StoredProposal, on id: String, in db: Database) throws {
        try recordCorrectionOccurrence(metadata: proposal.metadata, rowID: proposal.id, createdAt: proposal.stagedAt,
                                       on: id, proposal: true, in: db)
    }

    /// A repeat uses the same canonical duplicate transaction as a save, with the incoming turn intact rather than encoded into a preview patch.
    func repeatCorrection(id: String, source: String, metadata: JSONValue, context: MemoryWriteContext) async throws {
        let metadata = try context.stamping(metadata)
        let saved = try await dbPool.write { db -> StoredMemory in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id])
                .map(Self.decodeMemory), row.metadata?.objectValue?["kind"] == .string("correction") else {
                throw MemoryV2Error.recordNotFound
            }
            var incoming = row
            incoming.source = source
            incoming.metadata = metadata
            return try Self.foldDuplicate(incoming, into: row, in: db)
        }
        invalidateRecallCache()
        pokeUserMDRegen(persona: saved.personaId)
        await pokeProjectionHooks(saved)
    }

    /// A window starting before the ledger's complete coverage throws: an uncovered window is never read as fewer corrections.
    private static func requireCorrectionCoverage(from start: Date, in db: Database) throws {
        guard let since = try Double.fetchOne(db, sql: "SELECT complete_since FROM correction_ledger_state WHERE id = 1"),
              since.isFinite else {
            throw MemoryStorageError.databaseUnavailable("correction ledger coverage is unavailable")
        }
        guard start.timeIntervalSince1970 >= since else {
            throw MemoryStorageError.databaseUnavailable(
                """
                    Complete correction history is available only since \(Date(timeIntervalSince1970: since).ISO8601Format()); earlier duplicate previews \
                    discarded occurrences.
                    """)
        }
    }

    /// Session and time of each correction in (start, end], under the same coverage law as `correctionOccurrences`; no memory text is read.
    func correctionMoments(from start: Date, to end: Date) async throws -> [CorrectionMoment] {
        try await dbPool.read { db in
            try Self.requireCorrectionCoverage(from: start, in: db)
            return try Row.fetchAll(db, sql: """
                SELECT c.session_id AS correction_session, c.occurred_at AS correction_date
                FROM correction_occurrences c JOIN memories ON memories.id = c.memory_id
                WHERE c.occurred_at > ? AND c.occurred_at <= ? AND memories.status != 'deleted'
                ORDER BY c.occurred_at, c.memory_id, c.origin_id
                """, arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]).map { row in
                    let instant: Double = try row.decode(forColumn: "correction_date")
                    guard instant.isFinite else {
                        throw MemoryStorageError.invalidTemporalEvidence("correction occurrence time is not finite")
                    }
                    let session: String? = try row.decode(forColumn: "correction_session")
                    return CorrectionMoment(session: session, at: Date(timeIntervalSince1970: instant))
                }
        }
    }

    /// Full owner record for the window. Failure or incomplete retained history throws; neither is presented as zero or a partial total.
    func correctionOccurrences(from start: Date, to end: Date) async throws -> [CorrectionOccurrence] {
        try await dbPool.read { db in
            try Self.requireCorrectionCoverage(from: start, in: db)
            return try Row.fetchAll(db, sql: """
                SELECT memories.*, c.origin_id AS correction_origin, c.at AS correction_at,
                       c.occurred_at AS correction_date, c.session_id AS correction_session,
                       c.history AS correction_history
                FROM correction_occurrences c JOIN memories ON memories.id = c.memory_id
                WHERE c.occurred_at >= ? AND c.occurred_at < ? AND memories.status != 'deleted'
                ORDER BY c.occurred_at DESC, c.memory_id, c.origin_id
                """, arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]).map { row in
                    let instant: Double = try row.decode(forColumn: "correction_date")
                    let at: String = try row.decode(forColumn: "correction_at")
                    guard instant.isFinite, MemoryDataProvenance.parseTimestamp(at)?.timeIntervalSince1970 == instant else {
                        throw MemoryStorageError.invalidTemporalEvidence("correction occurrence time disagrees with its timestamp")
                    }
                    return try CorrectionOccurrence(memory: Self.decodeMemory(row),
                        originID: row.decode(forColumn: "correction_origin"),
                        at: at, date: Date(timeIntervalSince1970: instant),
                        sessionID: row.decode(forColumn: "correction_session"), history: row.decode(forColumn: "correction_history"))
                }
        }
    }
}

extension SwiftNativeMemoryV2 {
    /// Corrections in (since, through] as session and time from the canonical ledger; a window the ledger does not cover throws.
    public static func correctionMoments(dataRoot: URL, since: Date, through: Date) async throws -> [CorrectionMoment] {
        try await resolvedStorage(dataRoot: dataRoot).correctionMoments(from: since, to: through)
    }

    func repeatCorrection(id: String, source: String, turnMetadata: [String: JSONValue], context: MemoryWriteContext) async throws {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        var metadata = turnMetadata
        metadata["kind"] = .string("correction")
        try await storage.repeatCorrection(id: id, source: source, metadata: .object(metadata), context: context)
    }
}
