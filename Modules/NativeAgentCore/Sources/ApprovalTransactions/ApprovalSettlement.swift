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
import Dispatcher
import Browser
import NotificationInbox
import AuthoredCapabilities
import Experiences
import MacIntegration
import ProviderRouting
import MacControl
import Transcripts
// Blueprint: | `ApprovalSettlement.swift` | Provenance checks precede spend; receipts precede continuation. |
extension ApprovalExecution {
    /// The returned outcome and the execution slot settle together. Failed storage keeps the exact outcome with its owner for receipt-only repair.
    func settleApprovalExecution(_ id: String, dataRoot: URL,
        settlement: ApprovalExecutionOwners.Settlement) async -> Result<ApprovalRecord, Error> {
        await Self.settleRecordedApprovalExecution(id, dataRoot: dataRoot, settlement: settlement)
    }
    static func settleRecordedApprovalExecution(_ id: String, dataRoot: URL,
        settlement: ApprovalExecutionOwners.Settlement) async -> Result<ApprovalRecord, Error> {
        await ApprovalExecutionOwners.settleExecution(id, dataRoot: dataRoot, settlement: settlement)
    }
    static func performDomainApprovalExecution(_ record: ApprovalRecord, dataRoot: URL,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> ApprovalExecutionOwners.Settlement?
    ) async {
        await ApprovalExecutionOwners.perform(record, dataRoot: dataRoot, operation: operation)
    }
    public func applyResolvedChatToolApproval(
        from rec: ApprovalRecord,
        dataRoot requestedRoot: URL? = nil,
        continuation: ChatApprovalContinuation? = nil
    ) async {
        let dataRoot = requestedRoot ?? self.dataRoot
        let continuation: ChatApprovalContinuation = continuation ?? { root, session, turn, prompt in
            try await self.continueChatToolApproval(dataRoot: root, sessionID: session, turn: turn, prompt: prompt)
        }
        // Recovery may annotate an abandoned durable spend, but must never annotate a spend whose executor is still awaiting its verifier.
        let owners = ApprovalExecutionOwners.shared
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
        let payload: [String: JSONValue] = if case .object(let fields) = rec.payload { fields } else { [:] }
        let carried: (sources: [String], elevated: [String])
        do { carried = try PeerDataTaint.steer(in: payload["peer"]) }
        catch {
            RepairOwed.owe(dataRoot, id: "approval.provenance:" + rec.id, kind: .run,
                operation: "approval.provenance:" + rec.id, owner: "Approval " + rec.id,
                words: error.localizedDescription, lever: "Preserve the unspent approval and repair its recorded provenance before replay.")
            return
        }
        // Spend immediately before dispatch so a restart cannot repeat an effect; injection owns its narrower fence.
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
        let settlement: ApprovalExecutionOwners.Settlement
        do {
            let ceiling = try replay.fileAccessCeiling.get()
            let tools = effects.toolDispatchClient(
                enforceAppAutonomy: false
            )
            let host = await ApprovalLifecycleBus.shared.hostContext(rec)
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
                ),
                work: ChatTurnWork(admissionOnly: host?.effectOptions.admissionOnly ?? false)
            )
            // The verified card is this replay's ingress, including its original remote/agent identity.
            let origin = replay.envelope
            let envelope = TurnEnvelope(surface: origin.surface, agent: origin.agent,
                verifiedChatId: origin.verifiedChatId, verifiedUserId: origin.verifiedUserId,
                commandSignatureVerified: true, deliveryRoute: origin.deliveryRoute,
                declaredRemote: origin.declaredRemote, macContinuation: origin.macContinuation,
                workIdentity: origin.workIdentity, answerExperienceID: origin.answerExperienceID)
            let steer = host?.turn.peerSteering ?? PeerDataTaint(restoring: carried.sources, elevated: carried.elevated)
            carried.sources.forEach { steer.mark(peer: $0) }
            carried.elevated.forEach { steer.elevate(peer: $0) }
            // A waiting host already holds this act. Standalone replay starts at the verified card.
            let turn = (host?.turn ?? TurnRequest(message: "", sessionID: replay.sessionId, fileAccess: replay.fileAccess,
                surface: replay.surface, envelope: envelope, verifiedSessionID: .some(replay.sessionId))
                .turn())
                .with(\.envelope, envelope)
                .with(\.verifiedSessionID, replay.sessionId)
                .with(\.fileAccess, replay.fileAccess)
                .with(\.fileAccessCeiling, ceiling)
                .with(\.peerSteering, steer)
                .with(\.offeredTools, [replay.toolName])
            // Replay owns one operation; conversation callbacks refine it and
            // hand that refinement to every nested dispatch on the held turn.
            let invocation = ChatToolInvocation().with(\.authoredCall, host?.effectExecutor?.call)
            let send: @Sendable (Turn, AgentConversationContext, MacOperationContext) async throws -> JSONValue = { turn, conversation, mac in
                try await gated.dispatch(tool: replay.toolName, input: replay.input, surface: replay.surface, turn: turn,
                    invocation: invocation.serving(conversation: conversation).serving(mac: mac))
            }
            let result: JSONValue
            if replay.toolName == "agent_message" {
                // The waiting call still owns its conversation exchange.
                let hostReply = await ApprovalLifecycleBus.shared.awaitsHostReply(rec)
                result = try await AgentConversationApproval.replay(turn: turn, mac: invocation.macContext(dataRoot: dataRoot),
                    conversation: invocation.conversation, workspace: ChatWorkspaceBinding.operation(turn: turn, invocation: invocation),
                    id: rec.id, dataRoot: dataRoot,
                    awaitingHostReply: hostReply, dispatch: { tool, input, turn, conversation, mac in
                        try await gated.dispatch(tool: tool, input: input, surface: replay.surface, turn: turn,
                            invocation: invocation.serving(conversation: conversation).serving(mac: mac))
                    }, perform: send)
            } else {
                result = try await send(turn, invocation.conversation, invocation.macContext(dataRoot: dataRoot))
            }
            let receipt = Self.chatToolApprovalExecutionReceipt(
                toolName: replay.toolName, surface: replay.surface, result: result, turn: turn)
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
    /// Commit one receipt before claiming follow-up on its originating surface; refusal retains that recovery evidence.
    @discardableResult
    public func ensureChatToolApprovalOutcomeReceipt(
        approvalID: String,
        dataRoot requestedRoot: URL? = nil,
        continuation: ChatApprovalContinuation? = nil
    ) async -> Bool {
        let dataRoot = requestedRoot ?? self.dataRoot
        let continuation: ChatApprovalContinuation = continuation ?? { root, session, turn, prompt in
            try await self.continueChatToolApproval(dataRoot: root, sessionID: session, turn: turn, prompt: prompt)
        }
        // Hold ownership through delivery and settlement. A concurrent scan must not retire a live claim and make its row evictable mid-turn.
        let owners = ApprovalExecutionOwners.continuations
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
              let replay = Self.chatToolApprovalReplay(from: rec),
              let safeSessionID = NativeAgentChatSessionID.normalizedPathComponent(replay.sessionId)
        else { return true }
        let executedAction: JSONValue
        if let saved = rec.executedAction { executedAction = saved }
        else if decision != "approved" {
            executedAction = .object(["status": .string(decision == "denied" ? "refused" : "cancelled")])
        } else { return true }
        if case .object(let state)? = rec.chatContinuation, state["settlement"] == .string("host_reply") { return true }
        // Page-owned ephemeral requests retain their result on the approval itself. There is no conversation to append to or wake with an LLM.
        if replay.surface == "connector_action",
           safeSessionID.hasPrefix("ephemeral:connector_action:") { return true }
        // A durable queued delivery survives downtime. Historical conversations without one remain bounded. Existing claims settle without resending.
        let continueConversation = SwiftNativeApprovalInbox.continuationIsPending(rec)
        // Missing outcome evidence remains unconfirmed, never success.
        let recordedStatus = executedAction.objectValue?["status"]?.stringValue
        let reply = ToolResult(executedAction)
        let resultClass = rec.executedAction == nil ? reply.outcome : rec.executionResultClass
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
        let payload: [String: JSONValue] = if case .object(let fields) = rec.payload { fields } else { [:] }
        let carried: (sources: [String], elevated: [String])
        do { carried = try PeerDataTaint.steer(in: payload["peer"]) }
        catch {
            RepairOwed.owe(dataRoot, id: "approval.provenance:" + rec.id, kind: .run,
                operation: "approval.provenance:" + rec.id, owner: "Approval " + rec.id,
                words: error.localizedDescription, lever: "Preserve the approval and repair its recorded provenance before continuation.")
            return false
        }
        // Validate provenance before queued steps can be consumed or released.
        let resume = await AgentScreen.resume(card: rec.id, decision: decision, completed: resultClass == .succeeded,
                                            dataRoot: dataRoot)
        let steer = PeerDataTaint(restoring: carried.sources + resume.sources, elevated: carried.elevated + resume.elevated)
        // Approval elevates the carried peers for the rest of this command.
        if decision == "approved" { steer.checkpointSources.forEach(steer.elevate) }
        // Absent retained file access uses the host's chat policy.
        let fileAccess: String? = if case .string(let mode)? = payload["fileAccess"] { mode } else { nil }
        do {
            try await inbox.writeChatReceipt(
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
            // The receipt is durable before any claim becomes evictable. A prior process may have delivered already, so never resend it.
            if abandonedClaim {
                _ = try await inbox.annotateChatContinuation(rec.id, done: true, settlement: "interrupted")
            } else if continueConversation,
               try await inbox.annotateChatContinuation(
                rec.id, done: false) {
                var settlement = "completed"
                do {
                    let turn = TurnRequest(message: "", sessionID: safeSessionID, surface: replay.surface,
                        envelope: replay.envelope, verifiedSessionID: .some(safeSessionID)).turn()
                        .with(\.peerSteering, steer).with(\.fileAccess, fileAccess)
                        .with(\.fileAccessCeiling, try replay.fileAccessCeiling.get())
                    try await continuation(dataRoot, safeSessionID, turn, """
                            The approval for \(replay.toolName) was decided. This is its receipt, not a new user request:
                            \(summary)\(resume.text.isEmpty ? "" : "\n" + resume.text)
                            Verify the outcome as needed, then briefly tell the user what happened, including any failure or uncertainty. \
                            Do not repeat the approved action or ask to approve this card again.
                            """)
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
    public typealias ChatApprovalContinuation = @Sendable (URL, String, Turn, String) async throws -> Void
    /// Follow-up holds the card's origin, file restriction and queued steps' steering on its explicit turn.
    public func continueChatToolApproval(dataRoot: URL, sessionID: String, turn: Turn, prompt: String) async throws {
        // With no turn's own, the chat applies the saved choice itself.
        let fileAccess = turn.fileAccess ?? "auto"
        try await effects.continueChatToolApproval(
            dataRoot: dataRoot, sessionID: sessionID, turn: turn, prompt: prompt, fileAccess: fileAccess)
    }
    /// Preserve outcome and receipt evidence before clipping the privacy-safe preview; never persist the full result.
    public static func chatToolApprovalExecutionReceipt(
        toolName: String,
        surface: String,
        result: JSONValue,
        turn: Turn
    ) -> (action: JSONValue, preview: String) {
        // Approval records sync across surfaces. Tool-specific redaction must remove literal values typed by ax_act before general redaction/caps.
        let redactedResult = MacInjectionResultRedaction.redacted(tool: toolName, result: result, turn: turn)
        let returnedID = ChatTranscriptEvidenceRendering.returnedIdentifier(redactedResult)
            .map(TurnTraceRedactor.redactText)
        let resultEffects = ChatTranscriptEvidenceRendering.receiptField("effects", in: redactedResult).map {
            String(ChatTranscriptEvidenceRendering.receiptValue(TurnTraceRedactor.redactValue($0)).prefix(512))
        }
        let preview = Self.approvalResultPreview(redactedResult)
        // Derive outcome before clipping; missing status still needs evidence, and unreadable results remain unconfirmed.
        let reply = ToolResult(result)
        let resultClass = reply.outcome
        var action: [String: JSONValue] = [
            "op": .string("chat_tool_approval_replay"),
            "tool": .string(toolName),
            "surface": .string(surface),
            "status": .string(result.objectValue?["status"]?.stringValue ?? resultClass.receipt.status),
            "resultClass": .string(resultClass.rawValue),
            "resultPreview": .string(preview),
        ]
        // Retain only the result's own class; nested queued evidence stays in the body.
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
