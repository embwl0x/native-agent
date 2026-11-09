import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import ApprovalInbox
import Desk
import MemoryV2
import NativeAgentShared
import NotificationInbox
import Transcripts
// Blueprint: | `DeviceSyncHost.swift` | Shared snapshot/action seam, checked layout and bounded message projections. |

/// Encode app-owned mirror types directly so device sync cannot invent a second wire shape.
public typealias DeviceSyncSnapshotRows = any Encodable & Sendable

public protocol DeviceSyncHost: Sendable {
    func helpersSnapshot() async throws -> MobileHelpersSnapshot
    /// The phone's agent thread: a read, or the person's own words sent through the door as the verified `device`'s act.
    func agentThreadAction(action: String, payload: [String: String], device: String) async throws -> [String: String]
    /// One Desk/authority read per pass; failed groups keep their own errors.
    func workOverview() async -> (
        overview: WorkOverview, deskItems: [DeskItem]?,
        approvals: Result<[ApprovalRequest], Error>, inbox: Result<[InboxItemRecord], Error>,
        jobEvidence: Result<[DeskExecutionEvidence], Error>
    )
    func getChatSessions() async throws -> [NativeAgentShared.ChatSession]
    func getChatTranscriptGenerations() async throws -> [String: Int?]
    @MainActor func sessionNavigation(for sessions: [NativeAgentShared.ChatSession]) -> ChatSessionNavigation
    @MainActor func surfaceLayout() -> SurfaceLayoutAvailability
    /// Every page's published face (the phone shows them all).
    @MainActor func pageFaces() async -> [String: PartFaceSnapshot]
    func faceRead(_ request: DocumentRequest, cursor: Int, revision: String?, device: String) async throws -> FaceReadPage
    @MainActor func faceAction(page: String, row: String, action: String, value: String?, device: String) async throws -> String?
    @MainActor func faceOutcome(page: String, row: String, action: String, value: String?, values: [String: PartFace.Value]?,
                               formRevision: String?, device: String,
                               expecting: PartFace.Call, operation: UUID, undoOf: UUID?, checking: Bool) async throws -> FaceActOutcome
    /// Installed phones 61/63 still send decision envelopes. These adapters reach the current decision/row owners, never another executor.
    func decidePhoneApproval(id: String, decision: String, device: String) async throws -> ApprovalRecord
    @MainActor func answerPhoneInteraction(_ fields: [String: String], device: String) async throws -> [String: String]
    func getChatMessages(sessionId: String) async throws -> [ChatMessageRecord]
    func getOtherRoomExchanges() async throws -> [OtherRoomExchange]
    func getHealth() async throws -> RuntimeHealth
    func turnSummariesSnapshotData() async -> Data?
    func turnSessionsFace() async -> TurnSessionsFace?
    func pendingMemoryProposals() async throws -> DeviceSyncSnapshotRows
    func getSkills() async throws -> DeviceSyncSnapshotRows
    func activeMemories() async throws -> [MemoryV2.MemoryRecord]
    func getConnectors() async throws -> [MobileConnectorSnapshot]
    func mobileToolCatalog() async throws -> [MobileToolCatalogRecord]
    func providers() async throws -> (providers: DeviceSyncSnapshotRows, routing: ProviderRoutingSnapshot)
    func providerCatalogSnapshot() async throws -> (providers: [NAProviderCatalogProvider], routing: ProviderRoutingSnapshot)
    func trustSnapshotData() async throws -> Data
    func macIntegrationPermissionsSnapshot() async throws -> [String: [String: Bool]]
    func telegramSnapshot() async throws -> MobileTelegramSnapshot
    func getPersonality() async throws -> PersonalityProfile
    func knowledgeGraphSnapshotData() async throws -> Data
    func getRunsStrict() async -> [RunRecord]?
    func disconnectConnector(id: String) async throws -> DeviceSyncSnapshotRows
    func cancelChatSession(sessionId: String, runIDs: [String]) async throws
    @MainActor func providerSignInStates() -> [String: [String: String]]
    func saveSurfaceSelection(
        surface: String,
        model: String,
        reasoningEffort: String?,
        serviceTier: String?,
        providerID: String?) async throws -> ProviderRoutingSnapshot
    @MainActor func closePinnedChatSession(_ sessionID: String) async throws -> Bool
    /// Remote control must pass through the app's Mac control route.
    func remoteMacControl(payload: [String: String], turn: Turn) async throws -> [String: String]

    /// Retry persisted result delivery independently of turn execution.
    func retryRequestedResults() async
}
