import EngineRuntime
import Foundation
import BackgroundWork
import Browser
import AppToolRuntime
import PersistenceCore
import Connectors
import NativeAgentShared
import NativeAgentCore
import ApprovalTransactions
import ApprovalInbox
import ChatOrchestration
import TrustCenter
import WorkshopExecution

extension ApprovalTransactionCoordinator {
    /// The approval coordinator over this app's effects, for one root.
    static func app(dataRootOverride: URL? = nil) -> ApprovalTransactionCoordinator {
        ApprovalTransactionCoordinator(
            effects: AppApprovalTransactionEffects(dataRootOverride: dataRootOverride),
            dataRootOverride: dataRootOverride
        )
    }

    static func resolveWorkshopStep(
        executionId: String,
        stepId: String,
        decision: String,
        provenance: ApprovalResolutionProvenance = .local(decidedBy: "mac_ui"),
        dataRootOverride: URL? = nil
    ) async throws -> WorkshopExecutionRecord {
        let root = dataRootOverride ?? SwiftNativeApprovalInbox.defaultDataRoot()
        return try await app(dataRootOverride: dataRootOverride).resolveWorkshopStep(
            executionId: executionId, stepId: stepId, decision: decision, provenance: provenance,
            runner: NativeAgentEngine.makeWorkshopExecutionRunner(dataRoot: root))
    }
}

/// Host bindings for approval effects and mounted conversation refresh.
struct AppApprovalTransactionEffects: ApprovalTransactionEffects {
    let dataRootOverride: URL?

    private var dataRoot: URL { dataRootOverride ?? PersistenceCore.defaultDataRoot() }

    func disableSkill(name: String) async throws {
        try await NativeSkillRegistryActions.disableSkill(name: name, dataRoot: dataRoot)
    }

    func enableSkill(name: String, reviewedDigest: String?, admitScript: Bool) async throws {
        try await NativeSkillRegistryActions.enableSkill(
            name: name, dataRoot: dataRoot,
            reviewedDigest: reviewedDigest, admitScript: admitScript
        )
    }

    var externalSendDependencies: ExternalSendExecutionDependencies { .production }

    func observeMotorActionState(_ state: MotorActionReadModel) async {
        await NativeAgentEngine.cognitionRuntime(for: dataRoot).observeMotorActionState(state)
    }

    func runConnectorAction(descriptor: ConnectorActionDescriptor, dryRun: Bool, input: [String: JSONValue],
                            approvedReplayApprovalID: String, dataRoot: URL) async throws -> ApprovalConnectorActionResult {
        let receipt = try await ConnectorActions(platform: AppConnectorActionPlatform(dataRoot: self.dataRoot))
            .runConnectorAction(descriptor: descriptor, dryRun: dryRun, input: input,
                                approvedReplayApprovalID: approvedReplayApprovalID, dataRoot: dataRoot)
        return ApprovalConnectorActionResult(id: receipt.id, status: receipt.status)
    }

    func toolDispatchClient(enforceAppAutonomy: Bool) -> any ToolDispatchClient {
        NativeAgentEngine.forRoot(dataRoot).toolDispatchClient(
            enforceAppAutonomy: enforceAppAutonomy)
    }

    func continueChatToolApproval(dataRoot: URL, sessionID: String, envelope: TurnEnvelope, prompt: String, fileAccess: String) async throws {
        try await NativeAgentEngine.makeTurnContinuationRuntime(dataRoot: dataRoot)
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
        guard dataRootOverride == nil else { return NativeAgentEngine.makeWorkshopExecutor(dataRoot: dataRoot) }
        return WorkshopExecutorRef.shared.current() ?? NativeAgentEngine.makeWorkshopExecutor()
    }

    func workshopStepNotFound(_ description: String) -> any Error {
        DaemonError.notFound(description)
    }
}
