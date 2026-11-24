import SenseCore
import Foundation
import MacNerves
import NativeAgentCore
import DeskCore
import MindCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
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
                    controlsNote: model.controls_note,
                    // The phone offers only what the account offers.
                    offered: model.offered,
                    offerNote: model.offer_note
                )
            }
        )
    }
}

extension NativeAgentEngine {
    @concurrent func mobileChatMessages(sessionId: String, limit: Int, beforeID: String? = nil,
                                        throughID: String? = nil) async throws -> ChatTranscriptSnapshot {
        guard let safeID = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else { throw CocoaError(.fileReadInvalidFileName) }
        // A phone read prepares the same cards and attachments without mounting saved rows in the Mac's live slot.
        var projection = try await transcripts.readTranscriptProjection(safeSessionId: safeID, cached: true)
        if !projection.isComplete {
            projection = try await transcripts.readTranscriptProjection(safeSessionId: safeID, cached: false)
        }
        guard projection.isComplete else { throw DeviceSyncError.underlying(message: "The complete chat history is unavailable.") }
        var page = ChatTranscriptSnapshot(sessionId: sessionId, messages: [], transcriptGeneration: nil)
        let messages = projection.messages
        var end = messages.endIndex
        if let anchor = (beforeID ?? throughID)?.lowercased() {
            guard !anchor.isEmpty, let index = messages.firstIndex(where: { Self.phoneMessageID($0.id).lowercased() == anchor }) else {
                page.readError = "That message is no longer in this chat on the Mac."
                return page
            }
            end = beforeID == nil ? index + 1 : index
        }
        let indices = Array((0..<end).reversed().lazy.filter { !messages[$0].isAgentOwnTurnInput }.prefix(limit + 1))
        page.hasOlder = indices.count > limit
        let selected = indices.prefix(limit).reversed()
        guard var first = selected.first, var last = selected.last else { return page }
        func foldNeighbor(_ index: Int) -> Bool {
            let row = messages[index]
            return (row.role == "tool" && row.metadata?.interactionMirror == nil)
                || (row.role == "system" && row.content.hasPrefix("[tool:"))
        }
        while first > 0 && foldNeighbor(first) && foldNeighbor(first - 1) { first -= 1 }
        while last + 1 < messages.count && foldNeighbor(last) && foldNeighbor(last + 1) { last += 1 }
        let rows = selected.map { messages[$0] }
        let faces = await mobileTranscriptFaces(rows, context: messages[first...last])
        var toolsByRun: [String: [ToolEvent]] = [:]
        let replyRuns = Set(rows.compactMap { $0.role == "assistant" ? $0.runId : nil })
        var lastReplyByRun: [String: String] = [:]
        for row in messages where row.role == "assistant" {
            if let run = row.runId, replyRuns.contains(run) { lastReplyByRun[run] = row.id }
        }
        let selectedIDs = Set(rows.map(\.id))
        for row in messages where row.role == "tool" && row.metadata?.kind == "tool_use" {
            if let run = row.runId, let reply = lastReplyByRun[run], selectedIDs.contains(reply), let rawName = row.metadata?.toolName {
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
        for message in rows {
            let events = message.runId.flatMap { lastReplyByRun[$0] == message.id ? toolsByRun[$0] : nil } ?? []
            var row = ChatMessageRecord(id: Self.phoneMessageID(message.id), sessionId: message.sessionId, role: message.role,
                content: TurnSecretRedactor.redactText(message.content), createdAt: message.createdAt, runId: message.runId,
                source: message.source, metadata: message.metadata)
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
                if let projected = message.inlineCards.first {
                    var card = projected.interaction
                    card.continuation = nil
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    // Stable bytes: an unchanged card never reads as a changed transcript, so the phone never rebuilds a chat for nothing.
                    encoder.outputFormatting = [.sortedKeys]
                    row.interactionJSON = try Self.phoneDisplayJSON(card, encoder: encoder)
                    // The phone's transcript schema carries the card, descriptor and source session from the same prepared owner.
                    row.interactionDescriptorJSON = try Self.phoneDisplayJSON(projected.descriptor, encoder: encoder)
                    row.interactionSessionID = projected.sessionID
                    // The card's own face, whole; the phone puts its own Inbox row's answers on it.
                    row.cardFaceJSON = try Self.phoneDisplayJSON(projected.face(answers: nil), encoder: encoder)
                }
            } catch {
                // One row the phone copy cannot prepare is that row's own failure, named with its cause; its siblings still cross.
                row.metadata = nil
                row.toolEvents = nil
                row.face = TranscriptRowFace(seat: TranscriptRowFace.plain(message).seat,
                    line: "This row could not be prepared for the phone.", failed: true, detail: String(describing: error))
            }
            page.messages.append(row)
        }
        return page
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
    private func mobileTranscriptFaces(_ messages: [ChatMessage], context: ArraySlice<ChatMessage>) async -> [String: TranscriptRowFace] {
        let receiptTitle = await transcripts.readFirstConversationReceiptTitle()
        let presentation = transcripts.presentation
        var faces = Dictionary(uniqueKeysWithValues: messages.map {
            ($0.id, TranscriptRowFace.read($0, receiptTitle: receiptTitle))
        })
        var folds: [(key: String, rows: [ChatMessage])] = []
        for group in TranscriptGrouping.groups(context) where group.isToolGroup {
            if group.messages.count == 1, group.messages[0].metadata?.interactionMirror != nil { continue }
            guard group.messages.contains(where: { row in
                guard let face = faces[row.id] else { return false }
                return face.asks != true && face.receipt == nil
            }) else { continue }
            let foldRows = group.messages.filter { row in
                let face = faces[row.id] ?? TranscriptRowFace.read(row, receiptTitle: receiptTitle)
                return face.asks != true && face.receipt == nil
            }
            guard let first = foldRows.first else { continue }
            folds.append(("headline:" + first.id, foldRows))
        }
        let keys = folds.map(\.key)
        let prior = await presentation.copies(keys)
        var preparations: [String: String] = [:]
        for fold in folds where prior[fold.key]?.copyWords(readyOnly: true) == nil {
            preparations[fold.key] = await transcripts.prepareToolFold(fold.rows)
        }
        let copies = await presentation.copies(keys + messages.map { "detail:" + $0.id })
        for fold in folds {
            let copy = copies[fold.key]
            if let prepared = preparations[fold.key], copy?.copyWords(readyOnly: true) == nil, prior[fold.key]?.copyWords() != prepared {
                nativeLog("[DeviceSync] Tool fold %@ has no prepared headline: %@", fold.rows[0].id, prepared)
            }
            let headline = copy?.copyWords()
            for row in fold.rows { faces[row.id]?.headline = headline }
        }
        for message in messages {
            faces[message.id]?.detail = copies["detail:" + message.id]?.copyWords()
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
        return TranscriptMessageID.derived(id).uuidString
    }
}

extension NativeAgentEngine {
    func turnSessionsFace() async -> TurnSessionsFace? {
        let projection = await self.turns.turnFaceProjection
        return await projection?.sessionsFace()
    }

    func workOverview() async -> (
        overview: WorkOverview, deskItems: [DeskItem]?,
        approvals: Result<[ApprovalRequest], Error>, inbox: Result<[InboxItemRecord], Error>,
        jobEvidence: Result<[DeskExecutionEvidence], Error>
    ) {
        // A standard pass may follow a source change the board has not read yet; it reads behind any read in flight.
        let board = await self.desk.refreshPage().board!
        let lifecycles = await self.turns.lifecycleBySession
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
    /// Published faces, with Memories drawn from its owner's ios-disclosed packet. No phone face means no Memories entry yet.
    @MainActor func pageFaces() async -> [String: PartFaceSnapshot] {
        var snapshots = await self.pages.snapshots
        snapshots["memories"] = await self.phoneMemoryPages.snapshots["memories"]
        return snapshots
    }
    @MainActor func faceAction(page: String, row: String, action: String, value: String?, device: String) async throws -> String? {
        let pages = page == "memories" ? self.phoneMemoryPages : self.pages
        let result = try await pages.act(page: page, row: row, action: action, value: value, door: "phone", device: device)
        // The phone's following Inbox readback must include this completed action, even before its source event is delivered.
        if page == "inbox" { _ = await settle { await self.desk.refreshPage() } }
        return result
    }
    @MainActor func faceOutcome(page: String, row: String, action: String, value: String?, values: [String: PartFace.Value]?,
                                       formRevision: String?, device: String,
                                       expecting: PartFace.Call, operation: UUID, undoOf: UUID?, checking: Bool) async throws -> FaceActOutcome {
        let pages = page == "memories" ? self.phoneMemoryPages : self.pages
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
    func decidePhoneApproval(id: String, decision: String, device: String) async throws -> ApprovalRecord {
        let provenance = ApprovalResolutionProvenance.signedIOS(clientID: device, decidedBy: "ios_signed_operator")
        let resolved = try await self.ports.backgroundWork.approvals.resolveApproval(id: id, decision: decision, provenance: provenance,
            turn: provenance.resolvingTurn(dataRoot: dataRoot))
        // Queue after any pre-decision read and await publication before returning to the phone's readback.
        _ = await settle { await self.desk.refreshPage() }
        return resolved
    }

    @MainActor func answerPhoneInteraction(_ fields: [String: String], device: String) async throws -> [String: String] {
        if fields["action"] == "open", let item = fields["itemID"], fields.count == 2 {
            let pointer = try await InlineInteractionDelivery.pointer(id: item, dataRoot: self.dataRoot)
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
              let card = try await interactions.interaction(id: id, sessionID: session),
              card.revision == revision else {
            throw PartCallError(code: "card_changed", message: "This card changed or is unavailable. Refresh the conversation before answering.")
        }
        let matter = "interaction:" + id
        if action == "verify" {
            // Check only: the canonical verifier reads the saved owners and runs no setup effect.
            let selection = try await interactions.selectionForReturn(card)
            _ = await interactions.completeIfVerified(id: id, sessionID: session, expectedRevision: revision,
                selection: selection, scope: card.kind == .modelChoice ? .persistent : nil, includeRetryable: true)
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
            guard let found = try await interactions.interaction(id: id, sessionID: session) else {
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
    func mobileOtherRoomExchanges() async throws -> [OtherRoomExchange] {
        try await AgentContactThreads.read(root: self.dataRoot, contacts: self.contacts,
            includeHelpers: false, refreshDoors: false).otherRooms.map { event in
            OtherRoomExchange(id: event.id, sessionID: event.sessionID, contactID: event.contactID,
                contact: TurnSecretRedactor.redactText(event.contact), agent: TurnSecretRedactor.redactText(event.agent), at: event.at,
                message: TurnSecretRedactor.redactText(event.message), reply: TurnSecretRedactor.redactText(event.reply))
        }
    }
    func pendingMemoryProposals() async throws -> DeviceSyncSnapshotRows {
        (try await self.memory.proposals(status: "pending")).map(MemoryProposalRecord.init)
    }
    func mobileToolCatalog() async throws -> [MobileToolCatalogRecord] {
        let native = MobileToolCatalog.records(from: try await self.tools.loadCatalog())
        let root = self.dataRoot
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
    func knowledgeGraphSnapshotData() async throws -> Data {
        try await AgentGraphReads.canonicalKnowledgeGraphSnapshotData(
            graphPath: self.dataRoot.appendingPathComponent("memory/memory.sqlite"), surface: "ios")
    }
    @MainActor func closePinnedChatSession(_ sessionID: String) async throws -> Bool {
        switch try await self.transcripts.closePinnedTab(sessionID) {
        case .closed: return true
        case .refusedAlreadyUnpinned: return false
        case .refusedInvalidSessionID: throw CocoaError(.fileReadInvalidFileName)
        }
    }
    @MainActor
    func remoteMacControl(payload: [String: String], turn: Turn) async throws -> [String: String] {
        let method = payload["method"] ?? ""
        guard let action = PhoneMacControlAction.resolve(payload) else {
            return ["status": "error", "message": "Unknown mac_control method: \(method)"]
        }
        if Set(["runShell", "readFile", "writeFile", "listDirectory", "moveFile", "trashFile"]).contains(method) {
            let policy = try await self.trust.load()
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
        let receipt = try await ports.deviceSyncPlatform.runMacControl(path: action.path, bodyData: bodyData,
                                                     turn: turn, context: .init(dataRoot: self.dataRoot))
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

        // A status the owner did not give stays absent; the phone judges the outcome by result_class.
        passthrough["status"] = (responseValue("status") as? String) ?? passthrough["status"]
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
    @MainActor func runMacControl(path: String, bodyData: Data, turn: Turn, context: MacOperationContext) async throws -> JSONValue
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
            await ApprovalChatCards.deliverAttentionPrompt(id: id, chatId: chat, interactions: NativeAgentEngine.forRoot(root).interactions)
        }
    )
    }
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
        ChatTurnCompleted.post(sessionID: sessionID)
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
        let runIDs = sync.engine.chatRunIDsForControlHandoff(for: sessionID)
        let activity = turns.lifecycle(for: sessionID)?.presentation.currentAction
        turns.runtime.phoneControlHandoffSentAt[sessionID] = max(
            turns.runtime.phoneControlHandoffSentAt[sessionID] ?? messageDate, messageDate
        )
        await appModel.releaseControlForHandoff(sessionId: sessionID) {
            if !runIDs.isEmpty { _ = sync.engine.cancelActiveChatTask(for: sessionID, runIDs: runIDs) }
        }
        return UserMessageIntentSignals.controlHandoffReply(lastActivity: activity)
    }
}
