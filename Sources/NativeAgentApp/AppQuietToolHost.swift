import GitHubConnector
import EngineRuntime
import ActivityWatch
import ApprovalInbox
import Connectors
import ProviderRouting
import AppToolRuntime
import Foundation
import ApprovalTransactions
import NativeAgentCore
import NativeAgentShared
import MemoryV2
import PersistenceCore
import Privacy
import ChatOrchestration
import Desk
import NotificationInbox
import TrustPersistence

@MainActor final class AppQuietToolHost: AppQuietSettingsHost, QuietToolHost {
    var activeChatSessionId: String { appModel.activeChatSessionId }
    func pageRead(_ page: QuietToolPage) async -> [JSONValue] {
        // The presentation port resolved this value from the same immutable page catalog.
        await QuietSelfAdminRender.pageRead(for: QuietPages.page(named: page.id)!, appModel: appModel)
    }
    func composerState(sessionId: String) async -> [String: JSONValue] {
        await QuietComposerCommands.state(appModel: appModel, sessionId: sessionId)
    }
    func runComposer(
        verb: String, value: String, choice: String, sessionId: String, attachments: [URL], reachesUser: Bool,
        turnSessionId: String
    ) async -> QuietComposerOutcome {
        await QuietComposerCommands.run(
            verb: verb, value: value, choice: choice, sessionId: sessionId,
            attachments: attachments, reachesUser: reachesUser, turnSessionId: turnSessionId, appModel: appModel
        )
    }
    func runChatSession(verb: String, input: [String: JSONValue], reachesUser: Bool) async -> JSONValue {
        await QuietChatSessionCommands.run(verb: verb, input: input, reachesUser: reachesUser, appModel: appModel)
    }
    func composerFence(verb: String, value: String, sessionId: String, reachesUser: Bool, turnSessionId: String)
        -> QuietComposerOutcome? {
        QuietComposerCommands.fence(verb: verb, value: value, sessionId: sessionId, reachesUser: reachesUser,
                                   turnSessionId: turnSessionId, appModel: appModel).refusal
    }
    func chatSessionFence(verb: String, input: [String: JSONValue], reachesUser: Bool) -> JSONValue? {
        if case .failure(let refusal) = QuietChatSessionCommands.fence(verb: verb, input: input, reachesUser: reachesUser, appModel: appModel) {
            return refusal.json
        }
        return nil
    }
    func saveProviderKey(_ key: String, provider: String) async -> NativeOAuthFlow.InlineSetupOutcome {
        await NativeOAuthFlow.saveInlineProviderKey(
            key, providerName: InlineInteractionRegistry.providerDisplayName(provider),
            testProvider: { try await appModel.testProvider(provider, apiKeyOverride: key) },
            configureProvider: {
                try await appModel.configureProvider(provider, apiKey: key, authMode: "api_key", defaultModel: nil)
            })
    }
    func upkeepFence(verb: String, input: [String: JSONValue]) async -> JSONValue? {
        guard verb == "backup_restore" else { return nil }
        if case .failure(let failure) = await AppToolExecutor.quietBackupRestoreTarget(input, dataRoot: appModel.engine.trust.dataRoot) { return failure.refusal }
        return nil
    }
    /// Each verb is the button's own call: Doctor's support report,
    /// Capabilities' Export, Trust's Back up now, the embedding download row,
    /// Setup's Release now and the Memories page's upkeep row.
    func runUpkeep(verb: String, input: [String: JSONValue]) async -> (ok: Bool, detail: String, fields: [String: JSONValue]) {
        let retry = " Read \(AppToolExecutor.doorDoctor) to see what is wrong, then try again."
        switch verb {
        case "support_report":
            switch await appModel.loadSupportDiagnostics() {
            case .loaded(let report, _):
                return (true, "Support report: \(report.app) \(report.version), health \(report.doctorStatus ?? "unknown"), made \(report.generatedAt). A file to send the developer: export.bundle {support:true}.",
                        ["report": (try? JSONValue.fromEncodable(report)) ?? .null])
            case .unavailable(let detail): return (false, detail, [:])
            case .failed(let detail): return (false, "Support report failed: \(detail)\(detail.hasSuffix(".") ? "" : ".")" + retry, [:])
            }
        case "export_bundle":
            let support = input["support"] == .bool(true)
            switch await appModel.createProductionExport(support: support) {
            case .verified(let export):
                return (true, "\(support ? "Support bundle" : "Export") created and verified at \(export.path).",
                        ["path": .string(export.path), "id": .string(export.id), "size_bytes": .int(Int64(export.sizeBytes ?? 0))])
            case .failed(_, let detail): return (false, "\(support ? "Support bundle" : "Export") failed: \(detail)." + retry, [:])
            }
        case "backup_now":
            let backup = await appModel.createBackup(reason: "upkeep backup_now")
            return backup.map { (true, appModel.statusForAgent, ["id": .string($0.id), "created_at": .string($0.createdAt)]) }
                ?? (false, appModel.statusForAgent, [:])
        case "embeddings_pause":
            let download = EmbeddingModelDownloadController.shared
            guard download.status.running else {
                return (true, "Nothing to pause: the memory-search model is not downloading (\(download.status.phase)).", ["changed": .bool(false)])
            }
            download.cancel()
            return (true, "Paused the memory-search model download. embeddings_resume picks it up where it stopped.", ["changed": .bool(true)])
        case "embeddings_resume":
            let download = EmbeddingModelDownloadController.shared
            guard !download.status.running, !download.activating else {
                return (true, "Already running: \(download.status.phase).", ["changed": .bool(false)])
            }
            download.start(createOnly: false, reconcile: true)
            return (true, "Checking and resuming the memory-search model download. \(AppToolExecutor.doorDoctor) shows its progress.", ["changed": .bool(true)])
        case "spotlight_reindex":
            let outcome = await MemorySpotlightReindexOperation.run(dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            if case .indexed = outcome { return (true, outcome.userMessage, [:]) }
            return (false, outcome.agentMessage, [:])
        case "consolidate_now", "hygiene_now":
            let feedback = verb == "consolidate_now" ? await appModel.consolidateMemory() : await appModel.runMemoryHygiene()
            return (!feedback.isAdverse,
                    UserFacingError.forAgent(feedback.message, cause: feedback.isAdverse ? appModel.statusCause : nil), [:])
        // User's two below Full Mac; the door refuses them there.
        case "backup_restore":
            let backup: BackupRecord
            switch await AppToolExecutor.quietBackupRestoreTarget(input, dataRoot: appModel.engine.trust.dataRoot) {
            case .success(let target): backup = target
            case .failure(let failure): return (false, failure.detail, failure.fields.merging(["effects": .string("none")]) { $1 })
            }
            await appModel.restoreBackup(backup)
            guard !appModel.statusText.hasPrefix("Restore failed") else { return (false, appModel.statusForAgent + retry, [:]) }
            // Awaited: a restore that stages restarts the app once this turn ends.
            _ = await HarnessDecidedRow.record(requester: "Full Mac", tool: "backup.restore \(backup.id)",
                                               sessionID: AppToolExecutor.inputString(input["__session_id"]),
                                               dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            return (true, appModel.statusForAgent, ["id": .string(backup.id)])
        case "activity_wipe":
            let activity = ActivityWatchController.shared
            let removed: Int
            switch await activity.wipeAll() {
            case .deleted(let rows): removed = rows
            case .failed(let message):
                return (false, message + " Deletion could not be confirmed." + retry, [:])
            }
            HarnessDecidedRow.post(requester: "Full Mac", tool: "history.clear",
                                   sessionID: AppToolExecutor.inputString(input["__session_id"]),
                                   dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            return (true, "Deleted all recorded activity (\(removed) spans). Recording settings are kept, "
                + "so if capture is on it keeps going.", ["removed_rows": .int(Int64(removed))])
        default:
            return (false, "No upkeep button is called \(verb).", [:])
        }
    }
}

/// The agent's own hands on a card (card.answer): every settle is `byAgent`.
@MainActor struct AppToolInteractionResolver: ToolInteractionResolving {
    func sessionID(ofCard id: String, dataRoot: URL) async -> String? {
        try? await InlineInteractionDelivery.pointer(id: "interaction:\(id)", dataRoot: dataRoot).sessionID
    }
    func cardFields(_ interaction: InlineInteraction, descriptor: InlineInteractionDescriptor) -> [String: JSONValue] {
        let card = InlineCardProjection.model(interaction, descriptor: descriptor)
        return [
                "title": .string(card.title),
                "state": .string(card.state.rawValue),
                "why": .string(card.why),
                "primary": .string(card.primaryLabel),
                "secondary": .string(card.secondaryLabel),
                "scope_lines": .array(card.scopeLines.map { .string($0) }),
                "outcome": card.outcome.map { JSONValue.string($0) } ?? .null,
                "outcome_meta": card.outcomeMeta.map { JSONValue.string($0) } ?? .null,
                "can_retry": .bool(card.canRetry),
                "revision": .int(Int64(interaction.revision)),
            ]
    }
    func saveConnectorToken(_ value: String, connector: String, dataRoot: URL) async -> String? {
            let result: OAuthFlowResult
            switch connector {
            case "notion": result = await NativeOAuthFlow.saveNotionToken(value, dataRoot: dataRoot)
            case "github": result = await NativeOAuthFlow.saveGitHubToken(value, dataRoot: dataRoot, credentialStore: GitHubCredentialStore.shared)
            default: result = OAuthFlowResult(ok: false, error: "No token route for \(connector).")
            }
            if !result.ok {
                return NativeOAuthFlow.inlineSetupFailureReason(
                    result.error ?? "",
                    service: InlineInteractionRegistry.connectorDisplayName(connector, dataRoot: dataRoot),
                    typed: [value]
                )
            }
        return nil
    }
}

// MARK: - inbox

extension AppQuietToolHost: QuietInboxHost {
    var inboxDataRoot: URL { appModel.engine.inbox.dataRoot }
    var interactionSource: String { InlineInteractionDelivery.source }
    func interactionForInboxItem(_ id: String, dataRoot: URL) async -> InlineInteraction? {
        guard let pointer = try? await InlineInteractionDelivery.pointer(id: id, dataRoot: dataRoot) else { return nil }
        return await InlineInteractionResolver.interaction(id: pointer.interactionID, sessionID: pointer.sessionID, dataRoot: dataRoot)
    }
    func readInbox() async throws -> [InboxItemRecord] { try await appModel.engine.inbox.list() }
    func inboxPresentation(_ item: InboxItemRecord) -> (hidden: Bool, linkedApproval: Bool, actions: [InboxActionRecord]) {
        (item.isHiddenFromDefaultInbox, item.hasLinkedApproval, item.effectiveActions)
    }
    func performInboxAction(_ id: String, action: String, metadata: [String: JSONValue], quiet: Bool, dataRootOverride: URL?) async throws {
        try await InboxCardActions.perform(id, action: action, metadata: metadata, quiet: quiet,
            dataRootOverride: dataRootOverride, effects: AppInboxCardActionEffects())
    }
    func withdrawApproval(id: String, decidedBy: String) async throws {
        _ = try await ApprovalTransactionCoordinator.app(dataRootOverride: appModel.dataRootOverride)
            .resolveApproval(id: id, decision: "cancel", provenance: .local(decidedBy: decidedBy))
    }
    func inboxFence(verb: String, input: [String: JSONValue]) async -> JSONValue? {
        await quietInboxFence(verb: verb, input: input)
    }
    func inbox(verb: String, input: [String: JSONValue]) async -> JSONValue {
        await quietInbox(verb: verb, input: input)
    }
    func refreshInboxSurfaces() async {
        _ = await appModel.refreshForSidebarItem(.activity)
        await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots()
    }

    func inboxActDescription(_ item: InboxItemRecord, action: String) -> String {
        if action == "repair" { return "Repaired and archived the note." }
        if item.source == InlineInteractionDelivery.source {
            switch action {
            case "reject", "deny": return "Declined the card (Not now)."
            case "act": return "Opened the card's conversation on the Mac."
            default: return "Selected the card's choice: \(item.effectiveActions.first { $0.id == action }?.label ?? action)."
            }
        }
        switch InboxCardActions.resolvePrimaryAction(for: item, effects: AppInboxCardActionEffects()) {
        case .openApprovals: return "Marked the note read; its approvals wait on the Approvals page. The person's screen was not moved."
        case .openDeskExecution: return "Marked the note read; its work is on the Desk. The person's screen was not moved."
        case .chatDraft: return "Marked the note read. Its action only drafts a chat message for the person, so nothing was put in their composer."
        case .chatSpoken: return "Posted the note into chat as your message and marked it read. The person's screen was not moved."
        case .diskCleanup: return "Moved the disk offenders to the Trash; the note now shows the result."
        case .unresolved(let reason): return reason
        }
    }

}

extension AppQuietToolHost {
    func provider(verb: String, input: [String: JSONValue]) async -> JSONValue {
        await ProvidersFacade.runQuietProvider(
            verb: verb, input: input, dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot(),
            refresh: {
                switch await appModel.engine.providers.refreshSettings(refreshCatalog: true, cause: UserFacingError.cause) {
                case .loaded(let snapshot):
                    _ = await appModel.loadProvidersForChat()
                    return (snapshot.providers, nil)
                case .failed(let detail): return ([], detail)
                }
            }, list: { try await appModel.engine.providers.list() },
            test: { try await appModel.testProvider($0) },
            authMode: {
                let mode = ProvidersFacade.authModePickerState(
                    advertisedModes: $0.auth_modes, savedMode: $0.auth_mode, providerIsReady: true)
                return (mode.canSave, mode.selectedMode)
            },
            configure: { try await appModel.configureProvider($0, apiKey: nil, authMode: $1, defaultModel: $2) },
            reload: { _ = await appModel.loadProvidersForChat() },
            disconnect: {
                let outcome = await appModel.disconnectProvider($0)
                return (outcome.ok, outcome.ok ? outcome.detail : UserFacingError.forAgent(outcome.detail, cause: outcome.cause))
            })
    }
}
