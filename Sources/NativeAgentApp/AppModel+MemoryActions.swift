import Foundation
import Observation
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

/// The Memory actions menu has one explicit receipt vocabulary. A completed
/// maintenance run, a staged approval, a refusal, and an unavailable writer
/// must not collapse into the generic application status line.
enum MemoryMenuActionFeedback: Equatable {
    case completed(String)
    case pendingApproval(String)
    case unavailable(String)
    case refused(String)
    case failed(String)

    var message: String {
        switch self {
        case let .completed(message), let .pendingApproval(message),
             let .unavailable(message), let .refused(message), let .failed(message):
            return message
        }
    }

    var isAdverse: Bool {
        switch self {
        case .unavailable, .refused, .failed:
            return true
        case .completed, .pendingApproval:
            return false
        }
    }
}

/// Maps the consolidation owner's raw envelope to the only outcomes the memory upkeep
/// may present. A deliberately disabled implementation is not a successful
/// no-op and must not trigger a refresh that can overwrite its warning badge.
struct MemoryConsolidationPresentation: Equatable {
    let disabledMessage: String?
    let statusText: String
    let shouldRefresh: Bool
    let feedback: MemoryMenuActionFeedback

    static func resolve(result: [String: Any]) -> Self {
        if (result["panelDisabled"] as? Bool == true)
            || (result["code"] as? String) == "not_implemented" {
            let reason = (result["reason"] as? String) ?? "feature not yet available"
            let message = "Consolidate disabled — \(reason)"
            return Self(
                disabledMessage: message,
                statusText: message,
                shouldRefresh: false,
                feedback: .unavailable(message)
            )
        }

        let errors = (result["errors"] as? [String]) ?? []
        let status: String
        let feedback: MemoryMenuActionFeedback
        if (result["status"] as? String) == "pending_approval" {
            status = "Memory consolidation queued for approval"
            feedback = .pendingApproval(status)
        } else if (result["status"] as? String) == "refused" {
            status = "Memory consolidation refused: candidate scored below live on the probe set"
            feedback = .refused(status)
        } else if !errors.isEmpty {
            status = "Memory consolidation finished with errors: \(errors.prefix(2).joined(separator: "; "))"
            feedback = .failed(status)
        } else {
            status = "Memory consolidation: no changes needed"
            feedback = .completed(status)
        }
        return Self(
            disabledMessage: nil,
            statusText: status,
            shouldRefresh: true,
            feedback: feedback
        )
    }
}

/// The row editor's claim about a pin change: made, or failed and why.
enum MemoryRowEditorPinOutcome: Equatable {
    case applied(pinned: Bool)
    case failed(String)

    var message: String {
        switch self {
        case let .applied(pinned):
            return pinned ? "Memory pinned" : "Memory unpinned"
        case let .failed(detail):
            return detail
        }
    }

    var isAdverse: Bool {
        if case .failed = self { return true }
        return false
    }

    var systemImage: String {
        switch self {
        case .applied: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
extension AppModel {
    @MainActor
    func pinMemory(_ memory: MemoryV2.MemoryRecord, pinned: Bool) async -> MemoryRowEditorPinOutcome {
        do {
            try await engine.memory.setPinned(pinned, id: memory.id)
            let outcome = MemoryRowEditorPinOutcome.applied(pinned: pinned)
            statusText = outcome.message
            await refreshAll()
            return outcome
        } catch {
            let outcome = MemoryRowEditorPinOutcome.failed(
                UserFacingError.message(error, action: "update that memory")
            )
            statusText = outcome.message
            systemToasts.push(error: statusText)
            return outcome
        }
    }

    /// False when the memory is still there; `statusText` says why.
    @MainActor
    func deleteMemory(_ memory: MemoryV2.MemoryRecord) async -> Bool {
        do {
            try await engine.memory.delete(id: memory.id)
            statusText = "Memory deleted"
            await refreshAll()
            return true
        } catch {
            setFailureStatus(error, action: "forget that memory")
            return false
        }
    }

    // Dry runs preview active memories and pending proposals; commit requests
    // use the consolidator's approval-gated path.
    nonisolated static func runMemoryConsolidation(dataRoot: URL, dryRun: Bool) async throws -> [String: Any] {
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
                processed: 0, duplicatesMerged: 0,
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
            "duplicates_merged": report.duplicatesMerged,
            "pending_for_review": report.pendingForReview,
            "stale_archived": report.staleArchived,
            "errors": report.errors,
        ]
        envelope.merge(extra) { _, new in new }
        return envelope
    }

    @MainActor
    @discardableResult
    func consolidateMemory() async -> MemoryMenuActionFeedback {
        do {
            let result = try await Self.runMemoryConsolidation(dataRoot: engine.dataRoot, dryRun: false)
            return await applyMemoryConsolidationResult(result)
        } catch let err as NSError where (err.userInfo["code"] as? String) == "not_implemented" {
            let reason = (err.userInfo["reason"] as? String) ?? "feature not yet available"
            memoryFeatureDisabledMessage = "Consolidate disabled — \(reason)"
            statusText = memoryFeatureDisabledMessage ?? "Consolidate disabled"
            return .unavailable(statusText)
        } catch {
            setFailureStatus(error, action: "consolidate memory")
            return .failed(statusText)
        }
    }

    /// Shared result application used by the mounted Consolidate command and
    /// by the runtime evaluation seam. Keeping disabled handling here prevents
    /// a raw envelope from being rendered as a successful maintenance run.
    @discardableResult
    func applyMemoryConsolidationResult(_ result: [String: Any]) async -> MemoryMenuActionFeedback {
        let presentation = MemoryConsolidationPresentation.resolve(result: result)
        memoryFeatureDisabledMessage = presentation.disabledMessage
        statusText = presentation.statusText
        if presentation.shouldRefresh {
            await refreshForSidebarItem(.memories)
        }
        return presentation.feedback
    }

    /// The manual hygiene path: the Swift MemoryV2 consolidator handles
    /// tombstones, duplicate proposal merges, high-durability auto-accepts,
    /// and stale active-memory archive. A dry run previews counts only.
    nonisolated static func memoryHygieneReport(dataRoot root: URL, dryRun: Bool) async throws -> MemoryHygieneReport {

        if dryRun {
            let storage = try await SwiftNativeMemoryV2.resolvedStorage(dataRoot: root)
            let before = (try? await storage.listMemories(persona: nil, status: nil, limit: nil).count) ?? 0
            let pending = (try? await storage.listProposals(status: "pending").count) ?? 0
            let now = Date()
            let nowISO = SwiftNativeManifestSigner.isoTimestamp(now)
            let nextISO = SwiftNativeManifestSigner.isoTimestamp(now.addingTimeInterval(7 * 24 * 3600))
            return MemoryHygieneReport(
                id: "hygiene-preview-\(UUID().uuidString.lowercased())",
                status: "dry_run",
                reason: "Preview only; no memory records were changed.",
                version: "swift-memory-v2-consolidator",
                createdAt: nowISO,
                beforeCount: before,
                afterCount: before,
                normalized: pending,
                archivedDuplicates: nil,
                archivedReflections: nil,
                distilledFactsAdded: nil,
                decayedMemories: nil,
                proposalHygiene: MemoryProposalHygiene(rejectedLowValue: nil, nearDuplicates: nil),
                consolidationRunId: nil,
                nextScheduled: nextISO
            )
        }

        // U3 wave-1 item 6 + review blocker (2026-06-10): this is the ONLY
        // direct-consolidate entry point, and both of its callers carry an
        // explicit approval — the Memories upkeep "Run hygiene" button (manual
        // human action) and applyApprovedSelfImprovement's approved
        // run_memory_hygiene op. The weekly tick calls runOnce itself
        // (MemoryConsolidationHygieneRunner, 2026-09-22).
        return try await MemoryConsolidationHygiene.runOnce(
            dataRoot: root, approvedDirectRun: true)
    }

    @MainActor
    @discardableResult
    func runMemoryHygiene(dryRun: Bool = false) async -> MemoryMenuActionFeedback {
        do {
            let result = try await Self.memoryHygieneReport(dataRoot: engine.dataRoot, dryRun: dryRun)
            latestMemoryHygiene = result
            memoryFeatureDisabledMessage = nil
            let summary = Self.memoryHygieneRunSummary(result, dryRun: dryRun)
            statusText = summary
            if dryRun || result.status == "staged" {
                // Staged ≠ applied: an info toast, not a green success.
                systemToasts.push(info: summary, autoDismissAfter: 5)
            } else if result.status == "refused" {
                systemToasts.push(warn: summary, autoDismissAfter: 6)
            } else {
                systemToasts.push(success: summary, autoDismissAfter: 5)
            }
            await refreshForSidebarItem(.memories)
            switch result.status {
            case "staged":
                return .pendingApproval(summary)
            case "refused":
                return .refused(summary)
            default:
                return .completed(summary)
            }
        } catch let err as NSError where (err.userInfo["code"] as? String) == "not_implemented" {
            let reason = (err.userInfo["reason"] as? String) ?? "feature not yet available"
            memoryFeatureDisabledMessage = "Hygiene disabled — \(reason)"
            statusText = memoryFeatureDisabledMessage ?? "Hygiene disabled"
            systemToasts.push(warn: statusText, autoDismissAfter: 6)
            return .unavailable(statusText)
        } catch {
            setFailureStatus(error, action: "tidy up memory")
            systemToasts.push(error: statusText)
            return .failed(statusText)
        }
    }

    private static func memoryHygieneRunSummary(
        _ result: MemoryHygieneReport,
        dryRun: Bool
    ) -> String {
        let before = result.beforeCount ?? result.afterCount ?? 0
        let processed = result.normalized ?? 0
        let merged = result.archivedDuplicates ?? 0
        let archived = result.archivedReflections ?? 0
        let accepted = result.distilledFactsAdded ?? 0
        let decayed = result.decayedMemories ?? 0
        let changed = merged + archived + accepted + decayed
        let scanned = "scanned \(before) \(before == 1 ? "memory" : "memories") / \(processed) \(processed == 1 ? "proposal" : "proposals")"
        if dryRun {
            return "Memory hygiene preview: \(scanned)"
        }
        var parts: [String] = []
        if merged > 0 { parts.append("merged \(merged)") }
        if archived > 0 { parts.append("archived \(archived)") }
        if accepted > 0 { parts.append("accepted \(accepted)") }
        if decayed > 0 { parts.append("decayed \(decayed)") }
        // Honest-status fix (2026-07-24): consolidation stages an approval
        // card; nothing is applied until User approves it. "complete: merged 3"
        // over a pending card claimed work that hadn't happened.
        if result.status == "staged" {
            let planned = parts.isEmpty ? "changes" : parts.joined(separator: ", ")
            return "Memory hygiene staged for approval: \(scanned); planned \(planned) — approve in Activity to apply"
        }
        if result.status == "refused" {
            return "Memory hygiene refused to stage: \(result.reason ?? "candidate scored below live on the probe set")"
        }
        if changed == 0 {
            return "Memory hygiene complete: \(scanned); no cleanup needed"
        }
        return "Memory hygiene complete: \(scanned); \(parts.joined(separator: ", "))"
    }

}
