import EngineRuntime
import ApprovalTransactions
import Foundation
import NativeAgentCore
import SwiftUI
import NativeAgentShared
import PersistenceCore
import AppToolRuntime
import ToolRegistry
import ProviderRouting
import DoctorChecks
import Research
import Connectors
import ChatTurnRuntime
import ChatTurnContracts
// Blueprint: | `AppModel+SkillsIntegrations.swift` | `AppModel`: connector updates, Telegram status/test/clear through the Telegram owner, Doctor runs |

enum ConnectorUpdateOutcome: Equatable {
    case verified(ConnectorRecord)
    case failed(String)
}

@MainActor
extension AppModel {
    @MainActor
    func updateConnector(_ connector: ConnectorRecord, enabled: Bool) async -> ConnectorUpdateOutcome {
        do {
            guard let confirmed = try await engine.connectors.update(id: connector.id, enabled: enabled) else {
                let detail = "The registry did not confirm the requested \(enabled ? "enable" : "disable") change."
                statusText = "Connector update failed: \(detail)"
                return .failed(detail)
            }
            statusText = "Connector \(confirmed.enabled ? "enabled" : "disabled") and verified"
            return .verified(confirmed)
        } catch {
            let detail = UserFacingError.cause(error, action: "turn that connector \(enabled ? "on" : "off")")
            setFailureStatus("Couldn't turn that connector \(enabled ? "on" : "off"). " + detail, cause: error)
            return .failed(detail)
        }
    }

    @MainActor
    func autodetectSearXNG() async -> SearXNGAutodetectOutcome {
        do {
            let detected = try await SwiftNativeResearchClient(dataRoot: engine.dataRoot).autodetectSearXNG()
            let outcome = detected.outcome
            if case .found = outcome { try await engine.configuration.readSearXNG(dataRoot: engine.dataRoot) }
            return outcome
        } catch {
            return .failed(UserFacingError.cause(error, action: "find a SearXNG server"))
        }
    }


    @MainActor
    /// Let a Telegram caller defer poll restart because shutdown waits for its own turn too.
    func clearTelegramToken(restartPollLoop: Bool = true) async -> AppMutationResult {
        statusText = "Clearing Telegram bot token..."
        let restart: (@Sendable () async -> Bool)? = restartPollLoop
            ? { @Sendable [backgroundLoopsManager] in
                await NativeAgentEngine.restartBackgroundLoop(
                    id: "telegram_poll",
                    manager: backgroundLoopsManager
                ).didRestart
            }
            : nil
        do {
            try await engine.telegram.disconnectTelegram(restartPollLoop: restart)
            await refreshAll()
            statusText = "Telegram bot token cleared"
            return .success("Telegram bot token cleared")
        } catch {
            setFailureStatus("Removing the Telegram token failed. " + UserFacingError.cause(error, action: "remove the Telegram token"), cause: error)
            return .failure(statusText, cause: error.localizedDescription)
        }
    }

    @MainActor
    @discardableResult
    func refreshTelegram() async -> Bool {
        do {
            let status = try await engine.telegram.refresh(manager: backgroundLoopsManager)
            let issue = status.credentialIssue ?? status.routingIssue
            statusText = issue ?? "Telegram status refreshed"
            return issue == nil
        } catch {
            setFailureStatus(error, action: "refresh Telegram")
            return false
        }
    }

    @MainActor
    func testTelegram() async -> AppMutationResult {
        statusText = "Sending Telegram test reply..."

        do {
            // The test goes to the first allowed chat, else the first allowed user, as the Telegram owner holds them now.
            let status = try await engine.telegram.refresh(manager: backgroundLoopsManager)
            let chatId = (status.allowedChatIds + status.allowedUserIds).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let result = try await engine.telegram.sendTelegramTestReply(chatId: chatId, manager: backgroundLoopsManager)
            await refreshAll()
            statusText = TelegramTestReplyPresentation.summary(for: result)
            return .init(succeeded: result.ok, userMessage: TelegramTestReplyPresentation.summary(for: result))
        } catch {
            setFailureStatus("Telegram test failed. " + UserFacingError.cause(error, action: "test Telegram"), cause: error)
            return .failure(statusText, cause: error.localizedDescription)
        }
    }

    @MainActor
    func clearTelegramLogs() async {
        guard !isClearingTelegramLogs else { return }
        isClearingTelegramLogs = true
        telegramClearLogsOutcome = nil
        statusText = "Clearing Telegram diagnostics…"
        defer { isClearingTelegramLogs = false }
        do {
            let receipt = try await engine.telegram.clearTelegramDiagnostics(manager: backgroundLoopsManager)
            telegramClearLogsOutcome = .completed(receipt)
            statusText = TelegramClearLogsPresentation.summary(for: receipt)
        } catch {
            let detail = UserFacingError.cause(error, action: "clear the Telegram logs")
            telegramClearLogsOutcome = .failed(detail: detail)
            setFailureStatus("Couldn't clear the Telegram logs. " + detail, cause: error)
        }
    }


    @MainActor
    @discardableResult
    func runDoctor(repair: Bool, repairScope: DoctorRepairScope = .automatic, checkID: String? = nil, turn: Turn? = nil) async -> DoctorFacade.RunOutcome {
        // Reject concurrent Doctor invocations while exposing the in-flight state.
        let doctor = engine.doctor
        guard doctor.admitRun() else {
            return .unavailable("Health checks are already running.")
        }
        statusText = repair ? "Running repair…" : "Running health checks…"
        do {
            let port = AppDoctorPort(dataRoot: engine.dataRoot, backgroundLoopsManager: backgroundLoopsManager)
            var report = try await EngineDoctorRuntime(dataRoot: engine.dataRoot, port: port, turn: turn)
                .runDoctor(repair: repair, repairScope: repairScope, checkID: checkID)
            let buttonRepair: Bool
            if case .button = repairScope {
                buttonRepair = repair && (checkID == "status.desk_attention" || (checkID == nil && doctor.report?.checks.contains {
                    $0.checkID == "status.desk_attention" && $0.repair_available == true
                } == true))
            } else {
                buttonRepair = false
            }
            let status = await DoctorFacade.statusChecks(
                dataRoot: engine.dataRoot,
                approvals: engine.approvals,
                repairDesk: buttonRepair,
                stuckReason: DeskPageContent.stuckReason,
                safeDetail: EngineDoctorRuntime<AppDoctorPort>.safeDetail
            )
            report = EngineDoctorRuntime<AppDoctorPort>.mergeReport(report, liveChecks: status.checks)
            report.repaired = report.repaired || status.repaired
            report.checks = await DoctorReadout.repairProjection(report.checks, dataRoot: engine.dataRoot)
            report.status = DoctorReadout.doctorRollup(report.checks.map(\.status))
            doctor.finishRun(report)
            statusText = repair
                ? DoctorFacade.repairCompletionMessage(report: report)
                : "Health checks finished"
            await refreshAll()
            let failing = report.checks.filter {
                ["fail", "error"].contains($0.status.lowercased())
            }
            return .completed(status: report.status, failingChecks: failing)
        } catch {
            doctor.finishRun(nil, failure: UserFacingError.message(error, action: "run the health checks"))
            setFailureStatus(error, action: "run the health checks")
            return .unavailable(statusText)
        }
    }

    /// Reconcile cheap live-owner rows so recovered conditions do not persist in the toolbar or require another full Doctor run.
    @MainActor
    func refreshLiveDoctorCoverage() async {
        guard let current = engine.doctor.report else { return }
        _ = await engine.doctor.reportRead.read({
        let liveChecks = await AppDoctorPort(dataRoot: engine.dataRoot, backgroundLoopsManager: backgroundLoopsManager)
            .runtime.liveDoctorCoverageChecks()
        let statusChecks = await DoctorFacade.statusChecks(
            dataRoot: engine.dataRoot,
            approvals: engine.approvals,
            repairDesk: false,
            stuckReason: DeskPageContent.stuckReason,
            safeDetail: EngineDoctorRuntime<AppDoctorPort>.safeDetail
        ).checks
        var refreshed = EngineDoctorRuntime<AppDoctorPort>.mergeReport(current, liveChecks: liveChecks + statusChecks)
        refreshed.checks = await DoctorReadout.repairProjection(refreshed.checks, dataRoot: engine.dataRoot)
        refreshed.status = DoctorReadout.doctorRollup(refreshed.checks.map(\.status))
        return refreshed
        }, publish: { engine.doctor.report = $0 })
    }

}

extension AppModel {
    // MARK: Integrations / inbox
    func inboxAction(_ id: String, action: String) async throws {
        // A native button starts this act; no running agent turn belongs to the tap.
        let turn = TurnRequest(message: "", sessionID: nil, surface: "native_actions",
            envelope: TurnEnvelope.personOnMac("mac_ui:inbox." + action, surface: "native_actions")).turn()
        try await InboxCardActions.perform(id, action: action, dataRootOverride: engine.dataRoot, turn: turn,
            effects: AppInboxCardActionEffects(inbox: engine.inbox))
    }
}
