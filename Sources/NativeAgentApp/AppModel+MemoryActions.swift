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
import CapabilityFoundry

@MainActor
extension AppModel {
    /// F2: run a semantic recall via SwiftNativeMemoryV2.shared and project
    /// hits onto the UI's MemoryRecord set (matched by id). Empty/trivial
    /// queries clear the search and revert to `memories`. Falls back to a
    /// substring filter if the embedder is unavailable (Mock) so callers still
    /// see something sensible.
    @MainActor
    func runMemorySemanticSearch(query: String) async {
        let requestToken = memorySearchGate.begin()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 3 {
            memorySearchResults = nil
            memorySearchError = nil
            return
        }
        // Always seed with a substring filter as a safety net — semantic recall
        // can return zero hits even when an obvious lexical match exists.
        let lower = trimmed.lowercased()
        let lexical = memories.filter {
            $0.text.lowercased().contains(lower) || $0.layer.lowercased().contains(lower)
        }
        do {
            let response = try await SwiftNativeMemoryV2.shared.recall(
                MemoryV2RecallRequest(text: trimmed, topK: 50, persona: nil)
            )
            // Map each recall hit's id back onto the UI's MemoryRecord. Hits
            // carry their record id under `extras.id` (see Wiring.recall).
            var seen = Set<String>()
            var ordered: [MemoryRecord] = []
            for hit in response.hits {
                var hitId: String? = nil
                if case .object(let obj)? = hit.extras,
                   case .string(let s)? = obj["id"] {
                    hitId = s
                }
                guard let id = hitId, !seen.contains(id),
                      let rec = memories.first(where: { $0.id == id })
                else { continue }
                seen.insert(id)
                ordered.append(rec)
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
        } catch {
            guard !Task.isCancelled, memorySearchGate.accepts(requestToken) else { return }
            memorySearchResults = lexical
            memorySearchError = "Semantic memory is unavailable; showing text matches only."
        }
    }

    @MainActor
    func pinMemory(_ memory: MemoryRecord, pinned: Bool) async {
        do {
            let result = try await client.updateMemory(id: memory.id, pinned: pinned)
            if (result["status"] as? String) == "pending_approval" {
                statusText = pinned ? "Pin queued for approval" : "Unpin queued for approval"
            } else {
                statusText = pinned ? "Memory pinned" : "Memory unpinned"
            }
            await refreshAll()
        } catch {
            statusText = "Memory update failed: \(error.localizedDescription)"
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
    func consolidateMemory() async {
        do {
            let result = try await client.consolidateMemory()
            // F2: honour the `panelDisabled / code:"not_implemented"` envelope so the
            // UI shows a "feature disabled" badge instead of a fake success toast.
            if (result["panelDisabled"] as? Bool == true)
                || (result["code"] as? String) == "not_implemented" {
                let reason = (result["reason"] as? String) ?? "feature not yet available"
                memoryFeatureDisabledMessage = "Consolidate disabled — \(reason)"
                statusText = memoryFeatureDisabledMessage ?? "Consolidate disabled"
                return
            }
            memoryFeatureDisabledMessage = nil
            let errors = (result["errors"] as? [String]) ?? []
            if (result["status"] as? String) == "pending_approval" {
                statusText = "Memory consolidation queued for approval"
            } else if (result["status"] as? String) == "refused" {
                // gpt-5.5 review (2026-07-24 MED): a probe-gate refusal fell
                // into the success branch and read "removed 0".
                statusText = "Memory consolidation refused: candidate scored below live on the probe set"
            } else if !errors.isEmpty {
                statusText = "Memory consolidation finished with errors: \(errors.prefix(2).joined(separator: "; "))"
            } else {
                // Only the gate's .noChanges outcome reaches here (staged and
                // refused take the branches above), so say that plainly.
                statusText = "Memory consolidation: no changes needed"
            }
            await refreshAll()
        } catch let err as NSError where (err.userInfo["code"] as? String) == "not_implemented" {
            let reason = (err.userInfo["reason"] as? String) ?? "feature not yet available"
            memoryFeatureDisabledMessage = "Consolidate disabled — \(reason)"
            statusText = memoryFeatureDisabledMessage ?? "Consolidate disabled"
        } catch {
            statusText = "Memory consolidation failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func runMemoryHygiene(dryRun: Bool = false) async {
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
        } catch let err as NSError where (err.userInfo["code"] as? String) == "not_implemented" {
            let reason = (err.userInfo["reason"] as? String) ?? "feature not yet available"
            memoryFeatureDisabledMessage = "Hygiene disabled — \(reason)"
            statusText = memoryFeatureDisabledMessage ?? "Hygiene disabled"
            systemToasts.push(warn: statusText, autoDismissAfter: 6)
        } catch {
            statusText = "Memory hygiene failed: \(error.localizedDescription)"
            systemToasts.push(error: statusText)
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
