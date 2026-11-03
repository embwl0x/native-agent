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
    /// re-proposed). Cancellation clears the stamp. Application/read failures
    /// preserve the same decision for repair; the shared approval owner keeps
    /// the returned outcome through its execution-receipt write.
    public static func applyResolvedKindBackfill(
        from rec: ApprovalRecord,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) async {
        guard rec.action == MemoryKindBackfill.action,
              rec.status == "resolved",
              let decision = rec.decision else { return }
        await ApprovalExecutionOwners.perform(rec, dataRoot: dataRoot) {
            switch decision {
            case "approved":
                let rows = MemoryKindBackfill.rowProposals(fromPayload: rec.payload)
                guard !rows.isEmpty else {
                    throw ApprovalInboxError.malformedResponse("kind-backfill payload carries no row proposals")
                }
                let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
                let outcome = try await MemoryKindBackfill.apply(rows, storage: storage)
                return .init(action: .object([
                    "op": .string("memory_kind_backfill"),
                    "applied": .array(outcome.applied.map { .string($0) }),
                    "skippedStale": .array(outcome.skippedStale.map { .string($0) }),
                    "failed": .object(outcome.failed.mapValues { .string($0) }),
                ]), detail: "kind backfill applied: \(outcome.applied.count) rows stamped, \(outcome.skippedStale.count) stale-skipped, \(outcome.failed.count) failed")
            case "denied":
                return .init(action: .object(["op": .string("memory_kind_backfill_deny")]),
                    detail: "kind backfill denied — rows untouched")
            case "canceled":
                MemoryKindBackfill.clearStamp(dataRoot: dataRoot)
                return .init(action: .object(["op": .string("memory_kind_backfill_cancel")]),
                    detail: "kind backfill canceled — next launch may stage a fresh card")
            default: throw ApprovalInboxError.malformedResponse("invalid kind-backfill decision: \(decision)")
            }
        }
    }

    /// Stages the kind-backfill approval card if the legacy kind-less rows
    /// still exist and no card was staged before (U3 wave-2 item 5).
    /// Canonical approval creation, Full Mac admission and the pending-card
    /// check use this root's inbox, including automatic applications.
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
                        let staged = try await inbox.create(body)
                        let admitted = try await inbox.resolve(staged.id, decision: .approved,
                            provenance: .local(decidedBy: "full_mac_yolo"))
                        await applyResolvedKindBackfill(from: admitted, dataRoot: dataRoot)
                        return admitted.id
                    }
                    return try await inbox.create(body).id
                }
            },
            approvalIsPending: { id in try await inbox.get(id).status == "pending" },
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
