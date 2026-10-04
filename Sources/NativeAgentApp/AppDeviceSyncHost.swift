import Foundation
import AttentionRouting
import ApprovalInbox
import Desk
import DeviceSync
import MemoryV2
import NativeAgentShared
import NotificationInbox
import PersistenceCore
import ProviderRouting
import ToolRegistry
import Transcripts

/// A needs-User knock the router did not get onto any channel. Thrown so the
/// edge is not committed as delivered and the next pass retries it.
struct NeedsUserNotifyUndelivered: LocalizedError {
    let projection: AttentionOutcome.Delivery
    var errorDescription: String? { "needs-User knock not delivered (\(projection.rawValue))" }
}

enum MobileToolCatalogProjection {
    static func records(from catalog: ChatToolCatalogSnapshot) -> [MobileToolCatalogRecord] {
        catalog.tools.map { tool in
            MobileToolCatalogRecord(
                id: tool.name,
                name: tool.name,
                kind: tool.dispatchableVia,
                status: tool.loadState,
                description: tool.description,
                autoRun: tool.effectiveAutonomy == "auto",
                riskClass: tool.effectiveAutonomy,
                updatedAt: nil
            )
        }
    }
}

extension NAProviderCatalogProvider {
    /// The phone's credential-free row for one provider.
    init(_ provider: ProviderInfo) {
        self.init(
            providerID: provider.provider_id,
            displayName: provider.display_name,
            authState: provider.auth_status.state,
            authModes: provider.auth_modes,
            models: provider.models.map { model in
                NAProviderCatalogModel(
                    id: model.id,
                    name: model.name,
                    contextLength: model.context_length,
                    supportsStreaming: model.supports_streaming,
                    supportsVision: model.supports_vision,
                    supportsTools: model.supports_tools,
                    supportsJSONMode: model.supports_json_mode,
                    defaultReasoningEffort: model.default_reasoning_effort,
                    supportedReasoningEfforts: model.supported_reasoning_efforts,
                    supportsFast: model.supports_fast
                )
            }
        )
    }
}

/// Device sync's reads and actions through the app's NativeClient, the live
/// engine's facades, remote Mac control and the attention router.
struct AppDeviceSyncHost: DeviceSyncHost {
    func retryRequestedResults() async {
        do { try await AttentionRouter.shared.retryRequestedResults(dataRoot: PersistenceCore.defaultDataRoot()) }
        catch { NSLog("requested_result: publication retry failed: %@", error.localizedDescription) }
    }

    private var api: NativeClient { NativeClient(baseURL: "") }
    private var engine: NativeAgentEngine { NativeAgentEngine.live }

    func getWorkshopExecutions() async throws -> DeviceSyncSnapshotRows { try await engine.desk.taskRows() }
    func workOverview() async -> (overview: WorkOverview, deskItems: [DeskItem]?) {
        let board = await engine.desk.loadBoard(includeOverview: true)
        return (board.overview!, board.deskState?.items)
    }
    func getChatSessions() async throws -> [ChatSession] { try await engine.transcripts.list() }
    func getChatMessages(sessionId: String) async throws -> [any DeviceSyncTranscriptMessage & Sendable] {
        try await engine.transcripts.loadMessages(sessionId: sessionId)
    }
    func getHealth() async throws -> RuntimeHealth { engine.doctor.readHealth() }
    func pendingMemoryProposals() async throws -> DeviceSyncSnapshotRows {
        try await engine.memory.proposals(status: "pending").map(MemoryProposalRecord.init)
    }
    func getTrainingProposals() async throws -> DeviceSyncSnapshotRows { try await api.getTrainingProposals() }
    func getPromotionPending() async throws -> DeviceSyncSnapshotRows { try await api.getPromotionPending() }
    func getSkills() async throws -> DeviceSyncSnapshotRows { try await api.getSkills() }
    func activeMemories() async throws -> [MemoryV2.MemoryRecord] { try await engine.memory.activeMemories() }
    func getConnectors() async throws -> DeviceSyncSnapshotRows { try await mobileConnectors() }
    func mobileToolCatalog() async throws -> [MobileToolCatalogRecord] {
        MobileToolCatalogProjection.records(from: try await engine.tools.loadCatalog())
    }
    func providers() async throws -> DeviceSyncSnapshotRows { try await engine.providers.list() }
    func providerCatalogSnapshot() async throws -> (providers: [NAProviderCatalogProvider], routing: ProviderRoutingSnapshot) {
        let snapshot = try await engine.providers.routing.checkedProviderSnapshot()
        return (try ProvidersFacade.connections(from: snapshot).map(NAProviderCatalogProvider.init), snapshot.routing)
    }
    func trustSnapshotData() async throws -> Data { try await engine.trust.snapshotData() }
    func getPersonality() async throws -> PersonalityProfile { try await api.getPersonality() }
    func approvals() async throws -> [ApprovalRequest] {
        try await engine.approvals.list().map(ApprovalRequest.init(record:))
    }
    func inboxItems() async throws -> [InboxItemRecord] { try await engine.inbox.list() }
    func knowledgeGraphSnapshotData() async throws -> Data { try await NativeClient.canonicalKnowledgeGraphSnapshotData() }
    func getRunsStrict() async -> [RunRecord]? { await api.getRunsStrict() }
    func turnSummariesSnapshotData(root: URL?, now: Date) async -> Data? {
        let root = root ?? TurnSummarySource.liveRoot()
        return await Task.detached(priority: .utility) { () -> Data? in
            let events = TurnSummarySource.loadEvents(root: root, now: now)
            let encoder = TurnSummaryComputer.makeEncoder()
            let file = TurnSummaryComputer.compute(from: events, encoder: encoder)
            return try? encoder.encode(file)
        }.value
    }

    func submitWorkshopExecution(title: String, objective: String) async throws -> DeviceSyncWorkshopSubmission {
        let result = try await api.submitWorkshopExecution(title: title, objective: objective)
        return DeviceSyncWorkshopSubmission(executionId: result.executionId, id: result.id,
                                            desk_handle: result.desk_handle, desk_alias: result.desk_alias)
    }
    func approveStep(executionId: String, stepId: String, provenance: ApprovalResolutionProvenance) async throws {
        _ = try await api.approveStep(executionId: executionId, stepId: stepId, provenance: provenance)
    }
    func rejectStep(executionId: String, stepId: String, provenance: ApprovalResolutionProvenance) async throws {
        _ = try await api.rejectStep(executionId: executionId, stepId: stepId, provenance: provenance)
    }
    func acceptMemoryProposal(proposalID: String) async throws -> MemoryV2.MemoryRecord {
        try await engine.memory.accept(proposalID: proposalID)
    }
    func rejectMemoryProposal(proposalID: String, reason: String) async throws {
        try await engine.memory.reject(proposalID: proposalID, reason: reason)
    }
    func deleteMemory(id: String) async throws { try await engine.memory.delete(id: id) }
    func approvePromotionPending(id: String) async throws { _ = try await api.approvePromotionPending(id: id) }
    func rejectPromotionPending(id: String, reason: String) async throws {
        _ = try await api.rejectPromotionPending(id: id, reason: reason)
    }
    func resolveApproval(id: String, decision: String, provenance: ApprovalResolutionProvenance) async throws -> ApprovalRecord {
        try await api.resolveApproval(id: id, decision: decision, provenance: provenance)
    }
    func inboxAction(_ id: String, action: String) async throws { try await api.inboxAction(id, action: action) }
    func cancelChatSession(sessionId: String) async throws { try await engine.turns.stop(sessionId: sessionId) }
    func configureProvider(_ id: String, apiKey: String?, authMode: String, defaultModel: String?) async throws {
        _ = try await api.configureProvider(id, apiKey: apiKey, authMode: authMode, defaultModel: defaultModel)
        await QuietSelfAdmin.shared.appModel?.adoptProviderForBlankSurfaces(id)
    }
    func testProvider(_ id: String) async throws -> NativeAgentShared.ProviderTestResult { try await api.testProvider(id) }
    func clearProvider(_ id: String) async throws { _ = try await api.clearProvider(id) }
    func setActiveProvider(surface: String, providerId: String) async throws {
        _ = try await api.setActiveProvider(surface: surface, providerId: providerId)
    }
    func configureModel(surface: String, model: String, reasoningEffort: String, serviceTier: String?, inferProvider: Bool) async throws {
        _ = try await api.configureModel(surface: surface, model: model, reasoningEffort: reasoningEffort,
                                         serviceTier: serviceTier, inferProvider: inferProvider)
    }
    func setSurfaceModel(surface: String, model: String, inferProvider: Bool) async throws {
        _ = try await api.setSurfaceModel(surface: surface, model: model, inferProvider: inferProvider)
    }
    func configureSurfaceSelection(surface: String, providerID: String, model: String, reasoningEffort: String, serviceTier: String?) async throws {
        _ = try await api.configureSurfaceSelection(surface: surface, providerID: providerID, model: model,
                                                    reasoningEffort: reasoningEffort, serviceTier: serviceTier)
    }
    @MainActor func pinnedChatSessionIDs() -> [String] { MacPinnedChatSessionStore.load() }
    @MainActor func savePinnedChatSessionIDs(_ ids: [String]) throws { try MacPinnedChatSessionStore.save(ids) }
    func remoteMacControl(payload: [String: String]) async throws -> [String: String] {
        try await MacSyncRemoteMacControl(port: AppMacSyncRemoteMacControlPort(api: api)).dispatch(payload: payload)
    }

    func knockNeedsUser(title: String, body: String, userInfo: [String: String]) async throws {
        // Owner-waiting by definition — this notifier exists because Agent
        // needs User.
        let outcome = try await AttentionRouter.shared.route(
            eventId: userInfo["dedupKey"] ?? "needs_user",
            importance: .ownerWaiting,
            title: title,
            body: body,
            userInfo: userInfo
        )
        // Only a knock that actually reached a channel — or one the ledger
        // had already delivered — is a delivery. `.noChannel`, `.deferred`
        // and `.failed` all mean nothing reached User, so throw: the caller
        // treats delivery as the commit point and a throw keeps the episode
        // unwritten for the next overview read to retry.
        let projection = outcome.deliveryProjection
        guard projection.reachedAChannel || projection == .previouslyHandled else {
            throw NeedsUserNotifyUndelivered(projection: projection)
        }
    }
}
