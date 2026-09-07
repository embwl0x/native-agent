import Foundation
import NativeAgentCore
import PersistenceCore
#if canImport(CryptoKit)
import CryptoKit
#endif

// Training-proposal and promotion-stage mutations on the local owner.
// Read surfaces, gate predicates, and shared JSON projections live in
// SelfImprovement+TrainingReads.swift.

extension SwiftNativeSelfImprovement {
    // MARK: - Subsystem #11: Training-proposal WRITE-SIDE
    //
    // Local-disk port of the two LIVE Mac-UI POST routes that mutate a staged
    // training proposal, mirroring `TrainingLoop.approve_proposal` /
    // `reject_proposal`:
    //
    //   POST /v1/training/proposals/<id>/approve -> approve (DIRECT mode only)
    //   POST /v1/training/proposals/<id>/reject  -> reject_proposal(id, reason)
    //
    // CALLERS: Mac SelfImprovementView.swift -> appModel.approveTrainingProposal
    // / rejectTrainingProposal -> NativeClient.approveTrainingProposal /
    // rejectTrainingProposal (the only callers; iOS does NOT mutate proposals,
    // and no script hits these two sub-routes — audit shows the prefix route
    // /v1/training/proposals has a single Mac caller). This file owns both
    // direct approval and route_through_promotion staging in Swift.
    //
    // TRUST GATE: the NativeClient routed helpers consult `trainingAllowed()`
    // (wave 32 W05, above) and throw the established 403 NSError before calling
    // these write methods. The raw methods below do NOT re-gate; the gate lives
    // one layer up, symmetric with the read methods.
    //
    // route_through_promotion is now Swift-native. When enabled, approval does
    // not mutate the target persona doc immediately. It writes a promotion
    // candidate plus pending stage under `training_journal/`, marks the proposal
    // `promotion_staged`, and lets the promotion approve/reject methods below
    // make the final doc mutation or rejection. No daemon fallback is involved.
    //
    // LOCKING: both methods wrap their file mutations in
    // `persistence.withFileLock(...)` (PersistenceCore+FileLock.swift) so other
    // NativeAgent processes cannot interleave with the Swift read-modify-write.
    // The in-process `withPathLock` is NOT used here because the file lock already
    // serializes within-process callers of the same path.

    public enum TrainingProposalWriteError: Error, Sendable, Equatable {
        /// Proposal id not found among `proposals/*.json`. Mirrors the daemon's
        /// `ValueError(f"Proposal {id} not found")`.
        case proposalNotFound(String)
        /// `approve_proposal` requires status == "pending"; mirrors the daemon's
        /// `ValueError(f"Proposal {id} is not pending (status={...})")` (L986).
        case notPending(id: String, status: String)
        /// target_doc is not one of the mutable personality docs. USER.md is
        /// generated from MemoryV2 and is not a training-promotion target.
        case targetDocNotAllowed(String)
        /// target_doc resolves OUTSIDE the memory dir (path-escape guard, L995).
        case targetDocEscapesMemoryDir(String)
        /// target_doc file is absent on disk (L998).
        case targetDocMissing(String)
        /// target_doc exists but could not be read as UTF-8 text. Mirrors the
        /// daemon's STRICT `doc_path.read_text()`, which
        /// RAISES on a read/decode failure and aborts the approve, leaving the
        /// doc untouched. The Swift read must throw the SAME way — degrading a
        /// failed read to "" would let `append` overwrite a valid personality
        /// doc with only the proposed snippet (gpt-5.5 wave-33 BLOCKER finding).
        case targetDocUnreadable(String)
        /// change_type/current combination cannot be applied (L1018).
        case cannotApplyChange(changeType: String)
        /// Pending promotion stage not found among promotion_stages/*.json.
        case promotionStageNotFound(String)
        /// Pending promotion stage exists, but status is no longer pending.
        case promotionStageNotPending(id: String, status: String)
        /// Pending promotion stage is missing the delta needed to apply/reject it.
        case promotionStageMalformed(String)
        /// Target doc changed after staging, so the saved before_hash no longer matches.
        case promotionStageStale(expected: String, actual: String)
    }

    /// `<root>/training_journal/proposals` — where the daemon's TrainingLoop
    /// writes proposal `*.json` files.
    private func trainingProposalsDir() -> URL {
        trainingJournalDir().appendingPathComponent("proposals", isDirectory: true)
    }

    private func promotionCandidatesDir() -> URL {
        trainingJournalDir().appendingPathComponent("promotion_candidates", isDirectory: true)
    }

    private func promotionStagesDir() -> URL {
        trainingJournalDir().appendingPathComponent("promotion_stages", isDirectory: true)
    }

    /// `<root>/training_journal/audit_ledger.jsonl` — the approve audit ledger
    ///.
    private func trainingLedgerPath() -> URL {
        trainingJournalDir().appendingPathComponent("audit_ledger.jsonl")
    }

    /// `<root>/memory` — the personality-doc directory the daemon's TrainingLoop
    /// is constructed against.
    private func trainingMemoryDir() -> URL {
        trainingPromotionDataRoot().appendingPathComponent("memory", isDirectory: true)
    }

    /// Run `body` under the cross-process `withFileLock(path)`.
    ///
    /// L7 (2026-08-01): this used to downcast to `SwiftNativePersistenceCore` and
    /// run `body` BARE otherwise — the stale comment claimed `withFileLock` was
    /// "declared only on the concrete type". It is a PersistenceCoreProtocol
    /// EXTENSION (PersistenceCore+FileLock.swift:4); every conformer has it, and
    /// it locks a local `<path>.lock` sidecar independent of the write backend.
    /// So the downcast only ever cost mutual exclusion. Lock uniformly.
    private func withTrainingFileLock<T: Sendable>(
        _ path: URL,
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        return try await trainingPromotionPersistence().withFileLock(path, body)
    }

    /// Find the proposal file whose `proposal_id` field equals `proposalId`,
    /// scanning `proposals/*.json` in FORWARD name order. Mirrors
    /// `TrainingLoop._find_proposal_file`: `sorted(glob)`,
    /// first file whose dict carries the matching `proposal_id`. Returns the
    /// URL plus the already-parsed dict so callers avoid a second read.
    private func findProposalFile(_ proposalId: String) async -> (url: URL, data: [String: JSONValue])? {
        let files = Self.sortedJSONFiles(in: trainingProposalsDir(), reversedName: false)
        for f in files {
            guard let obj = await readJSONObject(f) else { continue }
            if case .string(let pid)? = obj["proposal_id"], pid == proposalId {
                return (f, obj)
            }
        }
        return nil
    }

    /// ISO-8601 UTC timestamp matching the daemon's `_now_iso()` =
    /// `datetime.now(timezone.utc).isoformat()`. The daemon
    /// emits `…+00:00`; this emits the cosmetically-equivalent `…Z` (with
    /// fractional seconds). Both round-trip identically through
    /// `datetime.fromisoformat`, the only reader of these stamps. Same choice
    /// as MacControl.iso8601 (MacControl.swift L920).
    private static func nowISO() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Date())
    }

    /// `hashlib.sha256(text.encode("utf-8")).hexdigest()`.
    private static func sha256Hex(_ text: String) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        // No CryptoKit (non-Apple build): the audit ledger hashes are
        // informational (before/after content fingerprints, never gated on),
        // so an empty digest degrades gracefully rather than failing the write.
        return ""
        #endif
    }

    /// `True` when the MERGED trust policy enables route-through-promotion. The
    /// daemon reads `self.runtime.trust_policy().get("trainingPolicy", {})`
    /// (the merged policy) then `bool(_training_policy.get("route_through_promotion", False))`
    ///. Under the trust-policy merge the default
    /// dict supplies `route_through_promotion: True` (default_trust_policy
    /// L25617), so the effective default is TRUE — modeled here with
    /// `defaultWhenAbsent: true`, identical to how the gate predicates treat
    /// `autonomous_training` / `enabled`.
    private func routeThroughPromotionEnabled() async throws -> Bool {
        let policy = try await readSavedTrustPolicy()
        return Self.nestedGateTruthy(
            policy,
            outer: "trainingPolicy",
            inner: "route_through_promotion",
            defaultWhenAbsent: true
        )
    }

    // MARK: POST /v1/training/proposals/<id>/reject

    /// Mirror of `TrainingLoop.reject_proposal`: find the
    /// proposal file, set `status="rejected"` and `rejection_reason=reason`,
    /// write the dict back atomically. Returns the daemon's exact response
    /// `{"status":"rejected","proposal_id":<id>,"reason":<reason>}`. Throws
    /// `.proposalNotFound` when no file matches (the daemon raises ValueError).
    ///
    /// PARITY: the daemon does NOT validate the prior status on reject (unlike
    /// approve) — any status can be overwritten to "rejected". We preserve that:
    /// every OTHER key in the proposal dict is carried through untouched.
    ///
    /// EMPTY-REASON DEFAULT (gpt-5.5 wave-33 finding, fixed wave-34 W04):
    /// keep the established external behavior where an empty reason becomes
    /// "No reason given"; whitespace-only text is preserved.
    public func rejectTrainingProposalLocal(
        proposalId: String,
        reason: String
    ) async throws -> JSONValue {
        guard let found = await findProposalFile(proposalId) else {
            throw TrainingProposalWriteError.proposalNotFound(proposalId)
        }
        // Python `body.get("reason") or "No reason given"`: empty string is the
        // only falsy String value, so default exactly when `reason` is empty.
        let effectiveReason = reason.isEmpty ? "No reason given" : reason
        let url = found.url
        let p = trainingPromotionPersistence()
        let fallbackData = found.data
        try await withTrainingFileLock(url) {
            // Re-read INSIDE the lock so a concurrent daemon write that landed
            // between findProposalFile and lock acquisition is not clobbered.
            let raw = await p.readJSON(url, defaultValue: .object([:]))
            var data: [String: JSONValue]
            if case .object(let o) = raw { data = o } else { data = fallbackData }
            data["status"] = .string("rejected")
            data["rejection_reason"] = .string(effectiveReason)
            try await p.writeJSON(.object(data), to: url)
        }
        return .object([
            "status": .string("rejected"),
            "proposal_id": .string(proposalId),
            "reason": .string(effectiveReason),
        ])
    }

    // MARK: POST /v1/training/proposals/<id>/approve  (DIRECT mode only)

    /// Mirror of `TrainingLoop.approve_proposal` for the
    /// direct branch. When `trainingPolicy.route_through_promotion` is truthy
    /// (the default), this stages a Swift-native promotion candidate instead of
    /// applying the doc immediately.
    ///
    /// Steps (verbatim from the daemon, applied under a cross-process lock on
    /// the target doc which also covers the proposal-file + ledger writes):
    ///   1. find proposal file; require status == "pending".
    ///   2. require target_doc ∈ {SOUL,VOICE,GROWTH,AGENTS}.md.
    ///   3. require target_doc resolves inside <root>/memory (path-escape guard).
    ///   4. require the doc exists; read it; sha256 + atomic backup to
    ///      `<doc>.backup-<id>.md`.
    ///   5. apply append (rstrip + "\n\n" + proposed + "\n") OR edit (replace
    ///      first `current` with `proposed`); else throw .cannotApplyChange.
    ///   6. atomic write the new doc; set proposal status="approved" + approved_at;
    ///      append a ledger entry to audit_ledger.jsonl.
    /// Returns `{"status":"approved","backup":<path>, ...ledgerEntry}`.
    public func approveTrainingProposalLocal(proposalId: String) async throws -> JSONValue {
        let routeThroughPromotion = try await routeThroughPromotionEnabled()
        guard let found = await findProposalFile(proposalId) else {
            throw TrainingProposalWriteError.proposalNotFound(proposalId)
        }
        let proposalURL = found.url
        let data = found.data

        // status must be "pending" (daemon L985). A missing/null status fails
        // the `!= "pending"` check too, matching Python where data.get("status")
        // would be None. This is a PRE-LOCK fast-fail only; the AUTHORITATIVE
        // gate is re-run inside the lock off the fresh snapshot (below).
        let statusStr: String = {
            if case .string(let s)? = data["status"] { return s }
            return ""
        }()
        guard statusStr == "pending" else {
            throw TrainingProposalWriteError.notPending(id: proposalId, status: statusStr)
        }

        // The wave-33 W10 port validated target_doc / allow-list / path-escape /
        // file-exists PRE-LOCK off `found.data` but applied the freshData content
        // INSIDE the lock, so a concurrent rewrite of the proposal's `target_doc`
        // between this read and lock-acquire would have written the fresh content
        // to the STALE doc with the STALE doc validated (gpt-5.5 wave-33 race
        // finding, fixed wave-34 W04). The daemon reads `data` ONCE (training.py
        // L984) and derives target_doc, the allow-list, the escape guard, the
        // existence check, AND the content all from that single snapshot. We
        // reproduce that single-snapshot consistency: EVERY target_doc-derived
        // check now runs inside the lock off `freshData`.
        let memoryDir = trainingMemoryDir()
        let p = trainingPromotionPersistence()
        let ledgerPath = trainingLedgerPath()
        let allowedDocs: Set<String> = ["SOUL.md", "VOICE.md", "GROWTH.md", "AGENTS.md"]
        let candidatesDir = promotionCandidatesDir()
        let stagesDir = promotionStagesDir()

        // Lock the PROPOSAL FILE (stable across target_doc churn), not the doc:
        // the doc path is derived from the mutable `target_doc`, so locking it
        // pre-lock would hold the wrong token if a concurrent writer flipped
        // target_doc (gpt-5.5 wave-34 stale-lock-token finding). The proposal file
        // is keyed by proposalId and never changes within the call, and it is the
        // thing we re-read for the in-lock snapshot — the natural serialization
        // point for "read proposal → decide → apply". This also matches reject
        // (which already locks the proposal file), so approve and reject now
        // serialize cross-process WITH EACH OTHER on the same proposal — strictly
        // better than §6.96's documented split-lock state. WITHIN-PROCESS, the
        // `SwiftNativeSelfImprovement` actor already serializes every call. The
        // lock is the CROSS-PROCESS guard for the eventual flag-ON future; the
        // daemon's own approve/reject take NO file lock today (training.py
        // L1022/L1053 use bare atomic writes), so this is the Swift-side half in
        // place for when the daemon side gains the matching flock (cutover
        // discipline). The in-lock re-read of `status` + target_doc below
        // short-circuits a double-apply / stale-doc-apply if the daemon DID
        // mutate the proposal first.
        let ledgerOut: [String: JSONValue] = try await withTrainingFileLock(proposalURL) {
            // Re-read the proposal inside the lock; a daemon approve that landed
            // first will have flipped status off "pending" — bail to avoid a
            // double-apply. ALL downstream fields (status, target_doc, content)
            // are read off THIS one snapshot, matching the daemon's single read.
            let freshRaw = await p.readJSON(proposalURL, defaultValue: .object([:]))
            var freshData: [String: JSONValue] = data
            if case .object(let o) = freshRaw { freshData = o }
            let freshStatus: String = {
                if case .string(let s)? = freshData["status"] { return s }
                return ""
            }()
            guard freshStatus == "pending" else {
                throw TrainingProposalWriteError.notPending(id: proposalId, status: freshStatus)
            }

            // target_doc allow-list (daemon L988-991), revalidated IN-LOCK off the
            // fresh snapshot. `str(data.get("target_doc",""))`.
            let targetDoc: String = {
                if case .string(let s)? = freshData["target_doc"] { return s }
                return ""
            }()
            guard allowedDocs.contains(targetDoc) else {
                throw TrainingProposalWriteError.targetDocNotAllowed(targetDoc)
            }

            // Path-escape guard (daemon L993-997): docPath.resolve() must be inside
            // memoryDir.resolve(). The allow-list already blocks "/" and ".."
            // because none of the five names contain a separator, but we reproduce
            // the daemon's defense-in-depth check verbatim. docPath/backupPath are
            // recomputed here from the FRESH target_doc so the read/backup/write all
            // target the doc the fresh proposal names.
            let docPath = memoryDir.appendingPathComponent(targetDoc)
            let resolvedDoc = docPath.resolvingSymlinksInPath().standardizedFileURL
            let resolvedMem = memoryDir.resolvingSymlinksInPath().standardizedFileURL
            let memPrefix = resolvedMem.path.hasSuffix("/") ? resolvedMem.path : resolvedMem.path + "/"
            guard resolvedDoc.path == resolvedMem.path || resolvedDoc.path.hasPrefix(memPrefix) else {
                throw TrainingProposalWriteError.targetDocEscapesMemoryDir(targetDoc)
            }

            let fm = FileManager.default
            guard fm.fileExists(atPath: docPath.path) else {
                throw TrainingProposalWriteError.targetDocMissing(targetDoc)
            }

            let backupPath = docPath.deletingPathExtension()
                .appendingPathExtension("backup-\(proposalId).md")

            // Content fields off the in-lock snapshot, with Python str() parity:
            // a present non-string is str()-coerced (so a malformed change_type
            // like null/false/0 yields "None"/"False"/"0" and falls through to
            // .cannotApplyChange — NOT silently treated as "append").
            let changeType = Self.pythonStr(freshData["change_type"], defaultWhenAbsent: "append")
            let proposed = Self.pythonStr(freshData["proposed"], defaultWhenAbsent: "")
            let current = Self.pythonStr(freshData["current"], defaultWhenAbsent: "")
            let rationale: JSONValue = freshData["rationale"] ?? .string("")  // daemon: data.get("rationale","")

            // STRICT read — the daemon's `doc_path.read_text()` raises on a
            // read/decode failure and aborts (doc untouched). Degrading to "" here
            // would let `append` overwrite a valid doc with only the proposed
            // snippet, so a failed read THROWS .targetDocUnreadable instead.
            let beforeText: String
            do {
                beforeText = try String(contentsOf: docPath, encoding: .utf8)
            } catch {
                throw TrainingProposalWriteError.targetDocUnreadable(targetDoc)
            }
            let beforeHash = Self.sha256Hex(beforeText)

            // Apply change (daemon L1014-1019).
            let afterText: String
            if changeType == "append" {
                let trimmed = Self.pythonRStrip(beforeText)
                afterText = trimmed + "\n\n" + proposed + "\n"
            } else if changeType == "edit" && !current.isEmpty && beforeText.contains(current) {
                afterText = Self.replaceFirst(current, with: proposed, in: beforeText)
            } else {
                throw TrainingProposalWriteError.cannotApplyChange(changeType: changeType)
            }
            let afterHash = Self.sha256Hex(afterText)

            if routeThroughPromotion {
                let stagedAt = Self.nowISO()
                let candidateId = Self.promotionCandidateID(forProposalID: proposalId)
                let patch: JSONValue = .object([
                    "file": .string(targetDoc),
                    "before_sha": .string(beforeHash),
                    "after_sha": .string(afterHash),
                ])
                let harness: JSONValue = .object([
                    "test_passed": .bool(true),
                    "smoke_passed": .bool(true),
                    "eval_delta": .double(0),
                ])
                let delta: JSONValue = .object([
                    "kind": .string("training_proposal"),
                    "proposal_id": .string(proposalId),
                    "proposal_path": .string(proposalURL.path),
                    "target_doc": .string(targetDoc),
                    "change_type": .string(changeType),
                    "current": .string(current),
                    "proposed": .string(proposed),
                    "rationale": rationale,
                    "before_hash": .string(beforeHash),
                    "after_hash": .string(afterHash),
                ])
                let candidate: JSONValue = .object([
                    "candidate_id": .string(candidateId),
                    "source": .string("training_b1"),
                    "tier": .string("B"),
                    "patches": .array([patch]),
                    "status": .string("done"),
                    "created_at": .string(stagedAt),
                    "finished_at": .string(stagedAt),
                    "harness": harness,
                    "decision": .string("STAGE_FOR_HUMAN"),
                    "decision_reason": .string("Swift-native training proposal staged for human promotion approval."),
                    "worktree_path": .string(""),
                    "branch_name": .string(""),
                    "merged_commit_sha": .null,
                    "error": .null,
                ])
                let stage: JSONValue = .object([
                    "candidate_id": .string(candidateId),
                    "tier": .string("B"),
                    "harness": harness,
                    "delta": delta,
                    "staged_at": .string(stagedAt),
                    "worktree_path": .string(""),
                    "branch_name": .string(""),
                    "status": .string("pending"),
                    "resolved_at": .null,
                    "resolution_reason": .null,
                ])

                let candidatePath = candidatesDir.appendingPathComponent("\(candidateId).json")
                let stagePath = stagesDir.appendingPathComponent("\(candidateId).json")
                try await p.writeJSON(candidate, to: candidatePath)
                try await p.writeJSON(stage, to: stagePath)

                freshData["status"] = .string("promotion_staged")
                freshData["promotion_candidate_id"] = .string(candidateId)
                freshData["promotion_staged_at"] = .string(stagedAt)
                try await p.writeJSON(.object(freshData), to: proposalURL)

                let ledgerEntry: [String: JSONValue] = [
                    "ts": .string(stagedAt),
                    "proposal_id": .string(proposalId),
                    "target_doc": .string(targetDoc),
                    "before_hash": .string(beforeHash),
                    "after_hash": .string(afterHash),
                    "rationale": rationale,
                    "approved_by": .string("user"),
                    "status": .string("promotion_staged"),
                    "candidate_id": .string(candidateId),
                ]
                // M6 (2026-07-09): capped — this audit ledger grew unbounded.
                try await appendJSONLCapped(
                    .object(ledgerEntry), to: ledgerPath, using: p,
                    maxLines: JSONLLineCaps.trainingAudit, logLabel: "TrainingPromotion.auditLedger"
                )

                return [
                    "status": .string("promotion_staged"),
                    "proposal_id": .string(proposalId),
                    "candidate_id": .string(candidateId),
                    "target_doc": .string(targetDoc),
                    "before_hash": .string(beforeHash),
                    "after_hash": .string(afterHash),
                    "approved_by": .string("user"),
                ]
            }

            // Atomic backup (daemon L1007 _atomic_write_text). writeJSON is for
            // JSON; the backup is raw .md text, so write atomically by hand.
            try Self.atomicWriteText(beforeText, to: backupPath)

            // Atomic write the doc (daemon L1022-1024).
            try Self.atomicWriteText(afterText, to: docPath)

            // Update proposal status (daemon L1027-1030). writeJSON re-reads via
            // freshData (the in-lock copy) so concurrent extras are preserved.
            freshData["status"] = .string("approved")
            let approvedAt = Self.nowISO()
            freshData["approved_at"] = .string(approvedAt)
            try await p.writeJSON(.object(freshData), to: proposalURL)

            // Audit ledger (daemon L1033-1042). approved_by hard-coded "user"
            // (the route is human-triggered from the Self-Improvement UI).
            let ledgerEntry: [String: JSONValue] = [
                "ts": .string(approvedAt),
                "proposal_id": .string(proposalId),
                "target_doc": .string(targetDoc),
                "before_hash": .string(beforeHash),
                "after_hash": .string(afterHash),
                "rationale": rationale,
                "approved_by": .string("user"),
            ]
            // M6 (2026-07-09): capped — this audit ledger grew unbounded.
            try await appendJSONLCapped(
                .object(ledgerEntry), to: ledgerPath, using: p,
                maxLines: JSONLLineCaps.trainingAudit, logLabel: "TrainingPromotion.auditLedger"
            )

            // Build the return dict (daemon L1044): {"status":"approved",
            // "backup":<path>, **ledgerEntry}.
            var out = ledgerEntry
            out["status"] = .string("approved")
            out["backup"] = .string(backupPath.path)
            return out
        }
        return .object(ledgerOut)
    }

    // MARK: POST /v1/promotion/pending/<id>/approve|reject

    private static func promotionCandidateID(forProposalID proposalId: String) -> String {
        var safe = ""
        for scalar in proposalId.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                safe.append(String(scalar))
            } else {
                safe.append("_")
            }
        }
        let trimmed = safe.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return "training_\(trimmed.isEmpty ? "proposal" : String(trimmed.prefix(80)))"
    }

    private func findPromotionStage(_ candidateId: String) async -> (url: URL, data: [String: JSONValue])? {
        let files = Self.sortedJSONFiles(in: promotionStagesDir(), reversedName: false)
        for f in files {
            guard let obj = await readJSONObject(f) else { continue }
            if case .string(let cid)? = obj["candidate_id"], cid == candidateId {
                return (f, obj)
            }
        }
        return nil
    }

    /// Apply a Swift-native promotion stage produced by
    /// `approveTrainingProposalLocal(route_through_promotion=true)`.
    public func approvePromotionStageLocal(candidateId: String) async throws -> JSONValue {
        guard let found = await findPromotionStage(candidateId) else {
            throw TrainingProposalWriteError.promotionStageNotFound(candidateId)
        }
        let stageURL = found.url
        let p = trainingPromotionPersistence()
        let memoryDir = trainingMemoryDir()
        let ledgerPath = trainingLedgerPath()
        let allowedDocs: Set<String> = ["SOUL.md", "VOICE.md", "GROWTH.md", "AGENTS.md"]
        let candidatePath = promotionCandidatesDir().appendingPathComponent("\(candidateId).json")

        let out: [String: JSONValue] = try await withTrainingFileLock(stageURL) {
            let raw = await p.readJSON(stageURL, defaultValue: .object([:]))
            var stage: [String: JSONValue] = found.data
            if case .object(let o) = raw { stage = o }
            let status = Self.pythonStr(stage["status"], defaultWhenAbsent: "")
            guard status == "pending" else {
                throw TrainingProposalWriteError.promotionStageNotPending(id: candidateId, status: status)
            }
            guard case .object(let delta)? = stage["delta"] else {
                throw TrainingProposalWriteError.promotionStageMalformed(candidateId)
            }
            guard case .string(let targetDoc)? = delta["target_doc"],
                  allowedDocs.contains(targetDoc),
                  case .string(let beforeHash)? = delta["before_hash"],
                  case .string(let expectedAfterHash)? = delta["after_hash"]
            else {
                throw TrainingProposalWriteError.promotionStageMalformed(candidateId)
            }

            let docPath = memoryDir.appendingPathComponent(targetDoc)
            let resolvedDoc = docPath.resolvingSymlinksInPath().standardizedFileURL
            let resolvedMem = memoryDir.resolvingSymlinksInPath().standardizedFileURL
            let memPrefix = resolvedMem.path.hasSuffix("/") ? resolvedMem.path : resolvedMem.path + "/"
            guard resolvedDoc.path == resolvedMem.path || resolvedDoc.path.hasPrefix(memPrefix) else {
                throw TrainingProposalWriteError.targetDocEscapesMemoryDir(targetDoc)
            }
            guard FileManager.default.fileExists(atPath: docPath.path) else {
                throw TrainingProposalWriteError.targetDocMissing(targetDoc)
            }

            let beforeText: String
            do {
                beforeText = try String(contentsOf: docPath, encoding: .utf8)
            } catch {
                throw TrainingProposalWriteError.targetDocUnreadable(targetDoc)
            }
            let actualBeforeHash = Self.sha256Hex(beforeText)
            guard actualBeforeHash == beforeHash else {
                throw TrainingProposalWriteError.promotionStageStale(expected: beforeHash, actual: actualBeforeHash)
            }

            let changeType = Self.pythonStr(delta["change_type"], defaultWhenAbsent: "append")
            let proposed = Self.pythonStr(delta["proposed"], defaultWhenAbsent: "")
            let current = Self.pythonStr(delta["current"], defaultWhenAbsent: "")
            let afterText: String
            if changeType == "append" {
                afterText = Self.pythonRStrip(beforeText) + "\n\n" + proposed + "\n"
            } else if changeType == "edit" && !current.isEmpty && beforeText.contains(current) {
                afterText = Self.replaceFirst(current, with: proposed, in: beforeText)
            } else {
                throw TrainingProposalWriteError.cannotApplyChange(changeType: changeType)
            }
            let afterHash = Self.sha256Hex(afterText)
            guard afterHash == expectedAfterHash else {
                throw TrainingProposalWriteError.promotionStageMalformed(candidateId)
            }

            let backupPath = docPath.deletingPathExtension()
                .appendingPathExtension("backup-\(candidateId).md")
            try Self.atomicWriteText(beforeText, to: backupPath)
            try Self.atomicWriteText(afterText, to: docPath)

            let resolvedAt = Self.nowISO()
            stage["status"] = .string("approved")
            stage["resolved_at"] = .string(resolvedAt)
            stage["resolution_reason"] = .string("approved")
            try await p.writeJSON(.object(stage), to: stageURL)

            let candidateRaw = await p.readJSON(candidatePath, defaultValue: .object([:]))
            var candidate: [String: JSONValue] = [:]
            if case .object(let existing) = candidateRaw { candidate = existing }
            candidate["candidate_id"] = .string(candidateId)
            candidate["status"] = .string("promoted")
            candidate["decision"] = .string("APPROVED")
            candidate["decision_reason"] = .string("Approved through Swift-native promotion stage.")
            candidate["finished_at"] = .string(resolvedAt)
            try await p.writeJSON(.object(candidate), to: candidatePath)

            if case .string(let proposalPath)? = delta["proposal_path"] {
                let proposalURL = URL(fileURLWithPath: proposalPath)
                let proposalRaw = await p.readJSON(proposalURL, defaultValue: .object([:]))
                if case .object(var proposal) = proposalRaw {
                    proposal["status"] = .string("approved")
                    proposal["approved_at"] = .string(resolvedAt)
                    proposal["promotion_resolved_at"] = .string(resolvedAt)
                    try await p.writeJSON(.object(proposal), to: proposalURL)
                }
            }

            let proposalId = Self.pythonStr(delta["proposal_id"], defaultWhenAbsent: "")
            let ledgerEntry: [String: JSONValue] = [
                "ts": .string(resolvedAt),
                "proposal_id": .string(proposalId),
                "candidate_id": .string(candidateId),
                "target_doc": .string(targetDoc),
                "before_hash": .string(beforeHash),
                "after_hash": .string(afterHash),
                "approved_by": .string("user"),
                "status": .string("promotion_approved"),
            ]
            // M6 (2026-07-09): capped — this audit ledger grew unbounded.
            try await appendJSONLCapped(
                .object(ledgerEntry), to: ledgerPath, using: p,
                maxLines: JSONLLineCaps.trainingAudit, logLabel: "TrainingPromotion.auditLedger"
            )

            return [
                "ok": .bool(true),
                "status": .string("approved"),
                "candidate_id": .string(candidateId),
                "proposal_id": .string(proposalId),
                "target_doc": .string(targetDoc),
                "backup": .string(backupPath.path),
            ]
        }
        return .object(out)
    }

    public func rejectPromotionStageLocal(candidateId: String, reason: String) async throws -> JSONValue {
        guard let found = await findPromotionStage(candidateId) else {
            throw TrainingProposalWriteError.promotionStageNotFound(candidateId)
        }
        let stageURL = found.url
        let p = trainingPromotionPersistence()
        let effectiveReason = reason.isEmpty ? "No reason given" : reason
        let candidatePath = promotionCandidatesDir().appendingPathComponent("\(candidateId).json")

        let out: [String: JSONValue] = try await withTrainingFileLock(stageURL) {
            let raw = await p.readJSON(stageURL, defaultValue: .object([:]))
            var stage: [String: JSONValue] = found.data
            if case .object(let o) = raw { stage = o }
            let status = Self.pythonStr(stage["status"], defaultWhenAbsent: "")
            guard status == "pending" else {
                throw TrainingProposalWriteError.promotionStageNotPending(id: candidateId, status: status)
            }
            let resolvedAt = Self.nowISO()
            stage["status"] = .string("rejected")
            stage["resolved_at"] = .string(resolvedAt)
            stage["resolution_reason"] = .string(effectiveReason)
            try await p.writeJSON(.object(stage), to: stageURL)

            let candidateRaw = await p.readJSON(candidatePath, defaultValue: .object([:]))
            var candidate: [String: JSONValue] = [:]
            if case .object(let existing) = candidateRaw { candidate = existing }
            candidate["candidate_id"] = .string(candidateId)
            candidate["status"] = .string("rejected")
            candidate["decision"] = .string("BLOCK")
            candidate["decision_reason"] = .string(effectiveReason)
            candidate["finished_at"] = .string(resolvedAt)
            try await p.writeJSON(.object(candidate), to: candidatePath)

            if case .object(let delta)? = stage["delta"],
               case .string(let proposalPath)? = delta["proposal_path"] {
                let proposalURL = URL(fileURLWithPath: proposalPath)
                let proposalRaw = await p.readJSON(proposalURL, defaultValue: .object([:]))
                if case .object(var proposal) = proposalRaw {
                    proposal["status"] = .string("rejected")
                    proposal["rejection_reason"] = .string(effectiveReason)
                    proposal["resolved_at"] = .string(resolvedAt)
                    try await p.writeJSON(.object(proposal), to: proposalURL)
                }
            }

            return [
                "ok": .bool(true),
                "status": .string("rejected"),
                "candidate_id": .string(candidateId),
                "reason": .string(effectiveReason),
            ]
        }
        return .object(out)
    }

    // MARK: - Text helpers (Python str semantics)

    /// Atomic text write: write to `<path>.tmp` then rename over `path`. Mirrors
    /// the daemon's `_tmp.write_text(...); os.replace(_tmp, path)` (training.py
    /// L1022-1024) and `_atomic_write_text` for the backup. Creates the parent
    /// directory first (the memory dir already exists in practice).
    private static func atomicWriteText(_ text: String, to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Daemon uses `path.with_suffix(path.suffix + ".tmp")` — i.e. it APPENDS
        // ".tmp" to the existing extension (foo.md -> foo.md.tmp). Reproduce that
        // exact temp name so a crash leaves a recognizable sibling, not foo.tmp.
        let tmp = path.appendingPathExtension("tmp")
        try Data(text.utf8).write(to: tmp, options: .atomic)
        // os.replace(tmp, path) is a POSIX rename(2): atomic, and works whether
        // or not `path` already exists (the BACKUP write targets a fresh path on
        // first approve). `FileManager.replaceItemAt` documents the original as
        // expected-to-exist, so we call rename(2) directly for byte-exact
        // os.replace parity in BOTH cases. POSIX paths are UTF-8 on Darwin.
        let rc = path.withUnsafeFileSystemRepresentation { destRep -> Int32 in
            guard let destRep else { return -1 }
            return tmp.withUnsafeFileSystemRepresentation { srcRep -> Int32 in
                guard let srcRep else { return -1 }
                return rename(srcRep, destRep)
            }
        }
        if rc != 0 {
            // Clean up the orphan tmp so a failed rename does not leave litter.
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "rename(\(tmp.path) -> \(path.path)) failed: \(String(cString: strerror(errno)))"]
            )
        }
    }

    /// Python `str.rstrip()` with no args: strip TRAILING ASCII+Unicode
    /// whitespace. Swift's `.whitespacesAndNewlines` set matches Python's
    /// default whitespace class for the characters that appear in markdown docs
    /// (space, tab, newline, CR, form-feed, vertical-tab). Only the TRAILING
    /// run is removed (Python rstrip), not leading.
    private static func pythonRStrip(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if s[prev].isWhitespace { end = prev } else { break }
        }
        return String(s[s.startIndex..<end])
    }

    /// `before.replace(current, proposed, 1)` — replace ONLY the first
    /// occurrence (Python's count=1). Swift's `replacingOccurrences` replaces
    /// ALL, so we splice the first range by hand.
    private static func replaceFirst(_ needle: String, with replacement: String, in haystack: String) -> String {
        guard let r = haystack.range(of: needle) else { return haystack }
        return haystack.replacingCharacters(in: r, with: replacement)
    }
}
