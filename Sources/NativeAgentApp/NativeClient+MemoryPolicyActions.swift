import Foundation
import Darwin
import AppKit
@preconcurrency import EventKit
import SwiftUI
import NativeAgentShared
import PersistenceCore
import NativeAgentCore
import MemoryV2
import ToolRegistry
import KnowledgeGraph
import XConnector
import SlackConnector
import ProviderRouting
import BackgroundLoops
import ApprovalInbox
import MCPDispatcher
import ToolExecution
import PersonaEngine
import ChatOrchestration
import TrustCenter
import DreamREMCycle
import DoctorChecks
import CommandPalette
import SelfImprovement
import Research
import MultimodalTTS
import TriggerScheduler
import WorkshopExecution
import NotificationInbox
import SystemOps
import ScreenVision
import TelegramBot
import Dispatcher
import MacControl
import Onboarding
import MacAssistantStatus
import WorkflowOrchestration
import Skills
import Connectors
import Browser
import CapabilityFoundry


extension NativeClient {
    func getMemoryProposals() async throws -> [MemoryProposalRecord] {
        // Swift-native MemoryV2 source of truth is SQLite. The old
        // <dataRoot>/memory/proposals.jsonl path disappeared with the daemon,
        // so listing from it made the Mac/iOS review surfaces permanently empty.
        let proposals = try await SwiftNativeMemoryV2.shared.listProposals(status: "pending")
        return proposals.compactMap { proposal in
            Self.memoryProposalPresentationRecord(
                id: proposal.id,
                content: proposal.content,
                source: proposal.source,
                status: proposal.status,
                createdAt: proposal.createdAt,
                rejectionReason: proposal.rejectionReason,
                metadata: proposal.metadata
            )
        }
    }

    /// Pending rows can predate the current quality contract. Keep them out of
    /// every review surface unless they still pass the same gate used by new
    /// proposals and acceptance. The row remains available to the approval-
    /// gated hygiene pass for tombstoning; it cannot be accidentally accepted.
    static func memoryProposalPresentationRecord(
        id: String,
        content: String,
        source: String?,
        status: String,
        createdAt: String,
        rejectionReason: String?,
        metadata: JSONValue?
    ) -> MemoryProposalRecord? {
        let kind: String? = {
            guard case .object(let metadata)? = metadata,
                  case .string(let value)? = metadata["kind"] else {
                return nil
            }
            return value
        }()
        guard MemoryCandidateQuality.isDurableCandidate(
            text: content,
            source: source,
            kind: kind
        ) else {
            return nil
        }

        let evidence = memoryProposalEvidence(source: source, metadata: metadata)
        return MemoryProposalRecord(
            proposal_id: id,
            fact_text: content,
            display_text: nil,
            supporting_session_ids: evidence.sessionIDs,
            recurrence_count: evidence.recurrenceCount,
            first_seen: createdAt,
            last_seen: createdAt,
            status: status,
            staged_at: createdAt,
            resolved_at: nil,
            rejection_reason: rejectionReason
        )
    }

    static func memoryProposalEvidence(
        source: String?,
        metadata: JSONValue?
    ) -> (sessionIDs: [String], recurrenceCount: Int) {
        var sessionIDs: [String] = []
        var recurrenceCount: Int?
        if case .object(let object)? = metadata {
            if case .array(let values)? = object["supporting_session_ids"] {
                sessionIDs = values.compactMap { value in
                    guard case .string(let raw) = value else { return nil }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
            }
            switch object["recurrence_count"] {
            case .int(let value)?: recurrenceCount = Int(value)
            case .double(let value)?: recurrenceCount = Int(value)
            case .string(let value)?: recurrenceCount = Int(value)
            default: break
            }
        }
        if sessionIDs.isEmpty,
           let source,
           source.lowercased().hasPrefix("adaptive-promoter:") {
            let sessionID = String(source.dropFirst("adaptive-promoter:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sessionID.isEmpty { sessionIDs = [sessionID] }
        }
        sessionIDs = Array(Set(sessionIDs)).sorted()
        return (sessionIDs, max(1, recurrenceCount ?? 1))
    }

    // FINAL/F1 (2026-06-03): daemon-dead PORT. SwiftNativeMemoryV2.shared.acceptProposal
    // (MemoryV2+Wiring.swift:191) re-runs the tombstone gate, promotes via
    // storage.insert + storage.updateProposalStatus — the same lifecycle the
    // daemon's POST /v1/memory/proposals/<id>/approve walked.
    func approveMemoryProposal(id: String) async throws -> [String: Any] {
        let record = try await SwiftNativeMemoryV2.shared.acceptProposal(id: id)
        var out: [String: Any] = [
            "ok": true,
            "id": record.id,
            "text": record.text,
            "createdAt": record.createdAt,
        ]
        if let v = record.layer { out["layer"] = v }
        if let v = record.updatedAt { out["updatedAt"] = v }
        if let v = record.status { out["status"] = v }
        if let v = record.sourceRunId { out["sourceRunId"] = v }
        return out
    }

    func rejectMemoryProposal(id: String, reason: String) async throws -> [String: Any] {
        _ = try await SwiftNativeMemoryV2.shared.rejectProposal(
            id: id,
            reason: reason.isEmpty ? nil : reason
        )
        return ["ok": true, "id": id, "status": "rejected"]
    }

    // FINAL/F1 (2026-06-03): daemon-dead PORT (commit path) + STUB (dry-run path).
    // MemoryConsolidator (MemoryV2+Consolidator.swift:60) runs the same
    // dedupe/auto-accept/archive pipeline the daemon's
    // POST /v1/memory/living/consolidate ran, but it has no `dryRun`
    // counterpart. Honor `dryRun=false` with a real run and `dryRun=true` with
    // a read-only preview of active memories + pending proposals.
    func triggerMemoryConsolidation(dryRun: Bool) async throws -> [String: Any] {
        let dataRoot = PersistenceCore.defaultDataRoot()
        let storage = try MemoryStorage(dataRoot: dataRoot)
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
