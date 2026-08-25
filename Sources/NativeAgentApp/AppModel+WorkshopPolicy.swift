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

enum NightlyReflectionJobOutcome: Equatable {
    case added
    case alreadyPresent
    case repaired
    case failed(String)

    var message: String {
        switch self {
        case .added:
            return "Nightly reflection added."
        case .alreadyPresent:
            return "Nightly reflection is already scheduled."
        case .repaired:
            return "Nightly reflection schedule repaired."
        case .failed(let message):
            return "Nightly reflection could not be added: \(message)"
        }
    }

    var succeeded: Bool {
        if case .failed = self { return false }
        return true
    }
}

/// The scheduler read result belongs to the scheduler surface. Its detail is
/// carried with the read rather than recovered later from AppModel.statusText,
/// which any unrelated operation may replace before SchedulerView renders.
enum SchedulerJobsRefreshResult: Equatable {
    case current
    case partial(detail: String)
    case unavailable(detail: String)

    var failureDetail: String? {
        switch self {
        case .current:
            nil
        case .partial(let detail), .unavailable(let detail):
            detail
        }
    }

    static func make(from feed: SchedulerJobsFeedState) -> Self {
        switch feed {
        case .current:
            return .current
        case .partial(let rows, let rejectedRows):
            return .partial(detail: SchedulerJobsFeedState.partial(rows, rejectedRows: rejectedRows).failureDetail
                ?? "Schedule is partially unavailable.")
        case .sourceAbsent:
            return .unavailable(detail: SchedulerJobsFeedState.sourceAbsent.failureDetail
                ?? "Schedule source is absent.")
        case .unavailable(let detail):
            return .unavailable(detail: SchedulerJobsFeedState.unavailable(detail).failureDetail
                ?? "Schedule source is unavailable.")
        }
    }
}

@MainActor
extension AppModel {
    @MainActor
    @discardableResult
    func refreshSchedulerJobs() async -> SchedulerJobsRefreshResult {
        let feed = await client.schedulerJobsFeed()
        let result = SchedulerJobsRefreshResult.make(from: feed)
        switch feed {
        case .current(let rows):
            jobs = rows
            return result
        case .partial(let rows, let rejectedRows):
            jobs = rows
            statusText = result.failureDetail ?? "Schedule is partially unavailable."
            return result
        case .sourceAbsent:
            statusText = result.failureDetail ?? "Schedule source is absent."
            return result
        case .unavailable(let detail):
            statusText = result.failureDetail ?? "Schedule source is unavailable."
            return result
        }
    }

    @MainActor
    func createDreamJob() async -> NightlyReflectionJobOutcome {
        do {
            let before: SchedulerJob?
            do {
                before = try await client.getJobs().first {
                    $0.id == "nativeagent-nightly-dream"
                }
            } catch SchedulerJobsFeedError.sourceAbsent {
                // Missing is the one recoverable feed state for this explicit
                // create action: the due-job owner will create the canonical
                // source below. Damage remains unavailable and is never reset.
                before = nil
            }

            // The due-job runner owns the canonical id, calendar cadence,
            // bounded payload, legacy-name migration, and cross-process lock.
            // Reuse that repair instead of creating a second daily dream job.
            // This is an EXPLICIT user re-enable action, so it clears a prior
            // cancellation tombstone (F3-M1): otherwise a once-cancelled dream
            // job could never be re-created — cancelledAt is never stripped by
            // the passive bootstrap pass.
            let scheduler: SchedulerDueJobRunner
            if let dataRootOverride {
                scheduler = SchedulerDueJobRunner(root: dataRootOverride)
            } else {
                scheduler = .shared
            }
            _ = try await scheduler.ensureDefaultCycleJobs(
                now: Date(),
                reactivateCancelled: true
            )

            let refreshed = try await client.getJobs()
            jobs = refreshed
            guard let after = refreshed.first(where: {
                $0.id == "nativeagent-nightly-dream"
            }) else {
                let message = "the canonical scheduler job was not persisted"
                statusText = "Nightly reflection failed: \(message)"
                return .failed(message)
            }

            let outcome: NightlyReflectionJobOutcome
            if let before {
                outcome = before == after ? .alreadyPresent : .repaired
            } else {
                outcome = .added
            }
            statusText = outcome.message
            return outcome
        } catch {
            let outcome = NightlyReflectionJobOutcome.failed(error.localizedDescription)
            statusText = outcome.message
            return outcome
        }
    }

    @MainActor
    func createWorkshopTask(title: String, objective: String) async {
        do {
            _ = try await client.createWorkshopTask(title: title, objective: objective)
            statusText = "Desk task created"
            await refreshAll()
        } catch {
            statusText = "Desk task creation failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func getTriggers() async throws -> [TriggerRecord] {
        try await client.getTriggers()
    }

    @MainActor
    func setTriggerEnabled(name: String, enabled: Bool) async throws -> WorkshopActionResult {
        try await client.setTriggerEnabled(name: name, enabled: enabled)
    }

    @MainActor
    func saveWorkshopPolicyToggle(enabled: Bool, showTimeline: Bool) async {
        guard let policy = trustPolicy else { return }
        do {
            let savedPolicy = try await client.saveTrustPolicy(
                permissionLevel: policy.permissionLevel,
                autonomyDefault: policy.autonomyDefault ?? "supervised",
                requireBackups: policy.filePolicy?.requireBackupBeforeWrite ?? true,
                outsideDefault: policy.filePolicy?.outsideWorkspaceDefault ?? "deny",
                developerMode: policy.developerMode,
                workshopExecutionEnabled: enabled,
                workshopExecutionShowTimeline: showTimeline
            )
            applySavedTrustPolicy(savedPolicy, status: "Desk execution policy saved")
        } catch {
            statusText = "Desk execution policy save failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    // PATCH-2026-05-06: dev-mode added as parameter, forwarded to daemon payload
    @discardableResult
    func saveTrustPolicy(permissionLevel: String, autonomyDefault: String, requireBackups: Bool, outsideDefault: String, developerMode: Bool = false, autonomousTraining: Bool? = nil, dreamScheduler: Bool? = nil) async -> Bool {
        do {
            let savedPolicy = try await client.saveTrustPolicy(
                permissionLevel: permissionLevel,
                autonomyDefault: autonomyDefault,
                requireBackups: requireBackups,
                outsideDefault: outsideDefault,
                developerMode: developerMode,
                autonomousTraining: autonomousTraining,
                dreamScheduler: dreamScheduler
            )
            applySavedTrustPolicy(savedPolicy, status: "Trust policy saved")
            await refreshAll()
            return true
        } catch {
            recordTrustActionFailure("Trust save failed: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    func saveMemoryPolicy(consolidationEnabled: Bool, crossSessionRecall: Bool, autoPromoteConsolidated: Bool) async {
        do {
            let savedPolicy = try await client.saveMemoryPolicy(
                consolidationEnabled: consolidationEnabled,
                crossSessionRecall: crossSessionRecall,
                autoPromoteConsolidated: autoPromoteConsolidated
            )
            applySavedTrustPolicy(savedPolicy, status: "Memory policy saved")
        } catch {
            recordTrustActionFailure("Memory policy save failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    @discardableResult
    func saveMultimodalPolicy(_ policy: TrustMultimodalPolicy) async -> Bool {
        do {
            let savedPolicy = try await client.saveMultimodalPolicy(policy)
            applySavedTrustPolicy(savedPolicy, status: "Multimodal policy saved")
            return true
        } catch {
            // A failed canonical write can mean the underlying policy bytes
            // became unreadable between the UI read and this mutation. Do not
            // leave a stale OpenAI-voice grant available to playback.
            trustPolicy = nil
            recordTrustActionFailure("Multimodal policy save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Reads the canonical policy directly for the mounted voice-output
    /// controls.  The card must never treat a failed refresh as the ordinary
    /// local-voice setting, because playback uses the same policy to decide
    /// whether a remote synthesis request is permitted.
    @MainActor
    @discardableResult
    func refreshVoiceOutputPolicy() async -> Bool {
        do {
            trustPolicy = try await client.getTrustPolicy()
            return true
        } catch {
            // Trust policy is a hard output-route authority. Its previous
            // snapshot cannot stand in for a failed canonical reload.
            trustPolicy = nil
            statusText = "Voice output policy unavailable: \(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    @discardableResult
    func patchMemoryPolicy(
        knowledgeGraphEnabled: Bool? = nil,
        adaptivePromotion: Bool? = nil,
        hygieneEnabled: Bool? = nil,
        archiveNoisyReflections: Bool? = nil,
        rejectLowValueProposals: Bool? = nil
    ) async -> Bool {
        do {
            let savedPolicy = try await client.patchMemoryPolicy(
                knowledgeGraphEnabled: knowledgeGraphEnabled,
                adaptivePromotion: adaptivePromotion,
                hygieneEnabled: hygieneEnabled,
                archiveNoisyReflections: archiveNoisyReflections,
                rejectLowValueProposals: rejectLowValueProposals
            )
            applySavedTrustPolicy(savedPolicy, status: "Memory policy saved")
            return true
        } catch {
            recordTrustActionFailure("Memory policy save failed: \(error.localizedDescription)")
            return false
        }
    }

    @MainActor
    func saveEnableAutonomy(_ enabled: Bool) async {
        do {
            let savedPolicy = try await client.saveEnableAutonomy(enabled)
            applySavedTrustPolicy(savedPolicy, status: enabled ? "Autonomy enabled" : "Autonomy disabled")
        } catch {
            recordTrustActionFailure("Autonomy save failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    func saveChromeControlEnabled(_ enabled: Bool) async {
        do {
            let savedPolicy = try await client.saveChromeControlEnabled(enabled)
            applySavedTrustPolicy(
                savedPolicy,
                status: enabled ? "Chrome control enabled" : "Chrome control disabled"
            )
            await ChromeControlRuntime.shared.reconcilePolicy()
        } catch {
            recordTrustActionFailure("Chrome control save failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    @discardableResult
    func saveAgentAccessMode(_ mode: String, developerMode: Bool? = nil) async -> Bool {
        do {
            let savedPolicy = try await client.saveAgentAccessMode(mode, currentPolicy: trustPolicy, developerMode: developerMode)
            let status = "Agent access saved: \(Self.agentAccessLabel(mode))"
            applySavedTrustPolicy(savedPolicy, status: status)
            chatFileAccess = Self.normalizedAgentAccessMode(mode)
            return true
        } catch {
            recordTrustActionFailure("Agent access save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Full Mac duration picker save (2026-06-10). Writes
    /// `fullMacMaxDurationHours` / `fullMacNeverExpires` (and, for >24h,
    /// the explicit `fullMacExpiresAt` instant) through the same trust-write
    /// chokepoint every other Trust Center save uses.
    @MainActor
    func saveFullMacDuration(_ option: FullMacDurationOption) async {
        do {
            // The >24h expiry instant derives inside the trust-write lock
            // from the ON-DISK confirmedAt (review blocker fix 2026-06-10)
            // — no policy snapshot is passed, so a concurrent reconfirm
            // can't stale-anchor the explicit expiry.
            let savedPolicy = try await client.saveFullMacDuration(
                hours: option.hours,
                neverExpires: option == .never
            )
            applySavedTrustPolicy(savedPolicy, status: "Full Mac duration saved: \(option.label)")
        } catch {
            recordTrustActionFailure("Full Mac duration save failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    func applySavedTrustPolicy(_ policy: TrustPolicy, status: String? = nil) {
        trustPolicy = policy
        if let status {
            statusText = status
            trustCenterActionOutcome = .saved(status)
        }
    }

    func recordTrustActionFailure(_ message: String) {
        statusText = message
        trustCenterActionOutcome = .failed(message)
    }

    nonisolated static func normalizedAgentAccessMode(_ mode: String) -> String {
        let value = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_")
        return ["auto", "read_only", "workspace", "full"].contains(value) ? value : "auto"
    }

    nonisolated static func agentAccessMode(from policy: TrustPolicy, fallback: String = "auto") -> String {
        if (policy.permissionLevel == "full_mac_os" || policy.filePolicy?.outsideWorkspaceDefault == "allow"),
           fullMacGrantIsActive(policy) {
            return "full"
        }
        if policy.permissionLevel == "strict" {
            return "read_only"
        }
        if policy.autonomyDefault == "workspace_autonomous" {
            return "workspace"
        }
        if macControlPolicyNeedsWorkspace(policy.macControlPolicy) {
            return "workspace"
        }
        return normalizedAgentAccessMode(fallback)
    }

    /// U5 W-A item 9a (2026-06-11, DISPLAY-ONLY): delegate the ACTIVE
    /// verdict to the REAL gate — `MacControlGate.fullMacActive`, the same
    /// check `SwiftToolDispatcher.fullMacToolAccess` runs before including
    /// the Full-Mac file-ops tool block in the agent's catalog. The old
    /// local mirror short-circuited TRUE on `developerMode` (the gate is
    /// devMode-blind) and clamped hours `min(max(0.1,h),24)` vs the gate's
    /// `max(0.01, min(h,24))` — so with devMode on, the old indicator and
    /// `agentAccessMode` claimed "full" forever while the tools were
    /// actually swept at expiry. Field sourcing rides
    /// `FullMacExpiry.trustFields` (the honest Trust-panel mirror's input
    /// builder), so the two display surfaces can never drift apart.
    /// NO gate logic changes here; consumers verified display/picker-sync
    /// only (TrustCenterView badge + agentAccessMode → chatFileAccess,
    /// a UserDefaults-backed UI mode — the dispatch gate computes
    /// `access.fileOpsAllowed` independently).
    nonisolated static func fullMacGrantIsActive(_ policy: TrustPolicy) -> Bool {
        MacControlGate.fullMacActive(FullMacExpiry.trustFields(policy))
    }

    nonisolated private static func macControlPolicyNeedsWorkspace(_ policy: TrustMacControlPolicy?) -> Bool {
        guard let policy, policy.enabled else { return false }
        return policy.applesScriptAllowed
            || policy.jxaAllowed
            || policy.shortcutsAllowed
            || policy.accessibilityAllowed
            || policy.systemControlAllowed
            || policy.fileOpsAllowed
            || policy.shellAllowed
            || policy.notificationsAllowed
            || policy.spotlightAllowed
            || policy.remoteFromIosAllowed
    }

    nonisolated static func tolerantISO8601Date(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return date
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    nonisolated static func agentAccessLabel(_ mode: String) -> String {
        switch normalizedAgentAccessMode(mode) {
        case "read_only": return "Read"
        case "workspace": return "Workspace"
        case "full": return "Full Mac"
        default: return "Auto"
        }
    }

    @MainActor
    func simulatePolicy(action: String, path: String) async {
        policySimulation = nil
        policySimulationFailure = nil
        do {
            policySimulation = try await client.simulatePolicy(action: action, path: path)
            statusText = "Policy simulation complete"
        } catch {
            policySimulationFailure = error.localizedDescription
            statusText = "Policy simulation failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func createBackup(reason: String) async {
        let receipt: String
        do {
            let backup = try await client.createBackup(reason: reason)
            receipt = "Backup created at \(backup.createdAt): \(backup.reason)"
        } catch {
            receipt = "Backup failed: \(error.localizedDescription)"
        }
        await refreshBackupList(preserving: receipt)
    }

    @MainActor
    func restoreBackup(_ backup: BackupRecord) async {
        let receipt: String
        do {
            let result = try await client.restoreBackup(id: backup.id)
            if result.requiresRestart {
                statusText = "Restore validated and staged with safety backup \(result.safetyBackupId ?? "created"). NativeAgent is restarting to restore before any live state owner opens."
                AppRelauncher.relaunchApp()
                return
            }
            let scopes = NativeClient.scopeNames(for: result.restored)
            let restoredDescription = scopes.isEmpty ? "no matching data scopes" : scopes.joined(separator: ", ")
            receipt = "Restore completed at \(result.restoredAt): \"\(backup.reason)\" from \(backup.createdAt). Safety backup created first. Restored: \(restoredDescription)."
        } catch {
            receipt = "Restore failed for \"\(backup.reason)\" from \(backup.createdAt): \(error.localizedDescription)"
        }
        await refreshBackupList(preserving: receipt)
    }

    @MainActor
    private func refreshBackupList(preserving receipt: String) async {
        do {
            backups = try await client.getBackups()
            statusText = receipt
        } catch {
            statusText = "\(receipt) Backup list refresh failed: \(error.localizedDescription)"
        }
    }

}
