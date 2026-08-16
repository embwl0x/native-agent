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

@MainActor
extension AppModel {
    @MainActor
    func savePersonality(_ profile: PersonalityProfile) async {
        do {
            personality = try await client.savePersonality(profile)
            compiledPersonality = try? await client.getCompiledPersonality(surface: "chat")
            if let docsResponse = try? await client.getPersonalityDocs() {
                personalityDocs = docsResponse.docs
            }
            statusText = "Personality saved"
            await refreshAll()
        } catch {
            statusText = "Personality save failed: \(error.localizedDescription)"
        }
    }

    /// TTL for reusing a completed Doctor run when building the Support
    /// Snapshot instead of re-running the whole offline pass (B2.6d).
    static let supportSnapshotDoctorReuseTTL: TimeInterval = 90

    @MainActor
    func loadSupportDiagnostics() async {
        do {
            // B2.6d: if a full Doctor run finished within the TTL, reuse its
            // result (identical offline rollup) rather than re-running the
            // whole pass. Falls back to a fresh run when stale or never run.
            let reuse: DoctorReport? = {
                guard let report = doctorReport,
                      let completedAt = doctorReportCompletedAt,
                      Date().timeIntervalSince(completedAt) < Self.supportSnapshotDoctorReuseTTL
                else { return nil }
                return report
            }()
            supportDiagnostics = try await client.getSupportDiagnostics(reusing: reuse)
            statusText = reuse != nil
                ? "Support diagnostics refreshed (reused recent Doctor result)"
                : "Support diagnostics refreshed"
        } catch {
            statusText = "Support diagnostics failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func loadPersonalityDocs() async {
        do {
            personalityDocs = try await client.getPersonalityDocs().docs
        } catch {
            statusText = "Personality docs load failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func savePersonalityDoc(id: String, content: String) async {
        do {
            let saved = try await client.savePersonalityDoc(id: id, content: content)
            if let index = personalityDocs.firstIndex(where: { $0.id == saved.id }) {
                personalityDocs[index] = saved
            } else {
                personalityDocs.append(saved)
            }
            compiledPersonality = try? await client.getCompiledPersonality(surface: "chat")
            statusText = "\(saved.filename) saved"
        } catch {
            statusText = "Personality doc save failed: \(error.localizedDescription)"
        }
    }

    // PATCH-2026-05-07: self-improvement-ui AppModel methods for B.1/B.3

    @MainActor
    func loadAllSelfImprovement() async {
        let api = client
        async let nextTrust = try? api.getTrustPolicy()
        async let nextImprovementSummary = try? api.getImprovementSummary()
        async let nextTrainingRuns = try? api.getTrainingRuns()
        async let nextTrainingProposals = try? api.getTrainingProposals()
        async let nextPromotionCandidates = try? api.getPromotionCandidates()
        async let nextPromotionPending = try? api.getPromotionPending()
        async let nextMemoryProposals = try? api.getMemoryProposals()
        let (
            trustRow,
            improvementRow,
            trainingRunRows,
            trainingProposalRows,
            promotionRows,
            pendingRows,
            memoryProposalRows
        ) = await (
            nextTrust,
            nextImprovementSummary,
            nextTrainingRuns,
            nextTrainingProposals,
            nextPromotionCandidates,
            nextPromotionPending,
            nextMemoryProposals
        )
        trustPolicy = trustRow ?? trustPolicy
        improvementSummary = improvementRow ?? improvementSummary
        trainingRuns = trainingRunRows ?? []
        trainingProposals = trainingProposalRows ?? []
        promotionCandidates = promotionRows ?? []
        promotionPending = pendingRows ?? []
        memoryProposals = memoryProposalRows ?? []
    }

    // PATCH-2026-05-07: living-memory AppModel methods for memory proposals
    // U5 W-A item 1 (2026-06-11): these five loaders previously swallowed
    // failures with bare `try? ... ?? []`, so a read/decode error rendered
    // as a healthy-EMPTY panel — indistinguishable from "no data". They now
    // ride decodeLogged, which logs the endpoint + error and records it in
    // lastRefreshError instead of fabricating an empty success.
    @MainActor
    func loadMemoryProposals() async {
        memoryProposals = await decodeLogged("getMemoryProposals", default: []) {
            try await client.getMemoryProposals()
        }
    }

    @MainActor
    func approveMemoryProposal(id: String) async throws -> [String: Any] {
        let result = try await client.approveMemoryProposal(id: id)
        await loadMemoryProposals()
        approvals = (try? await client.getApprovals()) ?? approvals
        return result
    }

    @MainActor
    func rejectMemoryProposal(id: String, reason: String = "") async throws -> [String: Any] {
        let result = try await client.rejectMemoryProposal(id: id, reason: reason)
        await loadMemoryProposals()
        approvals = (try? await client.getApprovals()) ?? approvals
        return result
    }

    @MainActor
    func triggerMemoryConsolidation(dryRun: Bool = false) async throws -> [String: Any] {
        let result = try await client.triggerMemoryConsolidation(dryRun: dryRun)
        await loadMemoryProposals()
        return result
    }

    @MainActor
    func loadTrainingRuns() async {
        trainingRuns = await decodeLogged("getTrainingRuns", default: []) {
            try await client.getTrainingRuns()
        }
    }

    @MainActor
    func loadTrainingProposals() async {
        trainingProposals = await decodeLogged("getTrainingProposals", default: []) {
            try await client.getTrainingProposals()
        }
    }

    @MainActor
    func loadPromotionCandidates() async {
        promotionCandidates = await decodeLogged("getPromotionCandidates", default: []) {
            try await client.getPromotionCandidates()
        }
    }

    @MainActor
    func loadPromotionPending() async {
        promotionPending = await decodeLogged("getPromotionPending", default: []) {
            try await client.getPromotionPending()
        }
    }

    @MainActor
    func runDrillBattery(surface: String = "chat") async {
        do {
            let env = try await client.runDrills(surface: surface)
            if let disabled = env["panelDisabled"] as? Bool, disabled {
                let reason = (env["reason"] as? String) ?? "drill runner unavailable"
                var badge = "Drill battery disabled — \(reason)"
                if let followup = env["followup"] as? String, !followup.isEmpty {
                    badge += " (see: \(followup))"
                }
                disabledFeature = badge
                statusText = badge
                selfImprovementError = nil
            } else {
                disabledFeature = nil
                let passed = env["passed"] as? Int
                let failed = env["failed"] as? Int
                if let passed, let failed {
                    statusText = "Drill battery finished: \(passed) passed, \(failed) failed"
                } else {
                    statusText = "Drill battery finished"
                }
            }
            await loadAllSelfImprovement()
        } catch {
            selfImprovementError = "Run drills failed: \(error.localizedDescription)"
            statusText = "Drill battery failed"
        }
    }

    @MainActor
    func runDreamPass() async {
        selfImprovementError = nil
        do {
            let result = try await client.runDream()
            statusText = Self.dreamRunStatusText(result)
            await loadAllSelfImprovement()
        } catch {
            selfImprovementError = "Dream cycle failed: \(error.localizedDescription)"
            statusText = "Dream cycle failed"
        }
    }

    // PATCH-2026-05-29: dreams-tab — Dreams tab data + control methods.

    /// Fetch the dream diary (newest first) plus the composite dream-enabled flag.
    /// Returns nil on failure and records the error in `dreamError`.
    @MainActor
    func fetchDreamDiary(limit: Int = 30) async -> DreamDiaryResponse? {
        dreamError = nil
        do {
            return try await client.getDreamDiary(limit: limit)
        } catch {
            dreamError = "Load dream diary failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Fetch a single diary entry by date (YYYY-MM-DD). Returns nil on 404/error.
    @MainActor
    func fetchDreamEntry(date: String) async -> DreamEntry? {
        dreamError = nil
        do {
            return try await client.getDreamEntry(date: date)
        } catch {
            dreamError = "Load entry \(date) failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Run a REM consolidation pass now. Returns true on success so the caller
    /// only reloads (which clears dreamError) when the run actually succeeded.
    @MainActor
    func runRemPass() async -> Bool {
        dreamError = nil
        do {
            _ = try await client.runRem()
            statusText = "REM consolidation started"
            return true
        } catch {
            dreamError = "REM cycle failed: \(error.localizedDescription)"
            statusText = "REM cycle failed"
            return false
        }
    }

    /// Toggle the deep dream kill switch (personalityPolicy.dream_cycle_enabled).
    /// Persists via the deep-merged trust patch and refreshes `trustPolicy`.
    @MainActor
    func setDreamCycleEnabled(_ enabled: Bool) async -> Bool {
        dreamError = nil
        do {
            let saved = try await client.patchDreamCycleEnabled(enabled)
            trustPolicy = saved
            statusText = enabled ? "Dream cycle enabled" : "Dream cycle disabled"
            return true
        } catch {
            dreamError = "Save dream cycle toggle failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Toggle the REM kill switch (trainingPolicy.rem_cycle_enabled).
    /// Persists via the deep-merged trust patch and refreshes `trustPolicy`.
    @MainActor
    func setRemCycleEnabled(_ enabled: Bool) async -> Bool {
        dreamError = nil
        do {
            let saved = try await client.patchRemCycleEnabled(enabled)
            trustPolicy = saved
            statusText = enabled ? "REM cycle enabled" : "REM cycle disabled"
            return true
        } catch {
            dreamError = "Save REM cycle toggle failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Dream-tab-scoped dream run: routes errors to `dreamError` (not the
    /// Self-Improvement banner) and skips the self-improvement reload. Mirrors
    /// runDreamPass() but stays in the Dreams surface. Returns true on success so
    /// the caller only reloads (which clears dreamError) when the run succeeded.
    @MainActor
    func runDreamPassForDreams() async -> Bool {
        dreamError = nil
        do {
            let result = try await client.runDream()
            statusText = Self.dreamRunStatusText(result)
            return true
        } catch {
            dreamError = "Dream cycle failed: \(error.localizedDescription)"
            statusText = "Dream cycle failed"
            return false
        }
    }

    private static func dreamRunStatusText(_ result: [String: Any]) -> String {
        let entries = dreamRunInt(result["entriesWritten"]) ?? 0
        let disabled = dreamRunBool(result["disabled"]) ?? false
        if disabled { return "Dream cycle disabled" }
        if entries <= 0 { return "Dream already ran for the target night" }
        return entries == 1 ? "Dream cycle wrote 1 entry" : "Dream cycle wrote \(entries) entries"
    }

    private static func dreamRunInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func dreamRunBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }

    // SUBSYSTEM #17: retired viewmodel wrappers runTrainingSelfTest / runPromotionSelfTest — zero view callers.

    @MainActor
    func approveTrainingProposal(id: String) async {
        do {
            let result = try await client.approveTrainingProposal(id: id)
            if (result["status"] as? String) == "promotion_staged" {
                statusText = "Proposal staged for promotion"
                await loadAllSelfImprovement()
            } else {
                statusText = "Proposal approved"
                await loadTrainingProposals()
            }
        } catch {
            selfImprovementError = "Approve failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func rejectTrainingProposal(id: String, reason: String) async {
        do {
            _ = try await client.rejectTrainingProposal(id: id, reason: reason)
            statusText = "Proposal rejected"
            await loadTrainingProposals()
        } catch {
            selfImprovementError = "Reject failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func saveTrustPolicyWithPromotion(
        permissionLevel: String,
        autonomyDefault: String,
        requireBackups: Bool,
        outsideDefault: String,
        developerMode: Bool = false,
        autonomousTraining: Bool? = nil,
        dreamScheduler: Bool? = nil,
        routeThroughPromotion: Bool? = nil,
        promotionEnabled: Bool? = nil,
        autoPromoteTierA: Bool? = nil
    ) async {
        do {
            let savedPolicy = try await client.saveTrustPolicyFull(
                permissionLevel: permissionLevel,
                autonomyDefault: autonomyDefault,
                requireBackups: requireBackups,
                outsideDefault: outsideDefault,
                developerMode: developerMode,
                autonomousTraining: autonomousTraining,
                dreamScheduler: dreamScheduler,
                routeThroughPromotion: routeThroughPromotion,
                promotionEnabled: promotionEnabled,
                autoPromoteTierA: autoPromoteTierA
            )
            applySavedTrustPolicy(savedPolicy, status: "Trust policy saved")
        } catch {
            statusText = "Trust save failed: \(error.localizedDescription)"
        }
    }
}
