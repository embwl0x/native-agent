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
import TelegramBot
import Connectors
import ChatTurnRuntime
import ChatTurnContracts
// Blueprint: | `AppModel+SkillsIntegrations.swift` | `AppModel`, `refreshTelegramSettingsDraft`, `LatestRead.refreshDraft`, `engine.connectors.update`: UI |

enum ConnectorUpdateOutcome: Equatable {
    case verified(ConnectorRecord)
    case failed(String)
}

struct TelegramSettingsDraftSnapshot: Equatable {
    var enabled: Bool
    var chats: String
    var users: String
    var requireMention: Bool
}

extension AppModel {
    var telegramSettingsDraftSnapshot: TelegramSettingsDraftSnapshot {
        TelegramSettingsDraftSnapshot(enabled: telegramEnabled, chats: telegramAllowedChats,
                                      users: telegramAllowedUsers, requireMention: telegramRequireMention)
    }
}

@MainActor
extension AppModel {
    /// Rebase only untouched clean fields from newest-started reads; user edits remain drafts.
    func refreshTelegramSettingsDraft<Value>(
        _ load: () async -> Value,
        snapshot: (Value) -> TelegramSettingsDraftSnapshot?,
        publish: (Value) -> Void = { _ in }
    ) async {
        let before = telegramSettingsDraftSnapshot
        let baseline = telegramSettingsDraftBaseline
        _ = await telegramSettingsRead.refreshDraft(load, apply: { value in
            if let saved = snapshot(value) {
                let current = telegramSettingsDraftSnapshot
                func mayUpdate<T: Equatable>(_ key: KeyPath<TelegramSettingsDraftSnapshot, T>) -> Bool {
                    current[keyPath: key] == before[keyPath: key]
                        && (baseline.map { before[keyPath: key] == $0[keyPath: key] } ?? true)
                }
                if mayUpdate(\.enabled) { telegramEnabled = saved.enabled }
                if mayUpdate(\.chats) { telegramAllowedChats = saved.chats }
                if mayUpdate(\.users) { telegramAllowedUsers = saved.users }
                if mayUpdate(\.requireMention) { telegramRequireMention = saved.requireMention }
                telegramSettingsDraftBaseline = saved
            }
            publish(value)
        })
    }

    func loadSkillManifests() async {
        isLoadingSkillManifests = true
        do {
            try await engine.tools.refreshSkills(includingSource: true)
            dismissSkillManifestFeedback()
        } catch {
            ModuleLog.app("%@", "[skills] learned skills read failed: \(error)")
            recordSkillManifestFailure("Couldn't read learned skills. Try again; if it keeps happening, the details are in the log.")
        }
        isLoadingSkillManifests = false
    }

    @MainActor
    func quarantineTool(_ tool: ToolRecord, reason: String = "Owner switched off from NativeAgent UI.") async {
        do {
            let updated = try await engine.tools.switchOff(id: tool.id, reason: reason)
            guard try await engine.tools.refreshAuthored(confirming: updated.id, status: "disabled") else {
                recordToolOperationStatus("Ability off could not be confirmed after reloading it.", outcome: .failed)
                return
            }
            recordToolOperationStatus("Ability off", outcome: .succeeded)
        } catch {
            recordToolOperationStatus(UserFacingError.message(error, action: "turn that ability off"), outcome: .failed, cause: error)
        }
    }

    @MainActor
    func promoteTool(_ tool: ToolRecord) async {
        if let refusal = engine.tools.keepRefusal(tool, turn: nil) {
            recordToolOperationStatus("Keeping unavailable: \(refusal)", outcome: .failed)
            return
        }
        do {
            let version = tool.reviewedKeepDigest
            guard version != nil || (tool.candidateDigest ?? tool.codeFingerprint) == nil
                && tool.activePath.map({ URL(fileURLWithPath: $0).pathExtension == "md" }) == true else {
                throw ToolRegistryError.invalidRequest("Refresh Tools before keeping this ability.")
            }
            let updated = try await engine.tools.keep(id: tool.id, version: version)
            guard try await engine.tools.refreshAuthored(confirming: updated.id, status: "active") else {
                recordToolOperationStatus("Keeping could not be confirmed after reloading the ability.", outcome: .failed)
                return
            }
            recordToolOperationStatus("Ability kept", outcome: .succeeded)
        } catch {
            recordToolOperationStatus(UserFacingError.message(error, action: "keep that ability"), outcome: .failed, cause: error)
        }
    }

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
    @discardableResult
    func saveTelegram() async -> TelegramSettingsSaveOutcome {
        isSavingTelegram = true
        telegramSettingsSaveOutcome = nil
        statusText = "Saving Telegram settings..."
        defer { isSavingTelegram = false }

        if let tokenError = TelegramFacade.tokenValidationMessage(for: telegramToken) {
            statusText = "Telegram save failed: \(tokenError)"
            let outcome = TelegramSettingsSaveOutcome.rejected(detail: tokenError)
            telegramSettingsSaveOutcome = outcome
            return outcome
        }
        guard TelegramBotTokenPresentation.canSave(
            draft: telegramToken,
            tokenConfigured: engine.telegram.status?.tokenConfigured == true
        ) else {
            let detail = "Add a bot token before saving settings."
            statusText = "Telegram save failed: \(detail)"
            let outcome = TelegramSettingsSaveOutcome.rejected(detail: detail)
            telegramSettingsSaveOutcome = outcome
            return outcome
        }
        let chats = parseTelegramNumericIDs(telegramAllowedChats)
        let users = parseTelegramNumericIDs(telegramAllowedUsers)
        let invalid = chats.invalidTokens + users.invalidTokens
        guard invalid.isEmpty else {
            let detail = "Invalid numeric ID(s): \(invalid.joined(separator: ", "))."
            statusText = "Telegram save failed: \(detail)"
            let outcome = TelegramSettingsSaveOutcome.rejected(detail: detail)
            telegramSettingsSaveOutcome = outcome
            return outcome
        }
        let normalizedEffort = ProvidersFacade.normalizedReasoningEffort(
            from: engine.providers.catalog,
            providers: engine.providers.connections,
            providerID: engine.providers.selection(for: "telegram").provider,
            model: telegramModel,
            selected: telegramReasoningEffort
        )
        telegramReasoningEffort = normalizedEffort
        let submittedEnabled = telegramEnabled
        let submittedModel = telegramModel
        let submittedToken = telegramToken
        do {
            try await engine.telegram.configureTelegram(
                token: submittedToken,
                allowedChatIds: chats.canonicalIDs,
                allowedUserIds: users.canonicalIDs,
                requireMention: telegramRequireMention,
                model: submittedModel,
                reasoningEffort: normalizedEffort,
                enabled: submittedEnabled,
                restartPollLoop: { [backgroundLoopsManager] in
                    _ = await NativeAgentEngine.restartBackgroundLoop(
                        id: "telegram_poll",
                        manager: backgroundLoopsManager
                    )
                }
            )
            if telegramToken == submittedToken { telegramToken = "" }
            await refreshAll()
            if pendingTelegramModel == submittedModel { pendingTelegramModel = nil }
            if pendingTelegramReasoningEffort == normalizedEffort { pendingTelegramReasoningEffort = nil }
            statusText = engine.telegram.status?.tokenConfigured == true ? "Telegram settings saved"
                : "Telegram settings saved. Add a bot token to enable Telegram."
            let outcome = TelegramSettingsSaveOutcome.saved(
                tokenConfigured: engine.telegram.status?.tokenConfigured == true,
                enabled: submittedEnabled,
                allowlistCount: Set(chats.canonicalIDs + users.canonicalIDs).count
            )
            telegramSettingsSaveOutcome = outcome
            return outcome
        } catch {
            let detail = UserFacingError.cause(error, action: "save Telegram settings")
            setFailureStatus("Couldn't save Telegram settings. " + detail, cause: error)
            let outcome = TelegramSettingsSaveOutcome.failed(detail: detail)
            telegramSettingsSaveOutcome = outcome
            return outcome
        }
    }

    @MainActor
    /// Let a Telegram caller defer poll restart because shutdown waits for its own turn too.
    func clearTelegramToken(restartPollLoop: Bool = true) async -> AppMutationResult {
        isSavingTelegram = true
        statusText = "Clearing Telegram bot token..."
        defer { isSavingTelegram = false }
        let restart: (@Sendable () async -> Bool)? = restartPollLoop
            ? { @Sendable [backgroundLoopsManager] in
                await NativeAgentEngine.restartBackgroundLoop(
                    id: "telegram_poll",
                    manager: backgroundLoopsManager
                ).didRestart
            }
            : nil
        let submittedToken = telegramToken
        do {
            try await engine.telegram.disconnectTelegram(restartPollLoop: restart)
            if telegramToken == submittedToken { telegramToken = "" }
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
        telegramStatusRefreshError = nil
        var published = false
        await refreshTelegramSettingsDraft({ () async -> Result<TelegramPresentationSnapshot, Error> in
        do {
            return .success(try await engine.telegram.refresh(manager: backgroundLoopsManager))
        } catch { return .failure(error) }
        }, snapshot: { result in
            guard case .success(let status) = result else { return nil }
            return TelegramSettingsDraftSnapshot(
                enabled: status.enabled, chats: status.allowedChatIds.joined(separator: ","),
                users: status.allowedUserIds.joined(separator: ","), requireMention: status.requireMention
            )
        }, publish: { result in
        switch result {
        case .success(let status):
            telegramStatusRefreshError = status.credentialIssue ?? status.routingIssue
            statusText = telegramStatusRefreshError ?? "Telegram status refreshed"
            published = telegramStatusRefreshError == nil
        case .failure(let error):
            setFailureStatus(error, action: "refresh Telegram")
            telegramStatusRefreshError = UserFacingError.advice(for: error)
        }
        })
        return published
    }

    @MainActor
    func testTelegram() async -> AppMutationResult {
        isTestingTelegram = true
        statusText = "Sending Telegram test reply..."
        defer { isTestingTelegram = false }

        do {
            let chatId = splitIDs(telegramAllowedChats).first ?? splitIDs(telegramAllowedUsers).first
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
            telegramStatusRefreshError = nil
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

    private func splitIDs(_ value: String) -> [String] {
        value
            .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

}

extension AppModel {
    @MainActor
    @discardableResult
    func refreshToolsFromToolbar() async -> ToolsRefreshPresentation.State {
        guard !isRefreshingTools else {
            return .alreadyRefreshing
        }
        isRefreshingTools = true
        toolsRefreshState = .refreshing
        defer { isRefreshingTools = false }

        await refreshForSidebarItem(.tools)
        let result = ToolsRefreshPresentation.completion(
            panelRefresh: panelRefreshStatus[.tools],
            catalogLoadFailed: engine.tools.catalogLoadError != nil,
            hasCatalog: engine.tools.catalog != nil
        )
        toolsRefreshState = result
        if let message = ToolsRefreshPresentation.message(for: result) {
            statusText = message
        }
        return result
    }

    // MARK: Integrations / inbox
    func inboxAction(_ id: String, action: String) async throws {
        // A native button starts this act; no running agent turn belongs to the tap.
        let turn = TurnRequest(message: "", sessionID: nil, surface: "native_actions",
            envelope: TurnEnvelope.personOnMac("mac_ui:inbox." + action, surface: "native_actions")).turn()
        try await InboxCardActions.perform(id, action: action, dataRootOverride: engine.dataRoot, turn: turn,
            effects: AppInboxCardActionEffects(inbox: engine.inbox))
    }
}
