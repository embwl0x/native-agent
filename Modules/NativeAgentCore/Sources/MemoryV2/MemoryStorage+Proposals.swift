import Foundation
import GRDB
import NativeAgentCore
import PersistenceCore

extension MemoryStorage {
    // MARK: - Proposals

    @discardableResult
    public func insertProposal(_ proposal: StoredProposal) async throws -> StoredProposal {
        try await dbPool.write { db in
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
        }
        return proposal
    }

    /// User, 2026-09-06: the pending-proposal dedup as ONE transaction.
    /// `SwiftNativeMemoryV2.propose` used to list pending proposals, merge the
    /// new evidence in Swift, then call `updateProposalMetadata`, which
    /// overwrites `metadata_json` unconditionally. Two observations of the same
    /// fact landing together both read the pre-merge row and the second write
    /// erased the first one's supporting sessions and recurrence — or, when
    /// neither saw a pending row yet, both inserted and the review queue got
    /// the duplicates the dedup exists to prevent. Doing the match, the merge
    /// and the insert under one write lock closes both.
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
        try await dbPool.write { db -> StoredProposal? in
            let key = foldedKey(proposal.content)
            // staged_at DESC matches `listProposals(status:)`, whose order this
            // path's `.first(where:)` used to depend on.
            let pending = try Row.fetchAll(
                db,
                sql: "SELECT * FROM proposals WHERE status = 'pending' ORDER BY staged_at DESC"
            ).map(Self.decodeProposal)
            if let existing = pending.first(where: { foldedKey($0.content) == key }) {
                let merged = try merge(existing)
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
            return proposal
        }
    }

    public func acceptProposal(
        id: String,
        review: ReviewedMomentAcceptance? = nil,
        superseding: SupersedingAcceptance? = nil
    ) async throws -> StoredMemory {
        // The semantic-gate rejection must COMMIT, so the write closure returns
        // an outcome instead of throwing mid-transaction (a throw inside
        // dbPool.write rolls back everything — including the rejection row).
        enum AcceptOutcome {
            case accepted(StoredMemory, evicted: [StoredMemory], demoted: StoredMemory?)
            case tombstoned
        }
        let outcome = try await dbPool.write { db -> AcceptOutcome in
            guard var proposal = try Row.fetchOne(db, sql: "SELECT * FROM proposals WHERE id = ?", arguments: [id]).map(Self.decodeProposal) else {
                throw MemoryStorageError.notFound(id)
            }
            guard proposal.status == "pending" else {
                throw MemoryStorageError.alreadyResolved(id)
            }
            if let review {
                guard proposal.content == review.expectedContent, MemoryMoments.isMoment(proposal.metadata) else {
                    throw MemoryV2Error.underlying("moment changed since review; review it again")
                }
                if let reason = MemoryCandidateQuality.rejectionReason(
                    text: review.content, source: proposal.source, kind: MemoryMoments.kind
                ) { throw MemoryV2Error.underlying("not durable memory: \(reason)") }
                proposal.content = review.content
                proposal.embedding = review.embedding
                proposal.embeddingEpoch = review.embeddingEpoch
            }
            // Recheck the exact denylist inside the admission transaction.
            // A tombstone can arrive after the caller's earlier check, and
            // embeddingless legacy claims cannot rely on the semantic gate.
            let exactTombstone = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM tombstones WHERE content_hash = ?",
                arguments: [Self.contentHash(proposal.content)]
            ) ?? 0 > 0
            if exactTombstone {
                if review != nil { throw MemoryStorageError.tombstoned(id) }
                try db.execute(sql: """
                    UPDATE proposals SET status = 'rejected', resolved_at = ?, rejection_reason = ?
                    WHERE id = ?
                """, arguments: [Self.nowISO8601(), "tombstoned: exact match to a rejected claim", id])
                return .tombstoned
            }
            // Semantic tombstone gate at acceptance, in the SAME transaction
            // (wave1 T3): a proposal that paraphrases a tombstoned claim must
            // not promote even if its exact hash differs. Legacy/no-embedding
            // proposals skip (the transaction's exact-hash gate covers them).
            if let pe = proposal.embedding,
               try Self.tombstoneMatch(
                   db: db,
                   query: pe,
                   queryEpoch: proposal.embeddingEpoch,
                   threshold: memoryTombstoneMatchThreshold
               ) {
                if review != nil { throw MemoryStorageError.tombstoned(id) }
                try db.execute(sql: """
                    UPDATE proposals SET status = 'rejected', resolved_at = ?, rejection_reason = ?
                    WHERE id = ?
                """, arguments: [Self.nowISO8601(), "tombstoned: semantic match to a rejected claim", id])
                return .tombstoned
            }
            let now = Self.nowISO8601()
            // #1: stamp the extractor's real confidence on the memory instead of
            // hardcoding 1.0, and keep `kind` in the memory metadata. The signal
            // rides in proposal.metadata.{confidence,kind}; default to 1.0 when
            // absent (legacy proposals / consolidator durability path).
            let proposalMeta: [String: JSONValue] = {
                if case .object(let o)? = proposal.metadata { return o }
                return [:]
            }()
            let stampedConfidence: Double = {
                // Accept double / int / numeric-string forms and clamp to 0...1
                // (gpt-5.5 review finding 2: a string "0.85" must not silently
                // overtrust to 1.0). Absent or unparseable → 1.0 (legacy default).
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
                // U3 wave-2 item 5a: promotion is a NEW write — proposals
                // whose extractor carried no kind get the semantics-neutral
                // default ("general" → decayFactor 1.0, no supersession).
                // Extractor-provided kinds pass through untouched.
                // Item 5 follow-up (2026-09-02): promotion is a NEW write, so
                // the due-date extractor runs here too. Both write paths — the
                // explicit `commit_memory` store above and this promoter
                // acceptance — stamp through the same extractor, so a plan is
                // dated the same way however it got remembered.
                metadata: MemoryDueDateStamp.stamping(
                    MemoryKindStamp.stampingDefaultKind(proposal.metadata),
                    text: proposal.content
                )
            )
            try Self.validateTemporalEvidence(mem)
            try db.execute(sql: """
                INSERT INTO memories
                  (id, content, persona_id, source, confidence,
                   created_at, updated_at, embedding, status, metadata_json, lifecycle, embedding_epoch,
                   valid_from, valid_to, observed_at, evidence_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                mem.id, mem.content, mem.personaId, mem.source, mem.confidence,
                mem.createdAt, mem.updatedAt,
                Self.encodeEmbedding(mem.embedding),
                mem.status,
                Self.encodeMetadata(mem.metadata),
                mem.lifecycle,
                mem.embeddingEpoch,
                mem.validFrom, mem.validTo, mem.observedAt,
                Self.encodeMetadata(mem.evidence)
            ])
            try db.execute(sql: """
                UPDATE proposals SET status = 'accepted', resolved_at = ? WHERE id = ?
            """, arguments: [now, id])
            // The replacement half of a memory-manager `update`: one
            // transaction, so the new memory and the demotion of the one it
            // replaces either both land or neither does. A throw here rolls the
            // acceptance back and the proposal stays pending.
            let demoted: StoredMemory? = try superseding.map {
                try Self.demoteSuperseded($0, by: mem, in: db)
            }
            let evicted = try Self.pruneMemoriesToBound(
                in: db,
                limit: memoryLimit,
                preservingIDs: [mem.id]
            )
            return .accepted(mem, evicted: evicted, demoted: demoted)
        }
        switch outcome {
        case .tombstoned:
            throw MemoryStorageError.tombstoned(id)
        case .accepted(let result, let evicted, let demoted):
            invalidateRecallCache()
            pokeUserMDRegen(persona: result.personaId)
            await pokeProjectionHooks(result)
            if let demoted {
                pokeUserMDRegen(persona: demoted.personaId)
                await pokeProjectionHooks(demoted)
            }
            await handleBoundEvictions(evicted, reason: "proposal_acceptance")
            return result
        }
    }

    /// Demote the memory an accepted update replaces, inside the acceptance
    /// transaction. Same lineage write as `markCorrected` — lifecycle
    /// 'corrected', queryable corrected_by/at plus history, DEMOTION not
    /// erasure — with one addition: the row must still hash to what it hashed
    /// to when the proposal was staged. If it has changed, or is gone, or is
    /// already terminal, this throws and the whole acceptance rolls back.
    private static func demoteSuperseded(
        _ superseding: SupersedingAcceptance,
        by replacement: StoredMemory,
        in db: Database
    ) throws -> StoredMemory {
        guard superseding.targetId != replacement.id else {
            throw MemoryV2Error.underlying(
                "update target is the accepted memory itself; nothing to supersede"
            )
        }
        guard var row = try Row.fetchOne(db, sql: """
            SELECT * FROM memories
            WHERE id = ? AND status = 'active'
              AND lifecycle NOT IN ('corrected', 'contradicted', 'deleted')
        """, arguments: [superseding.targetId]).map(Self.decodeMemory) else {
            throw MemoryV2Error.underlying(
                "memory this update replaces (\(superseding.targetId)) is gone or already superseded"
            )
        }
        if Self.contentHash(row.content) != superseding.expectedContentHash {
            throw MemoryV2Error.underlying(
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
        try db.execute(sql: """
            UPDATE memories SET lifecycle = ?, updated_at = ?, metadata_json = ?
            WHERE id = ? AND status = 'active'
              AND lifecycle NOT IN ('corrected', 'contradicted', 'deleted')
        """, arguments: [row.lifecycle, row.updatedAt, Self.encodeMetadata(row.metadata), row.id])
        guard db.changesCount > 0 else {
            throw MemoryV2Error.underlying(
                "could not demote the memory this update replaces (\(superseding.targetId))"
            )
        }
        return row
    }

    @discardableResult
    public func rejectProposal(id: String, reason: String?) async throws -> StoredTombstone {
        try await dbPool.write { db in
            guard let proposal = try Row.fetchOne(db, sql: "SELECT * FROM proposals WHERE id = ?", arguments: [id]).map(Self.decodeProposal) else {
                throw MemoryStorageError.notFound(id)
            }
            guard proposal.status == "pending" else {
                throw MemoryStorageError.alreadyResolved(id)
            }
            let now = Self.nowISO8601()
            let hash = Self.contentHash(proposal.content)
            // Carry the rejected proposal's embedding so paraphrases of the
            // rejected claim block at the semantic gate (wave1 T2).
            let tomb = StoredTombstone(
                contentHash: hash, content: proposal.content,
                rejectedAt: now, reason: reason, embedding: proposal.embedding,
                embeddingEpoch: proposal.embeddingEpoch
            )
            try Self.upsertTombstone(
                db: db, content: tomb.content, reason: tomb.reason,
                embedding: tomb.embedding,
                embeddingEpoch: tomb.embeddingEpoch
            )
            try db.execute(sql: """
                UPDATE proposals SET status = 'rejected', resolved_at = ?, rejection_reason = ?
                WHERE id = ?
            """, arguments: [now, reason, id])
            return tomb
        }
    }

    /// Commit duplicate corroboration and proposal resolution together, using
    /// the memory metadata read under the same SQLite write transaction.
    func mergeProposal(id: String, intoMemoryID: String, resolvedAt: String) async throws {
        let updated = try await dbPool.write { db -> StoredMemory in
            guard let proposal = try Row.fetchOne(
                db, sql: "SELECT * FROM proposals WHERE id = ?", arguments: [id]
            ).map(Self.decodeProposal) else {
                throw MemoryStorageError.notFound(id)
            }
            guard proposal.status == "pending" else {
                throw MemoryStorageError.alreadyResolved(id)
            }
            guard var memory = try Row.fetchOne(
                db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [intoMemoryID]
            ).map(Self.decodeMemory) else {
                throw MemoryStorageError.notFound(intoMemoryID)
            }
            var metadata: [String: JSONValue] = [:]
            if case .object(let existing)? = memory.metadata { metadata = existing }
            let currentCount: Int64 = try {
                if case .int(let n)? = metadata["recall_count"] { return n }
                if case .double(let d)? = metadata["recall_count"] {
                    guard let count = Int64(exactly: d.rounded(.towardZero)) else {
                        throw MemoryStorageError.databaseUnavailable("merge proposal: recall_count is outside Int64 range")
                    }
                    return count
                }
                return 0
            }()
            let (nextCount, overflow) = currentCount.addingReportingOverflow(1)
            guard !overflow else {
                throw MemoryStorageError.databaseUnavailable("merge proposal: recall_count overflow")
            }
            metadata["recall_count"] = .int(nextCount)
            memory.metadata = .object(metadata)
            memory.updatedAt = Self.nowISO8601()
            try Self.validateTemporalEvidence(memory)
            try Self.requireWritableEpoch(in: db, vector: nil, epoch: nil)
            try db.execute(sql: """
                UPDATE memories SET metadata_json = ?, updated_at = ? WHERE id = ?
                """, arguments: [Self.encodeMetadata(memory.metadata), memory.updatedAt, memory.id])
            try db.execute(sql: """
                UPDATE proposals SET status = 'merged', resolved_at = ? WHERE id = ?
                """, arguments: [resolvedAt, id])
            return memory
        }
        invalidateRecallCache()
        pokeUserMDRegen(persona: updated.personaId)
        await pokeProjectionHooks(updated)
    }

    /// Set a proposal's `status` (and optional `resolved_at`) without going
    /// through accept/reject. Used by MemoryConsolidator to record 'merged'
    /// outcomes for proposals deduped against existing active memories.
    /// No-op when the proposal id isn't found; doesn't enforce a pending
    /// precondition (consolidator is idempotent and tolerates re-runs).
    public func markProposalStatus(
        id: String,
        status: String,
        resolvedAt: String?
    ) async throws {
        try await dbPool.write { db in
            try db.execute(sql: """
                UPDATE proposals SET status = ?, resolved_at = COALESCE(?, resolved_at)
                WHERE id = ?
            """, arguments: [status, resolvedAt, id])
        }
    }

    /// U5 W-G fix (2026-06-11): direct by-id lookup. `SwiftNativeMemoryV2.
    /// getProposal` used to call `listProposals(status: nil)` (full-table
    /// scan + decode) per lookup, which made the auto-accept sweep O(N²)
    /// over a multi-hundred-proposal backlog.
    public func getProposal(id: String) async throws -> StoredProposal? {
        try await dbPool.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM proposals WHERE id = ?",
                arguments: [id]
            ).map(Self.decodeProposal)
        }
    }

    /// 2026-07-21 audit fix: metadata rewrite for the pending-proposal
    /// content-hash dedup (SwiftNativeMemoryV2.propose merges session
    /// evidence / recurrence onto the surviving row instead of inserting a
    /// duplicate). PENDING-ONLY: a resolved proposal's metadata is part of
    /// its audit trail and must not be rewritten — a non-pending or missing
    /// id returns nil so the caller falls back to a fresh insert.
    ///
    /// `superseded` is the one resolved status this also accepts (Astra comb 4,
    /// lane5 finding 2). Supersession is bookkeeping, not a person's decision,
    /// and the successor link IS that row's audit trail: the 2026-09-11 build
    /// retired `CE41D07E-806A-4794-9F98-AFD44E4AAB7E` with no reason and no
    /// relationship, and the launch recovery cannot write the link it
    /// reconstructs without this. `accepted`, `rejected` and `merged` stay
    /// closed.
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

    /// The moments-lane COUNT. A scalar SQL aggregate — no `SELECT *`, no row
    /// decode, no Swift-side JSON walk — because the nudge line asks this on
    /// the turn path and only ever needs the number.
    ///
    /// The `kind` disjunct mirrors `MemoryMoments.isMoment`: a row staged
    /// before `lane` existed is identified by its kind, and the SQL must agree
    /// with the Swift predicate or the nudge would count a different set than
    /// the tool lists.
    public func countMomentProposals(status: String?) async throws -> Int {
        try await dbPool.read { db in
            var sql = """
                SELECT COUNT(*) FROM proposals
                WHERE (json_extract(metadata_json, '$.lane') = 'moment'
                       OR json_extract(metadata_json, '$.kind') = 'moment')
            """
            var args: [DatabaseValueConvertible] = []
            if let status { sql += " AND status = ?"; args.append(status) }
            return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? 0
        }
    }

    public func listProposals(status: String? = "pending") async throws -> [StoredProposal] {
        try await dbPool.read { db in
            var sql = "SELECT * FROM proposals"
            var args: [DatabaseValueConvertible] = []
            if let status { sql += " WHERE status = ?"; args.append(status) }
            sql += " ORDER BY staged_at DESC"
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return try rows.map(Self.decodeProposal)
        }
    }

    @discardableResult
    public func deleteProposal(id: String) async throws -> Bool {
        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM proposals WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

}
