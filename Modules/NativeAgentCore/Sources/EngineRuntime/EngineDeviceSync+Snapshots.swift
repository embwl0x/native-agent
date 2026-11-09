import AgentConversations
import AuthoredCapabilities
import Foundation
import CryptoKit
import ChatTurnRuntime
import ChatSessionWork
import ChatToolParsing
import NativeAgentCore
import SlackBot
import TelegramBot
import TriggerScheduler
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
import ToolExecution
import Transcripts
import TurnTrace
import StandingBots
import ChatTurnContracts
// Blueprint: | `EngineDeviceSync+Snapshots.swift` | `engine.connectors`, `engine.persona`, `engine.runs`, `engine.trust.snapshotData`; Checked phone adapter |

// Phone timestamp fields project `createdAt`; they are not independent historical facts, and `resolved_at` remains unset.
extension MemoryProposalRecord {
    public init(_ proposal: ProposalRecord) {
        self.init(id: proposal.id, text: proposal.content,
                  supportingSessionIds: proposal.evidence.sessionIDs,
                  recurrenceCount: proposal.evidence.recurrenceCount, status: proposal.status,
                  createdAt: proposal.createdAt, rejectionReason: proposal.rejectionReason,
                  evidenceError: proposal.evidence.error)
    }
}

public enum MobileToolCatalog {
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
    /// Never expose provider credentials in phone rows.
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
                    supportsFast: model.supports_fast,
                    controlsNote: model.controls_note
                )
            }
        )
    }
}

extension NativeAgentEngine {
    @concurrent public func mobileChatMessages(sessionId: String) async throws -> [ChatMessageRecord] {
        guard let safeID = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else { return [] }
        // A phone read prepares the same cards and attachments without mounting saved rows in the Mac's live slot.
        let projection = try await transcripts.readTranscriptProjection(safeSessionId: safeID, cached: true)
        let cards = projection.cardsByRow
        var result: [ChatMessageRecord] = []
        let messages = projection.messages
        // Snapshot and history callers select their windows after this shared projection; every row must already carry its face.
        let faces = await mobileTranscriptFaces(messages)
        var toolsByRun: [String: [ToolEvent]] = [:]
        let lastReplyByRun = Dictionary(messages.filter { $0.role == "assistant" }.compactMap { row in
            row.runId.map { ($0, row.id) }
        }, uniquingKeysWith: { _, last in last })
        for row in messages where row.role == "tool" && row.metadata?.kind == "tool_use" {
            if let run = row.runId, let rawName = row.metadata?.toolName {
                let name = ToolNameAliases.shown(rawName, inputJSON: row.metadata?.inputJSON).name
                let output = row.metadata?.resultSummary.flatMap { try? JSONValue.parse(Data($0.utf8)) }
                let outcome = output.map { value in
                    let reply = ToolResult(value)
                    return ChatToolOutcome.recordedResultClass(reply.payload) ?? reply.outcome
                }?.rawValue ?? "unknown"
                let detail = output.map { [ChatToolOutcome.explanation($0), ChatToolOutcome.remedy($0)].compactMap { $0 }.joined(separator: " · ") }
                let seq = toolsByRun[run, default: []].count + 1
                toolsByRun[run, default: []].append(ToolEvent(name: name,
                    seq: seq,
                    activity: ToolActivityPresentation.finished(name, outcome: outcome, detail: detail),
                    outcome: outcome, resultDetail: detail))
            }
        }
        for message in messages {
            let events = message.runId.flatMap { lastReplyByRun[$0] == message.id ? toolsByRun[$0] : nil } ?? []
            var row = ChatMessageRecord(id: Self.phoneMessageID(message.id), sessionId: message.sessionId, role: message.role,
                content: TurnSecretRedactor.redactText(message.content), createdAt: message.createdAt, runId: message.runId,
                source: message.source, metadata: message.metadata, isPersonVisible: !message.isAgentOwnTurnInput)
            do {
                row.metadata = try Self.phoneDisplayCopy(row.metadata)
                // Tool input is embedded JSON, not prose: redact its values without breaking its keys or syntax.
                if let input = message.metadata?.inputJSON {
                    do {
                        row.metadata?.inputJSON = try TurnTraceRedactor.redactValue(JSONValue.parse(Data(input.utf8))).serialize(pretty: false)
                    } catch {
                        // This row alone has unreadable input. Keep its outcome, provenance and siblings; name the display gap.
                        row.metadata?.inputJSON = nil
                        let prior = row.metadata?.error
                        row.metadata?.error = [prior, "Phone tool input unavailable: saved input is not readable JSON."]
                            .compactMap { $0 }.joined(separator: " · ")
                    }
                }
                row.face = try Self.phoneDisplayCopy(faces[message.id])
                if !events.isEmpty { row.toolEvents = try Self.phoneDisplayCopy(events) }
                // The phone draws a row's card as its matter's Inbox row, named by the card's id (`interaction:` and that id).
                if let projected = cards[message.id]?.first {
                    var card = projected.interaction
                    card.continuation = nil
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    // Stable bytes: an unchanged card never reads as a changed transcript, so the phone never rebuilds a chat for nothing.
                    encoder.outputFormatting = [.sortedKeys]
                    row.interactionJSON = try Self.phoneDisplayJSON(card, encoder: encoder)
                    // Phone builds 61/63 require all three fields to draw their conversation card. These are the same prepared owner's facts.
                    row.interactionDescriptorJSON = try Self.phoneDisplayJSON(projected.descriptor, encoder: encoder)
                    row.interactionSessionID = projected.sessionID
                }
            } catch {
                // One row the phone copy cannot prepare is that row's own failure, named with its cause; its siblings still cross.
                row.metadata = nil
                row.toolEvents = nil
                row.face = TranscriptRowFace(seat: TranscriptRowFace.plain(message).seat,
                    line: "This row could not be prepared for the phone.", failed: true, detail: String(describing: error))
            }
            result.append(row)
        }
        return result
    }

    /// Only display values cross this projection; row/session/run identities remain the transcript owner's values.
    private nonisolated static func phoneDisplayJSON<Value: Encodable>(_ value: Value, encoder: JSONEncoder) throws -> String {
        let object = try JSONValue.parse(encoder.encode(value))
        // This is a typed display schema: a card's `secret.signIn.token` is an endpoint, not a credential field.
        // Withholding by argument name belongs only to the tool-input object above.
        return try object.mapStrings(TurnSecretRedactor.redactText).serialize(pretty: false)
    }

    private nonisolated static func phoneDisplayCopy<Value: Codable>(_ value: Value) throws -> Value {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let text = try phoneDisplayJSON(value, encoder: encoder)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: Data(text.utf8))
    }

    @concurrent
    private func mobileTranscriptFaces(_ messages: [ChatMessage]) async -> [String: TranscriptRowFace] {
        guard !messages.isEmpty else { return [:] }
        let receiptTitle = await transcripts.readFirstConversationReceiptTitle()
        let presentation = transcripts.presentation
        var faces = Dictionary(uniqueKeysWithValues: messages.map {
            ($0.id, TranscriptRowFace.read($0, receiptTitle: receiptTitle))
        })
        for group in TranscriptGrouping.groups(messages) where group.isToolGroup {
            if group.messages.count == 1, group.messages[0].metadata?.interactionMirror != nil { continue }
            let foldRows = group.messages.filter { faces[$0.id]?.asks != true && faces[$0.id]?.receipt == nil }
            guard let first = foldRows.first else { continue }
            let key = "headline:" + first.id
            if await presentation.words(key, readyOnly: true) == nil {
                let previous = await presentation.words(key)
                let prepared = await transcripts.prepareToolFold(foldRows)
                // The owner's retained diagnostic suppresses repeated logs while later snapshots retry the failed preparation.
                if await presentation.words(key, readyOnly: true) == nil, previous != prepared {
                    nativeLog("[DeviceSync] Tool fold %@ has no prepared headline: %@", first.id, prepared)
                }
            }
            // A snapshot or history page may begin inside this group; its first visible fold row needs the same owner's headline.
            let headline = await presentation.words(key)
            for row in foldRows { faces[row.id]?.headline = headline }
        }
        for message in messages {
            faces[message.id]?.detail = await presentation.words("detail:" + message.id)
        }
        return faces
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

/// Throw on undelivered owner attention so the edge remains owed for the next pass.
extension NativeAgentEngine {
    /// Derive stable UUIDs for non-UUID transcript ids so every phone snapshot names the same message.
    nonisolated static func phoneMessageID(_ id: String) -> String {
        if UUID(uuidString: id) != nil { return id }
        var bytes = Array(SHA256.hash(data: Data(("nativeagent.message:" + id).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // name-based (v5 layout)
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }
}

/// Device sync shares live engine facades and native app owners.
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

    public func turnSessionsFace() async -> TurnSessionsFace? {
        let projection = await engine.turns.turnFaceProjection
        return await projection?.sessionsFace()
    }

    public func workOverview() async -> (
        overview: WorkOverview, deskItems: [DeskItem]?,
        approvals: Result<[ApprovalRequest], Error>, inbox: Result<[InboxItemRecord], Error>,
        jobEvidence: Result<[DeskExecutionEvidence], Error>
    ) {
        let board = await engine.desk.refreshPage().board!
        let lifecycles = await engine.turns.lifecycleBySession
        let approvals = board.approvals.map { records in
            let links = Dictionary(uniqueKeysWithValues: lifecycles.values.compactMap { state -> (String, String)? in
                guard let approval = TurnCardReadout.approval(
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
        // The jobs carrying Desk items are their movement on the phone, as on the Mac.
        let jobEvidence: Result<[DeskExecutionEvidence], Error> = board.agentJobs.unavailableReason.map {
            .failure(NSError(domain: "Jobs", code: 1, userInfo: [NSLocalizedDescriptionKey: $0]))
        } ?? .success(board.agentJobs.items.filter { $0.desk != nil }.map(DeskMovementPresentation.evidence(of:)))
        return (board.overview!, board.deskState?.items, approvals, board.inbox, jobEvidence)
    }
    public func getChatSessions() async throws -> [NativeAgentShared.ChatSession] { try await engine.transcripts.list() }
    public func getChatTranscriptGenerations() async throws -> [String: Int?] { try await engine.transcripts.transcriptGenerations() }
    @MainActor public func sessionNavigation(
        for sessions: [NativeAgentShared.ChatSession]
    ) -> ChatSessionNavigation { engine.transcripts.navigation(for: sessions) }
    @MainActor public func surfaceLayout() -> SurfaceLayoutAvailability { engine.layout.availability }
    /// Published faces, with Memories drawn from its owner's ios-disclosed packet. No phone face means no Memories entry yet.
    @MainActor public func pageFaces() async -> [String: PartFaceSnapshot] {
        var snapshots = await engine.pages.snapshots
        snapshots["memories"] = await engine.phoneMemoryPages.snapshots["memories"]
        return snapshots
    }
    public func faceRead(_ request: DocumentRequest, cursor: Int, revision: String?, device: String) async throws -> FaceReadPage {
        try await engine.documentPage(request, cursor: cursor, revision: revision, device: device)
    }
    @MainActor public func faceAction(page: String, row: String, action: String, value: String?, device: String) async throws -> String? {
        let pages = page == "memories" ? engine.phoneMemoryPages : engine.pages
        return try await pages.act(page: page, row: row, action: action, value: value, door: "phone", device: device)
    }
    @MainActor public func faceOutcome(page: String, row: String, action: String, value: String?, values: [String: PartFace.Value]?,
                                       formRevision: String?, device: String,
                                       expecting: PartFace.Call, operation: UUID, undoOf: UUID?, checking: Bool) async throws -> FaceActOutcome {
        let pages = page == "memories" ? engine.phoneMemoryPages : engine.pages
        if checking { return await pages.reconcile(page: page, row: row, value: value, values: values, expecting: expecting) }
        do {
            var outcome = try await pages.actOutcome(page: page, row: row, action: action, value: value, values: values,
                                              formRevision: formRevision,
                                              door: "phone", device: device, expecting: expecting, operation: operation, undoOf: undoOf)
            let request = PageActRequest(page: page, row: row, action: action,
                                         value: values.map(PartFace.Value.object) ?? value.map(PartFace.Value.string),
                                         expectedRevision: formRevision, expectedCall: expecting)
            outcome.failure = outcome.failure.map { EngineFaceActs.redacted($0, act: .pageAct(request)) }
            return outcome
        } catch let error as PartCallError {
            return .interrupted(WireFailure(code: error.code, message: error.message, cause: nil, effects: .none))
        }
    }
    public func decidePhoneApproval(id: String, decision: String, device: String) async throws -> ApprovalRecord {
        let provenance = ApprovalResolutionProvenance.signedIOS(clientID: device, decidedBy: "ios_signed_operator")
        return try await engine.ports.backgroundWork.approvals.resolveApproval(id: id, decision: decision, provenance: provenance,
            turn: provenance.resolvingTurn)
    }

    @MainActor public func answerPhoneInteraction(_ fields: [String: String], device: String) async throws -> [String: String] {
        if fields["action"] == "open", let item = fields["itemID"], fields.count == 2 {
            let pointer = try await InlineInteractionDelivery.pointer(id: item, dataRoot: engine.dataRoot)
            return ["status": "ok", "ok": "true", "sessionID": pointer.sessionID]
        }
        // Deployed forms may contain a key/token. No credential is accepted, copied into a call, or reflected in an error.
        let allowed: Set<String> = ["sessionID", "interactionID", "revision", "action", "choice", "scope"]
        guard Set(fields.keys).isSubset(of: allowed) else {
            throw PartCallError(code: "mac_required", message: "Enter credentials in the protected entry on the Mac. Nothing was changed.")
        }
        guard let session = fields["sessionID"], NativeAgentChatSessionID.normalizedPathComponent(session) == session,
              let id = fields["interactionID"], let revision = fields["revision"].flatMap(Int.init),
              let action = fields["action"], ["primary", "decline", "verify"].contains(action),
              let card = try await InlineInteractionResolver.interaction(id: id, sessionID: session, dataRoot: engine.dataRoot),
              card.revision == revision else {
            throw PartCallError(code: "card_changed", message: "This card changed or is unavailable. Refresh the conversation before answering.")
        }
        let matter = "interaction:" + id
        if action == "verify" {
            // Check only: the canonical verifier reads the saved owners and runs no setup effect.
            let selection = try await InlineInteractionResolver.selectionForReturn(card, dataRoot: engine.dataRoot)
            _ = await InlineInteractionResolver.completeIfVerified(id: id, sessionID: session, expectedRevision: revision,
                selection: selection, scope: card.kind == .modelChoice ? .persistent : nil, includeRetryable: true, dataRoot: engine.dataRoot)
        } else {
            let answer: String
            if action == "decline" { answer = "reject" }
            else if let choice = fields["choice"], let index = card.options.firstIndex(where: { $0.id == choice }) {
                if card.kind == .modelChoice, let scope = fields["scope"], scope != card.primaryScope?.rawValue {
                    throw PartCallError(code: "mac_required", message: "Change the saved group model in Providers on the Mac. Nothing was changed.")
                }
                answer = "interaction_choice_\(index)"
            } else {
                throw PartCallError(code: "mac_required", message: "Complete this setup in its control on the Mac, then Check again here.")
            }
            _ = try await faceAction(page: "inbox", row: matter, action: answer, value: nil, device: device)
        }
        let after: InlineInteraction
        do {
            guard let found = try await InlineInteractionResolver.interaction(id: id, sessionID: session, dataRoot: engine.dataRoot) else {
                return ["status": "outcome_unknown", "result_class": "unknown",
                    "message": "The answer returned, but its card is absent from readback. Check before repeating it."]
            }
            after = found
        } catch {
            return ["status": "outcome_unknown", "result_class": "unknown",
                "message": "The answer returned, but its card readback failed. Check before repeating it: "
                    + TurnSecretRedactor.redactText(error.localizedDescription)]
        }
        switch after.state {
        case .pending, .running, .unknown, .stopped, .superseded:
            return ["status": "pending", "result_class": "unknown", "state": after.state.name,
                "message": "The saved card is \(after.state.name); completion is not confirmed. "
                    + "Refresh the conversation and finish setup on the Mac if needed."]
        case .settled, .declined, .failed: break
        }
        let failed = after.continuationFailure ?? after.state.failureReason
        return ["status": failed == nil ? "ok" : "error", "ok": failed == nil ? "true" : "false", "state": after.state.name,
            "message": failed ?? after.state.outcome?.summary ?? (after.state == .declined ? after.declineConsequence : "The card is \(after.state.name).")]
    }
    public func getChatMessages(sessionId: String) async throws -> [ChatMessageRecord] {
        try await engine.mobileChatMessages(sessionId: sessionId)
    }
    public func getOtherRoomExchanges() async throws -> [OtherRoomExchange] {
        try await AgentContactThreads.read(root: engine.dataRoot, contacts: engine.contacts, includeHelpers: false).otherRooms.map { event in
            OtherRoomExchange(id: event.id, sessionID: event.sessionID, contactID: event.contactID,
                contact: TurnSecretRedactor.redactText(event.contact), agent: TurnSecretRedactor.redactText(event.agent), at: event.at,
                message: TurnSecretRedactor.redactText(event.message), reply: TurnSecretRedactor.redactText(event.reply))
        }
    }
    public func getHealth() async throws -> RuntimeHealth { engine.doctor.readHealth() }
    public func pendingMemoryProposals() async throws -> DeviceSyncSnapshotRows {
        (try await engine.memory.proposals(status: "pending")).map(MemoryProposalRecord.init)
    }
    public func getSkills() async throws -> DeviceSyncSnapshotRows { try await engine.tools.refreshSkills() }
    public func activeMemories() async throws -> [MemoryV2.MemoryRecord] { try await engine.memory.activeMemories() }
    public func getConnectors() async throws -> [MobileConnectorSnapshot] { try await engine.connectors.mobileConnectors() }
    public func mobileToolCatalog() async throws -> [MobileToolCatalogRecord] {
        let native = MobileToolCatalog.records(from: try await engine.tools.loadCatalog())
        let root = engine.dataRoot
        // Use the Tools page’s checked all-kind owner so executable parts remain visible alongside guidance.
        let abilities = try await Task.detached(priority: .utility) {
            try Parts(root: root).rows(kind: nil).map { row in
                let checked = try JSONRow(.object(row))
                let id = try checked.string("id")
                let kind = try checked.string("kind")
                // Parts owns both display names and row-local name damage.
                return MobileToolCatalogRecord(id: "ability:" + id, name: try checked.string("name"),
                    kind: kind, status: try checked.optionalString("status"),
                    description: try checked.optionalString("unavailableReason") ?? checked.optionalString("description"))
            }
        }.value
        return abilities + native
    }
    public func providers() async throws -> (providers: DeviceSyncSnapshotRows, routing: ProviderRoutingSnapshot) { try await engine.providers.list() }
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
    public func knowledgeGraphSnapshotData() async throws -> Data {
        try await AgentGraphReads.canonicalKnowledgeGraphSnapshotData(
            graphPath: engine.dataRoot.appendingPathComponent("memory/memory.sqlite"), surface: "ios")
    }
    public func getRunsStrict() async -> [RunRecord]? { try? await engine.runs.refresh(dataRoot: engine.dataRoot) }
    public func cancelChatSession(sessionId: String, runIDs: [String]) async throws {
        try await engine.turns.runtime.stop(sessionId: sessionId, runIDs: runIDs)
    }
    public func saveSurfaceSelection(surface: String, model: String, reasoningEffort: String?, serviceTier: String?,
        providerID: String?) async throws -> ProviderRoutingSnapshot {
        try await engine.providers.saveSurfaceSelection(
            surface: surface, model: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier, providerID: providerID)
    }
    @MainActor public func closePinnedChatSession(_ sessionID: String) async throws -> Bool {
        switch try await engine.transcripts.closePinnedTab(sessionID) {
        case .closed: return true
        case .refusedAlreadyUnpinned: return false
        case .refusedInvalidSessionID: throw CocoaError(.fileReadInvalidFileName)
        }
    }
    @MainActor
    public func remoteMacControl(payload: [String: String], turn: Turn) async throws -> [String: String] {
        let method = payload["method"] ?? ""
        guard let action = PhoneMacControlAction.resolve(payload) else {
            return ["status": "error", "message": "Unknown mac_control method: \(method)"]
        }
        if Set(["runShell", "readFile", "writeFile", "listDirectory", "moveFile", "trashFile"]).contains(method) {
            let policy = try await engine.trust.load()
            guard policy.macControlPolicy?.remoteFromIosAllowed == true,
                  policy.filePolicy?.outsideWorkspaceDefault == "allow"
                    || policy.permissionLevel == "full_mac_os" else {
                return [
                    "status": "error",
                    "message": "\(method) requires Full Mac access with iOS remote enabled on the Mac.",
                ]
            }
        }

        var body: [String: Any] = ["trigger": "ios"]
        for (key, value) in payload where key != "method" && key != "trigger" {
            body[key] = value
        }
        if action == .volume {
            guard let level = payload["value"].flatMap(Int.init), (0...100).contains(level) else {
                return ["status": "error", "message": "Volume must be between 0% and 100%."]
            }
            body.removeValue(forKey: "action")
            body.removeValue(forKey: "value")
            body["level"] = level
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let receipt = try await platform.runMacControl(path: action.path, bodyData: bodyData,
                                                     turn: turn, context: .init(dataRoot: engine.dataRoot))
        let reply = ToolResult(receipt)
        let result = reply.payload.foundationObject as? [String: Any] ?? [:]

        let nestedOutput = result["output"] as? [String: Any]
        func responseValue(_ key: String) -> Any? {
            result[key] ?? nestedOutput?[key]
        }

        var passthrough: [String: String] = [:]
        for (key, value) in result where !(value is NSNull) {
            if let string = value as? String {
                passthrough[key] = string
            } else {
                passthrough[key] = "\(value)"
            }
        }
        if let nestedOutput {
            for (key, value) in nestedOutput where passthrough[key] == nil && !(value is NSNull) {
                if let string = value as? String {
                    passthrough[key] = string
                } else {
                    passthrough[key] = "\(value)"
                }
            }
        }

        passthrough["status"] = (responseValue("status") as? String) ?? passthrough["status"] ?? "ok"
        passthrough["result_class"] = reply.outcome.rawValue

        let resultText: String
        if (responseValue("output_kind") as? String) == "binary_data" {
            resultText = (responseValue("stdout") as? String) ?? "<binary output>"
        } else if let content = responseValue("content") as? String {
            resultText = content
        } else if let stdout = responseValue("stdout") as? String, !stdout.isEmpty {
            resultText = stdout
        } else if let stderr = responseValue("stderr") as? String, !stderr.isEmpty {
            resultText = stderr
        } else if let nestedOutput {
            // Preserve output JSON keys for structured readers.
            resultText = String(decoding: try JSONSerialization.data(withJSONObject: nestedOutput, options: [.sortedKeys]), as: UTF8.self)
        } else {
            resultText = (responseValue("error") as? String) ?? ""
        }
        passthrough["result"] = resultText
        return passthrough
    }

}

public protocol EngineDeviceSyncPlatform: Sendable {
    @MainActor func settingsHost() throws -> any QuietSettingsHost
    @MainActor var oauthPlatform: any NativeOAuthPlatformPort.Type { get }
    @MainActor func adoptProvider(_ id: String) async
    @MainActor func runMacControl(path: String, bodyData: Data, turn: Turn, context: MacOperationContext) async throws -> JSONValue
}

extension EngineDeviceSyncHost {
    public func helpersSnapshot() async throws -> MobileHelpersSnapshot {
        try await engine.deviceHelpersSnapshot()
    }

    public func agentThreadAction(action: String, payload: [String: String], device: String) async throws -> [String: String] {
        try await engine.deviceAgentThreadAction(action: action, payload: payload, device: device)
    }
}

extension EngineDeviceSyncHost {
    public func telegramSnapshot() async throws -> MobileTelegramSnapshot {
        try await TelegramFacade(dataRoot: engine.dataRoot).mobileTelegramSnapshot(
            manager: BackgroundLoops.BackgroundLoopLifetimes.shared)
    }

}

extension EngineDeviceSyncHost {
    @MainActor
    public func providerSignInStates() -> [String: [String: String]] { ProviderSignInHandoff.shared.states }
}

extension EngineDeviceSyncHost {
    public func disconnectConnector(id: String) async throws -> DeviceSyncSnapshotRows {
        try await engine.connectors.disconnectMobileConnector(id: id)
    }
}

extension AttentionDeliveryPorts {
    public static func engineDelivery(phone: @escaping AttentionRouter.PhoneSender) -> AttentionDeliveryPorts {
        AttentionDeliveryPorts(
        phone: phone,
        telegram: { token, destination, text in
            await TelegramPollLoop.notificationOutcome(token, destination, text)
        },
        slack: { input, dataRoot in
            await SlackWebAPI.notificationOutcome(input: input, dataRoot: dataRoot)
        },
        telegramApproval: { id, chat, root in
            await ApprovalChatCards.deliverAttentionPrompt(id: id, chatId: chat, dataRoot: root)
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
                            progress: TurnEventSink?, turn: Turn) async throws -> ChatResponse {
        guard let id = BotDefinition.id(forSession: sessionID) else { throw BotRunnerError.cannotRun("invalid helper session id") }
        let bot = try BotDefinitionStore(dataRoot: engine.dataRoot).get(id)
        let reply = try await engine.standingBotSession(admitted: true, attachments: attachments, fileAccess: fileAccess, progress: progress)(
            bot, message, turn, .init(), .init())
        return StandingBotContinuity.response(reply, sessionID: sessionID,
            runID: turn.run)
    }

    public func received(in sessionID: String) {
        receive(sessionID)
    }

    public func completed(sessionID: String?) {
        NotificationCenter.default.post(name: .chatTurnCompleted, object: sessionID)
    }

    public func controlHandoffGeneration(sessionID: String) -> Int {
        engine.turns.runtime.controlHandoffGenerations[sessionID] ?? 0
    }

    /// Same-second handoffs are not provably older, so they remain eligible to run.
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
}
