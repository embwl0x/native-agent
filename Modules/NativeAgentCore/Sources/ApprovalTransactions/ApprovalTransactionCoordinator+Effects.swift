import SelfImprovement
import Foundation
import NativeAgentShared
import PersistenceCore
import ApprovalInbox
import ChatOrchestration
import MemoryV2
import TrustCenter
import WorkshopExecution

/// Effect adapters supplied by the host; transaction ordering and replay fences
/// remain in ApprovalTransactionCoordinator.
public protocol ApprovalTransactionEffects: Sendable {
    var telegramSurface: String { get }
    var telegramIncludesEvolutionBridge: Bool { get }
    func runMemoryHygiene() async throws -> ApprovalMemoryHygieneResult
    func disableSkill(name: String) async throws
    /// `reviewedDigest` nil turns on only what needs no admission; a digest
    /// admits exactly that script as User's, as the Skills page's Install does.
    func enableSkill(name: String, reviewedDigest: String?) async throws
    func applyResolvedExternalSend(from record: ApprovalRecord) async -> Bool
    func selfEvolutionDependencies() -> SelfEvolutionApprovalExecutor.SelfEvolutionDeps
    func runConnectorAction(descriptor: ConnectorActionDescriptor, dryRun: Bool, input: [String: JSONValue], approvedReplayApprovalID: String, dataRoot: URL) async throws -> ApprovalConnectorActionResult
    func toolDispatchClient(includeEvolutionBridge: Bool, denyExternalMcp: Bool, enforceAppAutonomy: Bool) -> any ToolDispatchClient
    func continueChatToolApproval(dataRoot: URL, sessionID: String, envelope: TurnEnvelope, prompt: String) async throws
    func chatTurnCompleted(sessionID: String?) async
    func observeBrowserMotorAction(runID: String, dataRoot: URL) async
    func executeApprovedBrowserRun(from record: ApprovalRecord) async throws
    func finishRejectedBrowserRun(from record: ApprovalRecord, status: String) async throws
    func workshopExecutor() -> WorkshopExecutorLoop
    func updateVisibleNotificationInboxStatus(id: String, action: String) async -> Bool
}

public struct ApprovalMemoryHygieneResult: Sendable {
    public let id: String?
    public let status: String?
    public let reason: String?
    public let consolidationRunId: String?

    public init(id: String?, status: String?, reason: String?, consolidationRunId: String?) {
        self.id = id
        self.status = status
        self.reason = reason
        self.consolidationRunId = consolidationRunId
    }
}

public struct ApprovalConnectorActionResult: Sendable {
    public let id: String
    public let status: String

    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }
}
