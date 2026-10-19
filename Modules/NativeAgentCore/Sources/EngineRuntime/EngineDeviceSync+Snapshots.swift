import Foundation
import ChatOrchestration
import NativeAgentCore
import SlackConnector
import TelegramBot
import TriggerScheduler
import WorkshopExecution
import BackgroundLoops
import AppToolRuntime
import TrustCenter
import MacControl
import ApprovalTransactions
import AttentionRouting
import ApprovalInbox
import Desk
import DeviceSync
import KnowledgeGraph
import MemoryV2
import NativeAgentShared
import NotificationInbox
import PersistenceCore
import PersonaEngine
import ProviderRouting
import SelfImprovement
import ToolRegistry
import Transcripts

// The phone's memory_proposals.json row. Mac views read ProposalRecord.
public struct MemoryProposalRecord: Codable, Identifiable, Hashable, Sendable {
    public var proposal_id: String
    public var fact_text: String
    public var display_text: String?
    public var supporting_session_ids: [String]
    public var recurrence_count: Int
    public var first_seen: String
    public var last_seen: String
    public var status: String
    public var staged_at: String
    public var resolved_at: String?
    public var rejection_reason: String?
    public var id: String { proposal_id }

    public init(_ proposal: ProposalRecord) {
        let evidence = proposal.evidence
        proposal_id = proposal.id
        fact_text = proposal.content
        display_text = nil
        supporting_session_ids = evidence.sessionIDs
        recurrence_count = evidence.recurrenceCount
        first_seen = proposal.createdAt
        last_seen = proposal.createdAt
        status = proposal.status
        staged_at = proposal.createdAt
        resolved_at = nil
        rejection_reason = proposal.rejectionReason
    }
}

private struct MobileCardTranscriptMessage: DeviceSyncTranscriptMessage, Sendable {
    var message: NativeAppChatMessage
    let interactionJSON: String
    let interactionDescriptorJSON: String
    let interactionSessionID: String
    var id: String { message.id }
    var content: String {
        get { message.content }
        set { message.content = newValue }
    }
    private enum CodingKeys: String, CodingKey { case interactionJSON, interactionDescriptorJSON, interactionSessionID }
    func encode(to encoder: Encoder) throws {
        try message.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(interactionJSON, forKey: .interactionJSON)
        try fields.encode(interactionDescriptorJSON, forKey: .interactionDescriptorJSON)
        try fields.encode(interactionSessionID, forKey: .interactionSessionID)
    }
}

public enum MobileToolCatalogProjection {
    public static func records(from catalog: ChatToolCatalogSnapshot) -> [MobileToolCatalogRecord] {
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
    public init(_ provider: ProviderInfo) {
        self.init(
            providerID: provider.provider_id,
            displayName: provider.display_name,
            authState: provider.auth_status.state,
            eligible: provider.auth_status.eligible,
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

extension NativeAgentEngine {
    public func mobileChatMessages(sessionId: String) async throws -> [any DeviceSyncTranscriptMessage & Sendable] {
        let messages = try await transcripts.loadMessages(sessionId: sessionId)
        let pairs = try await InlineInteractionResolver.checkedInteractionsByRow(sessionID: sessionId).get()
        let cards = Dictionary(pairs.map { ($0.rowID, $0.interaction) }, uniquingKeysWith: { _, last in last })
        var result: [any DeviceSyncTranscriptMessage & Sendable] = []
        for message in messages {
            var card = cards[message.id]
            var origin = sessionId
            if let mirror = message.metadata?.interactionMirror {
                origin = mirror.sessionID
                card = await InlineInteractionResolver.interaction(id: mirror.interactionID, sessionID: origin)
            }
            if var card {
                card = await InlineInteractionResolver.liveProjection(card, dataRoot: PersistenceCore.defaultDataRoot())
                let descriptor = await InlineInteractionResolver.descriptor(for: card, dataRoot: PersistenceCore.defaultDataRoot())
                card.continuation = nil
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                result.append(MobileCardTranscriptMessage(message: message,
                    interactionJSON: String(decoding: try encoder.encode(card), as: UTF8.self),
                    interactionDescriptorJSON: String(decoding: try encoder.encode(descriptor), as: UTF8.self),
                    interactionSessionID: origin))
            } else { result.append(message) }
        }
        return result
    }
    public func mobileProviderCatalogSnapshot() async throws -> (providers: [NAProviderCatalogProvider], routing: ProviderRoutingSnapshot) {
        let snapshot = try await providers.routing.checkedProviderSnapshot()
        return (try ProvidersFacade.connections(from: snapshot).map(NAProviderCatalogProvider.init), snapshot.routing)
    }
}

/// A needs-User knock the router did not get onto any channel. Thrown so the
/// edge is not committed as delivered and the next pass retries it.
struct NeedsUserNotifyUndelivered: LocalizedError {
    let projection: AttentionOutcome.Delivery
    var errorDescription: String? { "needs-owner knock not delivered (\(projection.rawValue))" }
}

/// Device sync's reads and actions through the live engine's facades and the
/// app's owners, remote Mac control and the attention router.
public struct EngineDeviceSyncHost: DeviceSyncHost {
    private let getEngine: @Sendable () -> NativeAgentEngine
    private let router: @Sendable () -> AttentionRouter
    private let platform: any EngineDeviceSyncPlatform

    public init(engine: @escaping @Sendable () -> NativeAgentEngine, router: @escaping @Sendable () -> AttentionRouter,
                platform: any EngineDeviceSyncPlatform) {
        self.getEngine = engine
        self.router = router
        self.platform = platform
    }
    public func retryRequestedResults() async {
        do { try await router().retryRequestedResults(dataRoot: engine.dataRoot) }
        catch { nativeLog("requested_result: publication retry failed: %@", error.localizedDescription) }
    }

    private var engine: NativeAgentEngine { getEngine() }

    public func getWorkshopExecutions() async throws -> DeviceSyncSnapshotRows { try await engine.desk.taskRows() }
    public func workOverview() async -> (
        overview: WorkOverview, deskItems: [DeskItem]?,
        approvals: Result<[ApprovalRequest], Error>, inbox: Result<[InboxItemRecord], Error>
    ) {
        let board = await engine.desk.loadBoard()
        let read = await engine.desk.loadOverview(board)
        return (read.overview, board.deskState?.items,
            read.approvals.map { $0.map(ApprovalRequest.init(record:)) }, read.inbox)
    }
    public func getChatSessions() async throws -> [NativeAgentShared.ChatSession] { try await engine.transcripts.list() }
    public func getChatMessages(sessionId: String) async throws -> [any DeviceSyncTranscriptMessage & Sendable] {
        try await engine.mobileChatMessages(sessionId: sessionId)
    }
    public func getHealth() async throws -> RuntimeHealth { engine.doctor.readHealth() }
    public func pendingMemoryProposals() async throws -> DeviceSyncSnapshotRows {
        platform.memoryProposalRows(try await engine.memory.proposals(status: "pending"))
    }
    public func getSkills() async throws -> DeviceSyncSnapshotRows { try await RuntimeReadProjection.skills(dataRoot: engine.dataRoot) }
    public func activeMemories() async throws -> [MemoryV2.MemoryRecord] { try await engine.memory.activeMemories() }
    public func getConnectors() async throws -> DeviceSyncSnapshotRows { try await ConnectorStatusProjection.mobileConnectors(root: engine.dataRoot, platform: platform.connectorStatus, canToggle: platform.connectorCanToggle) }
    public func mobileToolCatalog() async throws -> [MobileToolCatalogRecord] {
        MobileToolCatalogProjection.records(from: try await engine.tools.loadCatalog())
    }
    public func providers() async throws -> DeviceSyncSnapshotRows { try await engine.providers.list() }
    public func providerCatalogSnapshot() async throws -> (providers: [NAProviderCatalogProvider], routing: ProviderRoutingSnapshot) {
        try await engine.mobileProviderCatalogSnapshot()
    }
    public func trustSnapshotData() async throws -> Data { try await engine.trust.snapshotData() }
    public func getPersonality() async throws -> PersonalityProfile {
        try PersonaCompiler.compileProfile(dataRoot: engine.dataRoot).sharedProfile
    }
    public func knowledgeGraphSnapshotData() async throws -> Data { try await KnowledgeGraphReadProjection.canonicalKnowledgeGraphSnapshotData() }
    public func getRunsStrict() async -> [RunRecord]? { await RuntimeReadProjection.runs(dataRoot: engine.dataRoot) }
    public func submitWorkshopExecution(title: String, objective: String) async throws -> DeviceSyncWorkshopSubmission {
        let result = try await platform.submitDeskTask(title: title, objective: objective)
        return DeviceSyncWorkshopSubmission(executionId: result.executionId, id: result.executionId,
                                            desk_handle: result.deskItem.handle, desk_alias: result.deskItem.alias)
    }
    public func approveStep(executionId: String, stepId: String, provenance: ApprovalResolutionProvenance) async throws {
        _ = try await platform.resolveWorkshopStep(
            executionId: executionId, stepId: stepId, decision: "approve", provenance: provenance)
    }
    public func rejectStep(executionId: String, stepId: String, provenance: ApprovalResolutionProvenance) async throws {
        _ = try await platform.resolveWorkshopStep(
            executionId: executionId, stepId: stepId, decision: "reject", provenance: provenance)
    }
    public func acceptMemoryProposal(proposalID: String) async throws -> MemoryV2.MemoryRecord {
        try await engine.memory.accept(proposalID: proposalID)
    }
    public func rejectMemoryProposal(proposalID: String, reason: String) async throws {
        try await engine.memory.reject(proposalID: proposalID, reason: reason)
    }
    public func deleteMemory(id: String) async throws { try await engine.memory.delete(id: id) }
    public func resolveApproval(id: String, decision: String, provenance: ApprovalResolutionProvenance) async throws -> ApprovalRecord {
        try await platform.resolveApproval(id: id, decision: decision, provenance: provenance)
    }
    public func inboxAction(_ id: String, action: String) async throws {
        try await platform.inboxAction(id, action: action)
    }
    @MainActor
    public func interactionAction(payload: [String: String], actionID: String, clientID: String) async throws -> [String: String] {
        try await platform.interactionAction(payload: payload, actionID: actionID, clientID: clientID)
    }
    public func cancelChatSession(sessionId: String) async throws { try await engine.turns.stop(sessionId: sessionId) }
    public func configureProvider(_ id: String, apiKey: String?, authMode: String, defaultModel: String?) async throws {
        try await engine.providers.configureProvider(id: id, apiKey: apiKey, authMode: authMode, defaultModel: defaultModel)
        await platform.adoptProvider(id)
    }
    public func testProvider(_ id: String) async throws -> NativeAgentShared.ProviderTestResult { try await engine.providers.testProvider(id) }
    public func clearProvider(_ id: String) async throws { try await engine.providers.clearProvider(id) }
    public func setActiveProvider(surface: String, providerId: String) async throws {
        try await engine.providers.routing.setActiveProvider(surface: surface, providerId: providerId)
    }
    public func configureModel(surface: String, model: String, reasoningEffort: String, serviceTier: String?, inferProvider: Bool) async throws {
        _ = try await engine.providers.saveSurfaceSelection(
            surface: surface, model: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier,
            providerID: inferProvider ? SwiftNativeProviderRouting.inferredProviderID(forModel: model) : nil)
    }
    public func setSurfaceModel(surface: String, model: String, inferProvider: Bool) async throws {
        _ = try await engine.providers.saveSurfaceSelection(
            surface: surface, model: model, reasoningEffort: nil, serviceTier: nil,
            providerID: inferProvider ? SwiftNativeProviderRouting.inferredProviderID(forModel: model) : nil)
    }
    public func configureSurfaceSelection(surface: String, providerID: String, model: String, reasoningEffort: String, serviceTier: String?) async throws {
        _ = try await engine.providers.saveSurfaceSelection(
            surface: surface, model: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier, providerID: providerID)
    }
    @MainActor public func pinnedChatSessionIDs() -> [String] { platform.pinnedChatSessionIDs() }
    @MainActor public func savePinnedChatSessionIDs(_ ids: [String]) throws { try platform.savePinnedChatSessionIDs(ids) }
    public func remoteMacControl(payload: [String: String]) async throws -> [String: String] {
        try await MacSyncRemoteMacControl(port: EngineRemoteMacControlPort(engine: engine, platform: platform)).dispatch(payload: payload)
    }

    public func knockNeedsUser(title: String, body: String, userInfo: [String: String]) async throws {
        // Owner-waiting by definition — this notifier exists because Agent
        // needs User.
        let outcome = try await router().route(
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

public protocol EngineDeviceSyncPlatform: Sendable {
    var connectorStatus: any ConnectorStatusPlatform { get }
    func connectorCanToggle(_ row: ConnectorRecord) -> Bool
    func memoryProposalRows(_ rows: [ProposalRecord]) -> DeviceSyncSnapshotRows
    func restartTelegram() async -> Bool
    @MainActor func settingsHost() throws -> any QuietSettingsHost
    @MainActor var oauthPlatform: any NativeOAuthPlatformPort.Type { get }
    @MainActor func adoptProvider(_ id: String) async
    @MainActor func pinnedChatSessionIDs() -> [String]
    @MainActor func savePinnedChatSessionIDs(_ ids: [String]) throws
    func submitDeskTask(title: String, objective: String) async throws -> WorkshopDirectedTaskResult
    func resolveWorkshopStep(executionId: String, stepId: String, decision: String, provenance: ApprovalResolutionProvenance) async throws -> WorkshopExecution.WorkshopExecutionRecord
    func resolveApproval(id: String, decision: String, provenance: ApprovalResolutionProvenance) async throws -> ApprovalRecord
    func inboxAction(_ id: String, action: String) async throws
    @MainActor func interactionAction(payload: [String: String], actionID: String, clientID: String) async throws -> [String: String]
    @MainActor func runMacControl(path: String, bodyData: Data) async throws -> MacControlRunResult
}

@MainActor
private struct EngineRemoteMacControlPort: MacSyncRemoteMacControlPort {
    let engine: NativeAgentEngine
    let platform: any EngineDeviceSyncPlatform
    func loadTrustPolicy() async throws -> TrustPolicy { try await engine.trust.load() }
    func run(path: String, bodyData: Data) async throws -> MacSyncRemoteMacControlResult {
        let result = try await platform.runMacControl(path: path, bodyData: bodyData)
        return MacSyncRemoteMacControlResult(statusCode: result.statusCode, json: result.json, rawData: result.rawData)
    }
}

extension EngineDeviceSyncHost {
    public func helpersSnapshot() async throws -> MobileHelpersSnapshot {
        try await engine.deviceHelpersSnapshot()
    }

    public func helperAction(action: String, payload: [String: String]) async throws -> [String: String] {
        try await engine.deviceHelperAction(action: action, payload: payload)
    }

    public func agentThreadAction(action: String, payload: [String: String]) async throws -> [String: String] {
        try await engine.deviceAgentThreadAction(action: action, payload: payload)
    }
}

extension EngineDeviceSyncHost {
    @MainActor
    public func appSettings() async throws -> [MobileAppSetting] {
        try await QuietSettings.mobileSettings(host: platform.settingsHost())
    }

    @MainActor
    public func setAppSetting(id: String, value: String, actionID: String, clientID: String) async throws -> MobileAppSetting {
        try await QuietSettings.setMobileSetting(host: platform.settingsHost(), id: id, value: value,
                                                actionID: actionID, clientID: clientID)
    }

}

extension EngineDeviceSyncHost {
    public func telegramSnapshot() async throws -> MobileTelegramSnapshot {
        try await TelegramFacade(dataRoot: engine.dataRoot).mobileTelegramSnapshot(
            manager: BackgroundLoops.BackgroundLoopsManager.shared)
    }

    public func changeTelegram(_ change: MobileTelegramChange) async throws -> MobileTelegramSnapshot {
        try await TelegramFacade(dataRoot: engine.dataRoot).changeTelegramSettings(change) {
            await platform.restartTelegram()
        }
        return try await telegramSnapshot()
    }
}

extension EngineDeviceSyncHost {
    public func applyMobileTrustAction(_ request: MobileTrustAction) async throws -> Data {
        let root = engine.dataRoot
        let saved = try await request.apply(dataRoot: root) { preset, confirmed in
            try await TrustPolicyPreset.saveMobilePreset(preset, dataRoot: root, fullMacConfirmed: confirmed)
        }
        await MainActor.run { engine.trust.policy = saved }
        return try await trustSnapshotData()
    }
}

extension EngineDeviceSyncHost {
    @MainActor
    public func startProviderSignIn(_ id: String, requestID: String) -> [String: String] {
        ProviderSignInHandoff.shared.start(id, requestID: requestID) {
            let root = engine.dataRoot
            let result = await NativeOAuthFlow.startOAuthFlow(
                platform: platform.oauthPlatform, providerId: id, dataRoot: root
            )
            let signedIn = result.ok && NativeOAuthFlow.isSignedIn(providerId: id, dataRoot: root)
            if signedIn {
                await platform.adoptProvider(id)
            }
            return signedIn
        } publish: {
            await engine.deviceSync?.engine.writeSnapshots(forceHeavy: true)
        }
    }

    @MainActor
    public func providerSignInStates() -> [String: [String: String]] { ProviderSignInHandoff.shared.states }
}

extension EngineDeviceSyncHost {
    public func setConnectorEnabled(id: String, enabled: Bool) async throws -> DeviceSyncSnapshotRows {
        try await ConnectorStatusProjection.setMobileConnectorEnabled(id: id, enabled: enabled,
            root: engine.dataRoot, platform: platform.connectorStatus, canToggle: platform.connectorCanToggle)
    }
    public func disconnectConnector(id: String) async throws -> DeviceSyncSnapshotRows {
        try await ConnectorStatusProjection.disconnectMobileConnector(id: id,
            root: engine.dataRoot, platform: platform.connectorStatus, canToggle: platform.connectorCanToggle)
    }
}

extension AttentionDeliveryPorts {
    public static func engineDelivery(phone: @escaping AttentionRouter.PhoneSender) -> AttentionDeliveryPorts {
        AttentionDeliveryPorts(
        phone: phone,
        telegram: { token, destination, text in
            try await TelegramPollLoop.defaultSendMessage(token, destination, text)
        },
        slack: { input, dataRoot in
            let result = try await SlackConnectorActions.postMessage(input: input, dataRoot: dataRoot)
            guard case .object(let envelope) = result, envelope["ok"] == .bool(true) else {
                throw NSError(domain: "AttentionRouter", code: -502, userInfo: [
                    NSLocalizedDescriptionKey: "Slack did not accept the notification."
                ])
            }
        }
    )
    }
}

extension DeviceSync: TriggerSnapshotDeliveryPort {
    public func writeSnapshots() async { await engine.writeSnapshots() }
}

@MainActor
public struct EngineICloudIncomingTurnPort: ICloudIncomingTurnPort {
    private let engine: NativeAgentEngine
    private let client: @MainActor @Sendable () -> SwiftNativeChatOrchestrationClient
    private let receive: @MainActor @Sendable (String) -> Void
    private let presentation: @MainActor @Sendable () throws -> any MacChatTurnPresentationPort

    public init(engine: NativeAgentEngine, client: @escaping @MainActor @Sendable () -> SwiftNativeChatOrchestrationClient,
                received: @escaping @MainActor @Sendable (String) -> Void,
                presentation: @escaping @MainActor @Sendable () throws -> any MacChatTurnPresentationPort) {
        self.engine = engine
        self.client = client
        self.receive = received
        self.presentation = presentation
    }
    public func residentChatClient() -> SwiftNativeChatOrchestrationClient {
        client()
    }

    public func publishReply(text: String, sessionID: String?, correlationID: String,
                      metadata: [String: String], attachments: [NativeAgentShared.MultimodalAttachment]) async throws -> BridgeMessage {
        try await engine.deviceSync!.bridge.sendChatMessage(
            text: text, sessionID: sessionID, correlationID: correlationID,
            metadata: metadata, attachments: attachments
        )
    }

    public func publishProgress(text: String, sessionID: String, correlationID: String,
                         metadata: [String: String], key: String, mirrorKey: String?) async -> Bool {
        await engine.deviceSync!.bridge.sendKVSChatProgress(
            text: text, sessionID: sessionID, correlationID: correlationID,
            metadata: metadata, key: key, mirrorKey: mirrorKey
        )
    }

    public func sendICloudReplyPushNotification(text: String, sessionID: String?, correlationID: String, kind: String) async {
        await engine.deviceSync!.relay.sendICloudReplyPushNotification(
            text: text, sessionID: sessionID, correlationID: correlationID, kind: kind
        )
    }

    public func received(in sessionID: String) {
        receive(sessionID)
    }

    public func completed(sessionID: String?) {
        NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
    }

    public func signatureVerified(_ message: BridgeMessage) -> Bool {
        (try? PairingSecretManager.loadOrGenerateSecret())
            .map { message.verifySignature(secret: $0) } ?? false
    }

    public func controlHandoffGeneration(sessionID: String) -> Int {
        engine.turns.runtime.controlHandoffGenerations[sessionID] ?? 0
    }

    /// Waiting when a handoff landed, or sent by the phone before its handoff.
    /// Same-second stamps are not provably older, so they run.
    public func holdsMessageAfterControlHandoff(sessionID: String, receivedAtGeneration: Int, sentAt: Date) -> Bool {
        let runtime = engine.turns.runtime
        if (runtime.controlHandoffGenerations[sessionID] ?? 0) != receivedAtGeneration { return true }
        guard let handoffSentAt = runtime.phoneControlHandoffSentAt[sessionID] else { return false }
        return sentAt < handoffSentAt
    }

    public func awaitPendingChatStop(sessionID: String) async {
        while let pending = engine.turns.runtime.pendingStopWrites[sessionID] {
            await pending.value
        }
    }

    public func stopChatForControlHandoff(sessionID: String, messageDate: Date) async throws -> String {
        let appModel = try presentation()
        let turns = engine.turns
        let sync = engine.deviceSync!
        let runID = sync.engine.activeChatRunID(for: sessionID)
        var activity = turns.lifecycle(for: sessionID)?.presentation.currentAction
        if let runID,
           let data = NSUbiquitousKeyValueStore.default.data(forKey: NativeAgentICloudBridgeConstants.KVSKey.chatProgressLatest) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let progress = try? decoder.decode(BridgeMessage.self, from: data),
               progress.sessionID == sessionID, progress.correlationID == runID,
               progress.metadata?["kind"] == "tool_use", let name = progress.metadata?["toolName"] {
                activity = ToolActivityPresentation.progress(name)
            }
        }
        turns.runtime.phoneControlHandoffSentAt[sessionID] = max(
            turns.runtime.phoneControlHandoffSentAt[sessionID] ?? messageDate, messageDate
        )
        await appModel.releaseControlForHandoff(sessionId: sessionID) {
            if let runID { _ = sync.engine.cancelActiveChatTask(for: sessionID, runIDs: [runID]) }
        }
        return UserMessageIntentSignals.controlHandoffReply(lastActivity: activity)
    }

    public func registerActiveChatTask(_ task: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int), Never>,
                                for sessionID: String, runID: String) {
        engine.deviceSync!.engine.registerActiveChatTask(task, for: sessionID, runID: runID)
    }

    public func unregisterActiveChatTask(for sessionID: String,
                                  expecting task: Task<(text: String, deltaSeq: Int, error: String?, toolEvents: Int), Never>) {
        engine.deviceSync!.engine.unregisterActiveChatTask(for: sessionID, expecting: task)
    }

    public func requestChatSnapshotPublication(includeTranscripts: Bool) {
        engine.deviceSync!.engine.requestChatSnapshotPublication(includeTranscripts: includeTranscripts)
    }
}
