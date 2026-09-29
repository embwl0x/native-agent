import Foundation
import PersistenceCore
import NativeAgentCore
import MemoryV2
import TrustCenter


extension NativeClient {
    // Dry runs preview active memories and pending proposals; commit requests
    // use the consolidator's approval-gated path.
    func triggerMemoryConsolidation(dryRun: Bool) async throws -> [String: Any] {
        let dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: dataRoot)
        if dryRun {
            let active = (try? await storage.listMemories(persona: nil, status: "active", limit: nil).count) ?? 0
            let pending = (try? await storage.listProposals(status: "pending").count) ?? 0
            return [
                "ok": true,
                "dry_run": true,
                "processed": pending,
                "active_memories": active,
                "pending_proposals": pending,
                "detail": "Preview only; no memory records were changed.",
            ]
        }
        let consolidator = MemoryConsolidator(storage: storage)
        // Honest-status fix (2026-07-24): consolidation is gated — it stages
        // an approval card and never mutates the live store here. Surface the
        // real outcome so the UI can say "queued for approval" instead of
        // reporting planned counters as applied work.
        let outcome = try await consolidator.consolidateGated()
        let report: MemoryV2.ConsolidationReport
        var extra: [String: Any] = [:]
        switch outcome {
        case .staged(let approvalId, _, _, let plan):
            report = plan
            extra["status"] = "pending_approval"
            extra["approval_id"] = approvalId
        case .alreadyStaged(let approvalId):
            report = MemoryV2.ConsolidationReport(
                processed: 0, autoAccepted: 0, duplicatesMerged: 0,
                pendingForReview: 0, staleArchived: 0, errors: [])
            extra["status"] = "pending_approval"
            extra["approval_id"] = approvalId
        case .refusedRegression(_, let plan):
            report = plan
            extra["status"] = "refused"
        case .noChanges(let plan):
            report = plan
        }
        var envelope: [String: Any] = [
            "ok": true,
            "processed": report.processed,
            "auto_accepted": report.autoAccepted,
            "duplicates_merged": report.duplicatesMerged,
            "pending_for_review": report.pendingForReview,
            "stale_archived": report.staleArchived,
            "errors": report.errors,
        ]
        envelope.merge(extra) { _, new in new }
        return envelope
    }

    func saveMemoryPolicy(consolidationEnabled: Bool, crossSessionRecall: Bool, autoPromoteConsolidated: Bool) async throws -> TrustPolicy {
        let body: [String: Any] = [
            "memoryPolicy": [
                "consolidation_enabled": consolidationEnabled,
                "cross_session_recall": crossSessionRecall,
                "auto_promote_consolidated": autoPromoteConsolidated,
            ]
        ]
        return try await postTrustWrite(body: body)
    }

    func patchMemoryPolicy(
        knowledgeGraphEnabled: Bool? = nil,
        adaptivePromotion: Bool? = nil,
        hygieneEnabled: Bool? = nil,
        archiveNoisyReflections: Bool? = nil,
        rejectLowValueProposals: Bool? = nil
    ) async throws -> TrustPolicy {
        var memoryPolicy: [String: Any] = [:]
        if let knowledgeGraphEnabled {
            memoryPolicy["knowledge_graph_enabled"] = knowledgeGraphEnabled
        }
        if let adaptivePromotion {
            memoryPolicy["adaptive_promotion"] = adaptivePromotion
        }
        if let hygieneEnabled {
            memoryPolicy["hygiene_enabled"] = hygieneEnabled
        }
        if let archiveNoisyReflections {
            memoryPolicy["archive_noisy_reflections"] = archiveNoisyReflections
        }
        if let rejectLowValueProposals {
            memoryPolicy["reject_low_value_proposals"] = rejectLowValueProposals
        }
        let body: [String: Any] = ["memoryPolicy": memoryPolicy]
        return try await postTrustWrite(body: body)
    }
}
