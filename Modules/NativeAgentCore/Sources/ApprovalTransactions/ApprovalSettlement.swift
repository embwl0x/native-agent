import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Studio
import TurnTrace
import MemoryV2
import AgentWorkspace
import ApprovalInbox
import Desk
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import ChatSessionWork
import AgentConversations
import ChatToolParsing
import TrustCenter
import ToolRegistry
import DreamREMCycle
import WorkshopExecution
import Dispatcher
import Browser
import NotificationInbox
import AuthoredCapabilities
import Experiences
import MacIntegration
import ProviderRouting
import MacControl
import Transcripts
// Blueprint: | `ApprovalSettlement.swift` | Chat tool execution and receipt settlement |
extension ApprovalExecution {
    /// The returned outcome and the execution slot settle together. Failed
    /// storage keeps the exact outcome with its owner for receipt-only repair.
    func settleApprovalExecution(_ id: String, dataRoot: URL,
        settlement: ChatToolApprovalExecutionOwners.Settlement) async -> Result<ApprovalRecord, Error> {
        await settle {
            let owners = ChatToolApprovalExecutionOwners.shared
            owners.retain(settlement, root: dataRoot, approvalID: id)
            defer { owners.release(root: dataRoot, approvalID: id) }
            do {
                let record = try await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                    id, executedAction: settlement.action, detail: settlement.detail, result: settlement.result)
                owners.retain(nil, root: dataRoot, approvalID: id)
                return Result<ApprovalRecord, Error>.success(record)
            } catch {
                nativeLog("[approvals] execution receipt save failed for \(id): \(error); returned outcome retained by the execution owner for receipt-only repair")
                return .failure(error)
            }
        }
    }
    public func applyResolvedChatToolApproval(
        from rec: ApprovalRecord,
        dataRoot requestedRoot: URL? = nil,
        continuation: ChatApprovalContinuation? = nil
    ) async {
        let dataRoot = requestedRoot ?? self.dataRoot
        let continuation: ChatApprovalContinuation = continuation ?? { root, session, envelope, prompt in
            try await self.continueChatToolApproval(dataRoot: root, sessionID: session, envelope: envelope, prompt: prompt)
        }
        // Recovery may annotate an abandoned durable spend, but must never
        // annotate a spend whose executor is still awaiting its verifier.
        let owners = ChatToolApprovalExecutionOwners.shared
        guard owners.acquire(root: dataRoot, approvalID: rec.id) else { return }
        var receiptOwnsRelease = false
        defer { if !receiptOwnsRelease { owners.release(root: dataRoot, approvalID: rec.id) } }
        if let retained = owners.settlement(root: dataRoot, approvalID: rec.id) {
            receiptOwnsRelease = true
            if case .success = await settleApprovalExecution(rec.id, dataRoot: dataRoot, settlement: retained), !Task.isCancelled {
                await ensureChatToolApprovalOutcomeReceipt(approvalID: rec.id, dataRoot: dataRoot, continuation: continuation)
            }
            return
        }
        guard rec.status == "resolved",
              let decision = rec.decision,
              let replay = Self.chatToolApprovalReplay(from: rec) else { return }
        guard decision == "approved" else {
            let op = decision == "denied"
                ? "chat_tool_approval_denied"
                : "chat_tool_approval_canceled"
            let outcome: ToolNotRunStatus = decision == "denied" ? .personDenied : .approvalCanceled
            if replay.toolName == "agent_message" {
                do {
                    _ = try AgentConversationStore(dataRoot: dataRoot).records()
                } catch {
                    nativeLog("[approvals] conversation decision write failed for \(rec.id): \(error)")
                    return
                }
            }
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                rec.id,
                executedAction: outcome.reporting(.object([
                    "op": .string(op),
                    "tool": .string(replay.toolName),
                    "surface": .string(replay.surface),
                ])),
                detail: outcome.sentence())
            await ensureChatToolApprovalOutcomeReceipt(approvalID: rec.id, dataRoot: dataRoot, continuation: continuation)
            return
        }
        // Injection approvals have their own capability-specific durable spend
        // inside InjectionApprovalVerifier. Every other generic approved tool
        // spends here, immediately before dispatch. A crash can therefore
        // leave an unknown outcome, but it cannot turn one approval into a
        // second effect after restart.
        if !MacInjectionToolNames.isInjectionTool(replay.toolName) {
            let inbox = SwiftNativeApprovalInbox(root: dataRoot)
            let digest = ApprovalInboxApprovedReplayVerifier.effectDigest(rec.payload)
            switch await inbox.consumeApprovedEffect(
                id: rec.id,
                digest: digest,
                action: replay.toolName,
                surface: replay.surface
            ) {
            case .spent:
                break
            case .alreadySpent:
                if (try? await inbox.get(rec.id).executedAction) == nil {
                    try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                        rec.id,
                        executedAction: .object([
                            "op": .string("chat_tool_approval_replay"),
                            "tool": .string(replay.toolName),
                            "surface": .string(replay.surface),
                            "status": .string("outcome_unknown"),
                            "error": .string("execution already started; automatic replay refused"),
                        ]),
                        detail: "\(replay.toolName) may have started before interruption; it was not replayed automatically."
                    )
                }
                await ensureChatToolApprovalOutcomeReceipt(approvalID: rec.id, dataRoot: dataRoot, continuation: continuation)
                return
            case .unavailable:
                if (try? await inbox.get(rec.id).executedAction) == nil {
                    try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                        rec.id,
                        executedAction: .object([
                            "op": .string("chat_tool_approval_replay"),
                            "tool": .string(replay.toolName),
                            "surface": .string(replay.surface),
                            "status": .string("blocked"),
                            "error": .string("durable execution fence unavailable"),
                        ]),
                        detail: "\(replay.toolName) was blocked before execution because its durable replay fence was unavailable."
                    )
                }
                await ensureChatToolApprovalOutcomeReceipt(approvalID: rec.id, dataRoot: dataRoot, continuation: continuation)
                return
            }
        }
        let settlement: ChatToolApprovalExecutionOwners.Settlement
        do {
            let tools = effects.toolDispatchClient(
                enforceAppAutonomy: false
            )
            let gated = makeGatedToolDispatchClient(
                tools: tools,
                fileAccess: replay.fileAccess,
                approvalFiler: nil,
                dataRoot: dataRoot,
                verifiedSessionId: replay.sessionId,
                approvedReplay: ApprovedChatToolReplay(
                    approvalID: rec.id,
                    tool: replay.toolName,
                    surface: replay.surface,
                    input: replay.input,
                    verifiedSessionID: replay.sessionId,
                    verifiedChatID: replay.telegramChatId,
                    verifiedUserID: replay.verifiedUserId
                )
            )
            // Verified approval carries the card's steer through all calls in this command.
            let payload: [String: JSONValue] = if case .object(let fields) = rec.payload { fields } else { [:] }
            let carried = PeerDataTaint.steer(in: payload["peer"])
            // Approval replay is a fresh detached dispatch, not the original
            // provider turn. Rehydrate only the approved lazy tool for this
            // dispatch so the lazy gate cannot answer `not_loaded`, while no
            // sibling tool receives an accidental capability grant.
            let result = try await PeerDataTaint.$current.withValue(PeerDataTaint(restoring: carried.sources, elevated: carried.elevated)) {
            try await LLMCallContext.$turnActiveTools.withValue([replay.toolName]) {
                try await ChatToolSessionContext.$commandSignatureVerified.withValue(true) {
                    try await TurnRequest(message: "", sessionID: replay.sessionId, surface: replay.surface,
                        verifiedSessionID: .some(replay.sessionId),
                        verifiedChatID: .some(replay.telegramChatId), verifiedUserID: .some(replay.verifiedUserId),
                        replyRoute: replay.replyRoute, threadKind: ChatPersistenceContext.threadKind,
                        ownedSessionID: ChatPersistenceContext.ownedSessionID).bind {
                        let send: @Sendable () async throws -> JSONValue = {
                            if let context = await ApprovalLifecycleBus.shared.hostContext(rec) {
                                return try await context {
                                    try await gated.dispatch(tool: replay.toolName, input: replay.input, surface: replay.surface)
                                }
                            }
                            return try await gated.dispatch(tool: replay.toolName, input: replay.input, surface: replay.surface)
                        }
                        if replay.toolName == "agent_message" {
                            // The waiting call still owns its conversation exchange.
                            let hostReply = await ApprovalLifecycleBus.shared.awaitsHostReply(rec)
                            let exactProtocol = if case .object(let payload) = rec.payload {
                                payload["agentExactProtocol"] == .bool(true)
                            } else { false }
                            return try await AgentConversationApproval.replay(id: rec.id, dataRoot: dataRoot,
                                exactProtocol: exactProtocol || hostReply, dispatch: { tool, input in
                                    try await gated.dispatch(tool: tool, input: input, surface: replay.surface)
                                }, perform: send)
                        }
                        return try await send()
                    }
                }
            }
            }
            let receipt = Self.chatToolApprovalExecutionReceipt(
                toolName: replay.toolName, surface: replay.surface, result: result)
            settlement = .init(action: receipt.action,
                detail: "", result: result)
        } catch {
            nativeLog("[approvals] approved chat tool replay failed for \(rec.id): \(error)")
            settlement = .init(action: .object([
                    "op": .string("chat_tool_approval_replay"),
                    "tool": .string(replay.toolName),
                    "surface": .string(replay.surface),
                    "status": .string("failed"),
                    "error": .string("\(error)"),
                ]),
                detail: "\(replay.toolName) approved replay FAILED: \(error.localizedDescription)")
        }
        receiptOwnsRelease = true
        if case .success = await settleApprovalExecution(rec.id, dataRoot: dataRoot, settlement: settlement), !Task.isCancelled {
            await ensureChatToolApprovalOutcomeReceipt(approvalID: rec.id, dataRoot: dataRoot, continuation: continuation)
        }
    }
    /// Persist exactly one compact tool receipt into the conversation that
    /// originated a generic approval, then claim one follow-up turn on
    /// that same surface. Owns the record read under continuation ownership;
    /// a refused turn leaves the receipt as recovery evidence.
    @discardableResult
    public func ensureChatToolApprovalOutcomeReceipt(
        approvalID: String,
        dataRoot requestedRoot: URL? = nil,
        continuation: ChatApprovalContinuation? = nil
    ) async -> Bool {
        let dataRoot = requestedRoot ?? self.dataRoot
        let continuation: ChatApprovalContinuation = continuation ?? { root, session, envelope, prompt in
            try await self.continueChatToolApproval(dataRoot: root, sessionID: session, envelope: envelope, prompt: prompt)
        }
        // Hold ownership through delivery and settlement. A concurrent scan
        // must not retire a live claim and make its row evictable mid-turn.
        let owners = ChatToolApprovalExecutionOwners.continuations
        guard owners.acquire(root: dataRoot, approvalID: approvalID) else { return true }
        defer { owners.release(root: dataRoot, approvalID: approvalID) }
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        let rec: ApprovalRecord
        do {
            rec = try await inbox.get(approvalID)
        } catch {
            nativeLog("[approvals] continuation record read failed: \(error)")
            return false
        }
        guard rec.status == "resolved",
              let decision = rec.decision,
              let replay = Self.chatToolApprovalReplay(from: rec, reportingOnly: true),
              let safeSessionID = NativeAgentChatSessionID.normalizedPathComponent(replay.sessionId)
        else { return true }
        // Telegram's send driver still owns already-produced legacy words.
        // Never generate another answer while that retained one is owed.
        if case .object(let state)? = rec.chatContinuation,
           state["done"] != .bool(true), state["assistantDelivery"] != nil { return true }
        let executedAction: JSONValue
        if let saved = rec.executedAction { executedAction = saved }
        else if decision != "approved" {
            executedAction = .object(["status": .string(decision == "denied" ? "refused" : "cancelled")])
        } else { return true }
        if case .object(let state)? = rec.chatContinuation, state["settlement"] == .string("host_reply") { return true }
        // Page-owned ephemeral requests retain their result on the approval
        // itself. There is no conversation to append to or wake with an LLM.
        if replay.surface == "connector_action",
           safeSessionID.hasPrefix("ephemeral:connector_action:") { return true }
        // A durable queued delivery survives downtime. Historical conversations
        // without one remain bounded. Existing claims settle without resending.
        let continueConversation = SwiftNativeApprovalInbox.continuationIsPending(rec)
        // Missing evidence is NOT a success. An annotation with no status and no
        // retained class tells us only that the replay ran; the outcome is
        // unconfirmed and every sentence below says so.
        let recordedStatus = executedAction.objectValue?["status"]?.stringValue
        let resultClass = rec.executedAction == nil ? ChatToolOutcome.exactResultClass(executedAction) : rec.executionResultClass
        let ok = resultClass.receipt.ok
        let resultPreview = (executedAction.objectValue?["resultPreview"]?.stringValue
            ?? executedAction.objectValue?["error"]?.stringValue).map(TurnTraceRedactor.redactText)
        let outcomeDescription = resultClass.receipt.label
        let prose = rec.decisionExperience.face?.words ?? ""
        // Serialize the preserved result class and redacted evidence for transcript readers.
        var envelope: [String: JSONValue] = ["detail": .string(prose)]
        if let approvedBy = rec.approvedBy { envelope["approved_by"] = .string(approvedBy) }
        if case .object(let execution) = executedAction,
           let notRun = execution["not_run_status"] {
            envelope["not_run_status"] = notRun
        }
        let failureDetail = JSONValue.string(resultPreview ?? outcomeDescription)
        envelope.merge(resultClass.receiptFields(recordedStatus: recordedStatus, failureDetail: failureDetail)) { _, value in value }
        let summary = (try? JSONValue.object(envelope).serialize(pretty: false)) ?? prose
        // Read the card's queued steps and carried steer fresh; decline drops the steps.
        let resume = await HerScreen.resume(card: rec.id, decision: decision, completed: resultClass == .succeeded,
                                            dataRoot: dataRoot)
        let payload: [String: JSONValue] = if case .object(let fields) = rec.payload { fields } else { [:] }
        // No record at all: a card filed before cards kept one (`unrecorded`).
        let carried = PeerDataTaint.steer(in: payload["peer"])
        let steer = PeerDataTaint(restoring: carried.sources + resume.sources, elevated: carried.elevated + resume.elevated)
        // Approval elevates the carried peers for the rest of this command.
        if decision == "approved" { steer.checkpointSources.forEach(steer.elevate) }
        // The filing turn's file access; nil for an older card (the host's chat default).
        let fileAccess: String? = if case .string(let mode)? = payload["fileAccess"] { mode } else { nil }
        do {
            let legacyStartedAt = try await inbox.writeChatReceipt(
                approvalID: rec.id, sessionID: safeSessionID, toolName: replay.toolName,
                surface: replay.surface, summary: summary, resultClass: resultClass.rawValue,
                resultStatus: executedAction.objectValue?["resultStatus"]?.stringValue, ok: ok, resultPreview: resultPreview,
                returnedID: executedAction.objectValue?["returned_id"]?.stringValue,
                effects: executedAction.objectValue?["effects"]?.stringValue,
                recoveredAt: continueConversation ? nil : (rec.resolvedAt ?? rec.createdAt))
            let abandonedClaim: Bool = {
                guard case .object(let state)? = rec.chatContinuation else { return false }
                return state["started"] != nil && state["done"] != .bool(true)
            }()
            // The receipt is durable before any claim becomes evictable. A
            // prior process may have delivered already, so never resend it.
            if abandonedClaim || legacyStartedAt != nil {
                if legacyStartedAt != nil {
                    _ = try await inbox.annotateChatContinuation(
                        rec.id, done: false, legacyStartedAt: legacyStartedAt)
                }
                _ = try await inbox.annotateChatContinuation(rec.id, done: true, settlement: "interrupted")
            } else if continueConversation,
               try await inbox.annotateChatContinuation(
                rec.id, done: false, clearQueuedDelivery: true) {
                var settlement = "completed"
                do {
                    try await PeerDataTaint.$current.withValue(steer) {
                        try await ChatToolSessionContext.$fileAccess.withValue(fileAccess) {
                        try await continuation(dataRoot, safeSessionID, replay.envelope, """
                            The approval for \(replay.toolName) was decided. This is its receipt, not a new user request:
                            \(summary)\(resume.text.isEmpty ? "" : "\n" + resume.text)
                            Verify the outcome as needed, then briefly tell the user what happened, including any failure or uncertainty. Do not repeat the approved action or ask to approve this card again.
                            """)
                        }
                    }
                } catch {
                    settlement = "failed"
                    nativeLog("[approvals] continuation failed for \(rec.id); receipt retained: \(error)")
                }
                _ = try await inbox.annotateChatContinuation(rec.id, done: true, settlement: settlement)
            }
        } catch {
            nativeLog("[approvals] outcome receipt or continuation failed for \(rec.id): \(error)")
            return false
        }
        // Notify the mounted chat to reload the persisted receipt.
        await effects.chatTurnCompleted(sessionID: replay.sessionId)
        return true
    }
    public typealias ChatApprovalContinuation = @Sendable (URL, String, TurnEnvelope, String) async throws -> Void
    /// Follow-up uses normal tools under the card's and queued steps' steer,
    /// bound by the caller as `PeerDataTaint.current` and retained by the host turn.
    public func continueChatToolApproval(dataRoot: URL, sessionID: String, envelope: TurnEnvelope, prompt: String) async throws {
        // With no turn's own, the chat applies the saved choice itself.
        let fileAccess = ChatToolSessionContext.fileAccess ?? "auto"
        try await effects.continueChatToolApproval(
            dataRoot: dataRoot, sessionID: sessionID, envelope: envelope, prompt: prompt, fileAccess: fileAccess)
    }
    /// The actual replay writer's projection, shared with injected fixtures.
    /// Preserve outcome and receipt fields from the complete result before the
    /// privacy-safe preview is clipped; never persist the full result.
    public static func chatToolApprovalExecutionReceipt(
        toolName: String,
        surface: String,
        result: JSONValue
    ) -> (action: JSONValue, preview: String) {
        // Approval records sync across surfaces. Tool-specific redaction must
        // remove literal values typed by ax_act before general redaction/caps.
        let redactedResult = MacInjectionResultRedaction.redacted(tool: toolName, result: result)
        let returnedID = ChatTranscriptEvidenceRendering.returnedIdentifier(redactedResult)
            .map(TurnTraceRedactor.redactText)
        let resultEffects = ChatTranscriptEvidenceRendering.receiptField("effects", in: redactedResult).map {
            String(ChatTranscriptEvidenceRendering.receiptValue(TurnTraceRedactor.redactValue($0)).prefix(512))
        }
        let preview = Self.approvalResultPreview(redactedResult)
        // The outcome is derived from the COMPLETE original result and retained
        // here, before the preview clips it. A result without a `status` field
        // still carries evidence (ok/success/error); it is never assumed to have
        // succeeded, and an unreadable one is recorded as unconfirmed.
        let resultClass = ChatToolOutcome.exactResultClass(result)
        var action: [String: JSONValue] = [
            "op": .string("chat_tool_approval_replay"),
            "tool": .string(toolName),
            "surface": .string(surface),
            "status": .string(result.objectValue?["status"]?.stringValue ?? resultClass.receipt.status),
            "resultClass": .string(resultClass.rawValue),
            "resultPreview": .string(preview),
        ]
        // The word the result itself recorded, never one made up here: the
        // replayed row keeps it as any tool row does, and omits it when the
        // result had none (a nested "queued" stays visible in the body).
        if let recorded = result.objectValue?["status"]?.stringValue { action["resultStatus"] = .string(recorded) }
        if let returnedID { action["returned_id"] = .string(returnedID) }
        if let resultEffects { action["effects"] = .string(resultEffects) }
        if toolName == "agent_connect" || toolName == "agent_message" {
            action["contactResult"] = Self.agentContactReceipt(TurnTraceRedactor.redactValue(result))
        }
        return (.object(action), preview)
    }
    public static func agentContactReceipt(_ result: JSONValue) -> JSONValue {
        guard case .object(let value) = result else { return .null }
        var display: [String: JSONValue] = [:]
        for key in ["status", "reply", "detail", "reason", "error", "connection_check", "connection_reply_received",
                    "sent", "completed", "terminal", "needs_input", "needs_authentication", "task_id",
                    "message_id", "conversation_id", "run_id", "local_request_id", "read_with"] {
            if case .string(let text)? = value[key] {
                display[key] = .string(String(text.prefix(4096)) + (text.count > 4096 ? "\nAnswer shortened." : ""))
            } else if let item = value[key] { display[key] = item }
        }
        if let probe = value["probe"] { display["probe"] = agentContactReceipt(probe) }
        if let remote = value["remote_evidence"] { display["remote_evidence"] = agentContactReceipt(remote) }
        return .object(display)
    }
    private static func approvalResultPreview(_ value: JSONValue, limit: Int = 1400) -> String {
        let redacted = TurnTraceRedactor.redactValue(value)
        let raw = (try? redacted.serialize(pretty: false)) ?? String(describing: redacted)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "..."
    }
}
