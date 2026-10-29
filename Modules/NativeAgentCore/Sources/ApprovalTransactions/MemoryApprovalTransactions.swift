import Foundation
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
import MemoryV2
import ProviderRouting
import TrustCenter
import DreamREMCycle
import NativeAgentShared
// Blueprint: | `MemoryApprovalTransactions.swift` | `MemoryApprovalTransactions` enum; `applyResolvedKindBackfill`, `stageKindBackfillIfNeeded` |

public enum MemoryApprovalTransactions {
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
                    // Clear the malformed card's stamp before annotating failure so future staging remains possible.
                    MemoryKindBackfill.clearStamp(dataRoot: dataRoot)
                    try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                        rec.id,
                        executedAction: .object(["error": .string("payload carries no row proposals")]),
                        detail: "kind backfill FAILED: payload carries no row proposals — "
                            + "stamp cleared; next launch re-stages whatever is still classifiable")
                    return
                }
                let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
                let outcome = try await MemoryKindBackfill.apply(rows, storage: storage)
                try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                    rec.id,
                    executedAction: .object([
                        "op": .string("memory_kind_backfill"),
                        "applied": .array(outcome.applied.map { .string($0) }),
                        "skippedStale": .array(outcome.skippedStale.map { .string($0) }),
                        "failed": .object(outcome.failed.mapValues { .string($0) }),
                    ]),
                    detail: "kind backfill applied: \(outcome.applied.count) rows stamped"
                        + (outcome.skippedStale.isEmpty ? "" : ", \(outcome.skippedStale.count) stale-skipped")
                        + (outcome.failed.isEmpty ? "" : ", \(outcome.failed.count) FAILED"))
            } catch {
                nativeLog("[kindBackfill] apply failed: \(String(describing: error))")
                MemoryKindBackfill.clearStamp(dataRoot: dataRoot)
                try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                    rec.id,
                    executedAction: .object(["error": .string("\(error)")]),
                    detail: "kind backfill FAILED: \(error.localizedDescription) — stamp cleared; "
                        + "next launch re-stages whatever is still classifiable")
            }
        case "denied":
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object(["op": .string("memory_kind_backfill_deny")]),
                detail: "kind backfill denied — rows untouched; will not be re-proposed")
        default: // canceled
            MemoryKindBackfill.clearStamp(dataRoot: dataRoot)
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: .object(["op": .string("memory_kind_backfill_cancel")]),
                detail: "kind backfill canceled — stamp cleared; next launch re-stages it")
        }
    }

    /// Stages the kind-backfill approval card if the legacy kind-less rows
    /// still exist and no card was staged before (U3 wave-2 item 5).
    /// MemoryV2 never imports ApprovalInbox (module-boundary rule), so the
    /// approval-record create + pending-scan are backed here with
    /// SwiftNativeApprovalInbox closures.
    public static func stageKindBackfillIfNeeded(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        makeLLMClient: @Sendable () -> any LLMClient
    ) async {
        let yolo = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
            .fullMacYoloAuthority(
                origin: SecurityOriginContext(
                    surface: "desk",
                    source: "memory_kind_backfill_stager",
                    isRemote: false
                )
            )
        if yolo.state == .explicitlyBlocked {
            return
        }
        let storage: MemoryStorage
        do {
            storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        } catch {
            nativeLog("[kindBackfill] storage open failed; staging skipped: \(String(describing: error))")
            return
        }
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        // Prefer on-device classification; remote classification uses the resolved Memory route.
        // Both accept only an exact supplied category.
        let llm = makeLLMClient()
        let classifier: @Sendable (String, [String]) async throws -> String = { content, taxonomy in
            if OnDeviceClassification.isAvailable {
                return try await MemoryKindBackfill.foundationModelsClassifier(
                    content: content, taxonomy: taxonomy)
            }
            let raw = try await PrivateWorkContextAssembly.$current.withValue(.taskOnly) {
                try await llm.complete(
                    prompt: OnDeviceClassification.classifyPrompt(content: content, categories: taxonomy),
                    system: try completionPolicy("kind-classification", section: "system"), model: nil, surface: "memory", purpose: "kind_backfill", tools: nil)
            }
            return try OnDeviceClassification.matchCategory(reply: raw, categories: taxonomy)
        }
        _ = await MemoryKindBackfill.stageIfNeeded(
            dataRoot: dataRoot,
            storage: storage,
            classifier: classifier,
            createApproval: { body in
                // Classification may outlive a Trust change. Admission and the
                // canonical writes share Trust's existing policy-file lock.
                try await SwiftNativePersistenceCore.withFileLock(SavedTrustPolicyAuthority.policyURL(dataRoot: dataRoot)) {
                    let yolo = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
                        .fullMacYoloAuthority(origin: SecurityOriginContext(
                            surface: "desk", source: "memory_kind_backfill_stager", isRemote: false))
                    if yolo.state == .explicitlyBlocked {
                        throw NSError(domain: "MemoryKindBackfill", code: 403, userInfo: [
                            NSLocalizedDescriptionKey: yolo.reason
                        ])
                    }
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
                        return id
                    }
                    return try await inbox.create(body).id
                }
            },
            listPendingBackfills: {
                let yolo = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
                    .fullMacYoloAuthority(origin: SecurityOriginContext(
                        surface: "desk", source: "memory_kind_backfill_stager", isRemote: false))
                if yolo.admitted { return [] }
                return try await inbox.list(
                    filter: ApprovalFilter(status: "pending", action: MemoryKindBackfill.action)
                ).map { (id: $0.id, payload: $0.payload) }
            })
    }
}
