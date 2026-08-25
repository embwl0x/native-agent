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

enum ToolApprovalEligibility {
    /// The mounted control only offers activation for an actual proposal that
    /// the last validator pass marked valid. SwiftNativeToolExecution repeats
    /// these checks at promotion time; this UI/app-model gate prevents known
    /// terminal or unloaded records from looking actionable in the meantime.
    static func refusal(for tool: ToolRecord) -> String? {
        let status = (tool.status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["proposed", "draft", "drafted"].contains(status) else {
            if status == "quarantined" {
                return "Quarantined tools must be reviewed before they can be approved."
            }
            if status.isEmpty {
                return "This tool has no loaded proposal status. Refresh before approving it."
            }
            return "Only proposed tools can be approved."
        }
        guard tool.validationStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "valid" else {
            return "This proposal has not passed validation."
        }
        return nil
    }
}

/// The authored-tools row is a projection of the same promotion boundary the
/// action repeats. Keeping its enabled state and refusal copy here prevents a
/// mounted SwiftUI control from becoming a second, untested eligibility rule.
enum ToolApprovalPresentation {
    struct Control: Equatable {
        let accessibilityIdentifier: String
        let isEnabled: Bool
        let help: String
        let refusal: String?
    }

    static func control(for tool: ToolRecord) -> Control {
        let refusal = ToolApprovalEligibility.refusal(for: tool)
        return Control(
            accessibilityIdentifier: "tools.authored.approve.\(tool.id)",
            isEnabled: refusal == nil,
            help: refusal ?? "Approve this validated proposal and activate it.",
            refusal: refusal
        )
    }
}

/// The result of one SearXNG discovery attempt. Research owns presentation of
/// this result so an incidental discovery cannot replace the app-wide status
/// message used by other mounted surfaces.
enum SearXNGAutodetectOutcome: Equatable {
    case found(String)
    case notFound(String)
    case failed(String)
}

@MainActor
extension AppModel {
    @MainActor
    func setSkill(_ skill: SkillRecord, status: String) async {
        do {
            _ = try await client.updateSkill(id: skill.id, status: status)
            Task.detached(priority: .utility) { await syncSkillPointerIndex() }
            statusText = "Skill \(status)"
            await refreshAll()
        } catch {
            statusText = "Skill update failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func deleteSkill(_ skill: SkillRecord) async {
        do {
            _ = try await client.deleteSkill(id: skill.id)
            Task.detached(priority: .utility) { await syncSkillPointerIndex() }
            statusText = "Skill deleted"
            await refreshAll()
        } catch {
            statusText = "Skill delete failed: \(error.localizedDescription)"
        }
    }

    // PATCH-2026-05-06: skill-ui AppModel methods — load registry from filesystem (v1 fallback)
    @MainActor
    func loadSkillManifests() async {
        isLoadingSkillManifests = true
        let api = client
        async let registryEntriesTask: [SkillRegistryEntry] = try await api.readSkillRegistry()
        async let learnedSkillsTask: [SkillRecord] = try await api.getSkills()
        var failures: [String] = []
        let entries: [SkillRegistryEntry]
        do {
            entries = try await registryEntriesTask
        } catch {
            entries = []
            failures.append("manifest registry: \(error.localizedDescription)")
        }
        let learnedSkills: [SkillRecord]
        do {
            learnedSkills = try await learnedSkillsTask
        } catch {
            learnedSkills = []
            failures.append("learned skills: \(error.localizedDescription)")
        }
        // mainactor_icloud: the per-skill manifest/README reads below use synchronous
        // Data(contentsOf:)/String(contentsOf:) disk I/O. Run them off the main thread
        // (awaited to preserve ordering), then hop back to @MainActor for state below.
        let skillClient = client
        let infos: [SkillInfo] = await Task.detached(priority: .utility) {
            var infos: [SkillInfo] = []
            var seenIds = Set<String>()
            for skill in learnedSkills {
                let info = SkillInfo.learnedSkill(skill)
                infos.append(info)
                seenIds.insert(info.id.lowercased())
                seenIds.insert(info.manifest.name.lowercased())
            }
            for entry in entries {
                let key = entry.name.lowercased()
                if seenIds.contains(key) { continue }
                let manifest = try? skillClient.readSkillManifest(entry: entry)
                if let manifest {
                    let readme = try? skillClient.readSkillReadme(entry: entry)
                    infos.append(SkillInfo(id: entry.name, manifest: manifest, registry: entry, readme: readme))
                    seenIds.insert(entry.name.lowercased())
                }
            }
            return infos
        }.value
        skillManifests = infos
        if !failures.isEmpty {
            recordSkillManifestFailure("Skill catalog unavailable: \(failures.joined(separator: "; "))")
        } else if skillLifecycleFeedback?.kind == .failure {
            dismissSkillManifestFeedback()
        }
        isLoadingSkillManifests = false
    }

    @MainActor
    @discardableResult
    func installReviewedSkill(_ info: SkillInfo) async -> SkillReviewInstallOutcome {
        if let refusal = SkillReviewInstallPresentation.preflight(for: info) {
            return .refused(detail: refusal)
        }
        let requestedName = info.registry.name
        do {
            try await client.enableSkill(name: requestedName)
            await loadSkillManifests()
            let key = requestedName.lowercased()
            let recovered = skillManifests.first { info in
                info.id.lowercased() == key || info.manifest.name.lowercased() == key
            }
            guard let recovered,
                  ["installed", "active"].contains(recovered.registry.state.lowercased()) else {
                let detail = "Install could not be verified after the registry refresh."
                recordSkillManifestFailure(detail)
                return .failed(detail: detail)
            }
            Task.detached(priority: .utility) { await syncSkillPointerIndex() }
            let receipt = SkillReviewInstallReceipt(
                requestedName: requestedName,
                confirmedName: recovered.manifest.name,
                confirmedState: recovered.registry.state.lowercased()
            )
            statusText = receipt.confirmedState == "active"
                ? "Skill active and available to recall"
                : "Skill installed and available to recall"
            return .installed(receipt)
        } catch {
            let detail = "Install failed: \(error.localizedDescription)"
            recordSkillManifestFailure(detail)
            return .failed(detail: detail)
        }
    }

    @MainActor
    func disableSkillManifest(name: String) async {
        do {
            try await client.disableSkill(name: name)
            await loadSkillManifests()
            Task.detached(priority: .utility) { await syncSkillPointerIndex() }
        } catch {
            recordSkillManifestFailure("Disable failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    func setToolAutoRun(_ tool: ToolRecord, autoRun: Bool) async {
        do {
            let updated = try await client.updateTool(id: tool.id, autoRun: autoRun)
            let reloaded = try await client.getTools()
            guard let confirmed = reloaded.first(where: { $0.id == updated.id }),
                  confirmed.autoRun == autoRun else {
                recordToolOperationStatus(
                    "Tool auto-run update could not be confirmed after reloading the registry.",
                    outcome: .failed
                )
                return
            }
            tools = reloaded
            recordToolOperationStatus(
                autoRun ? "Tool auto-run enabled" : "Tool auto-run disabled",
                outcome: .succeeded
            )
        } catch {
            recordToolOperationStatus("Tool update failed: \(error.localizedDescription)", outcome: .failed)
        }
    }

    @MainActor
    func quarantineTool(_ tool: ToolRecord) async {
        do {
            let updated = try await client.quarantineTool(
                id: tool.id,
                reason: "User quarantined from NativeAgent UI."
            )
            let reloaded = try await client.getTools()
            guard let confirmed = reloaded.first(where: { $0.id == updated.id }),
                  confirmed.status == "quarantined" else {
                recordToolOperationStatus(
                    "Tool quarantine could not be confirmed after reloading the registry.",
                    outcome: .failed
                )
                return
            }
            tools = reloaded
            recordToolOperationStatus("Tool quarantined", outcome: .succeeded)
        } catch {
            recordToolOperationStatus("Tool quarantine failed: \(error.localizedDescription)", outcome: .failed)
        }
    }

    @MainActor
    func promoteTool(_ tool: ToolRecord, userRequested: Bool = true) async {
        if let refusal = ToolApprovalEligibility.refusal(for: tool) {
            recordToolOperationStatus("Tool activation unavailable: \(refusal)", outcome: .failed)
            return
        }
        do {
            let updated = try await client.promoteTool(
                id: tool.id,
                allowRisky: userRequested,
                userRequested: userRequested
            )
            let reloaded = try await client.getTools()
            guard let confirmed = reloaded.first(where: { $0.id == updated.id }),
                  confirmed.status == "active" else {
                recordToolOperationStatus(
                    "Tool activation could not be confirmed after reloading the registry.",
                    outcome: .failed
                )
                return
            }
            tools = reloaded
            recordToolOperationStatus("Tool activated", outcome: .succeeded)
        } catch {
            recordToolOperationStatus("Tool activation failed: \(error.localizedDescription)", outcome: .failed)
        }
    }

    @MainActor
    func runEval() async {
        do {
            _ = try await client.runEval(name: "NativeAgent operator workflow eval")
            disabledFeature = nil
            statusText = "Eval finished"
            await refreshAll()
        } catch let err as NSError where AppModel.isNotImplemented(err) {
            disabledFeature = AppModel.disabledBadge(for: "Eval run", error: err)
            statusText = disabledFeature ?? "Eval disabled"
        } catch {
            statusText = "Eval failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func addWorkspace(name: String, path: String, writable: Bool) async -> Bool {
        if case .verified = await addWorkspaceWithReceipt(name: name, path: path, writable: writable) {
            return true
        }
        return false
    }

    @MainActor
    func addWorkspaceWithReceipt(name: String, path: String, writable: Bool) async -> WorkspaceAddOutcome {
        do {
            let added = try await client.addWorkspace(name: name, path: path, permissions: writable ? ["read", "write"] : ["read"])
            let refreshed = try await client.getWorkspaces()
            guard refreshed.contains(where: { $0.id == added.id }) else {
                let detail = "The workspace registry did not confirm the saved workspace."
                statusText = "Workspace add failed: \(detail)"
                return .failed(detail)
            }
            workspaces = refreshed
            statusText = "Workspace added and verified"
            return .verified(added)
        } catch {
            let detail = error.localizedDescription
            statusText = "Workspace add failed: \(detail)"
            return .failed(detail)
        }
    }

    @MainActor
    func searchWorkspace(_ query: String) async {
        do {
            let response = try await client.searchWorkspace(query: query)
            workspaceSearchResults = response.results
            statusText = "Workspace search found \(response.results.count)"
        } catch {
            statusText = "Workspace search failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func updateConnector(_ connector: ConnectorRecord, enabled: Bool) async -> ConnectorUpdateOutcome {
        do {
            let updated = try await client.updateConnector(id: connector.id, enabled: enabled)
            let refreshed = try await client.getConnectors()
            guard let confirmed = refreshed.first(where: { $0.id == updated.id }),
                  confirmed.enabled == enabled else {
                let detail = "The registry did not confirm the requested \(enabled ? "enable" : "disable") change."
                statusText = "Connector update failed: \(detail)"
                return .failed(detail)
            }
            connectors = refreshed
            statusText = "Connector \(confirmed.enabled ? "enabled" : "disabled") and verified"
            return .verified(confirmed)
        } catch {
            let detail = error.localizedDescription
            statusText = "Connector update failed: \(detail)"
            return .failed(detail)
        }
    }

    @MainActor
    func autodetectSearXNG() async -> SearXNGAutodetectOutcome {
        do {
            let detected = try await client.autodetectSearXNG()
            return applySearXNGAutodetect(detected)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Applies only a usable discovery response. The UI deliberately receives
    /// the typed outcome instead of consulting or replacing `statusText`, which
    /// belongs to cross-app work such as doctor, settings, and tool actions.
    func applySearXNGAutodetect(_ detected: DetectSearXNGResponse) -> SearXNGAutodetectOutcome {
        guard detected.found else {
            let detail = detected.error?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                return .notFound(detail)
            }
            return .notFound("No reachable local instance was found.")
        }
        guard let baseURL = detected.baseURL,
              !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("SearXNG detection returned no usable URL.")
        }
        do {
            let normalized = try NativeClient.normalizedSearXNGBaseURL(baseURL)
            searxngBaseURL = normalized
            return .found(normalized)
        } catch {
            return .failed("SearXNG detection returned an invalid URL: \(error.localizedDescription)")
        }
    }

    @MainActor
    @discardableResult
    func saveTelegram() async -> TelegramSettingsSaveOutcome {
        isSavingTelegram = true
        telegramSettingsSaveOutcome = nil
        statusText = "Saving Telegram settings..."
        defer { isSavingTelegram = false }

        if let tokenError = TelegramBotTokenPresentation.validationMessage(for: telegramToken) {
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
        let normalizedEffort = normalizedReasoningEffort(
            from: modelCatalog,
            model: telegramModel,
            selected: telegramReasoningEffort
        )
        telegramReasoningEffort = normalizedEffort
        do {
            try await client.configureTelegram(
                token: telegramToken,
                allowedChatIds: chats.canonicalIDs,
                allowedUserIds: users.canonicalIDs,
                requireMention: telegramRequireMention,
                model: telegramModel,
                reasoningEffort: normalizedEffort,
                enabled: telegramEnabled
            )
            telegramToken = ""
            await refreshAll()
            statusText = telegramTokenConfigured ? "Telegram settings saved" : "Telegram settings saved. Add a bot token to enable Telegram."
            let outcome = TelegramSettingsSaveOutcome.saved(
                tokenConfigured: telegramTokenConfigured,
                enabled: telegramEnabled,
                allowlistCount: Set(chats.canonicalIDs + users.canonicalIDs).count
            )
            telegramSettingsSaveOutcome = outcome
            return outcome
        } catch {
            statusText = "Telegram save failed: \(error.localizedDescription)"
            let outcome = TelegramSettingsSaveOutcome.failed(detail: error.localizedDescription)
            telegramSettingsSaveOutcome = outcome
            return outcome
        }
    }

    @MainActor
    func clearTelegramToken() async {
        isSavingTelegram = true
        statusText = "Clearing Telegram bot token..."
        defer { isSavingTelegram = false }
        do {
            try await client.configureTelegram(
                token: "",
                allowedChatIds: splitIDs(telegramAllowedChats),
                allowedUserIds: splitIDs(telegramAllowedUsers),
                requireMention: telegramRequireMention,
                model: telegramModel,
                reasoningEffort: telegramReasoningEffort,
                enabled: false,
                clearToken: true
            )
            telegramToken = ""
            await refreshAll()
            statusText = "Telegram bot token cleared"
        } catch {
            statusText = "Telegram token clear failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func refreshTelegram() async {
        telegramStatusRefreshError = nil
        do {
            telegramStatus = try await client.getTelegramStatus()
            telegramTokenConfigured = telegramStatus?.tokenConfigured ?? telegramTokenConfigured
            telegramEnabled = telegramStatus?.enabled ?? telegramEnabled
            statusText = "Telegram status refreshed"
        } catch {
            telegramStatusRefreshError = error.localizedDescription
            statusText = "Telegram refresh failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    func testTelegram() async {
        isTestingTelegram = true
        statusText = "Sending Telegram test reply..."
        defer { isTestingTelegram = false }

        do {
            let chatId = splitIDs(telegramAllowedChats).first ?? splitIDs(telegramAllowedUsers).first
            let result = try await client.testTelegram(chatId: chatId)
            await refreshAll()
            statusText = TelegramTestReplyPresentation.summary(for: result)
        } catch {
            statusText = "Telegram test failed: \(error.localizedDescription)"
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
            let receipt = try await client.clearTelegramLogs()
            telegramStatus = receipt.status
            telegramStatusRefreshError = nil
            telegramClearLogsOutcome = .completed(receipt)
            statusText = TelegramClearLogsPresentation.summary(for: receipt)
        } catch {
            let detail = error.localizedDescription
            telegramClearLogsOutcome = .failed(detail: detail)
            statusText = "Clear Telegram logs failed: \(detail)"
        }
    }

    /// What a Doctor run actually produced.
    ///
    /// gpt-5.5 review BLOCKING 2 (2026-08-02): `runDoctor` used to return a Bool
    /// that meant "a report came back", and onboarding read it as "the repair
    /// worked". A repair that ran to completion over a store it could NOT fix
    /// returned `true`, so the wizard showed "<Agent> is ready" over a broken
    /// scaffold. The two questions are now distinct on the type.
    enum DoctorRunOutcome: Equatable {
        /// No report: another run held the lock, or the run threw.
        case unavailable(String)
        /// A report came back. `failingChecks` are its `status == fail|error`
        /// rows — the run completing says nothing about them.
        case completed(status: String, failingChecks: [DoctorCheck])

        /// True when the run produced a report at all. This is the old Bool's
        /// meaning; callers that only wanted "did it run" keep using it.
        var didRun: Bool {
            if case .completed = self { return true }
            return false
        }

        /// Failing rows outside the `live.*` namespace, which covers optional
        /// user-configured subsystems (Telegram token, SearXNG URL). Those are
        /// real Doctor findings but they are NOT the app-owned scaffold, and
        /// blocking onboarding on them would strand a user who skipped setup.
        var failingScaffoldChecks: [DoctorCheck] {
            guard case .completed(_, let failing) = self else { return [] }
            return failing.filter { !$0.id.hasPrefix("live.") }
        }

        /// One line naming what to fix, for a user-facing surface.
        var failureDetail: String {
            switch self {
            case .unavailable(let reason):
                return reason
            case .completed:
                let failing = failingScaffoldChecks
                guard !failing.isEmpty else { return "Doctor reported a failure with no failing check." }
                return failing.map { "\($0.title): \($0.detail)" }.joined(separator: " ")
            }
        }
    }

    @MainActor
    @discardableResult
    func runDoctor(repair: Bool) async -> DoctorRunOutcome {
        // PATCH-2026-05-30: surface in-flight state to the UI so the user
        // sees a spinner + "Running…" text instead of an apparent freeze.
        // Block concurrent invocations — clicking Run while a run is in
        // flight should be a no-op, not a queued duplicate.
        guard !doctorRunning else {
            return .unavailable("A Doctor run is already in progress.")
        }
        doctorRunning = true
        doctorRunStartedAt = Date()
        // gpt-5.5 review (B2 wave): invalidate the snapshot-reuse freshness
        // stamp for the whole run — Support Snapshot must never reuse a report
        // from BEFORE an in-flight run (the stamp re-lands on success only).
        doctorReportCompletedAt = nil
        statusText = repair ? "Running Doctor repair…" : "Running Doctor checks…"
        defer {
            doctorRunning = false
            doctorRunStartedAt = nil
        }
        do {
            let report = try await client.runDoctor(repair: repair)
            doctorReport = report
            doctorReportCompletedAt = Date()
            statusText = repair
                ? DoctorSafeRepairIssuesPresentation.completionMessage(report: report)
                : "Doctor check finished"
            await refreshAll()
            let failing = report.checks.filter {
                ["fail", "error"].contains($0.status.lowercased())
            }
            return .completed(status: report.status, failingChecks: failing)
        } catch {
            statusText = "Doctor failed: \(error.localizedDescription)"
            return .unavailable(error.localizedDescription)
        }
    }

    /// The Diagnostics button may run only repairs that the currently shown
    /// report explicitly offered. Onboarding calls `runDoctor(repair:)`
    /// directly because fresh-install scaffold repair has no prior report.
    @MainActor
    @discardableResult
    func repairSafeDoctorIssues() async -> DoctorRunOutcome {
        let state = DoctorSafeRepairIssuesPresentation.state(
            report: doctorReport,
            isRunning: doctorRunning
        )
        guard state.canRun else {
            statusText = state.detail
            return .unavailable(state.detail)
        }
        return await runDoctor(repair: true)
    }

    /// Reconcile the cheap live-owner rows in an existing Doctor report.
    /// This avoids preserving a recovered Telegram/provider/tool condition in
    /// the toolbar while also avoiding a second full Doctor run on tab entry.
    @MainActor
    func refreshLiveDoctorCoverage() async {
        guard let current = doctorReport else { return }
        let liveChecks = await client.liveDoctorCoverageChecks()
        doctorReport = NativeClient.mergeDoctorReport(current, liveChecks: liveChecks)
    }

    private func splitIDs(_ value: String) -> [String] {
        value
            .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

}
