import SenseCore
import MacNerves
import MindCore
import NativeAgentShared
import Foundation
import NativeAgentCore
import PersistenceCore
import DeskCore
import ProviderRouting
// Blueprint: | `DoorExecution.swift` | Execution of the admitted effect and its outcome |

extension DoorPipeline {
    /// Runs an allowed call, or admits it only; an owner that answers that the person must decide turns the decision to their ask.
    /// Returns nil when the decision turned and the call is judged again.
    func runAllowed(_ judged: inout JudgedCall) async throws -> JSONValue? {
        let tool = judged.tool, input = judged.input, surface = judged.surface, turn = judged.turn, work = judged.work,
            namedConnect = judged.namedConnect, approvedReplayAuthorizes = judged.approvedReplayAuthorizes,
            injectionReplayApprovalID = judged.injectionReplayApprovalID, requester = judged.requester,
            decidedRequester = judged.decidedRequester, trustedBridge = judged.trustedBridge
        if work.admissionOnly {
            await audit(Self.securityEnvelope(judged.admission, decision: .allow, reason: "admitted"), turn: turn)
            return .object(["status": .string("admitted"), "effects": .string("none"),
                            "execution": .string("not_run"), "reason": .string("admitted")])
        }
        // Bind the approved session so downstream dispatch reconstructs the same origin instead of falsely blocking it.
        // Injection still requires exact approved replay; `runInner` refuses any allow without its approval ID.
        var result = try await runInner(
            admission: judged.admission,
            tool: tool,
            input: input,
            surface: surface,
            injectionApprovalID: injectionReplayApprovalID ?? (approvedReplayAuthorizes ? policy.approvedReplay?.approvalID : nil),
            // Reaching .allow IS the person's go-ahead: their approval, or Full Mac.
            personApprovedHost: namedConnect,
            // A verified replay of the person's approved card runs as their decision of this exact call, levers included; so does a call
            // the person asked for in their own words.
            turn: policy.approvedReplay.flatMap { (replay) -> Turn? in
                guard approvedReplayAuthorizes else { return nil }
                turn.cardCause?.approved(by: replay.approvalID)
                return turn.with(\.personAct, PersonAct(by: .card(id: replay.approvalID), tool: tool, input: input, spent: [.call])) }
                ?? judged.wordTurn ?? turn,
            work: work)
        let reply = ToolResult(result)
        // Only the stem's own verbs ask this way (an app action that is no part's, connector's or folded tool's, or the door's own list
        // of calls that are all the person's to decide), so no reply a part, a peer or a remote tool writes can word the person's card.
        let stemAsks: Bool = if let asking = input["action"]?.stringValue { AppActionBinding.declaredBinding(asking)?.folded == false }
            else { input["action"] == nil && input["actions"]?.arrayValue != nil }
        if reply.said("needs_person"), !approvedReplayAuthorizes, turn.personAct == nil, input["preview"] != .bool(true), tool == "app",
           stemAsks, let words = Self.ownersDetail(result) {
            judged.decision = .requireApproval(reason: words)
            judged.ownerAsked = true
            // The owner's ask is the person's, as a lever's is, unless another agent is behind this turn; one their ask already
            // decided and that still asks goes on their card.
            judged.theirs = requester == nil && judged.wordTurn == nil
            judged.wordTurn = nil
            return nil
        }
        // What the agent reads says it undid its own act, and what it made.
        if let ownUndo = judged.ownUndo, case .object(var fields) = result {
            fields["undoing_own_act"] = .string(ownUndo)
            result = .object(fields)
        }
        // What the agent reads says the call ran as the person's act, on their own ask.
        if let words = judged.wordTurn?.personAct?.words, case .object(var fields) = result {
            fields["decided_by"] = .string("person")
            fields["persons_word"] = .string(words)
            if judged.cardsSettled != .null { fields["cards_settled_by_persons_word"] = judged.cardsSettled }
            result = .object(fields)
        }
        // A call the person's card decided says which card and that the person decided it, so the agent's own log ties it to them.
        if approvedReplayAuthorizes, let replay = policy.approvedReplay, case .object(var fields) = result {
            fields["decided_by"] = .string("person")
            fields["card"] = .string("\(ApprovalWords.call(tool: tool, input: .object(input)).act) (\(replay.approvalID)), approved by the person")
            result = .object(fields)
        }
        if turn.doorPreview == nil, let decidedRequester, !trustedBridge, tool != "app",
           reply.outcome == .succeeded {
            BodyDecidedRow.post(turn: turn, requester: decidedRequester, tool: tool, sessionID: policy.verifiedSessionId,
                                  dataRoot: dataRoot, ran: true)
        }
        return result
    }

    /// Restore approved secrets at the execution boundary and bind injection capabilities to the exact action and body.
    /// Full Mac may supply approval identity; non-injection calls clear inherited capabilities.
    func runInner(
        admission: SecurityToolEnvelope,
        tool: String,
        input: [String: JSONValue],
        surface: String,
        injectionApprovalID: String?,
        personApprovedHost: Bool = false,
        turn: Turn, work: ChatTurnWork
    ) async throws -> JSONValue {
        var effectiveInput = input
        var capability: MacInjectionCapability?

        if MacInjectionArgRedaction.isRedacted(tool: tool, input: input) {
            guard let approvalID = injectionApprovalID,
                  let secrets = await MacInjectionSecretVault.shared.take(approvalID: approvalID),
                  !secrets.isEmpty else {
                throw AutonomyGateError.toolDenied(
                    reason: "injection_secret_unavailable: the approved text for \(tool) is no "
                        + "longer held in memory (app restarted or already replayed). Ask again."
                )
            }
            effectiveInput = MacInjectionArgRedaction.rehydrated(tool: tool, input: input, secrets: secrets)
            guard !MacInjectionArgRedaction.isRedacted(tool: tool, input: effectiveInput),
                  MacInjectionArgRedaction.redacted(tool: tool, input: effectiveInput, turn: turn) == input else {
                throw AutonomyGateError.toolDenied(reason: "injection_secret_mismatch: approved text for \(tool) could not be verified.")
            }
        } else if let approvalID = injectionApprovalID {
            // An approval resolved in this call still has its original arguments.
            _ = await MacInjectionSecretVault.shared.take(approvalID: approvalID)
        }

        if MacInjectionToolNames.isInjectionTool(tool) {
            // Full Mac synthesizes a missing injection approval id; category and TCC gates still apply.
            let resolvedApprovalID = injectionApprovalID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let approvalID = if let resolvedApprovalID, !resolvedApprovalID.isEmpty {
                resolvedApprovalID
            } else { "yolo-\(UUID().uuidString)" }
            guard let action = MacInjectionToolNames.action(forTool: tool) else {
                throw AutonomyGateError.toolDenied(
                    reason: "injection_approval_missing: \(tool) has no mapped action"
                )
            }
            guard let minted = MacInjectionCapability.mint(
                approvalID: approvalID,
                action: action,
                body: effectiveInput
            ) else {
                throw AutonomyGateError.toolDenied(
                    reason: "injection_capability_mint_failed: \(tool) could not be authorized"
                )
            }
            capability = minted
        }

        let executionSessionID = policy.verifiedSessionId ?? turn.verifiedSessionID
        let turn = turn.with(\.verifiedSessionID, executionSessionID)
            .with(\.injectionCapability, capability).with(\.personApprovedHost, personApprovedHost)
        let finalInput = ChatToolSessionInjection.apply(turn: turn, toolName: tool, input: effectiveInput)
        try Task.checkCancellation()
        let admitted = Self.securityEnvelope(admission, decision: .allow, reason: "admitted")
        let result: JSONValue
        if let call = work.authoredCall, call.tool == tool {
            await audit(admitted, turn: turn)
            result = try await call.perform()
        } else if AuthoredToolEffects.primitiveCapabilities[tool] != nil || tool.hasPrefix("fetch.") {
            throw ToolFailureError("The originating ability run ended; its primitive broker is no longer available. This primitive call did not run.",
                effects: .none, owner: "originating ability run",
                nextCall: (try? SwiftNativeTurnEngine.dispatchReceiptCall(turn: turn).serialize(pretty: false)),
                code: "primitive_broker_ended", status: .refused,
                instruction: "Read the originating run's receipts and inspect any uncertain effects. A new ability run is new execution, not a "
                    + "replay of this primitive; start one only after reconciling earlier work.", recovery: .reconcile)
        } else if !policy.includeAppOwnedTools, ["mac_notify", "mobile_notify"].contains(tool) {
            result = .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("canonical_body_unavailable"),
                "detail": .string("Notifications are not available in this context, so nothing was sent."), "tool": .string(tool)])
        } else {
            var invocation = work.invocation
            invocation[AdmittingDoor.self] = self
            if turn.doorPreview == nil { try await securityCenter.record(admitted) }
            let admission = SecurityToolAdmission(envelope: admitted, tool: tool, input: finalInput, surface: surface, turn: turn)
            result = try await endpoint.executeAdmitted(consume admission, invocation: policy.scoping(invocation))
        }
        let reply = ToolResult(result)
        if surface == "chat", tool == FirstConversationPersonaProgression.writeTool,
           finalInput["preview"] != .bool(true), reply.outcome == .succeeded {
            let root = securityCenter.dataRoot, session = executionSessionID
            // Stop does not cancel the bookkeeping for an already committed write.
            // Every allowed path (including approved replay) settles here once.
            let progressionFailure: String? = await settle {
                do {
                    _ = try await FirstConversationPersonaProgression.settleSuccessfulWrite(
                        tool: tool, input: finalInput, dataRoot: root, sessionID: session)
                    return nil
                } catch {
                    RepairOwed.owe(root, id: "first-conversation:" + UUID().uuidString, kind: .run,
                        operation: "first_conversation.progression", owner: PersonaRootResolver.resolveIsolated(dataRoot: root).path,
                        words: """
                            The persona append succeeded, but its progression remains owed: \(error.localizedDescription). Inspect the retained token \
                            and persona bytes; repair progression without appending the same section again.
                            """)
                    return error.localizedDescription
                }
            }
            if let progressionFailure, case .object(var fields) = result {
                fields["progression_status"] = .string("repair_owed")
                fields["progression_detail"] = .string("The persona append succeeded. Repair its progression without repeating the append: "
                    + progressionFailure)
                return .object(fields)
            }
        }
        return result
    }
}
