import Foundation
import GRDB
import ApprovalInbox
import KnowledgeGraph
import NativeAgentCore
import OSLog
import PersistenceCore

extension MemoryConsolidationGate {
    // MARK: - Manifest + receipt

    struct SwapManifest {
        let runId: String
        let liveFingerprint: String
        let candidateFingerprint: String
    }

    static func writeManifest(
        dataRoot: URL, runId: String,
        liveFingerprint: String, candidateFingerprint: String,
        scores: MemoryProbeComparison, diff: MemoryConsolidationDiff,
        stagedAt: Date
    ) throws {
        let manifest: JSONValue = .object([
            "schema": .int(Int64(manifestSchema)),
            "run_id": .string(runId),
            "action": .string(approvalAction),
            "staged_at": .string(Self.iso8601(stagedAt)),
            "live_fingerprint": .string(liveFingerprint),
            "candidate_fingerprint": .string(candidateFingerprint),
            "scores": .object([
                "live": .string(scores.live.summary),
                "candidate": .string(scores.candidate.summary),
            ]),
            "diff": .string(diff.summary),
        ])
        try manifest.serializedData(pretty: true)
            .write(to: manifestPath(dataRoot: dataRoot, runId: runId), options: .atomic)
    }

    static func readManifest(dataRoot: URL, runId: String) throws -> SwapManifest {
        let data = try Data(contentsOf: manifestPath(dataRoot: dataRoot, runId: runId))
        let parsed = try JSONValue.parse(data)
        guard case .object(let obj) = parsed,
              case .string(let live)? = obj["live_fingerprint"],
              case .string(let cand)? = obj["candidate_fingerprint"],
              case .string(let run)? = obj["run_id"]
        else {
            throw MemoryConsolidationGateError.stagingFailed("manifest shape invalid for run \(runId)")
        }
        return SwapManifest(runId: run, liveFingerprint: live, candidateFingerprint: cand)
    }

    /// Receipt fields needed by reconcile's annotation repair. nil when the
    /// receipt is absent or unparseable (repair is best-effort).
    static func readReceipt(
        dataRoot: URL, runId: String
    ) -> (status: String, at: String, backupPath: String?, reason: String?)? {
        guard let data = try? Data(contentsOf: receiptPath(dataRoot: dataRoot, runId: runId)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let receiptRunId = obj["run_id"] as? String,
              receiptRunId == runId,
              let status = obj["status"] as? String,
              let at = obj["at"] as? String,
              Self.parseISO8601(at) != nil else { return nil }
        return (
            status: status,
            at: at,
            backupPath: obj["backup_path"] as? String,
            reason: obj["reason"] as? String
        )
    }

    static func writeReceipt(
        dataRoot: URL, runId: String, status: String,
        approvalId: String?, backupPath: String?, reason: String?
    ) {
        let receiptAt = Self.iso8601(Date())
        let receipt: JSONValue = .object([
            "run_id": .string(runId),
            "status": .string(status),
            "at": .string(receiptAt),
            "approval_id": approvalId.map { .string($0) } ?? .null,
            "backup_path": backupPath.map { .string($0) } ?? .null,
            "reason": reason.map { .string($0) } ?? .null,
        ])
        do {
            try FileManager.default.createDirectory(
                at: receiptsDir(dataRoot: dataRoot), withIntermediateDirectories: true)
            try receipt.serializedData(pretty: true)
                .write(to: receiptPath(dataRoot: dataRoot, runId: runId), options: .atomic)
            if status == "applied" || status == "applied_prior" {
                reconcileAppliedMaintenanceTruth(
                    dataRoot: dataRoot,
                    runId: runId,
                    status: status,
                    at: receiptAt
                )
            }
        } catch {
            logger.error("consolidation receipt write failed for \(runId, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Project a terminal, fully reconciled consolidation onto the shared
    /// maintenance-health receipt. `hygiene_last_run.json` is the canonical
    /// body/UI health input, so leaving its prior `staged` value behind after
    /// an approved swap makes healthy memory look permanently degraded.
    ///
    /// Existing malformed bytes are preserved and remain fail-closed. The
    /// exact applied consolidation receipt remains the compatibility proof,
    /// and a later reconciliation pass retries this projection.
    static func reconcileAppliedMaintenanceTruth(
        dataRoot: URL,
        runId: String,
        status: String,
        at: String
    ) {
        guard status == "applied" || status == "applied_prior",
              let appliedAt = Self.parseISO8601(at)
        else { return }
        let path = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("hygiene_last_run.json")
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path.path) {
            guard let data = try? Data(contentsOf: path),
                  let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                logger.error("consolidation health projection refused unreadable hygiene receipt for \(runId, privacy: .public)")
                return
            }
            object = existing
            // 2026-09-06: reconciliation REPLAYS every applied terminal receipt
            // on every pass, and this projection used to overwrite the record
            // unconditionally — so a months-old run re-stamped a NEWER hygiene
            // status (a deferred run, or a later consolidation) back to
            // "completed", with the old run's createdAt and nextScheduled. A
            // replayed receipt may only refresh a record that is not newer than
            // it is; the same run re-stamping itself carries an equal stamp and
            // still lands, so crash-window and upgrade recovery are unaffected.
            //
            // 2026-09-06: "equal stamp still lands" was too loose. These stamps
            // are second-resolution ISO strings, so two DIFFERENT runs can carry
            // the same one — and each replay then overwrote the other's record,
            // ping-ponging the run id and reason on every pass. An equal stamp
            // is accepted only from the run that wrote the record; anyone else's
            // loses to what is already there.
            if let existingAt = (existing["createdAt"] as? String).flatMap(Self.parseISO8601) {
                if existingAt > appliedAt { return }
                if existingAt == appliedAt,
                   (existing["consolidationRunId"] as? String) != runId {
                    return
                }
            }
        }
        object["id"] = (object["id"] as? String) ?? "consolidation-\(runId)"
        object["status"] = "completed"
        object["reason"] = status == "applied_prior"
            ? "approved consolidation was already applied and its projections were reconciled"
            : "approved consolidation applied and its projections were reconciled"
        object["version"] = (object["version"] as? String) ?? "swift-memory-v2-consolidator"
        object["createdAt"] = at
        object["nextScheduled"] = Self.iso8601(appliedAt.addingTimeInterval(7 * 24 * 60 * 60))
        object["consolidationRunId"] = runId
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: path, options: .atomic)
        } catch {
            logger.error("consolidation health projection failed for \(runId, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Staging (approval + inbox card; wave-1 memory.repair shape)

    static func stageApproval(
        inbox: SwiftNativeApprovalInbox, dataRoot: URL, runId: String,
        scores: MemoryProbeComparison, diff: MemoryConsolidationDiff
    ) async throws -> String {
        let title = "Memory consolidation ready — probe \(scores.live.summary) → \(scores.candidate.summary)"
        let reason = "The consolidator built a candidate store (\(diff.summary)) and the "
            + "known-answer probe set scored it at or above live. Approve to atomically swap "
            + "the live store to the candidate (live store backed up first), then reconcile "
            + "the KG/index tables against the current memory rows; deny to discard the "
            + "candidate and leave your memories exactly as they are."
        let missLines = scores.candidate.misses.prefix(10).map {
            "• [\($0.probeId)] \($0.question)"
        }
        let detail = "Diff: \(diff.summary)\n"
            + "Probe score live: \(scores.live.summary); candidate: \(scores.candidate.summary)\n"
            + "Post-approval: the approved card also authorizes bounded KG hygiene to remove orphan graph/index rows caused by archived memories.\n"
            + (missLines.isEmpty
                ? "No probe misses on the candidate."
                : "Candidate probe misses:\n" + missLines.joined(separator: "\n"))
        let body: JSONValue = .object([
            "title": .string(title),
            "action": .string(approvalAction),
            "risk": .string("medium"),
            "reason": .string(reason),
            "payload": .object([
                "kind": .string(payloadKind),
                "run_id": .string(runId),
                "candidate_path": .string("memory/consolidation/candidates/\(runId)/memory/memory.sqlite"),
                "scores": .object([
                    "live_hits": .int(Int64(scores.live.hits)),
                    "candidate_hits": .int(Int64(scores.candidate.hits)),
                    "total": .int(Int64(scores.live.total)),
                    // Per-probe regression info (review finding 3). Empty by
                    // the gate rule on every STAGED card; carried so the
                    // payload shape documents the per-probe contract.
                    "lost_probe_ids": .array(scores.lostProbeIds.map { .string($0) }),
                ]),
                "diff": .object([
                    "memories_active_before": .int(Int64(diff.memoriesActiveBefore)),
                    "memories_active_after": .int(Int64(diff.memoriesActiveAfter)),
                    "proposals_pending_before": .int(Int64(diff.proposalsPendingBefore)),
                    "proposals_pending_after": .int(Int64(diff.proposalsPendingAfter)),
                    "accepted": .int(Int64(diff.accepted)),
                    "merged": .int(Int64(diff.merged)),
                    "archived": .int(Int64(diff.archived)),
                ]),
            ]),
            "payloadPreview": .string("[\(payloadKind)] \(diff.summary)"),
        ])
        let record = try await inbox.create(body)
        do {
            try await ensureInboxCard(
                dataRoot: dataRoot, approvalId: record.id,
                title: title, summary: "\(diff.summary) — probe \(scores.live.summary) → \(scores.candidate.summary)",
                detail: detail,
                relatedPath: dataRoot.appendingPathComponent("memory/memory.sqlite").path
            )
        } catch {
            // Review finding 5: the approval exists but its card never made
            // it to the inbox — a pending approval no one can see. Resolve
            // it as canceled BEFORE the caller deletes the candidate, so no
            // orphan pending approval survives. Best-effort: if even the
            // cancel fails we still propagate the original card error.
            logger.error("consolidation gate: inbox card creation failed for \(record.id, privacy: .public) — canceling the approval: \(String(describing: error), privacy: .public)")
            if (try? await inbox.resolve(
                record.id, decision: .canceled, decidedBy: "consolidation-gate")) != nil {
                await annotateApproval(
                    dataRoot: dataRoot, id: record.id,
                    executedAction: .object([
                        "op": .string("memory_consolidation_swap"),
                        "status": .string("canceled_cleanup"),
                        "run_id": .string(runId),
                        "error": .string("inbox card creation failed: \(error)"),
                    ]),
                    detail: "consolidation swap canceled: the inbox card could not be created, "
                        + "so the approval was auto-canceled and the candidate discarded — "
                        + "nothing applied")
                writeReceipt(dataRoot: dataRoot, runId: runId, status: "canceled_cleanup",
                             approvalId: record.id, backupPath: nil,
                             reason: "inbox card creation failed: \(error)")
            }
            throw error
        }
        return record.id
    }

    // MARK: - Approval annotation (memory.repair convention)

    /// Stamp `executedAction` + a human `detail` through ApprovalInbox's
    /// checked mutation seam so consolidation never becomes a second writer
    /// for requests.json. Best-effort: an annotation failure is logged, never
    /// fatal to the already-known swap outcome.
    static func annotateApproval(
        dataRoot: URL, id: String, executedAction: JSONValue, detail: String
    ) async {
        do {
            _ = try await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                id,
                executedAction: executedAction,
                detail: detail
            )
        } catch {
            logger.error("consolidation gate: approval annotation failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Card id == approval id so InboxView's approve/reject routes through
    /// resolveApproval(id). Idempotent whole-file scan inside the flock —
    /// the same shape as the REM and memory.repair stagers.
    static func ensureInboxCard(
        dataRoot: URL, approvalId: String, title: String,
        summary: String, detail: String, relatedPath: String
    ) async throws {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let card: JSONValue = .object([
            "id": .string(approvalId),
            "created_at": .string(Self.iso8601(Date())),
            "source": .string("memory_consolidation"),
            "severity": .string("actionable"),
            "title": .string(title),
            "summary": .string(String(summary.prefix(500))),
            "detail": .string(detail),
            "related_mission_id": .null,
            "related_approval_id": .string(approvalId),
            "related_paths": .array([.string(relatedPath)]),
            "related_groups": .array([]),
            "actions": .array([
                .object(["id": .string("view"), "label": .string("View"),
                         "description": .string("See full detail")]),
                .object(["id": .string("approve"), "label": .string("Approve"),
                         "description": .string("Swap the live store to the candidate (backed up first)")]),
                .object(["id": .string("reject"), "label": .string("Deny"),
                         "description": .string("Discard the candidate; memories stay untouched")]),
                .object(["id": .string("dismiss"), "label": .string("Dismiss"),
                         "description": .string("Dismiss this card")]),
            ]),
            "status": .string("unread"),
            "read_at": .null,
        ])
        // Idempotent append via the shared bounded-scan helper (replaces the
        // per-append whole-inbox slurp; same shape as the REM/memory.repair stagers).
        try await appendUniqueById(card, to: inboxPath, using: SwiftNativePersistenceCore())
    }

}
