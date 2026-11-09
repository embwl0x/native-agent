import Foundation
import PersonaEngine
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import ApprovalInbox
import ChatTurnRuntime
import ChatTurnContracts
import MemoryV2
import TrustCenter
// Blueprint: | `ApprovalTransactionCoordinator+Effects.swift` | `ApprovalTransactionEffects`, `ApprovalExecution.approvedEffectTurn` |

/// Effect adapters supplied by the host; transaction ordering and replay fences remain in ApprovalExecution.
public protocol ApprovalTransactionEffects: Sendable {
    /// Only a reviewed digest admits executable code as the owner's; nil restores Markdown guidance.
    func enableSkill(name: String, reviewedDigest: String?, turn: Turn) async throws
    func runConnectorAction(descriptor: ConnectorActionDescriptor, dryRun: Bool, input: [String: JSONValue], approvedReplayApprovalID: String,
        dataRoot: URL, turn: Turn) async throws -> ConnectorActionReceipt
    func toolDispatchClient(enforceAppAutonomy: Bool) -> any ToolDispatchClient
    func continueChatToolApproval(dataRoot: URL, sessionID: String, turn: Turn, prompt: String, fileAccess: String) async throws
    func chatTurnCompleted(sessionID: String?) async
    func observeBrowserMotorAction(runID: String, dataRoot: URL) async
    func executeApprovedBrowserRun(from record: ApprovalRecord) async throws -> JSONValue
    func finishRejectedBrowserRun(from record: ApprovalRecord, status: String) async throws -> JSONValue
}

public extension ApprovalExecution {
    /// These bounded domain cards carry no request envelope. Their approved
    /// effect is a local approval act; the resolving door only records who decided.
    internal func approvedEffectTurn(from record: ApprovalRecord) async -> Turn {
        let host = await ApprovalLifecycleBus.shared.hostContext(record)
        let envelope = TurnEnvelope.personOnMac("approval:" + record.id)
        return (host?.turn ?? Turn(run: record.id)).with(\.envelope, envelope)
    }
}
