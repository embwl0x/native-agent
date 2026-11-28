import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import MindCore
import SenseCore
import MacNerves
// Blueprint: | `TurnSettle.swift` | `TurnSettle` enum; `recordDispatch`, `requestedResultIntent`, `takeStreamSuffix`, `transcriptRow` |

/// Every turn settles waiting state, terminal truth, transport prose and transcript through one owner so delivery and memory agree.
enum TurnSettle {
    static let dispatchWriteFailedNotice = "turn_settlement_failed"

    static func recordDispatch(_ call: SwiftNativeTurnEngine.PreparedToolCall, result: JSONValue, surface: String, turn: Turn) async {
        await settle {
            let view = await ChatToolDispatchTracer.resultView(turn: turn, tool: call.ranCall.tool,
                input: call.ranCall.input, result: result, receiptID: nil, dataRoot: turn.dataRoot)
            var payload: [String: JSONValue] = [
                "invocationID": .string(call.invocationID), "callID": .string(call.pairedId), "tool": .string(call.ranCall.tool),
            ]
            payload["parentId"] = turn.act.map(JSONValue.string)
            payload["result_recovery"] = view.recovery
            do {
                if view.failed {
                    payload["result_retention_failed"] = .bool(true)
                    payload["receipt"] = .string(view.content)
                } else {
                    payload["receipt"] = try view.recovery ?? JSONValue.parse(Data(view.content.utf8))
                }
            } catch {
                payload["result_retention_failed"] = .bool(true)
                payload["receipt"] = .string("The redacted result could not be decoded. Inspect its effect before repeating it.")
            }
            let event = TurnTraceEvent(turnId: turn.id, kind: TurnTraceEvent.dispatchSettledKind,
                sessionId: ChatToolSessionInjection.currentSession(turn: turn), surface: surface, payload: .object(payload), turn: turn)
            let operation = "dispatch:\(turn.id):\(call.invocationID)"
            do {
                try await TurnTracePersistLane(dataRootOverride: turn.dataRoot).appendChecked(event, transitionId: operation)
            } catch {
                let cause = TurnTraceRedactor.redactText(error.localizedDescription)
                ModuleLog.app("[dispatch] settlement receipt for %@ in turn %@ was not confirmed: %@",
                              call.invocationID, turn.id, cause)
                let name = TurnTraceRedactor.redactText(SwiftNativeTurnEngine.spokenName(call))
                let words = "Couldn't confirm the saved result of \(name) after its wait ended. "
                    + "Inspect its effects before repeating it."
                await turn.notices?(dispatchWriteFailedNotice, words)
                await RepairOwed.owe(turn.dataRoot, id: operation, kind: .run,
                    operation: operation, owner: "Turn \(turn.id)", words: "\(words) \(cause)").value
            }
        }
    }

    /// The obligation rides on the result's own durable row. Delivery readers
    /// can retry it without asking the provider or replaying any tool.
    static func requestedResultIntent(
        message: String, result: TurnEngineResult,
        sessionID: String, runID: String, surface: String,
        resumedRequest: Bool,
        turn: Turn
    ) -> JSONValue? {
        guard result.completionState == .completed,
              turn.execution?.waitingForInteraction != true,
              turn.execution?.transcriptRowKind == nil else { return nil }
        let completion = turn.rows.codexCompletion
        let origin = turn.origin
        guard completion != nil || origin?.authored != .agent else { return nil }
        // Discovery and context expansion alone cannot satisfy requested work.
        func isWorkAction(_ action: JSONValue?) -> Bool {
            guard let id = action?.trimmedString?.lowercased() else { return false }
            return id != "find" && id != "context.expand"
        }
        let meaningfulTools = result.toolDispatches.filter {
            let (tool, input) = $0.ranCall
            guard tool == "app" else { return tool != "context_expand" && tool != "app_find" }
            return isWorkAction(input["action"])
                || input["actions"]?.arrayValue?.contains(where: { isWorkAction($0.objectValue?["action"]) }) == true
                || input["script"]?.trimmedString != nil
        }
        var authored = (message.components(separatedBy: "\n\n[").first ?? message)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if authored.hasPrefix("["), let close = authored.firstIndex(of: "]") {
            authored = String(authored[authored.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard completion != nil || resumedRequest || !meaningfulTools.isEmpty ||
            UserMessageIntentSignals.explicitlyRequestsWork(authored) else { return nil }
        // An accepted asynchronous assignment is still owed. Its resident
        // continuation, carrying the completion binding, supplies the result.
        if meaningfulTools.contains(where: { dispatch in
            let ran = dispatch.ranCall.tool
            let input = dispatch.ranCall.input
            // A job the agent gave another agent settles by waking the context that commissioned it.
            if ran == "app", input["action"] == .string("agent.job"), case .object(let fields) = dispatch.result {
                return ["working", "needs_you"].contains(fields["state"]?.stringValue ?? "")
            }
            guard ["agent_message", "bot_run_once"].contains(ran),
                  case .object(let fields) = dispatch.result else { return false }
            // A one-way note completes when sent: its contract deliberately
            // creates no returning turn to own this obligation later.
            if input["expects_reply"] == .bool(false) ||
                fields["automatic_return"] == .bool(false) { return false }
            if ran == "agent_message", case .string(let state)? = fields["state"] {
                return ["waiting", "sending", "working"].contains(state)
            }
            if fields["terminal"] == .bool(true) || fields["completed"] == .bool(true) ||
                fields["sent"] == .bool(false) { return false }
            let states = [fields["status"], fields["state"]].compactMap { field -> String? in
                if case .string(let value)? = field { return value }; return nil
            }
            return fields["queued"] == .bool(true) || states.contains {
                ["accepted", "enqueued", "queued", "joined", "running", "working", "in_progress", "waiting", "pending", "submitted", "delivering"].contains($0)
            }
        }) { return nil }
        let route = turn.replyRoute?.surface ?? surface
        guard route != "caller-result", route != AgentConversationStore.heldReplySurface else { return nil }
        return .object([
            "eventId": .string("requested-result:" + (completion?.deliveryId ?? runID)),
            "sessionId": .string(sessionID), "runId": .string(runID),
            "surface": .string(route), "state": .string("pending"),
        ])
    }

    /// Consume synthesized card prose once inside the progress execution scope.
    static func takeStreamSuffix(turn: Turn) -> String? {
        guard let suffix = turn.execution?.takeStreamSuffix(), !suffix.isEmpty else { return nil }
        return suffix
    }

    /// Persist the card-lane sentence for waiting turns; expanded text belongs only to transport.
    /// Stamp synthesized-only rows as mechanical so memory never mistakes card copy for model-authored prose.
    static func transcriptRow(for reply: String, turn: Turn) -> (text: String, mechanicalRow: CognitiveMechanicalRowKind?) {
        let text = turn.execution?.transcriptReply(reply) ?? reply
        return (
            text,
            turn.execution?.transcriptReplyIsCardLane == true ? .cardLane : turn.execution?.transcriptRowKind
        )
    }
}
