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
// Blueprint: | `AppApprovalTransactionEffects.swift` | Approval factory and live effect bindings; canonical browser outcomes |

extension ApprovalExecution {
    static func app() -> ApprovalExecution {
        ApprovalExecution(effects: AppApprovalTransactionEffects(), dataRootOverride: NativeAgentEngine.live.dataRoot)
    }
}

struct AppApprovalTransactionEffects: ApprovalTransactionEffects {
    private var dataRoot: URL { NativeAgentEngine.live.dataRoot }

    func enableSkill(name: String, reviewedDigest: String?, turn: Turn) async throws {
        try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(
            envelope: TurnEnvelope.current(turn: turn, surface: "ability.enable"), turn: turn) { door in
            try await NativeSkillRegistryActions.enableSkill(name: name, dataRoot: dataRoot,
                reviewedDigest: reviewedDigest, turn: door.turn, execution: door.execution)
        }
    }

    func runConnectorAction(descriptor: ConnectorActionDescriptor, dryRun: Bool, input: [String: JSONValue],
                            approvedReplayApprovalID: String, dataRoot: URL, turn: Turn) async throws -> ConnectorActionReceipt {
        let engine = NativeAgentEngine.forRoot(dataRoot)
        return try await engine.tools.withPartDoor(envelope: TurnEnvelope.current(turn: turn, surface: "approval:connector_action"), turn: turn) { door in
            try await ConnectorActions(platform: AppConnectorActionPlatform(engine: engine))
                .runConnectorAction(descriptor: descriptor, dryRun: dryRun, input: input,
                                    approvedReplayApprovalID: approvedReplayApprovalID, dataRoot: dataRoot, turn: door.turn)
        }
    }

    func toolDispatchClient(enforceAppAutonomy: Bool) -> any ToolDispatchClient {
        NativeAgentEngine.forRoot(dataRoot).toolDispatchClient(
            enforceAppAutonomy: enforceAppAutonomy)
    }

    func continueChatToolApproval(dataRoot: URL, sessionID: String, turn: Turn, prompt: String, fileAccess: String) async throws {
        try await NativeAgentEngine.makeTurnContinuationRuntime(dataRoot: dataRoot)
            .continueChatToolApproval(sessionID: sessionID, turn: turn, prompt: prompt, fileAccess: fileAccess)
    }

    func chatTurnCompleted(sessionID: String?) async {
        await MainActor.run {
            NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
        }
    }

    func observeBrowserMotorAction(runID: String, dataRoot: URL) async {
        await BrowserActionRoutes.app.observeBrowserMotorAction(runID: runID, dataRoot: dataRoot)
    }

    func executeApprovedBrowserRun(from record: ApprovalRecord) async throws -> JSONValue {
        try await BrowserActionRoutes.app.executeApprovedBrowserRun(from: record, dataRoot: dataRoot)
    }

    func finishRejectedBrowserRun(from record: ApprovalRecord, status: String) async throws -> JSONValue {
        try await BrowserActionRoutes.app.finishRejectedBrowserRun(from: record, status: status, dataRoot: dataRoot)
    }
}
