import Foundation
import PersistenceCore
import ProviderRouting
import ApprovalInbox
import Desk
import MemoryV2
import NativeAgentShared
import NotificationInbox
import Transcripts
// Blueprint: | `DeviceSyncHost.swift` | Engine snapshot/action seam; transcript timestamps bound read-only other-room exchanges to shown history; message owners omit previews for transport budgets |

/// Snapshot rows whose type the app's mirrors still own. Device sync only
/// encodes them, with the snapshot encoder, so the phone's bytes are the app
/// type's own.
public typealias DeviceSyncSnapshotRows = any Encodable & Sendable

/// One transcript row as the phone reads it. The app's chat model supplies the
/// bytes; transport budgets can trim content and omit optional previews.
public protocol DeviceSyncTranscriptMessage: Encodable {
    var id: String { get }
    var createdAt: String { get }
    var content: String { get set }
    mutating func omitAttachmentPreviews()
    /// False for a row that is hers alone (her wake inputs): the phone's view
    /// of the conversation omits it, though it still anchors history paging.
    var isPersonVisible: Bool { get }
}

extension DeviceSyncTranscriptMessage {
    public var isPersonVisible: Bool { true }
}

/// A transcript row in a published chat snapshot: the app's own encoding.
struct DeviceSyncTranscriptRow: Encodable, Sendable {
    var message: any DeviceSyncTranscriptMessage & Sendable

    func encode(to encoder: Encoder) throws {
        try message.encode(to: encoder)
    }
}

/// What a Workshop submission hands back to the phone.
public struct DeviceSyncWorkshopSubmission: Sendable {
    public var executionId: String?
    public var id: String?
    public var desk_handle: String?
    public var desk_alias: String?

    public init(executionId: String?, id: String?, desk_handle: String?, desk_alias: String?) {
        self.executionId = executionId
        self.id = id
        self.desk_handle = desk_handle
        self.desk_alias = desk_alias
    }
}

/// What device sync reaches that the app still owns: its reads and actions,
/// the engine facades, remote Mac control and the attention router.
public protocol DeviceSyncHost: Sendable {
    func helpersSnapshot() async throws -> MobileHelpersSnapshot
    func helperAction(action: String, payload: [String: String]) async throws -> [String: String]
    func agentThreadAction(action: String, payload: [String: String]) async throws -> [String: String]
    // Snapshot reads.
    func getWorkshopExecutions() async throws -> DeviceSyncSnapshotRows
    /// One Desk/authority read per pass; failed lanes keep their own errors.
    func workOverview() async -> (
        overview: WorkOverview, deskItems: [DeskItem]?,
        approvals: Result<[ApprovalRequest], Error>, inbox: Result<[InboxItemRecord], Error>
    )
    func getChatSessions() async throws -> [NativeAgentShared.ChatSession]
    @MainActor func sessionNavigation(for sessions: [NativeAgentShared.ChatSession]) -> ChatSessionNavigation
    @MainActor func surfaceLayout() -> SurfaceLayout
    func getChatMessages(sessionId: String) async throws -> [any DeviceSyncTranscriptMessage & Sendable]
    func getOtherRoomExchanges() async throws -> [OtherRoomExchange]
    func getHealth() async throws -> RuntimeHealth
    func turnSummariesSnapshotData() async -> Data?
    func pendingMemoryProposals() async throws -> DeviceSyncSnapshotRows
    func getSkills() async throws -> DeviceSyncSnapshotRows
    func activeMemories() async throws -> [MemoryV2.MemoryRecord]
    func getConnectors() async throws -> DeviceSyncSnapshotRows
    func mobileToolCatalog() async throws -> [MobileToolCatalogRecord]
    func providers() async throws -> DeviceSyncSnapshotRows
    func providerCatalogSnapshot() async throws -> (providers: [NAProviderCatalogProvider], routing: ProviderRoutingSnapshot)
    func trustSnapshotData() async throws -> Data
    func macIntegrationPermissionsSnapshot() async throws -> [String: [String: Bool]]
    func telegramSnapshot() async throws -> MobileTelegramSnapshot
    func changeTelegram(_ change: MobileTelegramChange) async throws -> MobileTelegramSnapshot
    func getPersonality() async throws -> PersonalityProfile
    func knowledgeGraphSnapshotData() async throws -> Data
    func getRunsStrict() async -> [RunRecord]?
    // The phone's signed actions.
    func schedulerCreateJob(input: [String: JSONValue]) async throws -> JSONValue
    /// The Mac's settings registry: every row as its page reads it, and one
    /// row set through the write its page control calls.
    @MainActor func appSettings() async throws -> [MobileAppSetting]
    @MainActor func setAppSetting(id: String, value: String, actionID: String, clientID: String) async throws -> MobileAppSetting
    func applyMobileTrustAction(_ request: MobileTrustAction) async throws -> Data
    func setConnectorEnabled(id: String, enabled: Bool) async throws -> DeviceSyncSnapshotRows
    func disconnectConnector(id: String) async throws -> DeviceSyncSnapshotRows
    func submitWorkshopExecution(title: String, objective: String) async throws -> DeviceSyncWorkshopSubmission
    func approveStep(executionId: String, stepId: String, provenance: ApprovalResolutionProvenance) async throws
    func rejectStep(executionId: String, stepId: String, provenance: ApprovalResolutionProvenance) async throws
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
    func configureModel(surface: String, model: String, reasoningEffort: String, serviceTier: String?, inferProvider: Bool) async throws
    func setSurfaceModel(surface: String, model: String, inferProvider: Bool) async throws
    func configureSurfaceSelection(surface: String, providerID: String, model: String, reasoningEffort: String, serviceTier: String?) async throws
    /// The Mac's own pinned chats, in order, and their one mutation seam.
    @MainActor func pinnedChatSessionIDs() -> [String]
    @MainActor func savePinnedChatSessionIDs(_ ids: [String]) throws
    /// A phone's `mac_control` action, through the app's Mac control route.
    func remoteMacControl(payload: [String: String]) async throws -> [String: String]

    /// The needs-User knock, through the attention router. Throws when it
    /// reached no channel, so the edge is retried.
    func knockNeedsUser(title: String, body: String, userInfo: [String: String]) async throws
    /// Retry persisted result delivery independently of turn execution.
    func retryRequestedResults() async
}
