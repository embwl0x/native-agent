import SenseCore
import MacNerves
import MindCore
import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
import ProviderRouting
// Blueprint: | `DoorApproval.swift` | Call settlement, approval filing and replay resolution |

extension DoorPipeline {
    func dispatchHeld(tool: String, input: [String: JSONValue], surface: String, turn: Turn,
                              invocation: ChatToolInvocation) async throws -> JSONValue {
        var work = self.policy.work.with(\.toolInvocation, invocation)
        work.handsBack = work.handsBack || invocation.handsBack
        if turn.doorPreview != nil {
            return try await dispatchNormalized(tool: tool, input: input, surface: surface, turn: turn, work: work)
        }
        if let wait = invocation[HostInteractionWait.self] {
            work.waitForInteraction = { need, tool, input in await wait(need, tool, input, turn) }
        }
        // A card never holds a running call: a call from a script or a part returns pending at once with its card, as a top-level call
        // does, and the program sees pending and goes on or ends; the person's Approve replays the call from the card. Only an ability's
        // own authored body waits on its card, since that body runs nowhere but inside its live run.
        guard turn.partID != nil, work.authoredCall != nil, !work.handsBack else {
            let result = try await dispatchNormalized(tool: tool, input: input, surface: surface, turn: turn, work: work)
            guard input["preview"] != .bool(true), let need = InlineInteractionNeed.interaction(in: result),
                  let session = policy.verifiedSessionId else { return result }
            let arguments = try JSONValue.object(input).serialize(pretty: false)
            let blocked = ToolNameAliases.ranTool(tool, input: input) != InlineInteractionWire.toolName
            let filed = try await SwiftNativeChatOrchestrationClient.fileInlineInteraction(
                need, sessionID: session, toolName: blocked ? tool : nil,
                toolArgumentsJSON: blocked && SwiftNativeChatOrchestrationClient.redactedPersistedToolInput(tool: tool, json: arguments,
                    turn: turn) == arguments
                    ? arguments : nil,
                requestingTool: tool, origin: TurnEnvelope.current(turn: turn, surface: surface), dataRoot: securityCenter.dataRoot,turn: turn)
            let retained = filed.card
            if blocked, PermissionLaw.personDecided(tool: tool, input: input, turn: turn) {
                PersonParkedCalls.park(retained.id, dataRoot: securityCenter.dataRoot, tool: tool, input: input)
            }
            if filed.changed { InlineInteractionDelivery.notify(sessionID: session, dataRoot: securityCenter.dataRoot) }
            guard case .object(var fields) = result,
                  let encoded = InlineInteractionNeed.encode(retained) else {
                throw ToolFailureError("The retained card could not be returned.", effects: .none, code: "card_encoding_failed")
            }
            fields[InlineInteractionWire.needsKey] = encoded
            fields["card_id"] = .string(retained.id)
            return .object(fields)
        }
        let id = UUID()
        let events = await ApprovalLifecycleBus.shared.events(forHostCall: id,
            context: .init(turn: turn,
                effectOptions: .init(admissionOnly: work.admissionOnly),
                effectExecutor: work.authoredCall.map { .init(tool: $0.tool, perform: $0.perform) }))
        let settlement = SettlementTicket("held host call")
        let outcome: Result<JSONValue, Error>
        do {
            var result = try await dispatchNormalized(tool: tool, input: input, surface: surface, turn: turn.with(\.hostCallID, id), work: work)
            let reply = ToolResult(result)
            if let approval = (ChatTranscriptEvidenceRendering.receiptField("approvalId", in: result))?.scalarText.flatMap({ $0.trimmingCharacters(in:
                .whitespacesAndNewlines).isEmpty ? nil : $0 })
                ?? (ChatTranscriptEvidenceRendering.receiptField("approval_id", in: result))?.scalarText.flatMap({ $0.trimmingCharacters(in:
                    .whitespacesAndNewlines).isEmpty ? nil : $0 }),
               ChatToolOutcome.isWaitingOnPerson(reply.payload, verdict: reply.outcome) {
                var event = try await work.deadlines.withHumanWait {
                    for await event in events where event.record.id == approval { return event }
                    throw CancellationError()
                }
                if event.phase != .executed, event.record.decision == "approved" {
                    for await settled in events where settled.phase == .executed && settled.record.id == approval {
                        event = settled
                        break
                    }
                }
                try Task.checkCancellation()
                result = event.record.decision == "approved" ? event.result
                    ?? .object(["status": .string("unknown"), "reason": .string("card_outcome_unavailable"),
                        "effects": .string("unknown"), "approval_id": .string(approval),
                        "detail": .string("Approved card \(approval) returned no outcome; approval alone does not prove the action completed."),
                        "remedy": Repair.reconcile(
                            instruction: "Read this exact card's retained execution record, then inspect the affected state before repeating the action.",
                            nextCall: .object(["tool": .string("app"), "input": .object([
                                "action": .string("files.read"), "args": .object(["path": .string(securityCenter.dataRoot
                                    .appendingPathComponent("workflows/approvals/requests.json").path)])])]))])
                    : .object(["status": .string("failed"), "reason": .string("declined"),
                        "detail": .string("""
                            workflows/approvals/requests.json card \(approval): status=\(event.record.status), \
                            decision=\(event.record.decision ?? "unanswered"). Nothing ran; the part is no longer waiting.
                            """), "effects": .string("none")])
            }
            // The call ends only after any interaction it waits on; its cards are released after that, never before.
            if let need = InlineInteractionNeed.interaction(in: result) {
                guard let wait = work.waitForInteraction else {
                    throw ToolFailureError("Card \(need.id) cannot resume because the originating conversation is not bound to this call.",
                        effects: .unknown, owner: "originating conversation",
                        nextCall: (try? SwiftNativeTurnEngine.dispatchReceiptCall(turn: turn).serialize(pretty: false)),
                        code: "card_conversation_unavailable",
                        instruction: """
                            Read this turn's receipts to locate the conversation for this card, then resolve the existing card there. Check its \
                            outcome before requesting the action again.
                            """, recovery: .reconcile)
                }
                result = await wait(need, tool, input)
            }
            outcome = .success(result)
        } catch {
            outcome = .failure(error)
        }
        await settlement.settle { [dataRoot = securityCenter.dataRoot] in
            let inbox = SwiftNativeApprovalInbox(root: dataRoot)
            for cardID in await ApprovalLifecycleBus.shared.finish(id) {
                do { try await inbox.resolve(cardID, decision: .canceled, decidedBy: "host call ended") }
                // A concurrent answer owns the decision; ending its call cannot replace it.
                catch ApprovalInboxError.alreadyResolved { continue }
                catch {
                    await RepairOwed.owe(dataRoot, id: "approval.host_end:" + cardID, kind: .decision,
                        operation: "approval.host_end:" + cardID, owner: inbox.approvalsPath.path,
                        words: "Host call \(id) ended; card \(cardID) could not be cancelled: \(error.localizedDescription)",
                        lever: "Repair the approval store, then cancel this exact card only if it is still pending; preserve any answer.").value
                }
            }
        }
        return try outcome.get()
    }

    /// Asks for the call: refusals no card can carry, then the card's words, the staging shortcut, the person's own ask, and the
    /// card itself. Returns nil when the person's own ask decided the call and it is judged again.
    func requestApproval(_ judged: inout JudgedCall, gateReason: String) async throws -> JSONValue? {
        let tool = judged.tool, input = judged.input, surface = judged.surface, turn = judged.turn, work = judged.work,
            envelope = judged.envelope, namedConnect = judged.namedConnect, securityAsked = judged.securityAsked,
            peerWorded = judged.peerWorded
        // The arguments were checked above, before any decision was acted on.
        let root = dataRoot
        if let refusal = try await MacAppActGate.requestRefusal(tool: tool, input: input, dataRoot: root,
            turn: turn, context: work.invocation.macContext(dataRoot: root)) {
            return ChatToolOutcome.refusedBeforeRunning(owner: .object(refusal.fields))
        }
        // A switch the user turned off refuses before any card, regardless of posture.
        if let gate = try SwiftToolDispatcher.integrationGate(tool: tool, input: input, turn: turn) {
            let root = dataRoot
            let store = root == defaultDataRoot() ? MacIntegrationPermissionStore.shared : MacIntegrationPermissionStore(dataRoot: root)
            if let refusal = try await SwiftToolDispatcher.switchRefusal(integration: gate.integration, mode: gate.mode, store: store) {
                return ChatToolOutcome.refusedBeforeRunning(owner: refusal)
            }
        }
        // A skill's step never files a card: it hands back to the agent.
        if work.handsBack, !work.admissionOnly { return SkillRunContext.handBack(ApprovalActionText.reason(gateReason,
            tool: tool, input: input)) }
        // Preserve the deciding rule alongside the implementation's disclosure; another agent's ask says who and why in the person's words, so
        // the policy line (kept in the security receipt) stays off its card.
        var reason = ApprovalActionText.reason(gateReason, tool: tool, input: input)
        if !peerWorded, let cause = envelope.autonomyReason, !reason.contains(cause) { reason += " " + cause }
        if tool.hasPrefix("fetch."), case .string(let raw)? = input["url"], let url = URL(string: raw) {
            let method = input["method"]?.scalarText.flatMap({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 })?.uppercased()
                ?? "GET"
            reason = "\(method) \(url.host ?? "")\(url.path) through \(tool). \(reason)"
        } else if let disclosed = try await work.invocation[ActionDescriptor.Bound.self]?.approvalReason?(dataRoot, endpoint.includeAppOwnedTools) {
            reason = disclosed + " " + reason
        }
        let ownsACPConnectCard: Bool
        if namedConnect, case .string(let name)? = input["name"] {
            ownsACPConnectCard = AgentHostDirectory.row(named: name)?.acp != nil
        } else { ownsACPConnectCard = false }
        if !securityAsked, envelope.capabilities.contains(.approvalStage) || ownsACPConnectCard {
            // ACP owns the connect card and immutable executable proposal; no executable grant precedes approval.
            // Staging persists only bounded replay requests. Injection never takes this shortcut; its approval path must remain separate.
            return try await runInner(
                admission: judged.admission,
                tool: tool,
                input: input,
                surface: surface,
                injectionApprovalID: nil,
             turn: turn, work: work)
        }
        // In the person's own turn their ask is their act: this exact call runs as theirs, admitted the way their card's Approve is (this
        // call, once), and the receipt and consent record carry their message. No card is filed; one still waiting for it is settled.
        if judged.theirs, let words = await personsAsk(tool: tool, input: input, turn: turn) {
            judged.wordTurn = turn.with(\.personAct, PersonAct(by: .word(quote: words), tool: tool, input: input, spent: [.call]))
            if turn.doorPreview == nil, !work.admissionOnly { judged.cardsSettled = await settleCards(decidedBy: words, tool: tool, input: input, turn: turn) }
            judged.admission = Self.securityEnvelope(envelope, decision: .allow,
                reason: "The person asked for this in their own message in this conversation: “\(words)”.")
            judged.theirs = false
            judged.decision = .allow
            return nil
        }
        // File approval and await gate resolution; without a usable filer,
        // deny explicitly so the loop records the rejection.
        let nonBlocking = policy.approvalFiler?.pendingCards
        guard policy.approvalFiler != nil, !work.admissionOnly || nonBlocking != nil else {
            await audit(Self.securityEnvelope(envelope, decision: .ask, reason: reason), turn: turn)
            // Missing filers fail closed. User-chat profiles wire the canonical inbox; policy edits must never bypass TrustCenter.
            return ToolNotRunStatus.approvalUnavailable.reporting(.object([
                "status": .string("refused"), "reason": .string("approval_unavailable"), "checker": .string("approval_admission"),
                "effects": .string("none"), "remedy": Repair.why(owner: "approval for this call", tap: "NativeAgent chat on Mac, phone or Telegram",
                    instruction: "Make this request in a conversation with an approval inbox; no card was filed here and policy edits cannot grant it.")]))
        }
        // Persist and display injection arguments as count + digest;
        // execution characters stay only in this process's memory.
        if turn.doorPreview != nil {
            return .object(["status": .string("preview"), "execution": .string("preview"), "effects": .string("none"),
                "would_card": .bool(true), "approver": .string("owner"), "detail": .string(reason)])
        }
        let approvalPayloadInput = MacInjectionArgRedaction.redacted(tool: tool, input: input, turn: turn)
        let injectionSecrets = try MacInjectionArgRedaction.extractSecrets(tool: tool, input: input, turn: turn)
        if let nonBlocking {
            return try await fileApprovalCard(judged, nonBlocking: nonBlocking, reason: reason, approvalPayloadInput: approvalPayloadInput,
                injectionSecrets: injectionSecrets)
        }
        return try await resolveApproval(judged, reason: reason, approvalPayloadInput: approvalPayloadInput, injectionSecrets: injectionSecrets)
    }

    /// Files the person's card without waiting on it; the call returns pending with its card.
    private func fileApprovalCard(_ judged: JudgedCall, nonBlocking: any NonBlockingApprovalFiler, reason: String,
                                  approvalPayloadInput: [String: JSONValue], injectionSecrets: [String: String]) async throws -> JSONValue {
        let tool = judged.tool, surface = judged.surface, turn = judged.turn, envelope = judged.envelope
        let approvalId: String
        do {
            approvalId = try await nonBlocking.fileApprovalRequest(toolName: tool, surface: surface,
                payload: .object(approvalPayloadInput), reason: reason, turn: filingTurn(turn))
        } catch let error as AutonomyGateError {
            throw error
        } catch {
            throw AutonomyGateError.approvalFilingFailed(String(describing: error))
        }
        // Keep injection characters in the one-use in-memory approval vault; after process death, replay must refuse absent characters.
        if !injectionSecrets.isEmpty {
            await MacInjectionSecretVault.shared.store(
                approvalID: approvalId,
                secrets: injectionSecrets
            )
        }
        await audit(Self.securityEnvelope(envelope, decision: .ask, reason: reason), turn: turn)
        var pending = await nonBlocking.pendingApprovalResult(
            id: approvalId,
            toolName: tool,
            surface: surface,
            reason: reason
        )
        if case .object(let fields) = pending, fields["not_run_status"] == nil {
            pending = ToolNotRunStatus.approvalFiled.reporting(pending)
        }
        if let remedy = envelope.remedy, case .object(var fields) = pending {
            fields["remedy"] = remedy
            pending = .object(fields)
        }
        // The owner's ask, or a lever's, is now the person's card: what the agent reads says so, and what to do next.
        if judged.ownerAsked || judged.theirs, case .object(var fields) = pending {
            let card = ApprovalWords.call(tool: tool, input: .object(approvalPayloadInput)).act
            fields["card"] = .string("The person's card \"\(card)\" (\(approvalId)) is up in Mac chat and on their phone, and they decide: "
                + "their Approve runs this exact call as theirs, their Decline leaves everything as it is; do not call it again.")
            pending = .object(fields)
        }
        if StandingBotContinuity.isHelperTurn(turn: turn) { turn.execution?.keepApproval(id: approvalId, pending) }
        return pending
    }

    /// Files the card and waits on the gate's resolution; an approved call runs as the person's decision under the policy current now.
    private func resolveApproval(_ judged: JudgedCall, reason: String, approvalPayloadInput: [String: JSONValue],
                                 injectionSecrets: [String: String]) async throws -> JSONValue {
        let tool = judged.tool, input = judged.input, surface = judged.surface, turn = judged.turn, work = judged.work,
            envelope = judged.envelope, namedConnect = judged.namedConnect
        let resolved = try await gate.resolveWithApprovalDetailed(toolName: tool, surface: surface,
            requestPayload: .object(approvalPayloadInput), timeoutSeconds: policy.approvalTimeoutSeconds,
            reason: reason, turn: filingTurn(turn))
        if !injectionSecrets.isEmpty, let filedID = resolved.approvalID {
            await MacInjectionSecretVault.shared.store(
                approvalID: filedID,
                secrets: injectionSecrets
            )
        }
        switch resolved.decision {
        case .allow:
            // Verify the filer's injection approval against the real inbox
            // record and exact body before minting; its claimed ID alone grants no authority.
            var mintApprovalID = resolved.approvalID
            if MacInjectionToolNames.isInjectionTool(tool) {
                let verdict = try await injectionApprovalVerifier.verifyInjectionApproval(
                    approvalID: resolved.approvalID ?? "",
                    tool: tool,
                    surface: surface,
                    input: input,
                    turn: turn
                )
                guard verdict == .verified else {
                    let r = "injection_approval_unverified: \(verdict.rawValue) "
                        + "(\(tool) resolved approval \(resolved.approvalID ?? "<none>"))"
                    await audit(
                        Self.securityEnvelope(envelope, decision: .block, reason: r), turn: turn
                    )
                    throw AutonomyGateError.toolDenied(reason: r)
                }
                mintApprovalID = resolved.approvalID
            }
            // The person may answer after the saved policy changes. The membrane refreshes hard blocks before carrying the approved call.
            let current = await securityCenter.evaluateTool(tool: tool,
                input: MacInjectionArgRedaction.redacted(tool: tool, input: input, turn: turn),
                origin: .currentTurn(turn: turn.with(\.verifiedSessionID, policy.verifiedSessionId ?? turn.verifiedSessionID), surface: surface),
                enforceAutonomy: false, turn: turn)
            if current.decision == .block {
                await audit(current, turn: turn)
                throw AutonomyGateError.toolDenied(reason: current.primaryReason, remedy: current.remedy)
            }
            return try await runInner(
                admission: Self.securityEnvelope(current, decision: .allow, reason: "The person approved this call."),
                tool: tool,
                input: input,
                surface: surface,
                injectionApprovalID: mintApprovalID,
                personApprovedHost: namedConnect,
                // The person approved this exact call on its card: it runs as their decision, levers included.
                turn: resolved.approvalID.map { (id) -> Turn in
                    turn.cardCause?.approved(by: id)
                    return turn.with(\.personAct, PersonAct(by: .card(id: id), tool: tool, input: input, spent: [.call])) } ?? turn,
                work: work)
        case .deny(let r):
            await audit(Self.securityEnvelope(envelope, decision: .block, reason: r), turn: turn)
            var refused: [String: JSONValue] = ["status": .string("refused"), "reason": .string(r), "gate_reason": .string(r),
                "checker": .string("approval_admission"), "effects": .string("none"),
                "remedy": Repair.terminal(instruction: "Respect the reported approval outcome. Inspect the retained card before another request; "
                    + "do not repeat prior effects to answer an unresolved outcome.")]
            refused["approvalId"] = resolved.approvalID.map(JSONValue.string)
            if let status = resolved.notRunStatus { return status.reporting(.object(refused), tool: tool) }
            return .object(refused)
        case .requireApproval(let r):
            await audit(Self.securityEnvelope(envelope, decision: .ask, reason: r), turn: turn)
            throw AutonomyGateError.toolDenied(reason: r, remedy: Repair.why(owner: "approval for this call",
                tap: "NativeAgent chat on Mac, phone or Telegram", instruction: "Inspect the existing approval request before asking again."))
        }
    }

    /// Approval filing precedes dispatch, so bind its session from the same origin the gate resolved.
    /// Preserve an outer transport-verified session; fill only nil and never change the gate decision.
    private func filingTurn(_ turn: Turn) -> Turn {
        turn.with(\.fileAccess, policy.fileAccess).with(\.verifiedSessionID, turn.verifiedSessionID ?? policy.verifiedSessionId)
    }
}
