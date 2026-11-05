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

/// A Desk task the phone starts: its item and the agent's line that carries it.
public struct DeviceSyncDeskTask: Sendable {
    public var job: String
    public var desk_handle: String
    public var desk_alias: String

    public init(job: String, desk_handle: String, desk_alias: String) {
        self.job = job
        self.desk_handle = desk_handle
        self.desk_alias = desk_alias
    }
}

public protocol DeviceSyncHost: Sendable {
    func helpersSnapshot() async throws -> MobileHelpersSnapshot
    func helperAction(action: String, payload: [String: String]) async throws -> [String: String]
    func agentThreadAction(action: String, payload: [String: String], turn: Turn) async throws -> [String: String]
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
    @MainActor func faceAction(page: String, row: String, action: String, value: String?, device: String) async throws -> String?
    func getChatMessages(sessionId: String) async throws -> [ChatMessageRecord]
    func getOtherRoomExchanges() async throws -> [OtherRoomExchange]
    func getHealth() async throws -> RuntimeHealth
    func turnSummariesSnapshotData() async -> Data?
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
    func disconnectTelegram() async throws -> MobileTelegramSnapshot
    func getPersonality() async throws -> PersonalityProfile
    func knowledgeGraphSnapshotData() async throws -> Data
    func getRunsStrict() async -> [RunRecord]?
    func schedulerCreateJob(input: [String: JSONValue]) async throws -> JSONValue
    /// Phone settings read and write through the same registry as the Mac page controls.
    @MainActor func appSettings() async throws -> [MobileAppSetting]
    @MainActor func setAppSetting(id: String, value: String, actionID: String, clientID: String) async throws -> MobileAppSetting
    func applyMobileTrustAction(_ request: MobileTrustAction) async throws -> Data
    func setConnectorEnabled(id: String, enabled: Bool) async throws -> DeviceSyncSnapshotRows
    func disconnectConnector(id: String) async throws -> DeviceSyncSnapshotRows
    func submitDeskTask(title: String, objective: String) async throws -> DeviceSyncDeskTask
    func acceptMemoryProposal(proposalID: String) async throws -> MemoryV2.MemoryRecord
    func rejectMemoryProposal(proposalID: String, reason: String) async throws
    func deleteMemory(id: String) async throws
    func resolveApproval(id: String, decision: String, provenance: ApprovalResolutionProvenance) async throws -> ApprovalRecord
    func inboxAction(_ id: String, action: String) async throws
    @MainActor func interactionAction(payload: [String: String], actionID: String, clientID: String) async throws -> [String: String]
    func cancelChatSession(sessionId: String, runIDs: [String]) async throws
    func configureProvider(_ id: String, apiKey: String?, authMode: String, defaultModel: String?) async throws
    @MainActor func startProviderSignIn(_ id: String, requestID: String) -> [String: String]
    @MainActor func providerSignInStates() -> [String: [String: String]]
    func testProvider(_ id: String) async throws -> NativeAgentShared.ProviderTestResult
    func clearProvider(_ id: String) async throws
    func setActiveProvider(surface: String, providerId: String) async throws
    func saveSurfaceSelection(
        surface: String,
        model: String,
        reasoningEffort: String?,
        serviceTier: String?,
        providerID: String?) async throws -> ProviderRoutingSnapshot
    @MainActor func pinnedChatSessionIDs() -> [String]
    @MainActor func savePinnedChatSessionIDs(_ ids: [String]) throws
    /// Remote control must pass through the app's Mac control route.
    func remoteMacControl(payload: [String: String], turn: Turn) async throws -> [String: String]

    /// Retry persisted result delivery independently of turn execution.
    func retryRequestedResults() async
}
