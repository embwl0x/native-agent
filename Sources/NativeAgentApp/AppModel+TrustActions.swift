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
import ChatTurnContracts
import ChatSessionWork
import MultimodalTTS
import TelegramBot
import DeviceSync
// Blueprint: | `AppModel+TrustActions.swift` | `AppModel`: Trust policy, backups, approval resolution and Mac control commands |

enum BackupCreationOutcome {
    case created(BackupRecord, String)
    case failed(String)
}

@MainActor
extension AppModel {
    func resolveApproval(_ approval: ApprovalRecord, decision: String) async {
        let result = await resolveApprovalOnce(id: approval.id, decision: decision)
        switch result {
        case .applied, .noOpAlreadyResolved:
            statusText = result.visibleMessage
            await refreshAll()
        case .noOpInFlight, .unavailable:
            statusText = result.visibleMessage
        }
    }

    /// All mounted approval controls must share the facade's one resolution flight.
    func resolveApprovalOnce(id: String, decision: String) async -> ApprovalsFacade.Resolution {
        do {
            return try await engine.approvals.resolveOnce(id: id) { id in
                try await resolveApproval(id: id, decision: decision)
            }
        } catch {
            return .unavailable(UserFacingError.cause(error, action: "update that approval"))
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
            await engine.chrome.reconcilePolicy(context: .init(dataRoot: engine.dataRoot))
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

    /// The command owns its result; UI status is only its projection.
    @MainActor
    @discardableResult
    func createBackup(reason: String) async -> BackupCreationOutcome {
        let receipt: String
        let result: BackupCreationOutcome
        var cause: String?
        do {
            let backup = try await TrustBackupPersistence.createBackup(
                reason: reason, dataRoot: firstRunDataRoot
            )
            receipt = "Backup created at \(backup.createdAt): \(backup.reason)"
            result = .created(backup, receipt)
        } catch {
            receipt = UserFacingError.message(error, action: "make a backup")
            result = .failed(receipt)
            cause = error.localizedDescription
        }
        await refreshBackupList(preserving: receipt, cause: cause)
        switch result {
        case .created: trustCenterActionOutcome = .saved(receipt)
        case .failed: trustCenterActionOutcome = .failed(receipt)
        }
        return result
    }

    @MainActor
    @discardableResult
    func restoreBackup(_ backup: BackupRecord) async -> TrustCenterActionOutcome {
        let receipt: String
        let outcome: TrustCenterActionOutcome
        var cause: String?
        do {
            let result = try await TrustBackupPersistence.restoreBackup(
                id: backup.id, dataRoot: firstRunDataRoot
            )
            if result.requiresRestart {
                let message = """
                    Restore validated and staged. NativeAgent is restarting to install the backup and carry only readable current requests and consumption \
                    evidence. A turn in progress when the backup was taken is restored as stopped; nothing from the backup runs on its own.
                    """
                statusText = message
                trustCenterActionOutcome = .saved(message)
                AppRelaunch.relaunchApp(terminate: {
                    RunLoop.main.perform(inModes: [.common]) {
                        MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
                    }
                }, onSpawnFailure: { error in
                    ModuleLog.app("[relaunch] failed to spawn relaunch helper for %@: %@", Bundle.main.bundlePath, "\(error)")
                })
                return .saved(message)
            }
            let scopes = TrustBackupPersistence.scopeNames(for: result.restored)
            let restoredDescription = scopes.isEmpty ? "no matching data scopes" : scopes.joined(separator: ", ")
            receipt = """
                Restore completed at \(result.restoredAt): \"\(backup.reason)\" from \(backup.createdAt). Safety backup created first. Restored: \
                \(restoredDescription).
                """
            outcome = .saved(receipt)
        } catch {
            receipt = "Restore failed for \"\(backup.reason)\" from \(backup.createdAt). "
                + UserFacingError.cause(error, action: "restore that backup")
            cause = error.localizedDescription
            outcome = .failed(receipt)
        }
        await refreshBackupList(preserving: receipt, cause: cause)
        trustCenterActionOutcome = outcome
        return outcome
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
    /// Concurrent ID-only callers share one task because a durable terminal decision may start a real executor.
    func resolveApproval(id: String, decision: String) async throws -> ApprovalRecord {
        try await engine.approvals.resolveApproval(
            id: id, decision: decision,
            coordinator: .app(), turn: ApprovalResolutionProvenance.local(decidedBy: "mac_ui").resolvingTurn
        )
    }

    // MARK: Mac assistant / Mac control
    func saveMacIntegrationPreset(_ preset: String, currentPolicy: TrustPolicy? = nil) async throws -> TrustPolicy {
        try await TrustPolicyActions(dataRoot: engine.dataRoot).saveMacIntegrationPreset(preset, currentPolicy: currentPolicy)
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
        let turn = TurnRequest(message: "", sessionID: nil, surface: "native_actions",
            envelope: TurnEnvelope.personOnMac("mac_ui:mac_control.notify", surface: "native_actions")).turn()
        return try await engine.trust.notify(
            title: title, message: message,
            notificationCenterAdapter: MacNotificationPosting(turn: turn, deadline: nil), turn: turn
        )
    }

    func macControlRun(action: MacControlWorkbenchAction, body: [String: JSONValue]) async throws -> MacControlResult {
        let turn = TurnRequest(message: "", sessionID: nil, surface: "native_actions",
            envelope: TurnEnvelope.personOnMac("mac_ui:mac_control." + action.rawValue, surface: "native_actions")).turn()
        return try await engine.trust.runMacControl(
            action: action, body: body,
            notificationCenterAdapter: MacNotificationPosting(turn: turn, deadline: nil), turn: turn
        )
    }

    func macControlRead(action: String, operation: UUID) async throws -> CommittedResult {
        let reply = try await engine.faceActs.handle(.runMacControl(.init(action: action,
            arguments: ["operationId": .string(operation.uuidString)], checking: true)))
        guard case .committed(let result) = reply else {
            throw WireFailure(code: "workbench_read_unconfirmed", message: "The Mac control owner did not return its operation state.",
                cause: nil, effects: .unknown)
        }
        return result
    }

}
