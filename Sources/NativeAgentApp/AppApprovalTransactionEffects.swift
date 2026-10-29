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
import ChatTurnRuntime
import ChatTurnContracts
import TrustCenter
import WorkshopExecution
// Blueprint: | `AppApprovalTransactionEffects.swift` | `AppApprovalTransactionEffects` struct and `ApprovalExecution.app`: app-bound approval factory and live executor/platform bindings; `AppApprovalTransactionEffects` struct; `ApprovalExecution.app` |

extension ApprovalExecution {
    /// The approval coordinator over the live app's effects.
    static func app() -> ApprovalExecution {
        ApprovalExecution(effects: AppApprovalTransactionEffects(), dataRootOverride: NativeAgentEngine.live.dataRoot)
    }

    static func resolveWorkshopStep(
        executionId: String,
        stepId: String,
        decision: String,
        provenance: ApprovalResolutionProvenance = .local(decidedBy: "mac_ui")
    ) async throws -> WorkshopExecutionRecord {
        return try await app().resolveWorkshopStep(
            executionId: executionId, stepId: stepId, decision: decision, provenance: provenance,
            runner: NativeAgentEngine.makeWorkshopExecutionRunner(dataRoot: NativeAgentEngine.live.dataRoot))
    }
}

/// Host bindings for approval effects and mounted conversation refresh.
struct AppApprovalTransactionEffects: ApprovalTransactionEffects {
    private var dataRoot: URL { NativeAgentEngine.live.dataRoot }

    func disableSkill(name: String) async throws {
        try await NativeSkillRegistryActions.disableSkill(name: name, dataRoot: dataRoot)
    }

    func enableSkill(name: String, reviewedDigest: String?) async throws {
        try await NativeSkillRegistryActions.enableSkill(
            name: name, dataRoot: dataRoot,
            reviewedDigest: reviewedDigest
        )
    }

    func runConnectorAction(descriptor: ConnectorActionDescriptor, dryRun: Bool, input: [String: JSONValue],
                            approvedReplayApprovalID: String, dataRoot: URL) async throws -> ConnectorActionReceipt {
        let engine = NativeAgentEngine.forRoot(dataRoot)
        return try await engine.tools.withPartDoor(envelope: .native("approval:connector_action:" + approvedReplayApprovalID)) {
            try await ConnectorActions(platform: AppConnectorActionPlatform(engine: engine))
                .runConnectorAction(descriptor: descriptor, dryRun: dryRun, input: input,
                                    approvedReplayApprovalID: approvedReplayApprovalID, dataRoot: dataRoot)
        }
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

    /// Use the published live executor when it is available.
    func workshopExecutor() -> WorkshopExecutorLoop {
        return WorkshopExecutorRef.shared.current() ?? NativeAgentEngine.makeWorkshopExecutor()
    }

    func workshopStepNotFound(_ description: String) -> any Error {
        DaemonError.notFound(description)
    }
}
