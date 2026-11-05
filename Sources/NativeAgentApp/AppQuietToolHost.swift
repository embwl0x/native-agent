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
import ChatToolRuntime
import Desk
import NotificationInbox
import TrustPersistence
// Blueprint: | `AppQuietToolHost.swift` | `AppQuietToolHost`: `inboxFence`, `inbox`, `provider` |

@MainActor final class AppQuietToolHost: AppQuietSettingsHost, QuietToolHost {
    private let inboxTurn: Turn?

    override init(_ appModel: AppModel) {
        inboxTurn = nil
        super.init(appModel)
    }

    private init(_ appModel: AppModel, inboxTurn: Turn) {
        self.inboxTurn = inboxTurn
        super.init(appModel)
    }

    var activeChatSessionId: String { appModel.activeChatSessionId }
    func pageRead(_ page: QuietToolPage, turn: Turn) async -> [JSONValue] {
        // Use the presentation port's immutable catalog value so the tool host keeps no second page truth.
        await QuietSelfAdminRender.pageRead(for: QuietPages.page(named: page.id)!, appModel: appModel, turn: turn)
    }
    func composerState(sessionId: String, turn: Turn) async -> [String: JSONValue] {
        await QuietComposerCommands.state(appModel: appModel, sessionId: sessionId, turn: turn)
    }
    func runComposer(
        verb: String, value: String, choice: String, sessionId: String, attachments: [URL], reachesUser: Bool,
        turnSessionId: String, turn: Turn
    ) async -> QuietComposerOutcome {
        await QuietComposerCommands.run(
            verb: verb, value: value, choice: choice, sessionId: sessionId,
            attachments: attachments, reachesUser: reachesUser, turnSessionId: turnSessionId, appModel: appModel, turn: turn
        )
    }
    func runChatSession(verb: String, input: [String: JSONValue], reachesUser: Bool, turn: Turn) async -> JSONValue {
        await QuietChatSessionCommands.run(verb: verb, input: input, reachesUser: reachesUser, appModel: appModel, turn: turn)
    }
    func composerFence(verb: String, value: String, sessionId: String, reachesUser: Bool, turnSessionId: String, turn: Turn)
        -> QuietComposerOutcome? {
        QuietComposerCommands.fence(verb: verb, value: value, sessionId: sessionId, reachesUser: reachesUser,
                                   turnSessionId: turnSessionId, appModel: appModel, turn: turn).refusal
    }
    func chatSessionFence(verb: String, input: [String: JSONValue], reachesUser: Bool, turn: Turn) -> JSONValue? {
        if case .failure(let refusal) = QuietChatSessionCommands.fence(verb: verb, input: input, reachesUser: reachesUser, appModel: appModel, turn: turn) {
            return refusal.json
        }
        return nil
    }
    func saveProviderKey(_ key: String, provider: String) async -> NativeOAuthFlow.InlineSetupOutcome {
        await NativeOAuthFlow.saveInlineProviderKey(
            key, providerName: InlineInteractionRegistry.providerDisplayName(provider),
            testProvider: { try await appModel.engine.providers.testProvider(provider, apiKeyOverride: key) },
            configureProvider: {
                try await appModel.engine.configureProvider(provider, apiKey: key, authMode: "api_key", defaultModel: nil)
            })
    }
    func upkeepFence(verb: String, input: [String: JSONValue]) async -> JSONValue? {
        guard verb == "backup_restore" else { return nil }
        if case .failure(let failure) = await AppToolExecutor.quietBackupRestoreTarget(
            input,
            dataRoot: appModel.engine.trust.dataRoot
        ) { return failure.refusal }
        return nil
    }
    /// Share each page button's own call so tool and UI mutations have one owner.
    func runUpkeep(verb: String, input: [String: JSONValue], turn: Turn) async -> (ok: Bool, detail: String, fields: [String: JSONValue]) {
        let retry = " Read \(AppToolExecutor.doorDoctor) to see what is wrong, then try again."
        switch verb {
        case "support_report":
            switch await appModel.loadSupportDiagnostics() {
            case .loaded(let report, _):
                return (true, """
                    Support report: \(report.app) \(report.version), health \(report.doctorStatus ?? "unknown"), made \(report.generatedAt). A file to send \
                    the developer: export.bundle {support:true}.
                    """,
                        ["report": (try? JSONValue.fromEncodable(report)) ?? .null])
            case .unavailable(let detail): return (false, detail, [:])
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
            let result = await appModel.createBackup(reason: "upkeep backup_now")
            switch result {
            case .created(let backup, let message):
                return (true, message, ["id": .string(backup.id), "created_at": .string(backup.createdAt)])
            case .failed(let message): return (false, message, [:])
            }
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
            download.start(createOnly: false)
            return (true, "Checking and resuming the memory-search model download. \(AppToolExecutor.doorDoctor) shows its progress.", ["changed": .bool(true)])
        case "spotlight_reindex":
            let outcome = await MemorySpotlightReindexOperation.run(dataRoot: appModel.engine.dataRoot)
            if case .indexed = outcome { return (true, outcome.userMessage, [:]) }
            return (false, outcome.agentMessage, [:])
        // Below Full Mac, these controls belong to the user; the tool door refuses them.
        case "backup_restore":
            let backup: BackupRecord
            switch await AppToolExecutor.quietBackupRestoreTarget(input, dataRoot: appModel.engine.trust.dataRoot) {
            case .success(let target): backup = target
            case .failure(let failure): return (false, failure.detail, failure.fields.merging(["effects": .string("none")]) { $1 })
            }
            let message: String
            switch await appModel.restoreBackup(backup) {
            case .saved(let detail): message = detail
            case .failed(let detail): return (false, detail + retry, [:])
            }
            // Await staging because a staged restore restarts the app after this turn settles.
            _ = await HarnessDecidedRow.record(turn: turn, requester: "Full Mac", tool: "backup.restore \(backup.id)",
                                               sessionID: input["__session_id"]?.scalarText,
                                               dataRoot: appModel.engine.dataRoot)
            return (true, message, ["id": .string(backup.id)])
        case "activity_wipe":
            let activity = appModel.engine.activityWatch
            let removed: Int
            switch await activity.wipeAll() {
            case .deleted(let rows): removed = rows
            case .failed(let message):
                return (false, message + " Deletion could not be confirmed." + retry, [:])
            }
            HarnessDecidedRow.post(turn: turn, requester: "Full Mac", tool: "history.clear",
                                   sessionID: input["__session_id"]?.scalarText,
                                   dataRoot: appModel.engine.dataRoot)
            return (true, "Deleted all recorded activity (\(removed) spans). Recording settings are kept, "
                + "so if capture is on it keeps going.", ["removed_rows": .int(Int64(removed))])
        default:
            return (false, "No upkeep button is called \(verb).", [:])
        }
    }
}

// MARK: - inbox

extension AppQuietToolHost: QuietInboxHost {
    var inboxDataRoot: URL { appModel.engine.inbox.dataRoot }
    var interactionSource: String { InlineInteractionDelivery.source }
    func interactionForInboxItem(_ id: String, dataRoot: URL) async throws -> InlineInteraction? {
        let pointer = try await InlineInteractionDelivery.pointer(id: id, dataRoot: dataRoot)
        return try await InlineInteractionResolver.interaction(id: pointer.interactionID, sessionID: pointer.sessionID, dataRoot: dataRoot)
    }
    func readInbox() async throws -> [InboxItemRecord] { try await appModel.engine.inbox.list() }
    func inboxPresentation(_ item: InboxItemRecord) -> (hidden: Bool, linkedApproval: Bool, actions: [InboxActionRecord]) {
        (item.isHiddenFromDefaultInbox, item.hasLinkedApproval, item.actions)
    }
    func performInboxAction(_ id: String, action: String, metadata: [String: JSONValue], quiet: Bool, dataRootOverride: URL?, turn: Turn) async throws {
        try await InboxCardActions.perform(id, action: action, metadata: metadata, quiet: quiet,
            dataRootOverride: dataRootOverride, turn: turn,
            effects: AppInboxCardActionEffects(inbox: appModel.engine.inbox))
    }
    func withdrawApproval(id: String, decidedBy: String) async throws {
        guard let turn = inboxTurn else {
            throw ToolFailureError("Inbox withdrawal has no invoking turn. Nothing was withdrawn.",
                effects: .none, owner: "inbox", code: "inbox_turn_unavailable")
        }
        _ = try await ApprovalExecution.app()
            .resolveApproval(id: id, decision: "cancel", provenance: .local(decidedBy: decidedBy), turn: turn)
    }
    func inboxFence(verb: String, input: [String: JSONValue], turn: Turn) async -> JSONValue? {
        await quietInboxFence(verb: verb, input: input, turn: turn)
    }
    func inbox(verb: String, input: [String: JSONValue], turn: Turn) async -> JSONValue {
        // QuietInboxHost's withdrawal callback has no turn parameter; each invocation holds its own immutable binding.
        await AppQuietToolHost(appModel, inboxTurn: turn).quietInbox(verb: verb, input: input, turn: turn)
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
            default: return "Selected the card's choice: \(item.actions.first { $0.id == action }?.label ?? action)."
            }
        }
        switch InboxCardActions.resolvePrimaryAction(for: item) {
        case .openApprovals: return "Marked the note read; its approvals wait on the Approvals page. The person's screen was not moved."
        case .chatDraft: return "Marked the note read. Its action only drafts a chat message for the person, so nothing was put in their composer."
        case .chatSpoken: return "Posted the note into chat as your message and marked it read. The person's screen was not moved."
        case .diskCleanup: return "Moved the disk offenders to the Trash; the note now shows the result."
        case .unresolved(let reason): return reason
        }
    }

}

extension AppQuietToolHost {
    func provider(verb: String, input: [String: JSONValue], turn: Turn) async -> JSONValue {
        await ProvidersFacade.runQuietProvider(
            verb: verb, input: input, dataRoot: appModel.engine.dataRoot, turn: turn,
            refresh: {
                switch await appModel.engine.providers.refreshSettings(refreshCatalog: true, cause: UserFacingError.cause) {
                case .loaded(let snapshot):
                    return (snapshot.providers, nil)
                case .failed(let detail): return ([], detail)
                }
            }, list: { try await appModel.engine.providers.list().providers },
            test: { try await appModel.engine.providers.testProvider($0) },
            authMode: {
                let mode = ProvidersFacade.authModePickerState(
                    advertisedModes: $0.auth_modes, savedMode: $0.auth_mode)
                return (mode.canSave, mode.selectedMode)
            },
            configure: { try await appModel.engine.configureProvider($0, apiKey: nil, authMode: $1, defaultModel: $2) },
            reload: { _ = await appModel.loadProvidersForChat() },
            disconnect: {
                let outcome = await appModel.disconnectProvider($0)
                return (outcome.ok, outcome.ok ? outcome.detail : UserFacingError.forAgent(outcome.detail, cause: outcome.cause))
            })
    }
}
