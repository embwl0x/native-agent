import Foundation
import AppKit
import EngineRuntime
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import TrustCenter
import TrustPersistence
import ApprovalInbox
import ApprovalTransactions
import ChatToolRuntime
import MacControl
import MacIntegration
import SystemOps
import Connectors
import AttentionRouting
import DoctorChecks
import WidgetKit
import AppIntents
import Observation
import SwiftUI
import MemoryV2
import ProviderRouting
import BackgroundLoops
import PersonaEngine
import ChatTurnRuntime
import ChatSessionWork
import MultimodalTTS
import TelegramBot
import DeviceSync
// Blueprint: | `AppModel+TrustActions.swift` | `AppModel`: Trust policy, backups, approval resolution and Mac control commands |

@MainActor
extension AppModel {
    @MainActor
    func saveWorkshopPolicyToggle(enabled: Bool? = nil) async {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot)
                .saveWorkshopPolicyToggle(enabled: enabled)
            applySavedTrustPolicy(savedPolicy, status: "Desk execution policy saved")
        } catch {
            setFailureStatus(error, action: "save the Desk execution policy")
        }
    }

    @MainActor
    func saveMemoryPolicy(crossSessionRecall: Bool) async {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot).saveMemoryPolicy(
                crossSessionRecall: crossSessionRecall
            )
            applySavedTrustPolicy(savedPolicy, status: "Memory policy saved")
        } catch {
            recordTrustActionFailure(UserFacingError.message(error, action: "save the memory policy"), cause: error)
            systemToasts.push(error: "That memory setting could not be saved.")
        }
    }

    @MainActor
    @discardableResult
    func saveMultimodalPolicy(_ policy: TrustMultimodalPolicy) async -> Bool {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot).saveMultimodalPolicy(policy)
            applySavedTrustPolicy(savedPolicy, status: "Multimodal policy saved")
            return true
        } catch {
            // A failed canonical write can mean the underlying policy bytes
            // became unreadable between the UI read and this mutation. Do not
            // leave a stale OpenAI-voice grant available to playback.
            engine.trust.publishPolicy(nil)
            recordTrustActionFailure(UserFacingError.message(error, action: "save the multimodal policy"), cause: error)
            return false
        }
    }

    @MainActor
    @discardableResult
    func patchMemoryPolicy(
        knowledgeGraphEnabled: Bool? = nil,
        adaptivePromotion: Bool? = nil
    ) async -> Bool {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot).patchMemoryPolicy(
                knowledgeGraphEnabled: knowledgeGraphEnabled,
                adaptivePromotion: adaptivePromotion
            )
            applySavedTrustPolicy(savedPolicy, status: "Memory policy saved")
            return true
        } catch {
            recordTrustActionFailure(UserFacingError.message(error, action: "save the memory policy"), cause: error)
            systemToasts.push(error: "That memory setting could not be saved.")
            return false
        }
    }

    @MainActor
    func saveEnableAutonomy(_ enabled: Bool) async {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot).saveEnableAutonomy(enabled)
            applySavedTrustPolicy(savedPolicy, status: enabled ? "Autonomy enabled" : "Autonomy disabled")
        } catch {
            recordTrustActionFailure(UserFacingError.message(error, action: "save autonomy"), cause: error)
        }
    }

    @MainActor
    func saveChromeControlEnabled(_ enabled: Bool) async {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot).saveChromeControlEnabled(enabled)
            applySavedTrustPolicy(
                savedPolicy,
                status: enabled ? "Chrome control enabled" : "Chrome control disabled"
            )
            await NativeAgentEngine.live.chrome.reconcilePolicy()
        } catch {
            recordTrustActionFailure(UserFacingError.message(error, action: "save Chrome control"), cause: error)
        }
    }

    @MainActor
    func saveKillSwitchEnabled(_ enabled: Bool) async -> Bool {
        do {
            let savedPolicy = try await TrustPolicyActions(dataRoot: engine.dataRoot).saveKillSwitchEnabled(enabled)
            applySavedTrustPolicy(savedPolicy, status: enabled ? "Everything paused" : "Pause lifted")
            return true
        } catch {
            recordTrustActionFailure(UserFacingError.message(error, action: "save Pause everything"), cause: error)
            return false
        }
    }

    @MainActor
    func applySavedTrustPolicy(_ policy: TrustPolicy, status: String? = nil) {
        engine.trust.publishPolicy(policy)
        if let status {
            statusText = status
            trustCenterActionOutcome = .saved(status)
        }
    }

    func recordTrustActionFailure(_ message: String, cause: Error? = nil) {
        statusText = message
        statusCause = cause?.localizedDescription
        trustCenterActionOutcome = .failed(message)
    }

    /// The backup, or nil; either way `statusText` carries the receipt.
    @MainActor
    @discardableResult
    func createBackup(reason: String) async -> BackupRecord? {
        let receipt: String
        var cause: String?
        var created: BackupRecord?
        do {
            let backup = try await TrustBackupPersistence.createBackup(
                reason: reason, dataRoot: firstRunDataRoot
            )
            created = backup
            receipt = "Backup created at \(backup.createdAt): \(backup.reason)"
        } catch {
            receipt = UserFacingError.message(error, action: "make a backup")
            cause = error.localizedDescription
        }
        await refreshBackupList(preserving: receipt, cause: cause)
        return created
    }

    @MainActor
    func restoreBackup(_ backup: BackupRecord) async {
        let receipt: String
        let outcome: TrustCenterActionOutcome
        var cause: String?
        do {
            let result = try await TrustBackupPersistence.restoreBackup(
                id: backup.id, dataRoot: firstRunDataRoot
            )
            if result.requiresRestart {
                statusText = "Restore validated and staged. NativeAgent is restarting to install the backup and carry only readable current requests and consumption evidence. A turn in progress when the backup was taken is restored as stopped; nothing from the backup runs on its own."
                trustCenterActionOutcome = .saved(statusText)
                AppRelaunch.relaunchApp(terminate: {
                    RunLoop.main.perform(inModes: [.common]) {
                        MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
                    }
                }, onSpawnFailure: { error in
                    ModuleLog.app("[relaunch] failed to spawn relaunch helper for %@: %@", Bundle.main.bundlePath, "\(error)")
                })
                return
            }
            let scopes = TrustBackupPersistence.scopeNames(for: result.restored)
            let restoredDescription = scopes.isEmpty ? "no matching data scopes" : scopes.joined(separator: ", ")
            receipt = "Restore completed at \(result.restoredAt): \"\(backup.reason)\" from \(backup.createdAt). Safety backup created first. Restored: \(restoredDescription)."
            outcome = .saved(receipt)
        } catch {
            receipt = "Restore failed for \"\(backup.reason)\" from \(backup.createdAt). "
                + UserFacingError.cause(error, action: "restore that backup")
            cause = error.localizedDescription
            outcome = .failed(receipt)
        }
        await refreshBackupList(preserving: receipt, cause: cause)
        trustCenterActionOutcome = outcome
    }

    @MainActor
    private func refreshBackupList(preserving receipt: String, cause: String? = nil) async {
        do {
            try await engine.trust.refreshBackups()
            statusText = receipt
            statusCause = cause
        } catch {
            statusText = "\(receipt) " + UserFacingError.message(error, action: "refresh the backup list")
            statusCause = [cause, error.localizedDescription].compactMap { $0 }.joined(separator: "; ")
        }
    }

    // MARK: Approvals
    /// Overload of the existing `resolveApproval(_:decision:)` for callers that
    /// hold only the approval id (inline cards, sidebar rows). Concurrent
    /// callers share one task because a terminal approval may start a real
    /// executor after its durable decision is written.
    func resolveApproval(id: String, decision: String) async throws -> ApprovalRecord {
        try await engine.approvals.resolveApproval(
            id: id, decision: decision,
            coordinator: .app()
        )
    }

    // MARK: Mac assistant / Mac control
    func saveMacIntegrationPreset(_ preset: String, currentPolicy: TrustPolicy? = nil) async throws -> TrustPolicy {
        try await TrustPolicyActions(dataRoot: engine.dataRoot).saveMacIntegrationPreset(preset, currentPolicy: currentPolicy)
    }

    /// Overload of the existing `runConnectorAction(_:)` for the id/dryRun/input
    /// call shape used by the Mac-data probe.
    func runConnectorAction(id: String, dryRun: Bool, input: [String: JSONValue] = [:]) async throws -> ConnectorActionReceipt {
        try await engine.runConnectorAction(id: id, dryRun: dryRun, input: input,
            origin: "mac_ui:connector_action:" + id, platform: AppConnectorActionPlatform(engine: engine))
    }

    func saveMacControlPolicy(
        _ policy: MacControlPolicyWireSnapshot,
        comparedTo baseline: MacControlPolicyWireSnapshot,
        guardedByLockedPolicy: (@Sendable ([String: JSONValue]) throws -> Void)? = nil
    ) async throws -> TrustPolicy {
        try await TrustPolicyActions(dataRoot: engine.dataRoot)
            .saveMacControlPolicy(policy, comparedTo: baseline, guardedByLockedPolicy: guardedByLockedPolicy)
    }

    func macControlNotify(title: String, message: String) async throws -> Bool {
        try await engine.trust.notify(
            title: title, message: message, notificationCenterAdapter: MacNotificationPosting()
        )
    }

    func macControlRun(action: MacControlWorkbenchAction, body: [String: JSONValue]) async throws -> MacControlResult {
        try await engine.trust.runMacControl(
            action: action, body: body, notificationCenterAdapter: MacNotificationPosting()
        )
    }

}
