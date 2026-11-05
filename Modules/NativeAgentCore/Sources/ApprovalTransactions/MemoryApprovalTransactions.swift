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
    /// Apply through the memory owner's content-hash guard so changed rows stay untouched. Denial keeps its staging stamp to prevent re-proposal; cancellation
    /// clears it. Failures retain the decision for repair and the shared owner retains outcomes until receipted.
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
                ]), detail: """
                    kind backfill applied: \(outcome.applied.count) rows stamped, \(outcome.skippedStale.count) stale-skipped, \
                    \(outcome.failed.count) failed
                    """)
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

    /// Stage kind-less rows only once through this root's canonical inbox, including automatic Full Mac applications.
    public static func stageKindBackfillIfNeeded(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        makeLLMClient: @Sendable (PrivateWorkContextAssembly) -> any LLMClient
    ) async {
        let yolo = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
            .fullMacYoloAuthority(
                origin: SecurityOriginContext(
                    surface: "desk",
                    source: "memory_kind_backfill_stager",
                    isRemote: false
                ), turn: nil
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
        // Prefer on-device classification; remote classification uses the resolved Memory route. Both accept only an exact supplied category.
        let llm = makeLLMClient(.taskOnly)
        let classifier: @Sendable (String, [String]) async throws -> String = { content, taxonomy in
            if OnDeviceClassification.isAvailable {
                return try await MemoryKindBackfill.foundationModelsClassifier(
                    content: content, taxonomy: taxonomy)
            }
            let raw = try await llm.complete(
                prompt: OnDeviceClassification.classifyPrompt(content: content, categories: taxonomy),
                system: try completionPolicy("kind-classification", section: "system"), model: nil, tools: nil,
                call: LLMCall(turn: nil, surface: "memory", purpose: "kind_backfill"))
            return try OnDeviceClassification.matchCategory(reply: raw, categories: taxonomy)
        }
        _ = await MemoryKindBackfill.stageIfNeeded(
            dataRoot: dataRoot,
            storage: storage,
            classifier: classifier,
            createApproval: { body in
                // Classification may outlive a Trust change. Admission and the canonical writes share Trust's existing policy-file lock.
                try await SwiftNativePersistenceCore.withFileLock(SwiftNativeTrustCenter.policyURL(dataRoot: dataRoot)) {
                    let yolo = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
                        .fullMacYoloAuthority(origin: SecurityOriginContext(
                            surface: "desk", source: "memory_kind_backfill_stager", isRemote: false), turn: nil)
                    if yolo.state == .explicitlyBlocked {
                        throw NSError(domain: "MemoryKindBackfill", code: 403, userInfo: [
                            NSLocalizedDescriptionKey: yolo.reason
                        ])
                    }
                    if yolo.admitted {
                        let staged = try await inbox.create(body, turn: nil)
                        let admitted = try await inbox.resolve(staged.id, decision: .approved,
                            provenance: .local(decidedBy: "full_mac_yolo"))
                        await applyResolvedKindBackfill(from: admitted, dataRoot: dataRoot)
                        return admitted.id
                    }
                    return try await inbox.create(body, turn: nil).id
                }
            },
            approvalIsPending: { id in try await inbox.get(id).status == "pending" },
            listPendingBackfills: {
                let yolo = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
                    .fullMacYoloAuthority(origin: SecurityOriginContext(
                        surface: "desk", source: "memory_kind_backfill_stager", isRemote: false), turn: nil)
                if yolo.admitted { return [] }
                return try await inbox.list(
                    filter: ApprovalFilter(status: "pending", action: MemoryKindBackfill.action)
                ).map { (id: $0.id, payload: $0.payload) }
            })
    }
}
