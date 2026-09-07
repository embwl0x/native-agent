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

/// Maps the consolidation owner's raw envelope to the only outcomes MemoryView
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

/// Translates the durable memory writer's receipt into the exact claim the row
/// editor is allowed to make. In particular, an unknown or refused response is
/// not permission to show a completed pin state.
enum MemoryRowEditorPinOutcome: Equatable {
    case applied(pinned: Bool)
    case pendingApproval(pinned: Bool)
    case refused(String)
    case failed(String)

    var message: String {
        switch self {
        case let .applied(pinned):
            return pinned ? "Memory pinned" : "Memory unpinned"
        case let .pendingApproval(pinned):
            return pinned ? "Pin queued for approval" : "Unpin queued for approval"
        case let .refused(detail):
            return "Memory pin change refused: \(detail)"
        case let .failed(detail):
            return "Memory update failed: \(detail)"
        }
    }

    var shouldRefresh: Bool {
        if case .applied = self { return true }
        return false
    }

    var isAdverse: Bool {
        switch self {
        case .refused, .failed: return true
        case .applied, .pendingApproval: return false
        }
    }

    var isPendingApproval: Bool {
        if case .pendingApproval = self { return true }
        return false
    }

    var systemImage: String {
        switch self {
        case .applied: return "checkmark.circle"
        case .pendingApproval: return "clock"
        case .refused, .failed: return "exclamationmark.triangle.fill"
        }
    }

    static func resolve(result: [String: Any], pinned: Bool) -> Self {
        let status = (result["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch status {
        case "ok":
            return .applied(pinned: pinned)
        case "pending_approval":
            return .pendingApproval(pinned: pinned)
        case "refused", "denied":
            return .refused(detail(in: result) ?? "the writer did not authorize this change")
        default:
            return .failed(detail(in: result) ?? "the memory writer returned an unrecognized outcome")
        }
    }

    private static func detail(in result: [String: Any]) -> String? {
        for key in ["reason", "message", "error"] {
            guard let raw = result[key] as? String else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

@MainActor
extension AppModel {
    /// F2: run a semantic recall via the root-resolved SwiftNativeMemoryV2 and project
    /// hits onto the UI's MemoryRecord set (matched by id). Empty/trivial
    /// queries clear the search and revert to `memories`. Falls back to a
    /// substring filter if the embedder is unavailable (Mock) so callers still
    /// see something sensible.
    @MainActor
    func runMemorySemanticSearch(query: String) async {
        let requestToken = memorySearchGate.begin()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        memorySearchResultQuery = trimmed
        memorySearchIsLoading = trimmed.count >= 3
        memorySearchResults = nil
        memorySearchError = nil
        if trimmed.count < 3 {
            memorySearchIsLoading = false
            return
        }
        // Debounce at the request-owner boundary. This lets the view invalidate
        // a prior result immediately, while the generation gate prevents a
        // canceled older query from landing after the newest keystroke.
        do {
            try await Task.sleep(nanoseconds: 150_000_000)
        } catch {
            if memorySearchGate.accepts(requestToken) {
                memorySearchIsLoading = false
            }
            return
        }
        guard !Task.isCancelled, memorySearchGate.accepts(requestToken) else { return }
        // Always seed with a substring filter as a safety net — semantic recall
        // can return zero hits even when an obvious lexical match exists.
        let lower = trimmed.lowercased()
        let lexical = memories.filter {
            $0.text.lowercased().contains(lower) || $0.layer.lowercased().contains(lower)
        }
        do {
            let root = dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let owner = SwiftNativeMemoryV2.resolvedOwner(dataRoot: root)
            // User, 2026-09-06: retrieve WITHOUT crediting use_count. This runs
            // on every keystroke pause and asks for 50 rows, most of which
            // never reach the list below; crediting them made browsing look
            // like use and blunted the eviction veto. The rows actually shown
            // are credited after the mapping.
            let response = try await owner.recall(
                MemoryV2RecallRequest(text: trimmed, topK: 50, persona: nil),
                recordingUsage: false
            )
            // Search resolves canonical records independently of the bounded
            // browsing list. A matching older memory must not disappear just
            // because it is outside the newest 200 rows.
            let hitIDs = response.hits.compactMap { hit -> String? in
                guard case .object(let obj)? = hit.extras,
                      case .string(let id)? = obj["id"] else { return nil }
                return id
            }
            let records = try await client.getMemories(ids: hitIDs)
            var seen = Set<String>()
            var ordered: [MemoryRecord] = []
            var deliveredIDs: [String] = []
            for hit in response.hits {
                var hitId: String? = nil
                if case .object(let obj)? = hit.extras,
                   case .string(let s)? = obj["id"] {
                    hitId = s
                }
                guard let id = hitId, !seen.contains(id),
                      let rec = records.first(where: { $0.id == id })
                else { continue }
                seen.insert(id)
                ordered.append(rec)
                deliveredIDs.append(id)
            }
            // Union with lexical matches (preserving semantic order first) so
            // pure substring hits don't disappear when the embedder is mock /
            // returns weak similarity.
            for rec in lexical where !seen.contains(rec.id) {
                seen.insert(rec.id)
                ordered.append(rec)
            }
            guard !Task.isCancelled, memorySearchGate.accepts(requestToken) else { return }
            memorySearchResults = ordered
            memorySearchError = nil
            memorySearchIsLoading = false
            // Credit exactly what the semantic lane delivered into the list.
            // Fire-and-forget, like recall's own bump: this is a UI path and a
            // dropped bump self-heals on the next serve.
            if !deliveredIDs.isEmpty {
                Task { try? await owner.recordRecallHits(ids: deliveredIDs) }
            }
        } catch {
            guard !Task.isCancelled, memorySearchGate.accepts(requestToken) else { return }
            memorySearchResults = lexical
            memorySearchError = "Semantic memory is unavailable; showing text matches only."
            memorySearchIsLoading = false
        }
    }

    @MainActor
    func pinMemory(_ memory: MemoryRecord, pinned: Bool) async -> MemoryRowEditorPinOutcome {
        do {
            let result = try await client.updateMemory(id: memory.id, pinned: pinned)
            let outcome = MemoryRowEditorPinOutcome.resolve(result: result, pinned: pinned)
            statusText = outcome.message
            if outcome.shouldRefresh {
                await refreshAll()
            }
            if outcome.isAdverse {
                systemToasts.push(error: outcome.message)
            }
            return outcome
        } catch {
            let outcome = MemoryRowEditorPinOutcome.failed(error.localizedDescription)
            statusText = outcome.message
            systemToasts.push(error: statusText)
            return outcome
        }
    }

    @MainActor
    func deleteMemory(_ memory: MemoryRecord) async {
        do {
            let result = try await client.deleteMemory(id: memory.id)
            statusText = (result["status"] as? String) == "pending_approval" ? "Delete queued for approval" : "Memory deleted"
            await refreshAll()
        } catch {
            statusText = "Memory delete failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    @discardableResult
    func consolidateMemory() async -> MemoryMenuActionFeedback {
        do {
            let result = try await client.consolidateMemory()
            return await applyMemoryConsolidationResult(result)
        } catch let err as NSError where (err.userInfo["code"] as? String) == "not_implemented" {
            let reason = (err.userInfo["reason"] as? String) ?? "feature not yet available"
            memoryFeatureDisabledMessage = "Consolidate disabled — \(reason)"
            statusText = memoryFeatureDisabledMessage ?? "Consolidate disabled"
            return .unavailable(statusText)
        } catch {
            statusText = "Memory consolidation failed: \(error.localizedDescription)"
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

    @MainActor
    @discardableResult
    func runMemoryHygiene(dryRun: Bool = false) async -> MemoryMenuActionFeedback {
        do {
            let result = try await client.runMemoryHygiene(dryRun: dryRun)
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
            statusText = "Memory hygiene failed: \(error.localizedDescription)"
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
