import Foundation
import PersistenceCore
import ApprovalInbox
import MemoryV2
import ProviderRouting

extension NativeClient {
    /// Applies a resolved memory.repair record (U3 wave-1 item 3 — mirror of
    /// applyResolvedREMProposal's shape). Approved → run the matching
    /// MemoryRepairOneShot executor (sqlite truncated-row completion or
    /// legacy note duplicate purge), which backs the store up FIRST and mutates
    /// only what the approved card's payload carries. Denied → store stays
    /// untouched and the staging stamp stays (a refused repair is never
    /// re-proposed). Canceled / apply-failure → stamp cleared so the next
    /// launch re-detects and re-stages a fresh card. Every branch annotates
    /// the approval record; an approved record must never read as silently
    /// applied (W8 lesson).
    /// Static + root-injectable (review blocker fix, 2026-06-10) so the
    /// on-launch crash-window reconciliation below can run the SAME executor
    /// against any data root. Self-guarding and idempotent: re-running an
    /// already-applied repair stale-skips every row (truncated kind) or
    /// finds zero remaining legacy-note duplicates — no double mutation.
    static func applyResolvedMemoryRepair(
        from rec: ApprovalRecord,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        // Self-defensive: only ever acts on a resolved memory.repair record.
        guard rec.action == "memory.repair",
              rec.status == "resolved",
              let decision = rec.decision else { return }
        guard let kind = MemoryRepairOneShot.payloadKind(rec.payload) else {
            NSLog("[memoryRepair] missing payload kind on approval \(rec.id)")
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object(["error": .string("missing payload kind")]),
                detail: "Memory repair \(decision) FAILED: payload carries no repair kind",
                root: dataRoot)
            return
        }
        switch decision {
        case "approved":
            do {
                switch kind {
                case MemoryRepairOneShot.truncatedRowsKind:
                    let repairs = MemoryRepairOneShot.truncatedRepairs(fromPayload: rec.payload)
                    let outcome = try await MemoryRepairOneShot.applyTruncatedRowsRepair(
                        dataRoot: dataRoot, repairs: repairs)
                    let unrefreshed = outcome.applied.count - outcome.embeddingRefreshed.count
                    try? await Self.annotateApprovalExecution(
                        id: rec.id,
                        executedAction: .object([
                            "op": .string("memory_repair_truncated_rows"),
                            "applied": .array(outcome.applied.map { .string($0) }),
                            "skippedStale": .array(outcome.skippedStale.map { .string($0) }),
                            "failed": .object(outcome.failed.mapValues { .string($0) }),
                            "backupPath": .string(outcome.backupPath),
                        ]),
                        detail: "memory repair applied: \(outcome.applied.count) rows completed"
                            + (outcome.skippedStale.isEmpty ? "" : ", \(outcome.skippedStale.count) stale-skipped")
                            + (outcome.failed.isEmpty ? "" : ", \(outcome.failed.count) FAILED")
                            + (unrefreshed > 0 ? ", \(unrefreshed) without embedding refresh" : "")
                            + " — backup at \(outcome.backupPath)",
                        root: dataRoot)
                case MemoryRepairOneShot.legacyNoteDupsKind:
                    let outcome = try await MemoryRepairOneShot.applyLegacyNoteDupPurge(dataRoot: dataRoot, payload: rec.payload)
                    try? await Self.annotateApprovalExecution(
                        id: rec.id,
                        executedAction: .object([
                            "op": .string("memory_repair_legacy_note_dups"),
                            "kept": .int(Int64(outcome.kept)),
                            "purged": .int(Int64(outcome.purged)),
                            "backupPath": .string(outcome.backupPath),
                        ]),
                        detail: outcome.purged > 0
                            ? "legacy note purge applied: \(outcome.purged) duplicates removed, "
                                + "\(outcome.kept) rows kept — backup at \(outcome.backupPath)"
                            : "legacy note purge: no duplicates remained at apply time; file untouched",
                        root: dataRoot)
                default:
                    NSLog("[memoryRepair] unknown repair kind: \(kind)")
                    try? await Self.annotateApprovalExecution(
                        id: rec.id,
                        executedAction: .object(["kind": .string(kind), "error": .string("unknown kind")]),
                        detail: "memory repair FAILED: unknown repair kind '\(kind)'",
                        root: dataRoot)
                }
            } catch {
                NSLog("[memoryRepair] apply failed for \(kind): \(String(describing: error))")
                // The approval record is terminal; clear the staging stamp so
                // the next launch re-detects whatever is still broken and
                // stages a fresh card instead of dead-ending.
                MemoryRepairOneShot.clearStamp(kind: kind, dataRoot: dataRoot)
                try? await Self.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object([
                        "kind": .string(kind),
                        "error": .string("\(error)"),
                    ]),
                    detail: "memory repair FAILED: \(error.localizedDescription) — stamp cleared; "
                        + "next launch re-stages whatever is still repairable",
                    root: dataRoot)
            }
        case "denied":
            // Store untouched; stamp stays so the refused repair is never
            // re-proposed.
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "op": .string("memory_repair_deny"),
                    "kind": .string(kind),
                ]),
                detail: "memory repair denied — store untouched; will not be re-proposed",
                root: dataRoot)
        default: // canceled
            MemoryRepairOneShot.clearStamp(kind: kind, dataRoot: dataRoot)
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object([
                    "op": .string("memory_repair_cancel"),
                    "kind": .string(kind),
                ]),
                detail: "memory repair canceled — stamp cleared; next launch re-stages it",
                root: dataRoot)
        }
    }

    /// REVIEW BLOCKER FIX (gpt-5.5, 2026-06-10): resolve→apply crash-window
    /// reconciliation for memory.repair. resolveApproval persists the
    /// approval terminal BEFORE the executor runs; a crash between the two
    /// leaves a resolved record whose repair never applied — and because
    /// the staging stamp survives, MemoryRepairOneShot.stageIfNeeded
    /// early-returns forever (approved-but-never-applied dead-end).
    ///
    /// Called on every launch BEFORE stageIfNeeded: scan resolved
    /// memory.repair records that lack an execution annotation
    /// (`executedAction` is only ever written AFTER the executor ran) and
    /// run the idempotent executor for them. Approved records apply (or
    /// stale-skip when already applied); denied records just gain their
    /// annotation; canceled records clear the stamp so the following
    /// stageIfNeeded re-stages.
    static func reconcileUnappliedMemoryRepairs(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let resolved: [ApprovalRecord]
        do {
            resolved = try await inbox.list(
                filter: ApprovalFilter(status: "resolved", action: MemoryRepairOneShot.action))
        } catch {
            NSLog("[memoryRepair] reconciliation scan failed: \(String(describing: error))")
            return
        }
        for rec in resolved where rec.executedAction == nil {
            NSLog("[memoryRepair] reconciling unapplied resolved repair \(rec.id) "
                + "(decision: \(rec.decision ?? "?"))")
            await applyResolvedMemoryRepair(from: rec, dataRoot: dataRoot)
        }
    }

    /// Applies a resolved memory.kind_backfill record (U3 wave-2 item 5 —
    /// mirror of applyResolvedMemoryRepair's shape). Approved → stamp each
    /// row's LLM-proposed kind through the store's own write path; the
    /// content-hash stale guard inside MemoryKindBackfill.apply skips any
    /// row whose content drifted since staging. Denied → store untouched
    /// and the staging stamp stays (a refused backfill is never
    /// re-proposed). Canceled / apply-failure / malformed payload → stamp
    /// cleared so the next launch re-detects and re-stages. Every branch
    /// annotates the approval record; an approved record must never read
    /// as silently applied.
    static func applyResolvedKindBackfill(
        from rec: ApprovalRecord,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        guard rec.action == MemoryKindBackfill.action,
              rec.status == "resolved",
              let decision = rec.decision else { return }
        switch decision {
        case "approved":
            do {
                let rows = MemoryKindBackfill.rowProposals(fromPayload: rec.payload)
                guard !rows.isEmpty else {
                    // Fix-round (gpt-5.5 review, 2026-06-10): a malformed
                    // card is apply-failure shaped — clear the stamp BEFORE
                    // annotating, or the stamp dead-ends every future
                    // staging behind a card that can never apply.
                    MemoryKindBackfill.clearStamp(dataRoot: dataRoot)
                    try? await Self.annotateApprovalExecution(
                        id: rec.id,
                        executedAction: .object(["error": .string("payload carries no row proposals")]),
                        detail: "kind backfill FAILED: payload carries no row proposals — "
                            + "stamp cleared; next launch re-stages whatever is still classifiable",
                        root: dataRoot)
                    return
                }
                let storage = try await Self.kindBackfillStorage(dataRoot: dataRoot)
                let outcome = try await MemoryKindBackfill.apply(rows, storage: storage)
                try? await Self.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object([
                        "op": .string("memory_kind_backfill"),
                        "applied": .array(outcome.applied.map { .string($0) }),
                        "skippedStale": .array(outcome.skippedStale.map { .string($0) }),
                        "failed": .object(outcome.failed.mapValues { .string($0) }),
                    ]),
                    detail: "kind backfill applied: \(outcome.applied.count) rows stamped"
                        + (outcome.skippedStale.isEmpty ? "" : ", \(outcome.skippedStale.count) stale-skipped")
                        + (outcome.failed.isEmpty ? "" : ", \(outcome.failed.count) FAILED"),
                    root: dataRoot)
            } catch {
                NSLog("[kindBackfill] apply failed: \(String(describing: error))")
                MemoryKindBackfill.clearStamp(dataRoot: dataRoot)
                try? await Self.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object(["error": .string("\(error)")]),
                    detail: "kind backfill FAILED: \(error.localizedDescription) — stamp cleared; "
                        + "next launch re-stages whatever is still classifiable",
                    root: dataRoot)
            }
        case "denied":
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object(["op": .string("memory_kind_backfill_deny")]),
                detail: "kind backfill denied — rows untouched; will not be re-proposed",
                root: dataRoot)
        default: // canceled
            MemoryKindBackfill.clearStamp(dataRoot: dataRoot)
            try? await Self.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object(["op": .string("memory_kind_backfill_cancel")]),
                detail: "kind backfill canceled — stamp cleared; next launch re-stages it",
                root: dataRoot)
        }
    }

    /// Crash-window reconciliation for memory.kind_backfill (same shape as
    /// reconcileUnappliedMemoryRepairs): resolved records lacking an
    /// execution annotation get the idempotent executor re-run on launch.
    static func reconcileUnappliedKindBackfills(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let resolved: [ApprovalRecord]
        do {
            resolved = try await inbox.list(
                filter: ApprovalFilter(status: "resolved", action: MemoryKindBackfill.action))
        } catch {
            NSLog("[kindBackfill] reconciliation scan failed: \(String(describing: error))")
            return
        }
        for rec in resolved where rec.executedAction == nil {
            NSLog("[kindBackfill] reconciling unapplied resolved backfill \(rec.id) "
                + "(decision: \(rec.decision ?? "?"))")
            await applyResolvedKindBackfill(from: rec, dataRoot: dataRoot)
        }
    }

    /// Storage handle for the kind-backfill surface. Fix-round NIT (gpt-5.5
    /// review, 2026-06-10): prefer the launch-attached SHARED storage —
    /// `SwiftNativeMemoryV2.shared.underlyingBridge().underlyingStorage()` —
    /// so USER.md regen / Spotlight / KG hooks fire on the kind stamps
    /// (same rule as updateMemory/deleteMemory, F2). The direct
    /// `MemoryStorage(dataRoot:)` open is the documented fallback only:
    /// custom dataRoot (tests run on temp roots — the shared instance is
    /// rooted at the default dataRoot, so it would target the WRONG store)
    /// or the bridge not yet attached at call time.
    private static func kindBackfillStorage(dataRoot: URL) async throws -> MemoryStorage {
        if dataRoot.path == PersistenceCore.defaultDataRoot().path,
           let bridge = await SwiftNativeMemoryV2.shared.underlyingBridge() {
            return await bridge.underlyingStorage()
        }
        return try MemoryStorage(dataRoot: dataRoot)
    }

    /// Stages the kind-backfill approval card if the legacy kind-less rows
    /// still exist and no card was staged before (U3 wave-2 item 5).
    /// MemoryV2 never imports ApprovalInbox (module-boundary rule), so the
    /// approval-record create + pending-scan are backed here with
    /// SwiftNativeApprovalInbox closures.
    static func stageKindBackfillIfNeeded(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        let storage: MemoryStorage
        do {
            storage = try await Self.kindBackfillStorage(dataRoot: dataRoot)
        } catch {
            NSLog("[kindBackfill] storage open failed; staging skipped: \(String(describing: error))")
            return
        }
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        // Classifier: Apple FM on-device when available (free, instant),
        // else WHICHEVER MODEL AGENT IS ON — resolved through the "memory"
        // picker surface with the dream/rem pin-only pattern: a pin on
        // "memory" wins (so the user can point this at something cheap from the
        // Providers panel), otherwise the chat surface's current pick
        // (Anthropic OR GPT-5.5 OAuth — never a hardcoded provider; the user's
        // call, 2026-06-10: she regularly runs on codex OAuth models to
        // save Anthropic tokens). Same no-fabrication contract as FM: a
        // reply outside the taxonomy throws → the row drops from the card
        // instead of carrying a made-up kind.
        let llm = BackgroundLoopsAssembly.makeSharedLLMClient()
        let routerForPins = SwiftNativeProviderRouting()
        let classifier: @Sendable (String, [String]) async throws -> String = { content, taxonomy in
            if AppleFoundationModelsAdapter.isAvailable {
                return try await MemoryKindBackfill.foundationModelsClassifier(
                    content: content, taxonomy: taxonomy)
            }
            // Surface-scoped resolution (gpt-5.5 review blocker): the
            // surface-less complete() defaults to "chat", whose active.json
            // provider entry can REMAP a pinned model to chat's provider —
            // bypassing the pin. A pin on "memory" routes under the
            // "memory" surface (no active.json entry → model-prefix
            // inference honors the pin); unpinned falls back to the chat
            // surface's own pick verbatim.
            let model: String?
            let surface: String
            if let pinned = await routerForPins.pinnedModelStringForSurface("memory") {
                model = pinned
                surface = "memory"
            } else {
                model = await routerForPins.modelStringForSurface("chat")
                surface = "chat"
            }
            let system = "You classify one memory snippet into exactly one of these kinds: "
                + taxonomy.joined(separator: ", ")
                + ". Reply with ONLY the kind word, lowercase, nothing else."
            let raw = try await llm.complete(
                prompt: content, system: system, model: model, surface: surface)
            // EXACT match only (gpt-5.5 review blocker): a substring branch
            // fabricates kinds from noncompliant replies ("not a preference"
            // → preference). Trim trailing punctuation, then exact-or-drop —
            // the no-fabrication contract: an unparseable reply drops the
            // row from the card, never invents a kind.
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".\"'`"))
                .lowercased()
            if let exact = taxonomy.first(where: { $0.lowercased() == cleaned }) {
                return exact
            }
            throw NSError(domain: "NativeAgentKindBackfill", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "classifier reply not in taxonomy: \(cleaned.prefix(80))"
            ])
        }
        _ = await MemoryKindBackfill.stageIfNeeded(
            dataRoot: dataRoot,
            storage: storage,
            classifier: classifier,
            createApproval: { body in
                try await inbox.create(body).id
            },
            listPendingBackfills: {
                try await inbox.list(
                    filter: ApprovalFilter(status: "pending", action: MemoryKindBackfill.action)
                ).map { (id: $0.id, payload: $0.payload) }
            })
    }
}
