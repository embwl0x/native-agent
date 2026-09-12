import Foundation
import NativeAgentCore
import PersistenceCore

extension SwiftNativeMemoryV2 {

    // MARK: Proposal lifecycle

    public func propose(
        content: String,
        source: String? = nil,
        confidence: Double? = nil,
        kind: String? = nil,
        supportingSessionIDs: [String] = [],
        recurrenceCount: Int? = nil,
        // Lane-specific metadata the caller owns (the moments lane's
        // lane/valence/salience/quote/session/surface/author). Merged UNDER the
        // typed fields above so no caller can overwrite confidence/kind through
        // the side door. Empty (the default) is byte-identical to the previous
        // behavior on both the fresh-insert and the dedup-merge path.
        extraMetadata: [String: JSONValue] = [:]
    ) async throws -> ProposalRecord {
        let content = MemoryTextClip.memoryDisplayText(content, kind: kind)
        guard !content.isEmpty else { throw MemoryV2Error.invalidQuery }
        if let reason = MemoryCandidateQuality.rejectionReason(text: content, source: source, kind: kind) {
            throw MemoryV2Error.underlying("not durable memory: \(reason)")
        }
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        // Carry the extractor's confidence + kind so acceptProposal stamps them
        // on the memory instead of discarding them (#1). nil → empty metadata.
        let sessions = Array(Set(supportingSessionIDs.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        })).sorted().prefix(32)
        // 2026-07-21 audit fix: content-hash dedup on PENDING proposals.
        // observeTurn re-stages the same extracted fact every turn with a
        // fresh UUID, flooding the review queue with duplicates of one fact.
        // A pending proposal with the same normalized content hash (persona
        // is the store constant — the bridge stamps
        // MemoryV2Defaults.personaID on every proposal insert) is updated in
        // place instead: session evidence unions, recurrence accrues,
        // confidence keeps the max, and the canonical row's id is returned
        // so the auto-accept lane still fires on it. Resolved proposals are
        // untouched — their rows are audit trail.
        // 2026-08-14 proposal-hygiene fix: fold articles before hashing so
        // extractor variants of one fact ("user is a AI assistant" vs "user
        // is AI assistant") dedupe instead of double-staging. Folding is
        // LOCAL to this comparison — both sides are folded at compare time
        // and no folded hash is ever stored, so stored contentHash uses
        // (KG memory index, kind backfill) are untouched.
        let dedupKey: @Sendable (String) -> String = { s in
            let folded = s.replacingOccurrences(
                of: #"(?i)\b(?:a|an|the)\s+"#,
                with: "",
                options: .regularExpression
            )
            return MemoryStorage.contentHash(folded)
        }
        // The evidence merge, lifted out of the old inline branch so BOTH the
        // atomic staging path and the legacy fallback below apply exactly the
        // same rules to the row they found.
        let mergedMetadata: @Sendable (ProposalRecord) throws -> JSONValue? = { existing in
            var merged: [String: JSONValue]
            if case .object(let m)? = existing.metadata { merged = m } else { merged = [:] }
            var sessionSet = Set<String>()
            if case .array(let arr)? = merged["supporting_session_ids"] {
                for case .string(let s) in arr { sessionSet.insert(s) }
            }
            sessionSet.formUnion(sessions)
            if !sessionSet.isEmpty {
                merged["supporting_session_ids"] = .array(sessionSet.sorted().prefix(32).map(JSONValue.string))
            }
            func intMeta(_ object: [String: JSONValue], _ key: String) throws -> Int64? {
                switch object[key] {
                case .int(let i)?: return i
                case .double(let d)?:
                    guard let count = Int64(exactly: d.rounded(.towardZero)) else {
                        throw MemoryStorageError.databaseUnavailable("stage proposal: recurrence_count is outside Int64 range")
                    }
                    return count
                case .string(let s)?:
                    // 2026-09-06: malformed saved evidence is not absence.
                    guard let count = Int64(s.trimmingCharacters(in: .whitespaces)) else {
                        NSLog("MemoryV2: refusing proposal merge with invalid recurrence_count; saved evidence retained")
                        throw MemoryStorageError.databaseUnavailable("stage proposal: recurrence_count is not a valid Int64")
                    }
                    return count
                case nil: return nil
                default:
                    NSLog("MemoryV2: refusing proposal merge with invalid recurrence_count type; saved evidence retained")
                    throw MemoryStorageError.databaseUnavailable("stage proposal: recurrence_count has an invalid type")
                }
            }
            // 2026-09-06: reject unrepresentable counters before staging writes;
            // propagate through the existing transaction instead of trapping.
            let priorRecurrence = try intMeta(merged, "recurrence_count") ?? 1
            let incomingRecurrence = Int64(max(1, recurrenceCount ?? 1))
            let (nextRecurrence, overflow) = priorRecurrence.addingReportingOverflow(incomingRecurrence)
            guard !overflow else {
                throw MemoryStorageError.databaseUnavailable("stage proposal: recurrence_count overflow")
            }
            merged["recurrence_count"] = .int(nextRecurrence)
            if let confidence {
                let prior: Double? = {
                    switch merged["confidence"] {
                    case .double(let d)?: return d
                    case .int(let i)?: return Double(i)
                    default: return nil
                    }
                }()
                merged["confidence"] = .double(max(confidence, prior ?? 0))
            }
            if merged["kind"] == nil, let kind, !kind.isEmpty {
                merged["kind"] = .string(kind)
            }
            // A re-staged moment refreshes its lane fields on the surviving
            // row: the newest telling is the one she will read.
            for (key, value) in extraMetadata where key != "kind" {
                merged[key] = value
            }
            return merged.isEmpty ? nil : .object(merged)
        }
        var meta: [String: JSONValue] = extraMetadata
        if let confidence { meta["confidence"] = .double(confidence) }
        if let kind, !kind.isEmpty { meta["kind"] = .string(kind) }
        if !sessions.isEmpty {
            meta["supporting_session_ids"] = .array(sessions.map(JSONValue.string))
        }
        if let recurrenceCount {
            meta["recurrence_count"] = .int(Int64(max(1, recurrenceCount)))
        }
        let proposal = ProposalRecord(
            id: UUID().uuidString,
            content: content,
            source: source,
            status: "pending",
            createdAt: Self.iso8601Now(),
            metadata: meta.isEmpty ? nil : .object(meta)
        )

        // User, 2026-09-06: match + merge (or insert) under ONE storage write
        // lock where the store supports it. The list → merge-in-Swift →
        // unconditional-overwrite shape below loses a concurrent observation's
        // evidence, and two observers who both miss the pending row both
        // insert. Pass one asks for a merge WITHOUT insert so no embedding work
        // happens on the repeat-observation path; pass two embeds and inserts,
        // re-checking for a row that appeared in between and merging into it.
        if let atomic = storage as? AtomicProposalStagingStorage {
            if let merged = try await atomic.stagePendingProposal(
                proposal,
                embedding: nil,
                embeddingEpoch: nil,
                insertIfAbsent: false,
                foldedKey: dedupKey,
                merge: mergedMetadata
            ) {
                return merged
            }
            let embedded = try await embedOneWithEpoch(content)
            if let staged = try await atomic.stagePendingProposal(
                proposal,
                embedding: embedded.vector,
                embeddingEpoch: embedded.epoch,
                insertIfAbsent: true,
                foldedKey: dedupKey,
                merge: mergedMetadata
            ) {
                return staged
            }
            return proposal
        }

        let newContentHash = dedupKey(content)
        if let existing = try await storage.listProposals(status: "pending")
            .first(where: { dedupKey($0.content) == newContentHash }) {
            return try await storage.updateProposalMetadata(
                id: existing.id,
                metadata: try mergedMetadata(existing)
            )
        }
        let embedded = try await embedOneWithEpoch(content)
        try await storage.insertProposal(
            proposal,
            embedding: embedded.vector,
            embeddingEpoch: embedded.epoch
        )
        return proposal
    }

    public func acceptProposal(id: String) async throws -> MemoryRecord {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        guard let proposal = try await storage.getProposal(id: id) else {
            throw MemoryV2Error.recordNotFound
        }
        if let reason = MemoryCandidateQuality.rejectionReason(
            text: proposal.content,
            source: proposal.source,
            kind: Self.metadataKind(proposal.metadata)
        ) {
            let rejection = "quality gate at acceptance: \(reason)"
            try await storage.updateProposalStatus(
                id: id,
                status: "rejected",
                rejectionReason: rejection
            )
            throw MemoryV2Error.underlying("not durable memory: \(reason)")
        }
        // The tombstone gate runs at acceptance too, not just at proposal time —
        // a proposal that was queued before the denylist entry landed must still
        // be rejected when it tries to promote.
        if try await storage.isTombstoned(content: proposal.content) {
            try await storage.updateProposalStatus(id: id, status: "rejected", rejectionReason: "tombstoned at acceptance")
            throw MemoryV2Error.underlying("tombstoned: proposal content matches a rejection denylist entry")
        }
        // An `update` from the memory manager carries the id of the memory it
        // replaces, plus that row's fingerprint at staging time. Keep is then ONE
        // transaction: the new memory lands and the old one is demoted (lifecycle
        // 'corrected' with superseded_by provenance — DEMOTION, never erasure),
        // or neither happens and this proposal stays pending with a reason.
        // Before 2026-09-11 this was accept-then-`try?`-demote, which could leave
        // both rows current and still report success (audit finding 1).
        if let targetId = Self.supersedesTargetId(from: proposal.metadata) {
            guard let superseding = Self.supersedingAcceptance(from: proposal.metadata) else {
                // A legacy proposal staged before the fingerprint existed. There
                // is nothing to check the target against, so applying it would be
                // an unverified demotion of whatever now holds that id. Left
                // pending for re-review rather than silently demoting.
                throw MemoryV2Error.underlying(
                    "needs re-review: target fingerprint missing for the memory this update replaces (\(targetId)); left pending"
                )
            }
            let accepted = try await acceptSuperseding(id: id, superseding: superseding)
            await flushDerivedMemoryChanges()
            return accepted
        }
        let accepted = try await storage.acceptProposal(id: id)
        await flushDerivedMemoryChanges()
        return accepted
    }

    /// The replacement an accepted update must perform, read off the proposal
    /// the person reviewed. nil when this proposal claims no supersession.
    static func supersedingAcceptance(from metadata: JSONValue?) -> SupersedingAcceptance? {
        guard case .object(let meta)? = metadata,
              let targetId = Self.supersedesTargetId(from: metadata),
              case .string(let hash)? = meta[MemoryManagerLane.supersedesHashKey],
              !hash.isEmpty else { return nil }
        return SupersedingAcceptance(
            targetId: targetId,
            expectedContentHash: hash,
            reason: "superseded by memory-manager update"
        )
    }

    /// The memory id this proposal claims to replace, fingerprint or not.
    /// Used to tell "no supersession" apart from "supersession we cannot
    /// verify" — the second must never be applied.
    static func supersedesTargetId(from metadata: JSONValue?) -> String? {
        guard case .object(let meta)? = metadata,
              case .string(let targetId)? = meta[MemoryManagerLane.supersedesKey],
              !targetId.isEmpty else { return nil }
        return targetId
    }

    /// Accept a validated update. ONE transaction or nothing: a storage that
    /// cannot accept and demote together refuses here, before any mutation, so
    /// the proposal stays pending instead of half-applying (the accept-then-
    /// demote fallback that lived here until 2026-09-11 could insert the new
    /// memory and then throw on the demotion).
    private func acceptSuperseding(
        id: String,
        superseding: SupersedingAcceptance
    ) async throws -> MemoryRecord {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        guard let atomic = storage as? AtomicSupersedingAcceptanceStorage else {
            throw MemoryV2Error.underlying(
                "this memory store cannot replace a memory in one transaction; "
                + "the update that replaces \(superseding.targetId) is left pending"
            )
        }
        return try await atomic.acceptProposal(id: id, superseding: superseding)
    }

    /// Prepare the final words before promotion. No active row or projection
    /// exists until the storage transaction accepts this exact reviewed version.
    public func acceptReviewedMoment(id: String, content: String) async throws -> MemoryRecord {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        guard let proposal = try await storage.getProposal(id: id),
              proposal.status == "pending", MemoryMoments.isMoment(proposal.metadata) else {
            throw MemoryV2Error.recordNotFound
        }
        if let reason = MemoryCandidateQuality.rejectionReason(
            text: content, source: proposal.source, kind: Self.metadataKind(proposal.metadata)
        ) { throw MemoryV2Error.underlying("not durable memory: \(reason)") }
        let embedded = try await embedOneWithEpoch(content)
        let accepted = try await storage.acceptReviewedMoment(id: id, review: ReviewedMomentAcceptance(
            expectedContent: proposal.content, content: content,
            embedding: embedded.vector, embeddingEpoch: embedded.epoch.rawValue
        ))
        await flushDerivedMemoryChanges()
        return accepted
    }

    /// A pending statement replaced by its own correction (2026-09-11, Astra
    /// comb finding 1). NOT a rejection: a rejection writes a tombstone, and the
    /// tombstone of "Claude uses GPT-5.6 for build reviews" then blocked its
    /// refined successor at the semantic gate (cosine 0.927 against a 0.92
    /// threshold, live). Refined is not denied. Status only, no tombstone, and
    /// any tombstone an earlier build wrote for this exact text is removed.
    ///
    /// THE SUCCESSOR IS WRITTEN DOWN (Astra comb 3, lane1 finding 2,
    /// 2026-09-12). The reason string handed to `updateProposalStatus` reaches
    /// `markProposalStatus` for every status except "rejected", and that writes
    /// status + resolved_at only: live row `CE41D07E-806A-4794-9F98-AFD44E4AAB7E`
    /// is `superseded` at 20:52:44.849Z with `rejection_reason=NULL` and no
    /// relationship in its metadata, leaving its link to successor
    /// `ED6A1402-9C3A-4886-A7B0-B40D51075BFB` recoverable only by guessing from
    /// wording and timing. The metadata write below is the durable record.
    ///
    /// ORDER IS THE RECOVERY STORY. Metadata first (the SQL behind it is
    /// pending-gated, so it must precede the status flip), then the tombstone,
    /// and the status LAST: every failure before the flip leaves the row
    /// pending, which the next attempt retries. The old order flipped first, so
    /// a failed delete left a retired row with a live tombstone that no later
    /// pass selected.
    @discardableResult
    public func supersedeProposal(id: String, by successorId: String) async throws -> Bool {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        guard let proposal = try await storage.getProposal(id: id) else {
            throw MemoryV2Error.recordNotFound
        }
        guard proposal.status == "pending" else {
            // Idempotent for a row already retired this way; a refusal for any
            // other resolved state, because re-retiring an accepted or rejected
            // row silently is how a review decision disappears.
            if proposal.status == "superseded" { return true }
            throw MemoryV2Error.underlying(
                "proposal \(id) is \(proposal.status), not pending: not superseded by \(successorId)"
            )
        }
        var metadata: [String: JSONValue]
        if case .object(let existing)? = proposal.metadata { metadata = existing } else { metadata = [:] }
        metadata["supersededBy"] = .string(successorId)
        metadata["supersededAt"] = .string(MemoryStorage.nowISO8601())
        _ = try await storage.updateProposalMetadata(id: id, metadata: .object(metadata))
        try await storage.removeTombstone(content: proposal.content)
        // THE FLIP RE-READS THE ROW (Astra comb 3, lane2 finding 3,
        // 2026-09-12). This actor is reentrant at every `await` above, so a
        // review can accept or reject this very proposal while the metadata and
        // tombstone writes are in flight; the unconditional flip that used to
        // stand here overwrote that decision with `superseded`. A decision that
        // arrived first wins — supersession is bookkeeping, the person's call is
        // not — and the successor link written above survives either way, so the
        // pair stays recoverable.
        guard let current = try await storage.getProposal(id: id) else {
            throw MemoryV2Error.recordNotFound
        }
        guard current.status == "pending" else {
            if current.status == "superseded" { return true }
            NSLog(
                "MemoryV2: proposal %@ was %@ while being superseded by %@; "
                + "leaving that decision alone, successor link retained",
                id, current.status, successorId
            )
            return false
        }
        try await storage.updateProposalStatus(
            id: id, status: "superseded", rejectionReason: "superseded by a correction: \(successorId)"
        )
        return true
    }

    /// Launch repair for rows the 2026-09-11 build retired through the rejection
    /// path: flip them to `superseded` and drop their tombstones so their
    /// successors can be kept. Idempotent; a no-op once clean.
    ///
    /// BOTH HALVES OF AN INTERRUPTED REPAIR (Astra comb 3, lane1 finding 2 /
    /// lane2 finding 5, 2026-09-12). The first cut flipped the status, then
    /// deleted the tombstone under `try?`: if the delete failed — or the process
    /// stopped between the two — the row was no longer `rejected`, so no later
    /// launch ever selected it again and the tombstone kept blocking the
    /// successor forever. This pass therefore looks for both shapes:
    ///
    /// - `rejected` rows whose reason names a correction: the untouched case.
    /// - `superseded` rows that still carry a tombstone: the half-repaired case.
    ///   Supersession never tombstones, so that combination is itself the
    ///   evidence, and it does not depend on a reason string that
    ///   `markProposalStatus` does not persist.
    /// - `pending` rows that already carry `supersededBy` metadata (Astra comb
    ///   3, lane2 finding 3, 2026-09-12): `supersedeProposal` writes the
    ///   successor link first and flips the status last, so a crash between the
    ///   two leaves a row that is still actionable in the review queue while its
    ///   replacement is already staged. The metadata IS the evidence the
    ///   supersession had begun; this pass finishes it.
    ///
    /// The tombstone goes FIRST and is verified gone before the status moves, so
    /// an interrupted run always leaves a row this pass can still find.
    public func repairSupersededTombstones() async {
        guard let storage else { return }
        var candidates: [ProposalRecord] = []
        if let rejected = try? await storage.listProposals(status: "rejected") {
            candidates += rejected.filter {
                ($0.rejectionReason ?? "").hasPrefix("superseded by a correction:")
            }
        }
        if let superseded = try? await storage.listProposals(status: "superseded") {
            candidates += superseded
        }
        if let pending = try? await storage.listProposals(status: "pending") {
            candidates += pending.filter { Self.supersededByMarker(in: $0.metadata) != nil }
        }
        for row in candidates {
            do {
                if try await storage.isTombstoned(content: row.content) {
                    try await storage.removeTombstone(content: row.content)
                    // Still there: leave the status alone so the next launch
                    // finds this row in exactly the same state.
                    if try await storage.isTombstoned(content: row.content) { continue }
                }
            } catch {
                continue
            }
            guard row.status != "superseded" else { continue }
            let reason = Self.supersededByMarker(in: row.metadata).map {
                Self.supersessionReasonPrefix + $0
            } ?? row.rejectionReason
            try? await storage.updateProposalStatus(
                id: row.id, status: "superseded", rejectionReason: reason
            )
        }
        // Rows retired before the successor metadata existed, and the pending
        // predecessors that retirement never retired (lane5 finding 2).
        await recoverSupersessionLinks()
    }

    /// Recover the successor link for rows retired BEFORE `supersedeProposal`
    /// wrote one (Astra comb 4, lane5 finding 2). Two live rows prove the gap:
    ///
    /// - `55F71D35-…` (superseded 20:52:08.383Z) names successor
    ///   `1FE2E5F1-…` in its reason string only; `markProposalStatus` never
    ///   persisted that string, so the reason the repair COMPUTES is the only
    ///   copy and it was being dropped for any row already `superseded`.
    /// - `CE41D07E-…` (superseded 20:52:44.849Z) has no reason and no
    ///   relationship at all. Its successor `ED6A1402-…` was staged at
    ///   20:52:44Z — the same pass that retired it, because that is the only
    ///   way a row becomes `superseded`: `AdaptivePromoter` stages the
    ///   correction and retires the row it corrects in the same iteration.
    ///
    /// So the second route is the staging instant, and it is deliberately
    /// strict: the candidate must be the UNIQUE non-moment proposal of the same
    /// session staged at or before the retirement and within
    /// `supersessionRecoveryWindow` of it, and staged after the retired row
    /// itself. More than one candidate, or none, and the row is left exactly as
    /// it is — a guess is worse than an acknowledged gap.
    ///
    /// Then the chain is walked back one step. `CE41D07E-…` was itself staged as
    /// the correction of `DA440751-…` ("Claude … avoids building in the main
    /// checkout"), which the pre-fix build left PENDING: the obsolete statement
    /// is still being offered for approval beside its own refinement. Same
    /// uniqueness rule, same window, anchored on the retired row's staging
    /// instant, and only ever applied to a `pending` non-moment row inside a
    /// chain whose successor link is now known.
    ///
    /// Every link this writes is stamped `supersededByRecovery` so the
    /// reconstruction is never mistaken for a first-hand record.

    /// Recover a successor link ONLY from first-hand evidence: the reason
    /// string an earlier build wrote ("superseded by a correction: <id>").
    /// Neighbour-by-time guesses were removed after review (GPT-5.6, e2 r1): on
    /// a busy database the sole row inside a window can be an unrelated
    /// proposal, and a guessed retirement takes a statement out of review
    /// silently. A retired row with no evidence keeps no link; its obsolete
    /// predecessor stays pending for the person's own Keep / Don't keep.
    func recoverSupersessionLinks() async {
        guard let storage else { return }
        guard let superseded = try? await storage.listProposals(status: "superseded") else { return }
        for row in superseded where Self.supersededByMarker(in: row.metadata) == nil {
            let reason = row.rejectionReason ?? ""
            guard reason.hasPrefix(Self.supersessionReasonPrefix) else { continue }
            let successor = String(reason.dropFirst(Self.supersessionReasonPrefix.count))
                .trimmingCharacters(in: .whitespaces)
            guard !successor.isEmpty else { continue }
            await writeRecoveredLink(on: row, successor: successor)
        }
    }

    static let supersessionReasonPrefix = "superseded by a correction: "

    private func writeRecoveredLink(
        on row: ProposalRecord, successor: String, preserveExisting: Bool = true
    ) async {
        guard let storage else { return }
        guard let current = try? await storage.getProposal(id: row.id) else { return }
        if preserveExisting, Self.supersededByMarker(in: current.metadata) != nil { return }
        var metadata: [String: JSONValue]
        if case .object(let existing)? = current.metadata { metadata = existing } else { metadata = [:] }
        metadata["supersededBy"] = .string(successor)
        if metadata["supersededAt"] == nil {
            metadata["supersededAt"] = .string(current.resolvedAt ?? MemoryStorage.nowISO8601())
        }
        metadata["supersededByRecovery"] = .string("launch-repair")
        _ = try? await storage.updateProposalMetadata(id: row.id, metadata: .object(metadata))
    }

    static func sessionID(of row: ProposalRecord) -> String? {
        guard case .object(let meta)? = row.metadata,
              case .string(let id)? = meta["session_id"],
              !id.isEmpty else { return nil }
        return id
    }

    /// The successor id `supersedeProposal` wrote into a row's metadata, if any.
    /// Present on a pending row means the supersession started and did not
    /// reach its status flip.
    public static func supersededByMarker(in metadata: JSONValue?) -> String? {
        guard case .object(let meta)? = metadata,
              case .string(let successor)? = meta["supersededBy"],
              !successor.isEmpty else { return nil }
        return successor
    }

    @discardableResult
    public func rejectProposal(id: String, reason: String? = nil) async throws -> Bool {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        guard let proposal = try await storage.getProposal(id: id) else {
            throw MemoryV2Error.recordNotFound
        }
        try await storage.updateProposalStatus(id: id, status: "rejected", rejectionReason: reason)
        // Rejection writes a tombstone so the same fact can't re-enter via a future
        // proposal — matches the Python promoter's denylist semantics.
        try await storage.recordTombstone(content: proposal.content, reason: reason)
        return true
    }

    /// A row that already carries a successor link is NOT offered among pending
    /// statements, whatever its status says (Astra comb 4, lane5 finding 2).
    /// `supersedeProposal` writes the link first and flips the status last, and
    /// the flip is refused outright when a review decision arrived meanwhile —
    /// so "pending with a successor" is a real state, and a statement whose
    /// replacement is already staged must not be offered for approval or fed
    /// back to the manager as competition for its own correction. `nil` status
    /// (the audit listings and the repair itself) is untouched.
    public func listProposals(status: String? = nil) async throws -> [ProposalRecord] {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        let rows = try await storage.listProposals(status: status)
        guard status == "pending" else { return rows }
        return rows.filter { Self.supersededByMarker(in: $0.metadata) == nil }
    }

    /// Count the moments lane. Uses the storage-level scalar when the seam
    /// offers one (production SQLite does) and falls back to the list path
    /// otherwise, so the answer is identical either way — only the cost differs.
    public func countMomentProposals(status: String? = "pending") async throws -> Int {
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        if let counting = storage as? any MomentProposalCountingStorage {
            return try await counting.countMomentProposals(status: status)
        }
        return try await storage.listProposals(status: status)
            .filter { MemoryMoments.isMoment($0.metadata) }
            .count
    }

}
