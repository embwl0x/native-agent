import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
// Blueprint: | `MemoryV2+Proposals.swift` | `SwiftNativeMemoryV2`: `propose`, `acceptProposal`, `supersedingAcceptance` |

extension SwiftNativeMemoryV2 {

    // MARK: Proposal lifecycle

    public func propose(
        content: String,
        source: String? = nil,
        confidence: Double? = nil,
        kind: String? = nil,
        supportingSessionIDs: [String] = [],
        recurrenceCount: Int? = nil,
        // Caller metadata is subordinate to typed fields when staging a new proposal.
        extraMetadata: [String: JSONValue] = [:]
    ) async throws -> ProposalRecord {
        let content = MemoryTextClip.memoryDisplayText(content, kind: kind)
        guard !content.isEmpty else { throw MemoryV2Error.invalidQuery }
        if let reason = MemoryCandidateQuality.rejectionReason(text: content, source: source, kind: kind) {
            throw MemoryV2Error.rejectedCandidate(reason)
        }
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        let sessions = Array(Set(supportingSessionIDs.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        })).sorted().prefix(32)
        // Deduplicate pending facts by article-folded content; never persist the comparison hash.
        let dedupKey: @Sendable (String) -> String = { s in
            MemoryStorage.contentHash(MemoryStorage.comparisonKey(s, mode: .proposal))
        }
        // Merge sessions, recurrence and maximum confidence under the pending-proposal write lock.
        let mergedMetadata: @Sendable (StoredProposal) throws -> JSONValue? = { existing in
            var merged: [String: JSONValue]
            if case .object(let m)? = existing.metadata { merged = m } else { merged = [:] }
            // Corrections merge only for the same subject and a nonolder originating turn.
            if kind == "correction" || merged["kind"] == .string("correction") {
                guard kind == "correction", merged["kind"] == .string("correction"),
                      case .string(let subject)? = merged["correction_subject"],
                      extraMetadata["correction_subject"] == .string(subject),
                      case .string(let priorTimestamp)? = merged["observed_at"],
                      case .string(let incomingTimestamp)? = extraMetadata["observed_at"],
                      let priorDate = MemoryRecallScoring.parseTimestamp(priorTimestamp),
                      let incomingDate = MemoryRecallScoring.parseTimestamp(incomingTimestamp),
                      priorDate <= incomingDate else {
                    throw MemoryStorageError.invalidTemporalEvidence(
                        "pending correction merge requires the same subject and a nonolder originating turn")
                }
            }
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
                    // Malformed saved evidence is not absence.
                    guard let count = Int64(s.trimmingCharacters(in: .whitespaces)) else {
                        nativeLog("MemoryV2: refusing proposal merge with invalid recurrence_count; saved evidence retained")
                        throw MemoryStorageError.databaseUnavailable("stage proposal: recurrence_count is not a valid Int64")
                    }
                    return count
                case nil: return nil
                default:
                    nativeLog("MemoryV2: refusing proposal merge with invalid recurrence_count type; saved evidence retained")
                    throw MemoryStorageError.databaseUnavailable("stage proposal: recurrence_count has an invalid type")
                }
            }
            // Reject counter overflow before staging writes.
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
            for (key, value) in extraMetadata where key != "kind" && key != "sense_versions" {
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
        var proposal = StoredProposal(
            id: UUID().uuidString,
            content: content,
            source: source,
            stagedAt: Self.iso8601Now(),
            status: "pending",
            metadata: meta.isEmpty ? nil : .object(meta)
        )

        // Match and merge before embedding, then recheck under the insertion
        // transaction so concurrent observations retain all their evidence.
        if let merged = try await storage.stagePendingProposal(
            proposal,
            insertIfAbsent: false,
            foldedKey: dedupKey,
            merge: mergedMetadata
        ) {
            return ProposalRecord(stored: merged)
        }
        let embedded = try await embedOneWithEpoch(content)
        proposal.embedding = embedded.vector
        proposal.embeddingEpoch = embedded.epoch.rawValue
        guard let staged = try await storage.stagePendingProposal(
            proposal,
            insertIfAbsent: true,
            foldedKey: dedupKey,
            merge: mergedMetadata
        ) else { throw MemoryV2Error.storageUnavailable }
        return ProposalRecord(stored: staged)
    }

    public func acceptProposal(id: String) async throws -> MemoryRecord {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        guard let proposal = try await storage.getProposal(id: id) else {
            throw MemoryV2Error.recordNotFound
        }
        if let reason = MemoryCandidateQuality.rejectionReason(
            text: proposal.content,
            source: proposal.source,
            kind: MemoryRecallScoring.kind(of: proposal.metadata)
        ) {
            let rejection = "quality gate at acceptance: \(reason)"
            try await storage.rejectProposal(id: id, reason: rejection)
            requestEmbeddingEpochReconcile()
            throw MemoryV2Error.rejectedCandidate("\(reason); the proposal was marked rejected.", effects: .occurred)
        }
        // Recheck tombstones at acceptance, including denials made after staging.
        if try await storage.isTombstoned(content: proposal.content) {
            try await storage.rejectProposal(id: id, reason: "tombstoned at acceptance")
            requestEmbeddingEpochReconcile()
            throw MemoryV2Error.forgottenContent("Proposal content matches a forgotten or rejected memory; the proposal was marked rejected.", effects: .occurred)
        }
        // Fingerprinted replacements atomically accept and mark the old memory corrected, preserving it.
        let superseding = Self.supersedingAcceptance(from: proposal.metadata)
        if let targetId = Self.supersedesTargetId(from: proposal.metadata), superseding == nil {
            // Without a recorded fingerprint, leave the replacement pending for review.
            throw ToolFailureError("The replacement target has no recorded fingerprint (\(targetId)); the proposal remains pending.",
                effects: .none, nextCall: ToolFailureError.call("app", ["action": .string("memory.list")]),
                code: "memory_supersession_review_required", status: .refused,
                instruction: "Read the current target and stage a newly reviewed replacement; do not resubmit this unverified proposal.", recovery: .inspect)
        }
        return MemoryRecord(stored: try await storage.acceptProposal(id: id, superseding: superseding))
    }

    /// Reviewed replacement intent; nil unless both target and fingerprint are present.
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

    /// Read target intent independently so missing fingerprints cannot turn replacements into ordinary accepts.
    static func supersedesTargetId(from metadata: JSONValue?) -> String? {
        guard case .object(let meta)? = metadata,
              case .string(let targetId)? = meta[MemoryManagerLane.supersedesKey],
              !targetId.isEmpty else { return nil }
        return targetId
    }

    /// Retire a pending proposal and record its successor atomically; preserve all tombstones.
    @discardableResult
    public func supersedeProposal(id: String, by successorId: String) async throws -> Bool {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        return try await storage.supersedeProposal(id: id, by: successorId)
    }

    /// Repair correction-rejected, superseded and successor-linked pending rows in cursor order.
    /// Remove only tombstones matching the proposal's content/hash and recorded supersession reason.
    /// Genuine denials remain authoritative; repair and cursor advancement commit together.
    public func repairSupersededTombstones() async {
        do { try await ensureCanonicalAttachment() }
        catch { emitDiagnostic("[MemoryV2] Supersession repair attachment failed: \(error)"); return }
        guard let storage else { return }
        do { try await storage.repairSupersededTombstones() }
        catch { nativeLog("MemoryV2: supersession repair failed: %@", String(describing: error)) }
    }

    static let supersessionReasonPrefix = "superseded by a correction: "

    /// A pending statement waits on the owner's review when nothing has
    /// superseded it and it passes the durable-candidate gate. The Today page
    /// ("Waiting on you") and the agent's home count by this one rule.
    public static func awaitsReview(content: String, source: String?, metadata: JSONValue?) -> Bool {
        guard supersededByMarker(in: metadata) == nil else { return false }
        let kind: String? = if case .object(let meta)? = metadata, case .string(let value)? = meta["kind"] { value } else { nil }
        return MemoryCandidateQuality.isDurableCandidate(text: content, source: source, kind: kind)
    }

    /// Successor evidence applies even while a proposal's status remains pending.
    public static func supersededByMarker(in metadata: JSONValue?) -> String? {
        guard case .object(let meta)? = metadata,
              case .string(let successor)? = meta["supersededBy"],
              !successor.isEmpty else { return nil }
        return successor
    }

    @discardableResult
    public func rejectProposal(id: String, reason: String? = nil) async throws -> Bool {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        guard try await storage.getProposal(id: id) != nil else {
            throw MemoryV2Error.recordNotFound
        }
        // Rejection and its vector-bearing tombstone commit together to prevent re-entry.
        try await storage.rejectProposal(id: id, reason: reason)
        requestEmbeddingEpochReconcile()
        return true
    }

    /// Pending listings exclude successor-linked rows; other status filters and unfiltered audit reads retain them.
    public func listProposals(status: String? = nil) async throws -> [ProposalRecord] {
        try await ensureCanonicalAttachment()
        guard let storage else { throw MemoryV2Error.storageUnavailable }
        let rows = try await storage.listProposals(status: status).map(ProposalRecord.init(stored:))
        guard status == "pending" else { return rows }
        return rows.filter { Self.supersededByMarker(in: $0.metadata) == nil }
    }
}
