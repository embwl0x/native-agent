import EngineRuntime
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
import Skills
import Connectors

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
    @MainActor
    func deleteSkill(_ skill: SkillRecord) async {
        do {
            try await NativeSkillRegistryActions.deleteSkill(id: skill.id, dataRoot: engine.dataRoot)
            statusText = "Skill deleted"
            await refreshAll()
        } catch {
            setFailureStatus(error, action: "delete that skill")
        }
    }

    @MainActor
    func loadSkillManifests() async {
        isLoadingSkillManifests = true
        let root = engine.dataRoot
        async let learnedSkillsTask: [SkillRecord] = try await RuntimeReadProjection.skills(dataRoot: engine.dataRoot)
        var failures: [String] = []
        let learnedSkills: [SkillRecord]
        do {
            learnedSkills = try await learnedSkillsTask
        } catch {
            learnedSkills = []
            ModuleLog.app("%@", "[skills] learned skills read failed: \(error)")
            failures.append("learned skills")
        }
        let infos: [SkillInfo] = await Task.detached(priority: .utility) {
            var infos: [SkillInfo] = []
            for skill in learnedSkills {
                let review = try? SwiftNativeSkillsClient(root: root).readSkill(name: skill.id, source: true)
                let info = SkillInfo.learnedSkill(skill, review: review)
                infos.append(info)
            }
            return infos
        }.value
        skillManifests = infos
        if !failures.isEmpty {
            recordSkillManifestFailure("Couldn't read \(failures.joined(separator: " or ")). Try again; if it keeps happening, the details are in the log.")
        } else if skillLifecycleFeedback?.kind == .failure {
            dismissSkillManifestFeedback()
        }
        isLoadingSkillManifests = false
    }

    /// `reviewSheet: false` is the agent's `skill_manage enable`, which also
    /// turns a disabled skill back on; the sheet installs drafts only.
    @MainActor
    @discardableResult
    func installReviewedSkill(_ info: SkillInfo, reviewSheet: Bool = true) async -> SkillReviewInstallOutcome {
        if reviewSheet, let refusal = InstalledSkillInventory.reviewInstallRefusal(
            version: info.registry.version, state: info.registry.state, name: info.registry.name,
            hasCandidate: info.candidateDigest != nil && info.readme != nil,
            validationStatus: info.validationStatus
        ) {
            return .refused(detail: refusal)
        }
        let requestedName = info.registry.name
        do {
            try await NativeSkillRegistryActions.enableSkill(
                name: requestedName, dataRoot: engine.dataRoot,
                reviewedDigest: info.candidateDigest, admitScript: true
            )
            await loadSkillManifests()
            let recovered = skillManifests.first { $0.id == info.id }
            guard let recovered,
                  ["installed", "active"].contains(recovered.registry.state.lowercased()) else {
                let detail = "Install could not be verified after the registry refresh."
                recordSkillManifestFailure(detail)
                return .failed(detail: detail)
            }
            let receipt = SkillReviewInstallReceipt(
                requestedName: requestedName,
                confirmedName: recovered.manifest.name,
                confirmedState: recovered.registry.state.lowercased()
            )
            statusText = receipt.confirmedState == "active"
                ? "Skill active"
                : "Skill installed"
            return .installed(receipt)
        } catch {
            let detail = UserFacingError.message(error, action: "install that skill")
            recordSkillManifestFailure(detail)
            return .failed(detail: detail)
        }
    }

    @MainActor
    func quarantineTool(_ tool: ToolRecord, reason: String = "Owner switched off from NativeAgent UI.") async {
        do {
            let updated = try await engine.tools.quarantine(id: tool.id, reason: reason, ownerAuthorized: true)
            guard try await engine.tools.refreshAuthored(confirming: updated.id, status: "disabled") else {
                recordToolOperationStatus(
                    "Tool off could not be confirmed after reloading the ability.",
                    outcome: .failed
                )
                return
            }
            recordToolOperationStatus("Tool off", outcome: .succeeded)
        } catch {
            recordToolOperationStatus(UserFacingError.message(error, action: "turn that tool off"), outcome: .failed, cause: error)
        }
    }

    @MainActor
    func promoteTool(_ tool: ToolRecord, userRequested: Bool = true) async {
        if let refusal = ToolApprovalEligibility.refusal(for: tool, ownerAuthorized: true) {
            recordToolOperationStatus("Tool activation unavailable: \(refusal)", outcome: .failed)
            return
        }
        do {
            let updated = try await engine.tools.promote(id: tool.id, allowRisky: userRequested, ownerAuthorized: true)
            guard try await engine.tools.refreshAuthored(confirming: updated.id, status: "active") else {
                recordToolOperationStatus(
                    "Tool activation could not be confirmed after reloading the registry.",
                    outcome: .failed
                )
                return
            }
            recordToolOperationStatus("Tool activated", outcome: .succeeded)
        } catch {
            recordToolOperationStatus(UserFacingError.message(error, action: "turn that tool on"), outcome: .failed, cause: error)
        }
    }

    @MainActor
    func addWorkspaceWithReceipt(name: String, path: String, writable: Bool) async -> WorkspaceAddOutcome {
        do {
            let result = try await ConnectorRegistryActions.addWorkspace(
                name: name, path: path, permissions: writable ? ["read", "write"] : ["read"], root: engine.dataRoot
            )
            guard result.verified else {
                let detail = "The workspace registry did not confirm the saved workspace."
                statusText = "Workspace add failed: \(detail)"
                return .failed(detail)
            }
            workspaces = result.refreshed
            statusText = "Workspace added and verified"
            return .verified(result.added)
        } catch {
            let detail = UserFacingError.cause(error, action: "add that workspace")
            setFailureStatus("Couldn't add that workspace. " + detail, cause: error)
            return .failed(detail)
        }
    }

    @MainActor
    func searchWorkspace(_ query: String) async {
        do {
            let response = try await ConnectorRegistryActions.searchWorkspace(query: query, root: engine.dataRoot)
            workspaceSearchResults = response.results
            statusText = "Workspace search found \(response.results.count)"
        } catch {
            setFailureStatus(error, action: "search the workspace")
        }
    }

    @MainActor
    func updateConnector(_ connector: ConnectorRecord, enabled: Bool) async -> ConnectorUpdateOutcome {
        do {
            let result = try await ConnectorStatusProjection.updateConnectorAndVerify(
                id: connector.id, enabled: enabled, root: engine.dataRoot, platform: AppConnectorStatusPlatform()
            )
            guard let confirmed = result.confirmed else {
                let detail = "The registry did not confirm the requested \(enabled ? "enable" : "disable") change."
                statusText = "Connector update failed: \(detail)"
                return .failed(detail)
            }
            connectors = result.refreshed
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
            if case .found(let url) = outcome { searxngBaseURL = url }
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
            tokenConfigured: telegramTokenConfigured
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
            model: telegramModel,
            selected: telegramReasoningEffort
        )
        telegramReasoningEffort = normalizedEffort
        let submittedEnabled = telegramEnabled
        do {
            try await engine.telegram.configureTelegram(
                token: telegramToken,
                allowedChatIds: chats.canonicalIDs,
                allowedUserIds: users.canonicalIDs,
                requireMention: telegramRequireMention,
                model: telegramModel,
                reasoningEffort: normalizedEffort,
                enabled: submittedEnabled,
                restartPollLoop: { [backgroundLoopsManager] in _ = await NativeAgentEngine.restartBackgroundLoop(id: "telegram_poll", manager: backgroundLoopsManager) }
            )
            telegramToken = ""
            await refreshAll()
            statusText = telegramTokenConfigured ? "Telegram settings saved" : "Telegram settings saved. Add a bot token to enable Telegram."
            let outcome = TelegramSettingsSaveOutcome.saved(
                tokenConfigured: telegramTokenConfigured,
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
    /// `restartPollLoop` false: the caller restarts it (the door's
    /// telegram.disconnect, which may run inside a Telegram turn the restart awaits).
    func clearTelegramToken(restartPollLoop: Bool = true) async {
        isSavingTelegram = true
        statusText = "Clearing Telegram bot token..."
        defer { isSavingTelegram = false }
        let restart: (@Sendable () async -> Void)? = restartPollLoop
            ? { @Sendable [backgroundLoopsManager] in _ = await NativeAgentEngine.restartBackgroundLoop(id: "telegram_poll", manager: backgroundLoopsManager) }
            : nil
        do {
            try await engine.telegram.configureTelegram(
                token: "",
                allowedChatIds: splitIDs(telegramAllowedChats),
                allowedUserIds: splitIDs(telegramAllowedUsers),
                requireMention: telegramRequireMention,
                model: telegramModel,
                reasoningEffort: telegramReasoningEffort,
                enabled: false,
                clearToken: true,
                restartPollLoop: restart
            )
            telegramToken = ""
            await refreshAll()
            statusText = "Telegram bot token cleared"
        } catch {
            setFailureStatus("Removing the Telegram token failed. " + UserFacingError.cause(error, action: "remove the Telegram token"), cause: error)
        }
    }

    @MainActor
    @discardableResult
    func refreshTelegram() async -> Bool {
        let requestID = UUID()
        telegramSettingsReadID = requestID
        let before = telegramSettingsDraftSnapshot
        let baseline = telegramSettingsDraftBaseline
        telegramStatusRefreshError = nil
        do {
            let status: TelegramPresentationSnapshot
            var credentialUnavailable = false
            do {
                status = try await engine.telegram.load(manager: backgroundLoopsManager)
            } catch is DeviceSecretKeychain.Failure {
                // Keep validated authority fields editable for explicit grant
                // replacement or disconnect; this is not transport readiness.
                status = try await engine.telegram.load(manager: backgroundLoopsManager, credentialUnavailable: true)
                credentialUnavailable = true
            }
            guard !Task.isCancelled, telegramSettingsReadID == requestID else { return false }
            if credentialUnavailable { telegramStatusRefreshError = UserFacingError.advice(for: DeviceSecretKeychain.Failure.unavailable) }
            engine.telegram.status = status
            telegramTokenConfigured = status.tokenConfigured
            // Refresh untouched fields only. Navigation and a read completing
            // late must not silently discard an authorization draft.
            func mayUpdate<T: Equatable>(_ key: KeyPath<TelegramSettingsDraftSnapshot, T>) -> Bool {
                telegramSettingsDraftSnapshot[keyPath: key] == before[keyPath: key]
                    && (baseline.map { before[keyPath: key] == $0[keyPath: key] } ?? true)
            }
            if mayUpdate(\.enabled) { telegramEnabled = status.enabled }
            if mayUpdate(\.chats) { telegramAllowedChats = status.allowedChatIds.joined(separator: ",") }
            if mayUpdate(\.users) { telegramAllowedUsers = status.allowedUserIds.joined(separator: ",") }
            if mayUpdate(\.requireMention) { telegramRequireMention = status.requireMention }
            telegramSettingsDraftBaseline = TelegramSettingsDraftSnapshot(
                enabled: status.enabled, chats: status.allowedChatIds.joined(separator: ","),
                users: status.allowedUserIds.joined(separator: ","), requireMention: status.requireMention
            )
            statusText = telegramStatusRefreshError ?? "Telegram status refreshed"
            return true
        } catch {
            guard !Task.isCancelled, telegramSettingsReadID == requestID else { return false }
            setFailureStatus(error, action: "refresh Telegram")
            telegramStatusRefreshError = UserFacingError.advice(for: error)
            return false
        }
    }

    @MainActor
    func testTelegram() async {
        isTestingTelegram = true
        statusText = "Sending Telegram test reply..."
        defer { isTestingTelegram = false }

        do {
            let chatId = splitIDs(telegramAllowedChats).first ?? splitIDs(telegramAllowedUsers).first
            let result = try await engine.telegram.sendTelegramTestReply(chatId: chatId, manager: backgroundLoopsManager)
            await refreshAll()
            statusText = TelegramTestReplyPresentation.summary(for: result)
        } catch {
            setFailureStatus("Telegram test failed. " + UserFacingError.cause(error, action: "test Telegram"), cause: error)
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
            engine.telegram.status = receipt.status
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
    func runDoctor(repair: Bool, repairScope: DoctorRepairScope = .automatic) async -> DoctorFacade.RunOutcome {
        // PATCH-2026-05-30: surface in-flight state to the UI so the user
        // sees a spinner + "Running…" text instead of an apparent freeze.
        // Block concurrent invocations — clicking Run while a run is in
        // flight should be a no-op, not a queued duplicate.
        let doctor = engine.doctor
        guard !doctor.isRunning else {
            return .unavailable("Health checks are already running.")
        }
        doctor.isRunning = true
        doctor.runStartedAt = Date()
        // gpt-5.5 review (B2 wave): invalidate the snapshot-reuse freshness
        // stamp for the whole run — Support Snapshot must never reuse a report
        // from BEFORE an in-flight run (the stamp re-lands on success only).
        doctor.reportCompletedAt = nil
        statusText = repair ? "Running repair…" : "Running health checks…"
        defer {
            doctor.isRunning = false
            doctor.runStartedAt = nil
        }
        do {
            var report = try await AppDoctorPort(dataRoot: engine.dataRoot, backgroundLoopsManager: backgroundLoopsManager)
                .runtime.runDoctor(repair: repair, repairScope: repairScope)
            let buttonRepair: Bool
            if case .button = repairScope {
                buttonRepair = repair && doctor.report?.checks.contains {
                    $0.id == "status.desk_attention" && $0.repair_available == true
                } == true
            } else {
                buttonRepair = false
            }
            let status = await DoctorFacade.statusChecks(dataRoot: engine.dataRoot, approvals: engine.approvals, repairDesk: buttonRepair, stuckReason: DeskPageContent.stuckReason, safeDetail: EngineDoctorRuntime<AppDoctorPort>.safeDetail)
            report = EngineDoctorRuntime<AppDoctorPort>.mergeReport(report, liveChecks: status.checks)
            report.repaired = report.repaired || status.repaired
            doctor.report = report
            doctor.reportCompletedAt = Date()
            statusText = repair
                ? DoctorFacade.repairCompletionMessage(report: report)
                : "Health checks finished"
            await refreshAll()
            let failing = report.checks.filter {
                ["fail", "error"].contains($0.status.lowercased())
            }
            return .completed(status: report.status, failingChecks: failing)
        } catch {
            setFailureStatus(error, action: "run the health checks")
            return .unavailable(statusText)
        }
    }

    /// Reconcile the cheap live-owner rows in an existing Doctor report.
    /// This avoids preserving a recovered Telegram/provider/tool condition in
    /// the toolbar while also avoiding a second full Doctor run on tab entry.
    @MainActor
    func refreshLiveDoctorCoverage() async {
        guard let current = engine.doctor.report else { return }
        let liveChecks = await AppDoctorPort(dataRoot: engine.dataRoot, backgroundLoopsManager: backgroundLoopsManager)
            .runtime.liveDoctorCoverageChecks()
        let statusChecks = await DoctorFacade.statusChecks(dataRoot: engine.dataRoot, approvals: engine.approvals, repairDesk: false, stuckReason: DeskPageContent.stuckReason, safeDetail: EngineDoctorRuntime<AppDoctorPort>.safeDetail).checks
        let withoutRetiredProbe = DoctorReport(status: current.status, repaired: current.repaired,
                                               checks: current.checks.filter { $0.id != "status.app_health" && $0.id != "status.living_sources" })
        engine.doctor.report = EngineDoctorRuntime<AppDoctorPort>.mergeReport(withoutRetiredProbe, liveChecks: liveChecks + statusChecks)
    }

    private func splitIDs(_ value: String) -> [String] {
        value
            .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

}
