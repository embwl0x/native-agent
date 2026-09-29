import Foundation
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
import MemoryV2
import ProviderRouting
import TrustCenter

/// Supplies the app-composed shared model client at the original staging boundary.
public struct MemoryApprovalTransactionPorts: Sendable {
    public let makeLLMClient: @Sendable () -> any LLMClient

    public init(makeLLMClient: @escaping @Sendable () -> any LLMClient) {
        self.makeLLMClient = makeLLMClient
    }
}

public enum MemoryApprovalTransactions {
    public static func applyResolvedMemoryRepair(
        from rec: ApprovalRecord,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await MemoryRepairOneShot.applyResolvedMemoryRepair(from: rec, dataRoot: dataRoot)
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
    public static func reconcileUnappliedMemoryRepairs(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await ApprovalTransactionCoordinator.reconcileUnappliedApprovalExecutions(dataRoot: dataRoot, kinds: [
            ApprovalTransactionCoordinator.ApprovalExecutionReconcileKind(
                action: MemoryRepairOneShot.action,
                shouldReconcile: { _ in true },
                execute: { await applyResolvedMemoryRepair(from: $0, dataRoot: dataRoot) })
        ])
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
    public static func applyResolvedKindBackfill(
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
                    try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                        id: rec.id,
                        executedAction: .object(["error": .string("payload carries no row proposals")]),
                        detail: "kind backfill FAILED: payload carries no row proposals — "
                            + "stamp cleared; next launch re-stages whatever is still classifiable",
                        root: dataRoot)
                    return
                }
                let storage = try await Self.kindBackfillStorage(dataRoot: dataRoot)
                let outcome = try await MemoryKindBackfill.apply(rows, storage: storage)
                try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
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
                try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                    id: rec.id,
                    executedAction: .object(["error": .string("\(error)")]),
                    detail: "kind backfill FAILED: \(error.localizedDescription) — stamp cleared; "
                        + "next launch re-stages whatever is still classifiable",
                    root: dataRoot)
            }
        case "denied":
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object(["op": .string("memory_kind_backfill_deny")]),
                detail: "kind backfill denied — rows untouched; will not be re-proposed",
                root: dataRoot)
        default: // canceled
            MemoryKindBackfill.clearStamp(dataRoot: dataRoot)
            try? await ApprovalExecutionAnnotation.annotateApprovalExecution(
                id: rec.id,
                executedAction: .object(["op": .string("memory_kind_backfill_cancel")]),
                detail: "kind backfill canceled — stamp cleared; next launch re-stages it",
                root: dataRoot)
        }
    }

    /// Crash-window reconciliation for memory.kind_backfill (same shape as
    /// reconcileUnappliedMemoryRepairs): resolved records lacking an
    /// execution annotation get the idempotent executor re-run on launch.
    public static func reconcileUnappliedKindBackfills(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        await ApprovalTransactionCoordinator.reconcileUnappliedApprovalExecutions(dataRoot: dataRoot, kinds: [
            ApprovalTransactionCoordinator.ApprovalExecutionReconcileKind(
                action: MemoryKindBackfill.action,
                shouldReconcile: { _ in true },
                execute: { await applyResolvedKindBackfill(from: $0, dataRoot: dataRoot) })
        ])
    }

    /// Storage handle for the kind-backfill surface. Fix-round NIT (gpt-5.5
    /// review, 2026-06-10): prefer the launch-attached SHARED storage —
    /// `SwiftNativeMemoryV2.shared.underlyingBridge().underlyingStorage()` —
    /// so USER.md regen / Spotlight / KG hooks fire on the kind stamps
    /// (same rule as updateMemory/deleteMemory, F2). The shared resolver opens
    /// a private store only for custom roots; an unavailable live owner fails
    /// closed instead of silently creating a hookless default-root fallback.
    private static func kindBackfillStorage(dataRoot: URL) async throws -> MemoryStorage {
        try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
    }

    /// Stages the kind-backfill approval card if the legacy kind-less rows
    /// still exist and no card was staged before (U3 wave-2 item 5).
    /// MemoryV2 never imports ApprovalInbox (module-boundary rule), so the
    /// approval-record create + pending-scan are backed here with
    /// SwiftNativeApprovalInbox closures.
    public static func stageKindBackfillIfNeeded(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        ports: MemoryApprovalTransactionPorts
    ) async {
        let yolo = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
            .fullMacYoloAuthority(
                tool: MemoryKindBackfill.action,
                origin: SecurityOriginContext(
                    surface: "desk",
                    source: "memory_kind_backfill_stager",
                    isRemote: false
                )
            )
        if yolo.state == .explicitlyBlocked {
            writeKindBackfillFullMacOutcome(
                dataRoot: dataRoot,
                status: "refused",
                detail: "memory kind backfill is explicitly blocked; no approval was staged."
            )
            return
        }
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
        let llm = ports.makeLLMClient()
        let routerForPins = SwiftNativeProviderRouting()
        let classifier: @Sendable (String, [String]) async throws -> String = { content, taxonomy in
            if AppleFoundationModelsAdapter.isAvailable {
                return try await MemoryKindBackfill.foundationModelsClassifier(
                    content: content, taxonomy: taxonomy)
            }
            // Surface-scoped resolution (gpt-5.5 review blocker): the
            // surface-less complete() defaults to "chat", whose active.json
            // provider entry can REMAP a pinned model to chat's provider —
            // bypassing the pin. Routing under "memory" keeps the Memory row's
            // own pin and its own provider.
            // User, 2026-09-06: an UNPINNED Memory row used to fall back to the
            // chat surface entirely, so assigning a provider to Memory without
            // also pinning a model did nothing. The Memory row now takes its
            // own surface whenever it says anything (a pin OR an assigned
            // provider). A BLANK row still routes on "chat": on "memory" it
            // would carry no active-provider entry and dispatch would infer the
            // transport from the model prefix, sending Memory to ChatGPT OAuth
            // while chat runs on the Codex CLI or the OpenAI API.
            let surface = await routerForPins.surfaceHasOwnRouting("memory") ? "memory" : "chat"
            let model = await routerForPins.modelStringForSurface(surface)
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
                if yolo.admitted {
                    guard case .object(let object) = body,
                          let payload = object["payload"] else {
                        throw NSError(domain: "MemoryKindBackfill", code: 422, userInfo: [
                            NSLocalizedDescriptionKey: "kind-backfill staging body carries no payload"
                        ])
                    }
                    let timestamp = ISO8601DateFormatter().string(from: Date())
                    let id = "full-mac-yolo-\(UUID().uuidString.lowercased())"
                    let admitted = ApprovalRecord(
                        id: id,
                        title: "Full Mac admitted memory kind backfill",
                        action: MemoryKindBackfill.action,
                        risk: "medium",
                        reason: "Admitted by active Full Mac authority",
                        status: "resolved",
                        payload: payload,
                        payloadPreview: "",
                        createdAt: timestamp,
                        resolvedAt: timestamp,
                        decision: "approved",
                        decidedBy: "full_mac_yolo",
                        remoteResolvable: false,
                        localOnly: true
                    )
                    await applyResolvedKindBackfill(from: admitted, dataRoot: dataRoot)
                    writeKindBackfillFullMacOutcome(
                        dataRoot: dataRoot,
                        status: "admitted",
                        detail: "Executed through the canonical kind-backfill executor without an approval prompt."
                    )
                    return id
                }
                return try await inbox.create(body).id
            },
            listPendingBackfills: {
                if yolo.admitted { return [] }
                return try await inbox.list(
                    filter: ApprovalFilter(status: "pending", action: MemoryKindBackfill.action)
                ).map { (id: $0.id, payload: $0.payload) }
            })
    }

    private static func writeKindBackfillFullMacOutcome(
        dataRoot: URL,
        status: String,
        detail: String
    ) {
        let path = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("kind_backfill.full_mac_outcome.json")
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let value: JSONValue = .object([
            "status": .string(status),
            "detail": .string(detail),
            "at": .string(ISO8601DateFormatter().string(from: Date())),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value) {
            try? data.write(to: path, options: .atomic)
        }
    }
}
