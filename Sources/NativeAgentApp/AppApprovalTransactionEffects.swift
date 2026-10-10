import Foundation
import Browser
import AppToolRuntime
import PersistenceCore
import Connectors
import NativeAgentShared
import NativeAgentCore
import ApprovalTransactions
import ApprovalInbox
import ChatOrchestration
import MemoryV2
import SlackConnector
import TrustCenter
import WorkshopExecution
import Agents
import TelegramBot
import SlackBot
import DeviceSync

extension ApprovalTransactionCoordinator {
    /// The approval coordinator over this app's effects, for one root.
    static func app(dataRootOverride: URL? = nil) -> ApprovalTransactionCoordinator {
        ApprovalTransactionCoordinator(
            effects: AppApprovalTransactionEffects(dataRootOverride: dataRootOverride),
            dataRootOverride: dataRootOverride
        )
    }

    // DAEMON-DEAD PORT (2026-06-02), REWRITTEN 2026-09-06.
    //
    // These two routes used to do their own read-modify-write on the canonical
    // approvals file, and both ways they touched it were corrupting:
    //
    //   * the read was `readJSON(defaultValue: .array([]))`, so an unreadable
    //     or malformed store became `[]` and was then WRITTEN BACK — every
    //     pending approval in it destroyed;
    //   * the write set `status` to "approved"/"rejected", which are outside
    //     the store's valid status set, and for an execution/step nobody
    //     staged it APPENDED a skeletal row with no id and no authority
    //     fields. Either row makes `loadApprovalRowsChecked` throw for the
    //     WHOLE file, so one tap on the phone took the entire approval inbox
    //     offline for every reader;
    //   * the "workshop execution not found" check ran only AFTER that write,
    //     so a request naming a nonexistent execution poisoned the store and
    //     then reported not-found.
    //
    // And nothing ever read those rows. A blocked step is resumed from a
    // RESOLVED `execution.step` ApprovalRecord (ApprovalTransactionCoordinator
    // .applyResolvedWorkshopStep), so the write was pure corruption with no
    // effect — approving a step from the phone never resumed anything.
    //
    // Both routes now go through the inbox owner: the execution is resolved
    // before anything is written, a damaged store throws instead of being
    // overwritten, and the decision is minted down the same checked path the
    // Approvals panel uses (which also makes the phone's approve actually
    // resume the execution).
    static func resolveWorkshopStep(
        executionId: String,
        stepId: String,
        decision: String,
        provenance: ApprovalResolutionProvenance = .local(decidedBy: "mac_ui"),
        dataRootOverride: URL? = nil
    ) async throws -> WorkshopExecution.WorkshopExecutionRecord {
        let root = dataRootOverride ?? SwiftNativeApprovalInbox.defaultDataRoot()
        let runner = BackgroundLoopsAssembly.makeWorkshopExecutionRunner(dataRoot: root)
        // Refused BEFORE any write: an unknown execution now costs one read.
        guard try await runner.getWorkshopExecution(executionId) != nil else {
            throw DaemonError.notFound("workshop execution \(executionId)")
        }
        let inbox = SwiftNativeApprovalInbox(root: root)
        // 2026-09-06: the pre-R5 merge runs INSIDE the inbox owner now — it
        // used to read and rewrite the canonical queue from here, outside the
        // actor's mutation chain and the file lock, so a concurrent create or
        // resolve was overwritten by the migration's stale copy.
        try await inbox.mergeLegacyApprovalRows()
        // A throwing list IS the damaged-store signal, and it propagates —
        // nothing below writes over a store this call could not read.
        let pending = try await inbox.list(filter: ApprovalFilter(status: "pending"))
        // The action is matched through the shared vocabulary so a card staged
        // by a 0.3.x binary (`mission.step`) still resolves.
        guard let staged = pending.first(where: { record in
            guard ExecutionEventVocabulary.matches(
                      record.action, WorkshopStepApprovalAction.canonical),
                  case .object(let payload) = record.payload,
                  let rowExecutionId = WorkshopStepApprovalPayload.executionId({ key in
                      if case .string(let value)? = payload[key] { return value }
                      return nil
                  }),
                  case .string(let rowStepId)? = payload["step_id"] else { return false }
            return rowExecutionId == executionId && rowStepId == stepId
        }) else {
            throw DaemonError.notFound(
                "pending \(WorkshopStepApprovalAction.canonical) approval for "
                    + "\(executionId)/\(stepId)"
            )
        }
        _ = try await app(dataRootOverride: dataRootOverride).resolveApproval(
            id: staged.id,
            decision: decision,
            provenance: provenance
        )
        guard let record = try await runner.getWorkshopExecution(executionId) else {
            throw DaemonError.notFound("workshop execution \(executionId)")
        }
        return record
    }
}

/// Host bindings for approval effects and mounted conversation refresh.
struct AppApprovalTransactionEffects: ApprovalTransactionEffects {
    let dataRootOverride: URL?

    private var dataRoot: URL { dataRootOverride ?? PersistenceCore.defaultDataRoot() }

    var telegramSurface: String { NativeAgentAppChatSurfaceProfile.telegram.rawValue }

    /// The approved run_memory_hygiene op: an explicit approval, so the one
    /// direct-consolidate entry point.
    func runMemoryHygiene() async throws -> ApprovalMemoryHygieneResult {
        let report = try await MemoryConsolidationHygiene.runOnce(dataRoot: dataRoot, approvedDirectRun: true)
        return ApprovalMemoryHygieneResult(id: report.id, status: report.status,
                                          reason: report.reason, consolidationRunId: report.consolidationRunId)
    }

    func disableSkill(name: String) async throws {
        try await NativeSkillRegistryActions.disableSkill(name: name, dataRoot: dataRoot)
    }

    /// A self-improvement card (no digest) may be hers to approve under Full
    /// Mac, so it never admits a script; User's script install card admits its digest.
    func enableSkill(name: String, reviewedDigest: String?) async throws {
        try await NativeSkillRegistryActions.enableSkill(
            name: name, dataRoot: dataRoot,
            reviewedDigest: reviewedDigest, admitScript: reviewedDigest != nil
        )
    }

    func applyResolvedExternalSend(from record: ApprovalRecord) async -> Bool {
        await ExternalSendApprovalTransactions.applyResolvedExternalSend(
            from: record,
            dataRoot: dataRoot,
            dependencies: .production,
            observeMotorActionState: { [dataRoot] in
                await BackgroundLoopsAssembly.cognitionRuntime(for: dataRoot).observeMotorActionState($0)
            }
        ).shouldArchiveVisibleCard
    }

    func runConnectorAction(descriptor: ConnectorActionDescriptor, dryRun: Bool, input: [String: JSONValue],
                            approvedReplayApprovalID: String, dataRoot: URL) async throws -> ApprovalConnectorActionResult {
        let receipt = try await ConnectorActions(platform: AppConnectorActionPlatform(dataRoot: self.dataRoot))
            .runConnectorAction(descriptor: descriptor, dryRun: dryRun, input: input,
                                approvedReplayApprovalID: approvedReplayApprovalID, dataRoot: dataRoot)
        return ApprovalConnectorActionResult(id: receipt.id, status: receipt.status)
    }

    func toolDispatchClient(denyExternalMcp: Bool,
                            enforceAppAutonomy: Bool) -> any ToolDispatchClient {
        NativeAgentEngine.forRoot(dataRoot).toolDispatchClient(
            denyExternalMcp: denyExternalMcp, enforceAppAutonomy: enforceAppAutonomy)
    }

    func continueChatToolApproval(dataRoot: URL, sessionID: String, envelope: TurnEnvelope, prompt: String) async throws {
        let fileAccess = ChatToolSessionContext.fileAccess
            ?? UserDefaults.standard.string(forKey: "chatFileAccess") ?? "read_only"
        try await BackgroundLoopsAssembly.makeTurnContinuationRuntime(dataRoot: dataRoot)
            .continueChatToolApproval(sessionID: sessionID, envelope: envelope, prompt: prompt, fileAccess: fileAccess) {
                let options = NativeChatTurnOptions.current(surface: envelope.surface)
                return (nil, options.serviceTier)
            }
    }

    func chatTurnCompleted(sessionID: String?) async {
        await MainActor.run {
            NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
        }
    }

    func observeBrowserMotorAction(runID: String, dataRoot: URL) async {
        await BrowserActionRoutes.app.observeBrowserMotorAction(runID: runID, dataRoot: dataRoot)
    }

    func executeApprovedBrowserRun(from record: ApprovalRecord) async throws {
        try await BrowserActionRoutes.app.executeApprovedBrowserRun(from: record, dataRoot: dataRoot)
    }

    func finishRejectedBrowserRun(from record: ApprovalRecord, status: String) async throws {
        try await BrowserActionRoutes.app.finishRejectedBrowserRun(from: record, status: status, dataRoot: dataRoot)
    }

    /// The published executor is the live root's; another root gets its own.
    func workshopExecutor() -> WorkshopExecutorLoop {
        guard dataRootOverride == nil else { return BackgroundLoopsAssembly.makeWorkshopExecutor(dataRoot: dataRoot) }
        return WorkshopExecutorRef.shared.current() ?? BackgroundLoopsAssembly.makeWorkshopExecutor()
    }

    func updateVisibleNotificationInboxStatus(id: String, action: String) async -> Bool {
        await InboxCardActions.updateVisibleStatus(
            id: id, action: action, inboxPath: InboxCardActions.visibleNotificationInboxPath(dataRoot: dataRoot))
    }
}

extension ExternalSendExecutionDependencies {
    static let production = ExternalSendExecutionDependencies(
        slackSend: { input, idempotencyKey, dataRoot in
            do {
                let result = try await SlackConnectorActions.postMessage(
                    input: input,
                    idempotencyKey: idempotencyKey,
                    dataRoot: dataRoot
                )
                return ExternalSendProviderOutcome.classifySlack(result)
            } catch let error as NSError
                where error.domain == "NativeAgentSlack" && [-400, -401].contains(error.code) {
                return .preDispatchFailed("connector_preflight_failed")
            } catch {
                // Once Slack's local preflight has passed, URLSession errors,
                // cancellation, and process interruption cannot prove whether
                // Slack received the request. Never turn ambiguity into failure.
                return .outcomeUnknown("transport_outcome_unknown")
            }
        },
        agentMailSend: { input, idempotencyKey, dataRoot in
            let result = await AgentMailActions.sendNow(
                input: input,
                approvalId: nil,
                idempotencyKey: idempotencyKey,
                dataRoot: dataRoot,
                recordReceipt: false
            )
            return ExternalSendProviderOutcome.classifyAgentMail(result)
        }
    )
}
