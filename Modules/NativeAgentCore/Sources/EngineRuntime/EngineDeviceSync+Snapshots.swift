import Foundation
import ChatTurnRuntime
import ChatSessionWork
import ChatToolParsing
import NativeAgentCore
import SlackBot
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
import MemoryV2
import NativeAgentShared
import NotificationInbox
import PersistenceCore
import ProviderRouting
import ToolRegistry
import Transcripts
import StandingBots
import ChatTurnContracts
// Blueprint: | `EngineDeviceSync+Snapshots.swift` | Phone snapshot/action adapter over engine owners: retained Desk board/overview and checked inbox/approval lanes, connectors through `engine.connectors`, persona through `engine.persona` (PersonaFacade), runs through `engine.runs`, skill inventory through engine.tools; shared transcript/card/navigation, other-room exchange and live layout projections; conversation rows carry engine classification and assistant rows carry persisted tool evidence; Trust serialization delegates to `engine.trust.snapshotData`; proposal first_seen/last_seen/staged_at project createdAt and resolved_at is unset; signed incoming-turn delivery and handoff ordering; approvals carry the selected Mac turn ID for transcript anchoring; native presentation and cross-area assembly through ports |

// The phone's memory_proposals.json row. Mac views read ProposalRecord.
// Legacy wire timestamps: first_seen, last_seen and staged_at all project
// createdAt; resolved_at is unset. They are not independent historical facts.
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

private struct MobileTranscriptToolEvent: Encodable, Sendable {
    let name: String
    let seq: Int
    let activity: String
    let outcome: String?
    let resultDetail: String?
}

private struct MobileCardTranscriptMessage: DeviceSyncTranscriptMessage, Sendable {
    var message: NativeAppChatMessage
    var interactionJSON: String? = nil
    var interactionDescriptorJSON: String? = nil
    var interactionSessionID: String? = nil
    var toolEvents: [MobileTranscriptToolEvent] = []
    var id: String { message.id }
    var createdAt: String { message.createdAt }
    var content: String {
        get { message.content }
        set { message.content = newValue }
    }
    mutating func omitAttachmentPreviews() { message.omitAttachmentPreviews() }
    private enum CodingKeys: String, CodingKey { case interactionJSON, interactionDescriptorJSON, interactionSessionID, toolEvents }
    func encode(to encoder: Encoder) throws {
        try message.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encodeIfPresent(interactionJSON, forKey: .interactionJSON)
        try fields.encodeIfPresent(interactionDescriptorJSON, forKey: .interactionDescriptorJSON)
        try fields.encodeIfPresent(interactionSessionID, forKey: .interactionSessionID)
        if !toolEvents.isEmpty { try fields.encode(toolEvents, forKey: .toolEvents) }
    }
}

public enum MobileToolCatalogProjection {
    public static func records(from catalog: ChatToolCatalogSnapshot) -> [MobileToolCatalogRecord] {
        catalog.tools.map { tool in
            MobileToolCatalogRecord(
                id: tool.name,
                name: tool.name,
                kind: tool.dispatchableVia,
                status: catalog.status(for: tool).rawValue,
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
        let projection = try await transcripts.loadTranscript(sessionId: sessionId, cached: true)
        let cards = projection.cardsByRow
        var result: [any DeviceSyncTranscriptMessage & Sendable] = []
        let messages = projection.messages
        var toolsByRun: [String: [MobileTranscriptToolEvent]] = [:]
        let lastReplyByRun = Dictionary(messages.filter { $0.role == "assistant" }.compactMap { row in
            row.runId.map { ($0, row.id) }
        }, uniquingKeysWith: { _, last in last })
        for row in messages where row.role == "tool" && row.metadata?.kind == "tool_use" {
            if let run = row.runId, let rawName = row.metadata?.toolName {
                let name = ToolNameAliases.shown(rawName, inputJSON: row.metadata?.inputJSON).name
                let output = row.metadata?.resultSummary.flatMap { try? JSONValue.parse(Data($0.utf8)) }
                let outcome = output.map { ChatToolOutcome.recordedResultClass($0) ?? ChatToolOutcome.exactResultClass($0) }?.rawValue ?? "unknown"
                let detail = output.map { [ChatToolOutcome.explanation($0), ChatToolOutcome.remedy($0)].compactMap { $0 }.joined(separator: " · ") }
                let seq = toolsByRun[run, default: []].count + 1
                toolsByRun[run, default: []].append(MobileTranscriptToolEvent(name: name,
                    seq: seq,
                    activity: ToolActivityPresentation.finished(name, outcome: outcome, detail: detail),
                    outcome: outcome, resultDetail: detail))
            }
        }
        for message in messages {
            let events = message.runId.flatMap { lastReplyByRun[$0] == message.id ? toolsByRun[$0] : nil } ?? []
            if let projected = cards[message.id]?.first {
                var card = projected.interaction
                card.continuation = nil
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                result.append(MobileCardTranscriptMessage(message: message,
                    interactionJSON: String(decoding: try encoder.encode(card), as: UTF8.self),
                    interactionDescriptorJSON: String(decoding: try encoder.encode(projected.descriptor), as: UTF8.self),
                    interactionSessionID: projected.sessionID, toolEvents: events))
            } else if !events.isEmpty {
                result.append(MobileCardTranscriptMessage(message: message, toolEvents: events))
            } else { result.append(message) }
        }
        return result
    }
    @MainActor public func mobileProviderCatalogSnapshot() async throws -> (providers: [NAProviderCatalogProvider], routing: ProviderRoutingSnapshot) {
        switch await providers.refreshSettings(refreshCatalog: false, cause: { error, _ in error.localizedDescription }) {
        case .loaded(let snapshot):
            return (snapshot.providers.map(NAProviderCatalogProvider.init), snapshot.routing)
        case .failed(let detail):
            throw ProviderRoutingError.underlying(detail)
        }
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

    public func turnSummariesSnapshotData() async -> Data? {
        await engine.trace.summaryData()
    }

    public func schedulerCreateJob(input: [String: JSONValue]) async throws -> JSONValue {
        try await engine.ports.macIntegration.schedulerCreateJob(input: input)
    }

    public func getWorkshopExecutions() async throws -> DeviceSyncSnapshotRows { try await engine.desk.taskRows() }
    public func workOverview() async -> (
        overview: WorkOverview, deskItems: [DeskItem]?,
        approvals: Result<[ApprovalRequest], Error>, inbox: Result<[InboxItemRecord], Error>
    ) {
        let board = await engine.desk.refreshPage().board!
        let lifecycles = await engine.turns.lifecycleBySession
        let approvals = board.approvals.map { records in
            let links = Dictionary(uniqueKeysWithValues: lifecycles.values.compactMap { state -> (String, String)? in
                guard let approval = MacChatTurnCardProjection.approval(
                    for: state, approvals: records,
                    parseTimestamp: UserDisplayFormatters.parseISOTimestamp
                ) else { return nil }
                return (approval.approvalId, state.identity.turnId)
            })
            return records.map { record in
                var row = ApprovalRequest(record: record)
                row.chatOriginTurnId = links[record.id]
                return row
            }
        }
        return (board.overview!, board.deskState?.items,
            approvals, board.inbox)
    }
    public func getChatSessions() async throws -> [NativeAgentShared.ChatSession] { try await engine.transcripts.list() }
    @MainActor public func sessionNavigation(for sessions: [NativeAgentShared.ChatSession]) -> ChatSessionNavigation { engine.transcripts.navigation(for: sessions) }
    @MainActor public func surfaceLayout() -> SurfaceLayout { engine.layout.layout }
    public func getChatMessages(sessionId: String) async throws -> [any DeviceSyncTranscriptMessage & Sendable] {
        try await engine.mobileChatMessages(sessionId: sessionId)
    }
    public func getOtherRoomExchanges() async throws -> [OtherRoomExchange] {
        try await AgentContactThreads.read(root: engine.dataRoot, contacts: engine.contacts, includeHelpers: false).otherRooms
    }
    public func getHealth() async throws -> RuntimeHealth { engine.doctor.readHealth() }
    public func pendingMemoryProposals() async throws -> DeviceSyncSnapshotRows {
        platform.memoryProposalRows(try await engine.memory.proposals(status: "pending"))
    }
    public func getSkills() async throws -> DeviceSyncSnapshotRows { try await engine.tools.refreshSkills() }
    public func activeMemories() async throws -> [MemoryV2.MemoryRecord] { try await engine.memory.activeMemories() }
    public func getConnectors() async throws -> DeviceSyncSnapshotRows { try await engine.connectors.mobileConnectors(canToggle: platform.connectorCanToggle) }
    public func mobileToolCatalog() async throws -> [MobileToolCatalogRecord] {
        MobileToolCatalogProjection.records(from: try await engine.tools.loadCatalog())
    }
    public func providers() async throws -> DeviceSyncSnapshotRows { try await engine.providers.list() }
    public func providerCatalogSnapshot() async throws -> (providers: [NAProviderCatalogProvider], routing: ProviderRoutingSnapshot) {
        try await engine.mobileProviderCatalogSnapshot()
    }
    public func trustSnapshotData() async throws -> Data { try await engine.trust.snapshotData() }
    public func macIntegrationPermissionsSnapshot() async throws -> [String: [String: Bool]] {
        try await engine.macIntegration.macIntegrationPermissionsSnapshot()
    }
    public func getPersonality() async throws -> PersonalityProfile {
        try await engine.persona.loadProfile()
    }
    public func knowledgeGraphSnapshotData() async throws -> Data { try await KnowledgeGraphReadProjection.canonicalKnowledgeGraphSnapshotData() }
    public func getRunsStrict() async -> [RunRecord]? { try? await engine.runs.refresh(dataRoot: engine.dataRoot) }
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
    public func cancelChatSession(sessionId: String, runIDs: [String]) async throws {
        try await engine.turns.runtime.stop(sessionId: sessionId, runIDs: runIDs)
    }
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
    @MainActor public func pinnedChatSessionIDs() -> [String] { engine.transcripts.pinnedSessionIDs }
    @MainActor public func savePinnedChatSessionIDs(_ ids: [String]) throws { _ = try engine.transcripts.savePinnedSessionIDs(ids) }
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
        await MainActor.run { engine.trust.publishPolicy(saved) }
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
        try await engine.connectors.setMobileConnectorEnabled(id: id, enabled: enabled, canToggle: platform.connectorCanToggle)
    }
    public func disconnectConnector(id: String) async throws -> DeviceSyncSnapshotRows {
        try await engine.connectors.disconnectMobileConnector(id: id, canToggle: platform.connectorCanToggle)
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
            let result = try await SlackWebAPI.postMessage(input: input, dataRoot: dataRoot)
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

    public func helperReply(message: String, sessionID: String, attachments: [NativeAgentShared.MultimodalAttachment], fileAccess: String,
                            progress: ChatOrchestrationProgressHandler?) async throws -> ChatResponse {
        guard let id = UUID(uuidString: String(sessionID.dropFirst(4))) else { throw BotRunnerError.cannotRun("invalid helper session id") }
        let bot = try BotDefinitionStore(dataRoot: engine.dataRoot).get(id)
        let reply = try await engine.standingBotSession(admitted: true, attachments: attachments, fileAccess: fileAccess, progress: progress)(bot, message)
        return StandingBotContinuity.response(reply, sessionID: sessionID,
            runID: ChatPersistenceContext.pinnedTurnRunID ?? UUID().uuidString)
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
