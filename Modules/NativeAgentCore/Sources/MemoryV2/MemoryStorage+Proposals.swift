import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore
// Blueprint: | `MemoryStorage+Proposals.swift` | `MemoryStorage`: `repairSupersededTombstones`, `stagePendingProposal`, `updateProposalMetadata` |

extension MemoryStorage {
    // Repair and cursor commit together; every row is visited without advancing past failed repairs.
    public func repairSupersededTombstones() async throws {
        try await dbPool.write { db in
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
                    // Preserve ordering keys during row repair.
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

    /// Bound review history without discarding quota evidence, retained references or unfinished supersession repairs; denial remains in tombstones.
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
    /// Match, merge and insert under one write lock to preserve concurrent evidence. `foldedKey` is caller normalization; disabling insertion returns nil on a
    /// miss so callers need not embed.
    public func stagePendingProposal(
        _ proposal: StoredProposal,
        insertIfAbsent: Bool,
        foldedKey: @Sendable (String) -> String,
        merge: @Sendable (StoredProposal) throws -> JSONValue?,
        context: MemoryWriteContext
    ) async throws -> StoredProposal? {
        var stamped = proposal
        stamped.metadata = try context.stamping(stamped.metadata)
        let proposal = stamped
        return try await dbPool.write { db -> StoredProposal? in
            let key = foldedKey(proposal.content)
            // Match listProposals' newest-first order for deterministic duplicate choice.
            let pending = try Row.fetchAll(
                db,
                sql: "SELECT * FROM proposals WHERE status = 'pending' ORDER BY staged_at DESC"
            ).map(Self.decodeProposal)
            if let existing = pending.first(where: { foldedKey($0.content) == key }) {
                var merged = try MemorySenseProvenance.preserving(existing: existing.metadata, incoming: merge(existing))
                // The pending proposal keeps every root it held and gains this observation's.
                let roots = try [MemoryRoot.roots(in: existing.metadata), MemoryRoot.roots(in: proposal.metadata)]
                merged = MemoryRoot.setting(MemoryRoot.union(roots), in: merged)
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
                try Self.recordProposedCorrection(proposal, on: existing.id, in: db)
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
            try Self.recordProposedCorrection(proposal, on: proposal.id, in: db)
            try Self.pruneTerminalProposals(in: db)
            return proposal
        }
    }

    public func acceptProposal(
        id: String,
        superseding: SupersedingAcceptance? = nil,
        context: MemoryWriteContext
    ) async throws -> StoredMemory {
        let turnProvenance = try MemorySenseProvenance.stamping(nil, reads: context.senseReads)
        // Return semantic refusal as an outcome so it commits; throwing inside the transaction would erase the refusal.
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
            let stampedConfidence = try MemoryProposalEvidence.confidence(in: proposal.metadata)
            let provenance = MemorySenseProvenance.merging(existing: proposal.metadata, incoming: turnProvenance)
            if !provenance.isEmpty {
                var metadata: [String: JSONValue] = [:]
                if case .object(let existing)? = proposal.metadata { metadata = existing }
                metadata.merge(provenance) { _, incoming in incoming }
                proposal.metadata = .object(metadata)
            }
            // Recheck exact tombstones inside admission: a denylist write may race the caller, and vectorless claims have no semantic gate.
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
                   content: proposal.content,
                   query: pe,
                   queryEpoch: proposal.embeddingEpoch
               ) {
                try db.execute(sql: """
                    UPDATE proposals SET status = 'rejected', resolved_at = ?, rejection_reason = ?
                    WHERE id = ?
                """, arguments: [Self.nowISO8601(), "tombstoned: semantic match to a rejected claim", id])
                try Self.pruneTerminalProposals(in: db)
                return .tombstoned
            }
            let now = Self.nowISO8601()
            // Preserve the checked proposal confidence and its recorded kind.
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
            // What lands keeps the roots staged with it (acceptance stamps no turn) and the roots of every row it replaces, as a save does.
            var replaced = subjectPredecessors
            if let superseding, !replaced.contains(where: { $0.id == superseding.targetId }),
               let target = try Row.fetchOne(db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [superseding.targetId])
                   .map(Self.decodeMemory) {
                replaced.append(target)
            }
            let roots = try [MemoryRoot.roots(in: proposal.metadata)] + replaced.map { try MemoryRoot.roots(in: $0.metadata) }
            proposal.metadata = MemoryRoot.setting(MemoryRoot.union(roots), in: proposal.metadata)
            var mem = StoredMemory(
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
                validFrom: proposalMeta["valid_from"]?.stringValue,
                validTo: proposalMeta["valid_to"]?.stringValue,
                observedAt: proposalMeta["observed_at"]?.stringValue,
                evidence: proposalMeta["evidence"],
                // Preserve supplied kinds and writer-named dates; absent kind stays general without decay or supersession.
                metadata: MemoryKindStamp.stampingDefaultKind(proposal.metadata)
            )
            try Self.validateTemporalEvidence(mem)
            try Self.recordProposedCorrection(proposal, on: proposal.id, in: db)
            try Self.executeMemoryInsert(mem, in: db, recordCorrection: false)
            // Pending merges keep every incoming origin. Acceptance transfers that full evidence, not recurrence_count or the latest metadata.
            try db.execute(sql: """
                INSERT INTO correction_occurrences (memory_id, origin_id, at, occurred_at, session_id, history)
                SELECT ?, origin_id, at, occurred_at, session_id, history
                FROM correction_proposal_occurrences WHERE proposal_id = ?
                ON CONFLICT(memory_id, origin_id) DO NOTHING
                """, arguments: [mem.id, proposal.id])
            try db.execute(sql: "DELETE FROM correction_proposal_occurrences WHERE proposal_id = ?", arguments: [proposal.id])
            try db.execute(sql: """
                UPDATE proposals SET status = 'accepted', resolved_at = ? WHERE id = ?
            """, arguments: [now, id])
            // Insert the replacement and demote its exact target in one transaction; refusal leaves the proposal pending.
            var demoted: [StoredMemory] = []
            if let superseding {
                demoted.append(try Self.demoteSuperseded(superseding, by: &mem, in: db))
            }
            for predecessor in subjectPredecessors where predecessor.id != superseding?.targetId {
                demoted.append(try Self.demoteSuperseded(SupersedingAcceptance(
                    targetId: predecessor.id, expectedContentHash: Self.contentHash(predecessor.content),
                    reason: "superseded by explicit standing correction on the same subject"
                ), by: &mem, in: db))
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
            throw MemoryV2Error.forgottenContent("""
                Proposal content matches a forgotten or rejected memory; the proposal was marked rejected. Proposal id: \(id)
                """, effects: .occurred)
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

    /// Demote only the fingerprint reviewed at staging, retaining corrected lineage and history. Changed, missing or terminal targets refuse the whole
    /// acceptance.
    static func demoteSuperseded(
        _ superseding: SupersedingAcceptance,
        by replacement: inout StoredMemory,
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
        if row.metadata?.objectValue?["pinned"] == .bool(true) {
            func rulingDate(_ memory: StoredMemory) throws -> Date {
                let raw: String
                if let supplied = memory.metadata?.objectValue?["turn_at"] {
                    guard case .string(let value) = supplied else {
                        throw MemoryStorageError.invalidTemporalEvidence("Pinned belief turn_at is not a timestamp string")
                    }
                    raw = value
                } else {
                    // A direct save without a turn has its own admission event.
                    raw = memory.createdAt
                }
                guard var date = MemoryDataProvenance.parseTimestamp(raw) else {
                    throw MemoryStorageError.invalidTemporalEvidence("Pinned belief ruling time is not ISO-8601")
                }
                if let supplied = memory.metadata?.objectValue?["duplicate_occurrences"] {
                    guard case .array(let occurrences) = supplied else {
                        throw MemoryStorageError.invalidTemporalEvidence("Pinned belief occurrences are not an array")
                    }
                    for occurrence in occurrences {
                        guard case .object(let fields) = occurrence else {
                            throw MemoryStorageError.invalidTemporalEvidence("Pinned belief occurrence is not an object")
                        }
                        if let supplied = fields["turn_at"] {
                            guard case .string(let raw) = supplied, let at = MemoryDataProvenance.parseTimestamp(raw) else {
                                throw MemoryStorageError.invalidTemporalEvidence("Pinned belief occurrence time is not ISO-8601")
                            }
                            date = max(date, at)
                        }
                    }
                }
                if let latest = try Double.fetchOne(db, sql: "SELECT MAX(occurred_at) FROM correction_occurrences WHERE memory_id = ?",
                                                    arguments: [memory.id]) {
                    guard latest.isFinite else {
                        throw MemoryStorageError.invalidTemporalEvidence("Pinned belief correction time is not finite")
                    }
                    date = max(date, Date(timeIntervalSince1970: latest))
                }
                return date
            }
            guard try rulingDate(replacement) >= rulingDate(row) else {
                throw MemoryV2Error.staleSupersession("A newer ruling owns this pin; the older replacement was not admitted.")
            }
        }
        let now = Self.nowISO8601()
        // The target's roots are read under the same transaction that retires it. A metadata-only change while the writer embedded must reach
        // the surviving memory too; a pre-insertion read cannot attest the roots present at this landing.
        let heldRoots = try MemoryRoot.roots(in: replacement.metadata)
        let roots = MemoryRoot.union([heldRoots, try MemoryRoot.roots(in: row.metadata)])
        var metadata = MemoryRoot.setting(roots, in: replacement.metadata)
        let steer = MemoryDataProvenance.sources(in: metadata)
        if superseding.restatesOwnPast, let teller = steer.first {
            throw ToolFailureError("These words came through \(steer.joined(separator: ", ")); they cannot become your own past through supersession.",
                argumentPath: "since / provenance", accepted: "provenance told by \(teller), without since", effects: .none,
                code: "memory_restatement_steered", status: .refused,
                instruction: "Save it as told by \(teller) without since, or leave the memory as it is.", recovery: .correctArguments)
        }
        if row.metadata?.objectValue?["pinned"] == .bool(true), metadata.objectValue?["pinned"] != .bool(true) {
            guard case .object(var fields) = metadata else {
                throw MemoryStorageError.databaseUnavailable("Replacement roots have no metadata object")
            }
            if let refusal = UserMDGenerator.pinFailure(kind: fields["kind"]?.stringValue) { throw refusal }
            fields["pinned"] = .bool(true)
            fields["pinned_order"] = row.metadata?.objectValue?["pinned_order"]
            metadata = .object(fields)
        }
        if metadata != replacement.metadata {
            replacement.metadata = metadata
            replacement.updatedAt = now
            try db.execute(sql: "UPDATE memories SET metadata_json = ?, updated_at = ? WHERE id = ?",
                           arguments: [Self.encodeMetadata(replacement.metadata), now, replacement.id])
        }
        var meta: [String: JSONValue] = [:]
        if case .object(let existing)? = row.metadata { meta = existing }
        meta.removeValue(forKey: "pinned")
        meta.removeValue(forKey: "pinned_order")
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
        // It was true until its replacement became true; the row stays. A replacement known since before this row began ends it where it began.
        let ends = replacement.validFrom ?? now
        if let end = MemoryRecallScoring.parseTimestamp(ends), let begun = row.validFrom.flatMap(MemoryRecallScoring.parseTimestamp), end < begun {
            row.validTo = row.validFrom
        } else {
            row.validTo = ends
        }
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

    public func getProposal(id: String) async throws -> StoredProposal? {
        try await dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM proposals WHERE id = ?",
                arguments: [id]
            ).map(Self.decodeProposal)
        }
    }

    /// Only pending or superseded rows permit metadata repair; preserve successor audit links without mutating terminal rows. The proposal keeps the
    /// roots it holds: a repair never writes them.
    @discardableResult
    public func updateProposalMetadata(id: String, metadata: JSONValue?) async throws -> StoredProposal? {
        try await dbPool.write { db in
            guard let current = try Row.fetchOne(db, sql: "SELECT * FROM proposals WHERE id = ?", arguments: [id]).map(Self.decodeProposal) else {
                return nil
            }
            let repaired = MemoryRoot.setting(try MemoryRoot.roots(in: current.metadata), in: metadata)
            try db.execute(sql: """
                UPDATE proposals SET metadata_json = ?
                WHERE id = ? AND status IN ('pending', 'superseded')
            """, arguments: [Self.encodeMetadata(repaired), id])
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
