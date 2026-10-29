import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryStorage+Proposals.swift` | `MemoryStorage`: `repairSupersededTombstones`, `stagePendingProposal`, `updateProposalMetadata` |

extension MemoryStorage {
    // Repair and cursor commit together; every row is visited without advancing past failed repairs.
    public func repairSupersededTombstones() async throws {
        try await dbPool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS proposal_repair_cursor (singleton INTEGER PRIMARY KEY, stamp TEXT NOT NULL, id TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS proposals_repair_order ON proposals
                (COALESCE(json_extract(metadata_json, '$.supersededAt'), resolved_at, staged_at), id);
                """)
            let cursor = try Row.fetchOne(db, sql: "SELECT stamp, id FROM proposal_repair_cursor WHERE singleton = 1")
            let stamp: String = cursor?["stamp"] ?? ""
            let id: String = cursor?["id"] ?? ""
            let rows = try Row.fetchAll(db, sql: """
                SELECT *, COALESCE(json_extract(metadata_json, '$.supersededAt'), resolved_at, staged_at) AS repair_stamp
                FROM proposals
                WHERE (COALESCE(json_extract(metadata_json, '$.supersededAt'), resolved_at, staged_at), id) > (?, ?)
                ORDER BY COALESCE(json_extract(metadata_json, '$.supersededAt'), resolved_at, staged_at), id
                LIMIT 256
                """, arguments: [stamp, id])
            for raw in rows {
                let row = try Self.decodeProposal(raw)
                let marker = SwiftNativeMemoryV2.supersededByMarker(in: row.metadata)
                let prefix = SwiftNativeMemoryV2.supersessionReasonPrefix
                let reason = row.rejectionReason ?? ""
                guard row.status == "superseded"
                    || (row.status == "rejected" && reason.hasPrefix("superseded by a correction:"))
                    || (row.status == "pending" && marker != nil) else { continue }
                if reason.hasPrefix(prefix), !reason.dropFirst(prefix.count).isEmpty {
                    try db.execute(sql: "DELETE FROM tombstones WHERE content_hash = ? AND content = ? AND reason = ?",
                                   arguments: [Self.contentHash(row.content), row.content, reason])
                }
                var metadata: [String: JSONValue] = [:]
                if case .object(let existing)? = row.metadata { metadata = existing }
                let successor = marker ?? (reason.hasPrefix(prefix)
                    ? String(reason.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : "")
                if marker == nil, !successor.isEmpty {
                    metadata["supersededBy"] = .string(successor)
                    // Preserve the ordering key while repairing historical rows.
                    metadata["supersededAt"] = .string(raw["repair_stamp"])
                    metadata["supersededByRecovery"] = .string("launch-repair")
                }
                if row.status != "superseded", metadata["supersededAt"] == nil {
                    metadata["supersededAt"] = .string(raw["repair_stamp"])
                }
                try db.execute(sql: """
                    UPDATE proposals SET status = 'superseded', rejection_reason = ?, metadata_json = ?,
                        resolved_at = CASE WHEN status = 'superseded' THEN resolved_at ELSE ? END WHERE id = ?
                    """, arguments: [marker.map { prefix + $0 } ?? row.rejectionReason,
                                     Self.encodeMetadata(.object(metadata)), Self.nowISO8601(), row.id])
            }
            if let last = rows.last {
                let stamp: String = last["repair_stamp"]
                let id: String = last["id"]
                try db.execute(sql: "INSERT OR REPLACE INTO proposal_repair_cursor VALUES (1, ?, ?)", arguments: [stamp, id])
            }
        }
    }

    // MARK: - Proposals

    /// Retain recent review history, today's quota evidence and every proposal
    /// referenced by retained rows or memories. Denial lives in tombstones,
    /// which this bound never changes. Historical supersession repairs must
    /// finish before their evidence can be forgotten.
    static func pruneTerminalProposals(in db: Database, at now: Date = Date()) throws {
        let terminalCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM proposals WHERE status IN ('accepted', 'rejected', 'merged', 'superseded')
            """) ?? 0
        guard terminalCount > 512 else { return }
        let dayStart = MemoryDueDateStamp.iso8601(Calendar.current.startOfDay(for: now))
        try db.execute(sql: """
            WITH RECURSIVE retained(id) AS (
                SELECT id FROM proposals WHERE status NOT IN ('accepted', 'rejected', 'merged', 'superseded')
                UNION
                SELECT id FROM proposals WHERE julianday(staged_at) >= julianday(?)
                UNION
                SELECT id FROM (
                    SELECT id FROM proposals WHERE status IN ('accepted', 'rejected', 'merged', 'superseded')
                    ORDER BY COALESCE(resolved_at, staged_at) DESC, id LIMIT 512
                )
                UNION
                SELECT p.id FROM proposals p JOIN memories m ON m.id = p.id
                UNION
                SELECT p.id FROM memories m, json_tree(m.metadata_json) link
                    JOIN proposals p ON p.id = link.value WHERE link.type = 'text'
                UNION
                SELECT id FROM proposals WHERE
                    (status = 'rejected' AND rejection_reason LIKE 'superseded by a correction:%')
                    OR (status = 'superseded' AND (
                        json_extract(metadata_json, '$.supersededBy') IS NULL
                        OR content IN (SELECT content FROM tombstones)
                    ))
                UNION
                SELECT target.id FROM retained r JOIN proposals p ON p.id = r.id,
                    json_tree(p.metadata_json) link JOIN proposals target ON target.id = link.value
                    WHERE link.type = 'text'
                UNION
                SELECT p.id FROM retained r JOIN proposals p
                    ON json_extract(p.metadata_json, '$.supersededBy') = r.id
            )
            DELETE FROM proposals WHERE status IN ('accepted', 'rejected', 'merged', 'superseded')
                AND id NOT IN (SELECT id FROM retained)
            """, arguments: [dayStart])
    }

    public func supersedeProposal(id: String, by successorId: String) async throws -> Bool {
        guard id != successorId else { return false }
        return try await dbPool.write { db in
            guard let proposal = try Row.fetchOne(
                db, sql: "SELECT * FROM proposals WHERE id = ?", arguments: [id]
            ).map(Self.decodeProposal) else { throw MemoryV2Error.recordNotFound }
            guard proposal.status == "pending" else { return proposal.status == "superseded" }
            var metadata: [String: JSONValue] = [:]
            if case .object(let existing)? = proposal.metadata { metadata = existing }
            let now = Self.nowISO8601()
            metadata["supersededBy"] = .string(successorId)
            metadata["supersededAt"] = .string(now)
            try db.execute(sql: """
                UPDATE proposals SET metadata_json = ?, status = 'superseded',
                    resolved_at = ?, rejection_reason = ? WHERE id = ?
                """, arguments: [Self.encodeMetadata(.object(metadata)), now,
                                  SwiftNativeMemoryV2.supersessionReasonPrefix + successorId, id])
            try Self.pruneTerminalProposals(in: db)
            return true
        }
    }

    @discardableResult
    /// Match, merge and insert pending proposals under one write lock to preserve concurrent evidence.
    ///
    /// `foldedKey` is the caller's normalisation (article folding + content
    /// hash); `merge` receives the row found under the lock and returns the
    /// metadata to store on it. With `insertIfAbsent` false, no match means no
    /// write and a nil result — that lets the caller skip embedding work it
    /// only needs on the insert path.
    public func stagePendingProposal(
        _ proposal: StoredProposal,
        insertIfAbsent: Bool,
        foldedKey: @Sendable (String) -> String,
        merge: @Sendable (StoredProposal) throws -> JSONValue?
    ) async throws -> StoredProposal? {
        var stamped = proposal
        stamped.metadata = MemoryDataProvenance.stamping(try MemorySenseProvenance.stamping(stamped.metadata))
        let proposal = stamped
        return try await dbPool.write { db -> StoredProposal? in
            let key = foldedKey(proposal.content)
            // staged_at DESC matches `listProposals(status:)`, whose order this
            // path's `.first(where:)` used to depend on.
            let pending = try Row.fetchAll(
                db,
                sql: "SELECT * FROM proposals WHERE status = 'pending' ORDER BY staged_at DESC"
            ).map(Self.decodeProposal)
            if let existing = pending.first(where: { foldedKey($0.content) == key }) {
                var merged = try MemorySenseProvenance.preserving(existing: existing.metadata, incoming: merge(existing))
                merged = MemoryDataProvenance.preserving(existing: existing.metadata, incoming: merged)
                merged = MemoryDataProvenance.preserving(existing: proposal.metadata, incoming: merged)
                let provenance = MemorySenseProvenance.merging(existing: merged, incoming: proposal.metadata)
                if !provenance.isEmpty {
                    var metadata: [String: JSONValue] = [:]
                    if case .object(let values)? = merged { metadata = values }
                    metadata.merge(provenance) { _, new in new }
                    merged = .object(metadata)
                }
                try db.execute(sql: """
                    UPDATE proposals SET metadata_json = ?
                    WHERE id = ? AND status = 'pending'
                """, arguments: [Self.encodeMetadata(merged), existing.id])
                return try Row.fetchOne(
                    db, sql: "SELECT * FROM proposals WHERE id = ?", arguments: [existing.id]
                ).map(Self.decodeProposal)
            }
            guard insertIfAbsent else { return nil }
            try Self.requireWritableEpoch(
                in: db,
                vector: proposal.embedding,
                epoch: proposal.embeddingEpoch
            )
            try db.execute(sql: """
                INSERT INTO proposals
                  (id, content, persona_id, source, staged_at, status,
                   resolved_at, rejection_reason, embedding, metadata_json, embedding_epoch)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                proposal.id, proposal.content, proposal.personaId, proposal.source,
                proposal.stagedAt, proposal.status,
                proposal.resolvedAt, proposal.rejectionReason,
                Self.encodeEmbedding(proposal.embedding),
                Self.encodeMetadata(proposal.metadata),
                proposal.embeddingEpoch
            ])
            try Self.pruneTerminalProposals(in: db)
            return proposal
        }
    }

    public func acceptProposal(
        id: String,
        superseding: SupersedingAcceptance? = nil
    ) async throws -> StoredMemory {
        let turnProvenance = try MemorySenseProvenance.stamping(nil)
        // The semantic-gate rejection must COMMIT, so the write closure returns
        // an outcome instead of throwing mid-transaction (a throw inside
        // dbPool.write rolls back everything — including the rejection row).
        enum AcceptOutcome {
            case accepted(StoredMemory, evicted: [StoredMemory], demoted: [StoredMemory])
            case tombstoned
        }
        let outcome = try await dbPool.write { db -> AcceptOutcome in
            guard var proposal = try Row.fetchOne(db, sql: "SELECT * FROM proposals WHERE id = ?", arguments: [id]).map(Self.decodeProposal) else {
                throw MemoryStorageError.notFound(id)
            }
            guard proposal.status == "pending" else {
                throw MemoryStorageError.alreadyResolved(id)
            }
            let provenance = MemorySenseProvenance.merging(existing: proposal.metadata, incoming: turnProvenance)
            if !provenance.isEmpty {
                var metadata: [String: JSONValue] = [:]
                if case .object(let existing)? = proposal.metadata { metadata = existing }
                metadata.merge(provenance) { _, incoming in incoming }
                proposal.metadata = .object(metadata)
            }
            // Recheck the exact denylist inside the admission transaction.
            // A tombstone can arrive after the caller's earlier check, and
            // embeddingless legacy claims cannot rely on the semantic gate.
            let exactTombstone = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM tombstones WHERE content_hash = ?",
                arguments: [Self.contentHash(proposal.content)]
            ) ?? 0 > 0
            if exactTombstone {
                try db.execute(sql: """
                    UPDATE proposals SET status = 'rejected', resolved_at = ?, rejection_reason = ?
                    WHERE id = ?
                """, arguments: [Self.nowISO8601(), "tombstoned: exact match to a rejected claim", id])
                try Self.pruneTerminalProposals(in: db)
                return .tombstoned
            }
            // Acceptance checks semantic tombstones in the same transaction; rows without embeddings use the exact-hash gate.
            if let pe = proposal.embedding,
               try Self.tombstoneMatch(
                   db: db,
                   query: pe,
                   queryEpoch: proposal.embeddingEpoch,
                   threshold: memoryNearVerbatimSimilarity
               ) {
                try db.execute(sql: """
                    UPDATE proposals SET status = 'rejected', resolved_at = ?, rejection_reason = ?
                    WHERE id = ?
                """, arguments: [Self.nowISO8601(), "tombstoned: semantic match to a rejected claim", id])
                try Self.pruneTerminalProposals(in: db)
                return .tombstoned
            }
            let now = Self.nowISO8601()
            // Preserve the proposal's confidence and kind, defaulting absent confidence to 1.0.
            let proposalMeta: [String: JSONValue] = {
                if case .object(let o)? = proposal.metadata { return o }
                return [:]
            }()
            var subjectPredecessors: [StoredMemory] = []
            if case .string("correction")? = proposalMeta["kind"] {
                guard case .string(let subject)? = proposalMeta["correction_subject"],
                      case .string(let observedAt)? = proposalMeta["observed_at"],
                      let ruleDate = MemoryRecallScoring.parseTimestamp(observedAt) else {
                    throw MemoryStorageError.invalidTemporalEvidence("standing correction requires its subject and originating turn time")
                }
                subjectPredecessors = try Row.fetchAll(db, sql: """
                    SELECT * FROM memories WHERE persona_id = ? AND status = 'active'
                      AND lifecycle NOT IN \(MemoryLifecycle.recallExcludedSQL)
                      AND json_extract(metadata_json, '$.kind') = 'correction'
                      AND json_extract(metadata_json, '$.correction_subject') = ?
                    """, arguments: [proposal.personaId, subject]).map(Self.decodeMemory)
                for predecessor in subjectPredecessors {
                    guard let observedAt = predecessor.observedAt,
                          let priorDate = MemoryRecallScoring.parseTimestamp(observedAt) else {
                        throw MemoryStorageError.invalidTemporalEvidence("prior standing correction time is not ISO-8601")
                    }
                    guard priorDate <= ruleDate else {
                        throw MemoryV2Error.underlying("a newer standing correction already governs this subject")
                    }
                }
            }
            let stampedConfidence: Double = {
                // Accept double, int and numeric-string confidence, clamp to 0...1; absent or unparseable defaults to 1.0.
                let raw: Double? = {
                    switch proposalMeta["confidence"] {
                    case .double(let d)?: return d
                    case .int(let i)?: return Double(i)
                    case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces))
                    default: return nil
                    }
                }()
                guard let raw else { return 1.0 }
                return min(max(raw, 0.0), 1.0)
            }()
            let mem = StoredMemory(
                id: proposal.id,
                content: proposal.content,
                personaId: proposal.personaId,
                source: proposal.source,
                confidence: stampedConfidence,
                createdAt: now,
                updatedAt: now,
                embedding: proposal.embedding,
                embeddingEpoch: proposal.embeddingEpoch,
                status: "active",
                validFrom: Self.metadataString(proposalMeta, "valid_from", fallback: "validFrom"),
                validTo: Self.metadataString(proposalMeta, "valid_to", fallback: "validTo"),
                observedAt: Self.metadataString(proposalMeta, "observed_at", fallback: "observedAt"),
                evidence: proposalMeta["evidence"],
                // Promotion preserves supplied kinds and defaults missing kinds to "general" (no decay or supersession).
                // Keep the writer's named date as supplied in the proposal.
                metadata: MemoryKindStamp.stampingDefaultKind(proposal.metadata)
            )
            try Self.validateTemporalEvidence(mem)
            try Self.executeMemoryInsert(mem, in: db)
            try db.execute(sql: """
                UPDATE proposals SET status = 'accepted', resolved_at = ? WHERE id = ?
            """, arguments: [now, id])
            // The replacement half of a memory-manager `update`: one
            // transaction, so the new memory and the demotion of the one it
            // replaces either both land or neither does. A throw here rolls the
            // acceptance back and the proposal stays pending.
            var demoted: [StoredMemory] = []
            if let superseding {
                demoted.append(try Self.demoteSuperseded(superseding, by: mem, in: db))
            }
            for predecessor in subjectPredecessors where predecessor.id != superseding?.targetId {
                demoted.append(try Self.demoteSuperseded(SupersedingAcceptance(
                    targetId: predecessor.id, expectedContentHash: Self.contentHash(predecessor.content),
                    reason: "superseded by explicit standing correction on the same subject"
                ), by: mem, in: db))
            }
            let evicted = try Self.pruneMemoriesToBound(
                in: db,
                limit: memoryLimit,
                preservingIDs: [mem.id]
            )
            try Self.pruneTerminalProposals(in: db)
            return .accepted(mem, evicted: evicted, demoted: demoted)
        }
        switch outcome {
        case .tombstoned:
            throw MemoryV2Error.forgottenContent("Proposal content matches a forgotten or rejected memory; the proposal was marked rejected. Proposal id: \(id)", effects: .occurred)
        case .accepted(let result, let evicted, let demoted):
            invalidateRecallCache()
            pokeUserMDRegen(persona: result.personaId)
            await pokeProjectionHooks(result)
            for predecessor in demoted {
                pokeUserMDRegen(persona: predecessor.personaId)
                await pokeProjectionHooks(predecessor)
            }
            await handleBoundEvictions(evicted)
            return result
        }
    }

    /// Demote the memory an accepted update replaces, inside the acceptance
    /// transaction. The one replacement lineage write — lifecycle
    /// 'corrected', queryable corrected_by/at plus history, DEMOTION not
    /// erasure — with one addition: the row must still hash to what it hashed
    /// to when the proposal was staged. If it has changed, or is gone, or is
    /// already terminal, this throws and the whole acceptance rolls back.
    static func demoteSuperseded(
        _ superseding: SupersedingAcceptance,
        by replacement: StoredMemory,
        in db: Database
    ) throws -> StoredMemory {
        guard superseding.targetId != replacement.id else {
            throw ToolFailureError("Update target is the accepted memory itself; nothing to supersede.", effects: .none,
                code: "memory_supersession_self", status: .refused,
                instruction: "Keep the existing record; a memory cannot supersede itself.", recovery: .terminal)
        }
        guard var row = try Row.fetchOne(db, sql: """
            SELECT * FROM memories
            WHERE id = ? AND status = 'active'
              AND lifecycle NOT IN \(MemoryLifecycle.recallExcludedSQL)
        """, arguments: [superseding.targetId]).map(Self.decodeMemory) else {
            throw MemoryV2Error.staleSupersession(
                "memory this update replaces (\(superseding.targetId)) is gone or already superseded"
            )
        }
        if Self.contentHash(row.content) != superseding.expectedContentHash {
            throw MemoryV2Error.staleSupersession(
                "memory this update replaces (\(superseding.targetId)) changed since the update was staged"
            )
        }
        let now = Self.nowISO8601()
        var meta: [String: JSONValue] = [:]
        if case .object(let existing)? = row.metadata { meta = existing }
        meta["corrected_by"] = .string(replacement.id)
        meta["corrected_at"] = .string(now)
        meta["correction_reason"] = .string(superseding.reason)
        var history: [JSONValue] = []
        if case .array(let existing)? = meta["correction_history"] { history = existing }
        history.append(.object([
            "by": .string(replacement.id),
            "at": .string(now),
            "reason": .string(superseding.reason),
        ]))
        meta["correction_history"] = .array(history)
        meta["superseded_by"] = .string(replacement.id)
        row.metadata = .object(meta)
        row.lifecycle = MemoryLifecycle.corrected
        row.updatedAt = now
        // It was true until its replacement became true; the row stays.
        row.validTo = replacement.validFrom ?? now
        try db.execute(sql: """
            UPDATE memories SET lifecycle = ?, updated_at = ?, metadata_json = ?, valid_to = ?
            WHERE id = ? AND status = 'active'
              AND lifecycle NOT IN \(MemoryLifecycle.recallExcludedSQL)
        """, arguments: [row.lifecycle, row.updatedAt, Self.encodeMetadata(row.metadata), row.validTo, row.id])
        guard db.changesCount > 0 else {
            throw ToolFailureError("Could not demote the memory this update replaces (\(superseding.targetId)).", effects: .none,
                owner: "memory store", nextCall: ToolFailureError.call("app", ["page": .string("memories")]),
                code: "memory_supersession_write_failed",
                instruction: "Inspect memory diagnostics and repair the reported write error before superseding.")
        }
        return row
    }

    public func rejectProposal(id: String, reason: String?) async throws {
        try await dbPool.write { db in
            guard let proposal = try Row.fetchOne(db, sql: "SELECT * FROM proposals WHERE id = ?", arguments: [id]).map(Self.decodeProposal) else {
                throw MemoryStorageError.notFound(id)
            }
            guard proposal.status == "pending" else {
                throw MemoryStorageError.alreadyResolved(id)
            }
            let now = Self.nowISO8601()
            // Preserve the rejected proposal's embedding so the semantic gate blocks paraphrases.
            try Self.upsertTombstone(
                db: db, content: proposal.content, reason: reason,
                embedding: proposal.embedding,
                embeddingEpoch: proposal.embeddingEpoch
            )
            try db.execute(sql: """
                UPDATE proposals SET status = 'rejected', resolved_at = ?, rejection_reason = ?
                WHERE id = ?
            """, arguments: [now, reason, id])
            try Self.pruneTerminalProposals(in: db)
        }
    }

    /// Fetch a proposal directly by id.
    public func getProposal(id: String) async throws -> StoredProposal? {
        try await dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM proposals WHERE id = ?",
                arguments: [id]
            ).map(Self.decodeProposal)
        }
    }

    /// Rewrite pending or superseded metadata; superseded rows need successor links for their audit trail.
    /// Accepted, rejected, merged and missing rows return nil without a write.
    @discardableResult
    public func updateProposalMetadata(id: String, metadata: JSONValue?) async throws -> StoredProposal? {
        try await dbPool.write { db in
            try db.execute(sql: """
                UPDATE proposals SET metadata_json = ?
                WHERE id = ? AND status IN ('pending', 'superseded')
            """, arguments: [Self.encodeMetadata(metadata), id])
            guard db.changesCount > 0 else { return nil }
            return try Row.fetchOne(db, sql: "SELECT * FROM proposals WHERE id = ?", arguments: [id])
                .map(Self.decodeProposal)
        }
    }

    public func listProposals(status: String? = "pending", limit: Int? = nil) async throws -> [StoredProposal] {
        try await dbPool.read { db in
            var sql = "SELECT * FROM proposals"
            var args: [DatabaseValueConvertible] = []
            if let status { sql += " WHERE status = ?"; args.append(status) }
            sql += " ORDER BY staged_at DESC"
            if let limit { sql += " LIMIT ?"; args.append(max(0, limit)) }
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return try rows.map(Self.decodeProposal)
        }
    }

}
