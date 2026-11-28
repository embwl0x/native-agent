import MacNerves
import Foundation
import NativeAgentShared
import DeskCore
import NativeAgentCore
import PersistenceCore
import SenseCore
import ProviderRouting
import MindCore
import Synchronization
// Blueprint: | `ChatOrchestration+ToolDispatch.swift` | Offered-call admission, determined-read following at every slot's return and Stop settlement |

extension SwiftNativeTurnEngine {
    nonisolated private static let dispatchSettlements = Mutex<[UUID: (call: String, settled: Task<Void, Never>)]>([:])

    /// Quit joins actual dispatch bodies after admitted turns drain, without holding their stopped callers.
    nonisolated public static func joinDispatchSettlements() async {
        while true {
            let pending = dispatchSettlements.withLock { Array($0.values) }
            guard !pending.isEmpty else { return }
            // A held quit names what it waits on.
            ModuleLog.app("[quit] waiting for %@ to settle", pending.map(\.call).joined(separator: ", "))
            for entry in pending { await entry.settled.value }
        }
    }

    // MARK: - Per-iteration dispatch shared by both loops

    /// Prepare Sendable call values before spawning children so they capture neither conversation storage nor actor state.
    struct PreparedToolCall: Sendable {
        let invocationID = UUID().uuidString
        let pairedId: String
        /// The spelling the model called, handed to the chain as-is so its
        /// canonicalizer resolves the same tool the agent named.
        let requestedName: String
        /// One canonical name keeps the pill, receipt and records consistent.
        let internalName: String
        let dispatchInput: [String: JSONValue]
        /// Planning identity; refreshed when execution starts, then carried unchanged.
        var ranCall: (tool: String, input: [String: JSONValue])
    }

    /// Both loops share ordered dispatch so serial and parallel behavior cannot drift.
    /// Admit and emit starts in index order, dispatch within the cap, then emit records and results in index order.
    /// Slot errors remain local; turn cancellation cancels all children.
    func dispatchIterationCalls(
        providerCalls: [ParsedToolCall],
        pairedIds: [String],
        providerTools: ProviderToolNameMap,
        priorDispatches: [TurnEngineResult.ToolDispatchRecord],
        modelId: String,
        surface: String,
        sessionId: String?,
        /// Only a loop that reads arrivals may withhold its unstarted calls.
        arrivalSessionId: String?,
        personaID: String? = nil,
        fluidContextTurn: ContextPreparedTurn? = nil,
        tools: any ToolDispatchClient,
        progress: ToolProgress?,
        cancelFlagPath: URL? = nil,
        turn: Turn, work: ChatTurnWork
    ) async -> (blocks: [LLMContentBlock], records: [TurnEngineResult.ToolDispatchRecord]) {
        let turnNotice = turn.notices
        let turn = turn.with(\.runtime, .init(model: modelId, surface: surface, personaID: personaID, providerID: turn.admission?.provider))
            .with(\.notices, { kind, text in
                if kind == TurnSettle.dispatchWriteFailedNotice, let turnNotice {
                    await turnNotice(kind, text)
                } else {
                    await progress?(.notice(kind: kind, text: text))
                }
            })
        let work = work.with(\.preparedContext, fluidContextTurn)
        let planned = prepareIterationCalls(
            providerCalls: providerCalls, pairedIds: pairedIds, providerTools: providerTools, sessionId: sessionId, turn: turn
        )
        let claimed = claimIterationApprovals(planned, priorDispatches: priorDispatches, turn: turn)
        let slots = await dispatchUnclaimedIterationCalls(
            planned, claimed: claimed, arrivalSessionId: arrivalSessionId, surface: surface,
            tools: tools, progress: progress, cancelFlagPath: cancelFlagPath, turn: turn, work: work
        )
        return await collectIterationResults(
            planned, claimed: claimed, slots: slots, providerTools: providerTools, priorDispatches: priorDispatches,
            tools: tools, surface: surface, cancelFlagPath: cancelFlagPath, turn: turn, work: work
        )
    }

    private typealias PlannedToolCall = (call: PreparedToolCall, offered: Bool, input: [String: JSONValue], undeclared: [String])

    private func prepareIterationCalls(
        providerCalls: [ParsedToolCall], pairedIds: [String], providerTools: ProviderToolNameMap,
        sessionId: String?, turn: Turn
    ) -> [PlannedToolCall] {
        return providerCalls
            .enumerated().compactMap { i, call in
                guard !ToolCallParser.isIgnorableToolName(call.name) else { return nil }
                var requestedName = providerTools.internalName(forProviderName: call.name)
                var internalName = CanonicalToolNameDispatcher.canonical(requestedName)
                var callInput = call.input
                var undeclared = call.undeclaredKeys
                // A call written under an action's own name is that action through `app`: the same act through the same gates, with no round
                // spent being told so. A name `app` has no action for is still refused.
                if providerTools.providerName(forInternalName: internalName) == nil, providerTools.providerName(forInternalName: "app") != nil {
                    let id = requestedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let args = callInput.filter { !$0.key.hasPrefix("__") }
                    var folded = ToolNameAliases.appCall(internalName, input: callInput)
                    // The name is an action's own id, a native one or an ability's: `app` with that action and these arguments.
                    if folded == nil, (try? AppActionBinding.binding(id, turn: turn)) != nil {
                        folded = args.isEmpty ? ["action": .string(id)] : ["action": .string(id), "args": .object(args)]
                    }
                    if let folded {
                        // The call is dispatched by the name it was asked under, so the asked name becomes `app` with it.
                        requestedName = "app"
                        internalName = "app"
                        callInput = folded
                        undeclared = []
                    }
                }
                let input = ChatToolSessionInjection.apply(toolName: internalName, input: callInput, sessionId: sessionId)
                let prepared = PreparedToolCall(
                    pairedId: i < pairedIds.count ? pairedIds[i] : call.id,
                    requestedName: requestedName,
                    internalName: internalName,
                    dispatchInput: input,
                    ranCall: ToolNameAliases.ranCall(internalName, input: input)
                )
                // Every model call requires an offered descriptor. Internal app re-entry
                // has its own checked gate and never passes through this provider layer.
                let refusal = Self.modelCallRefusal(name: internalName, input: callInput,
                    undeclaredKeys: undeclared, providerTools: providerTools)
                return (prepared, refusal == nil, callInput, undeclared)
            }
    }

    private func claimIterationApprovals(
        _ planned: [PlannedToolCall], priorDispatches: [TurnEngineResult.ToolDispatchRecord], turn: Turn
    ) -> [String: JSONValue] {
        // An undecided card owns its effect. Its resolution answers one re-proposal; later identical calls are fresh gated invocations.
        var approvalRecords: Result<[ApprovalRecord], Error>?
        func cardClaim(on call: PreparedToolCall) -> JSONValue? {
            guard let held = priorDispatches.last(where: {
                $0.ranCall.tool == call.ranCall.tool && $0.ranCall.input == call.ranCall.input
            }), ChatToolOutcome.isWaitingApproval(held.result), case .string(let card)? = ChatTranscriptEvidenceRendering.receiptField("approvalId",
                in: held.result)
                ?? ChatTranscriptEvidenceRendering.receiptField("approval_id", in: held.result) else { return nil }
            let path = (remPinsDataRoot ?? defaultDataRoot()).appendingPathComponent("workflows/approvals/requests.json")
            let record: ApprovalRecord
            do {
                let records = approvalRecords ?? Result {
                    try SwiftNativeApprovalInbox(root: remPinsDataRoot ?? defaultDataRoot()).recordsUnlocked()
                }
                approvalRecords = records
                guard let found = try records.get().first(where: { $0.id == card }) else {
                    return .object(["status": .string("unknown"), "effects": .string("unknown"), "card": .string(card),
                        "not_run_status": .string("claimed_by_card"), "reason": .string("claimed_card_missing"),
                        "detail": .string("""
                            The loaded approval queue has no card \(card) for this exact call. This proposal did not run again; the earlier outcome \
                            is unknown.
                            """),
                        "remedy": Repair.reconcile(instruction: """
                            Read the prior dispatch receipts and inspect the affected state before proposing new work; a missing card does not prove \
                            the earlier action did not run.
                            """,
                            nextCall: Self.dispatchReceiptCall(turn: turn))])
                }
                record = found
            } catch {
                return .object(["status": .string("unknown"), "effects": .string("unknown"), "card": .string(card),
                    "not_run_status": .string("claimed_by_card"),
                    "reason": .string("claimed_card_unreadable"),
                    "detail": .string("""
                        Card \(card) for this exact call could not be read: \(error.localizedDescription). This proposal did not run again; the \
                        earlier outcome is unknown.
                        """),
                    "remedy": Repair.reconcile(instruction: "Read the approval store for this card before relying on its decision or repeating the action.",
                        nextCall: .object(["tool": .string("app"), "input": .object([
                            "action": .string("files.read"), "args": .object(["path": .string(path.path)])])]))])
            }
            guard record.status != "pending" else {
                guard case .object(var waiting) = held.result else { return held.result }
                // Its own waiting fields stay as they are, so it still waits on the card.
                waiting["claimed_by_card"] = .string(card)
                waiting["detail"] = .string("This exact call already waits on card \(card); answering the card runs it once. It was not run again.")
                return .object(waiting)
            }
            let approved = record.decision == "approved"
            return .object(["status": .string(record.executionIsStopped ? "stopped" : approved ? record.executionResultClass.rawValue : "skipped"),
                "effects": .string(approved ? "unknown" : "none"), "card": .string(card),
                "decision": .string(record.decision ?? record.status), "receipt": record.executedAction ?? .null,
                "not_run_status": .string("claimed_by_card"),
                "reason": .string(record.executionIsStopped ? DataRootLife.stoppedReason : approved && record.executedAction == nil
                    ? "card_outcome_unavailable" : "card_already_decided"),
                "detail": .string("""
                    This exact call was already decided on card \(card) (\(record.decision ?? record.status)); its receipt is the card's, and it was \
                    not run again.
                    """),
                "remedy": approved && record.executedAction == nil
                    ? Repair.reconcile(
                        instruction: "Read this card's execution record, then inspect the affected state before repeating an action whose outcome is missing.",
                        nextCall: .object(["tool": .string("app"), "input": .object([
                            "action": .string("files.read"), "args": .object(["path": .string(path.path)])])]))
                    : Repair.terminal(instruction: "Use the retained card decision and receipt; this proposal did not run again.")])
        }
        var answered: Set<String> = []
        let claimed: [String: JSONValue] = planned.reduce(into: [:]) { claims, entry in
            guard let receipt = cardClaim(on: entry.call) else { return }
            if case .object(let fields) = receipt, fields["decision"] != nil, case .string(let card)? = fields["card"] {
                guard answered.insert(card).inserted else { return }
            }
            claims[entry.call.pairedId] = receipt
        }
        return claimed
    }

    private func dispatchUnclaimedIterationCalls(
        _ planned: [PlannedToolCall], claimed: [String: JSONValue], arrivalSessionId: String?,
        surface: String, tools: any ToolDispatchClient, progress: ToolProgress?, cancelFlagPath: URL?,
        turn: Turn, work: ChatTurnWork
    ) async -> [DispatchedSlot] {
        let prepared = planned.filter { $0.offered && claimed[$0.call.pairedId] == nil }.map(\.call)
        return await Self.runIterationDispatchGroups(
            prepared: prepared,
            sessionId: arrivalSessionId,
            surface: surface,
            tools: tools,
            cancelFlagPath: cancelFlagPath,
            onToolUse: { p in
                await progress?(.toolUse(name: p.internalName,
                    input: .object(MacInjectionArgRedaction.redacted(tool: p.internalName, input: p.dispatchInput, turn: turn))),
                    invocationID: p.invocationID)
            },
            onOutcome: { p, result, publishedStart in
                let reply = ToolResult(result)
                let receipt = ToolReceipt(turn: turn.with(\.invocationID, p.invocationID),
                    checkpoint: work.checkpoint, invocationID: p.invocationID,
                    toolName: p.internalName, input: ChatSecretRedactor.redactValue(.object(p.dispatchInput)),
                    ranCall: p.ranCall, output: ChatSecretRedactor.redactValue(result),
                    ok: ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome), cognitiveOutput: reply.payload)
                let event: TurnStreamEvent
                if surface == "chat", !publishedStart,
                   let disposition = MacChatTurnActivityBoundary.unstartedDisposition(reply) {
                    event = .unstartedStep(id: p.pairedId, name: Self.spokenName(p), disposition: disposition)
                } else {
                    event = .toolResult(name: p.internalName, output: result)
                }
                await progress?(event, receipt: receipt,
                    invocationID: p.invocationID)
            },
            turn: turn, work: work)
    }

    private func collectIterationResults(
        _ planned: [PlannedToolCall], claimed: [String: JSONValue], slots: [DispatchedSlot],
        providerTools: ProviderToolNameMap, priorDispatches: [TurnEngineResult.ToolDispatchRecord],
        tools: any ToolDispatchClient, surface: String, cancelFlagPath: URL?, turn: Turn, work: ChatTurnWork
    ) async -> (blocks: [LLMContentBlock], records: [TurnEngineResult.ToolDispatchRecord]) {
        var slotIterator = slots.makeIterator()
        // Requests offering app hear next calls as app calls; a restricted catalog uses its own tool names.
        let appDoor = providerTools.providerName(forInternalName: "app") != nil
        var blocks: [LLMContentBlock] = []
        var records: [TurnEngineResult.ToolDispatchRecord] = []
        var images: [LLMContentBlock] = []
        blocks.reserveCapacity(planned.count)
        records.reserveCapacity(planned.count)
        for entry in planned {
            var prepared = entry.call
            let result: JSONValue, isError: Bool
            if entry.offered, let receipt = claimed[entry.call.pairedId] {
                let reply = ToolResult(receipt)
                result = reply.payload
                isError = reply.carriesFailureEvidence
            } else if entry.offered {
                guard let slot = slotIterator.next() else { continue }
                images.append(contentsOf: slot.images)
                prepared = slot.prepared
                result = slot.result
                isError = slot.isError
            } else {
                let refusal = entry.undeclared.isEmpty
                    ? Self.notOfferedToolResult(entry.call.internalName, input: entry.input)
                    : Self.undeclaredFieldsResult(entry.call.internalName, keys: entry.undeclared)
                result = await ChatToolDispatchTracer.traceUndispatched(turn: turn, tool: entry.call.internalName,
                    input: entry.call.dispatchInput, surface: surface, result: refusal, dataRoot: remPinsDataRoot ?? defaultDataRoot())
                isError = true
            }
            let out = await Self.makeSlotOutputs(prepared: prepared, result: result, isError: isError,
                priorDispatches: priorDispatches + records, dataRoot: remPinsDataRoot,
                appDoor: appDoor,
                tools: tools, surface: surface, cancelFlagPath: cancelFlagPath, turn: turn, work: work)
            records.append(out.record)
            blocks.append(out.block)
        }
        // Keep all paired results first; pixels belong to the same user
        // continuation, not the persisted/tool-result text representation.
        blocks.append(contentsOf: images)
        return (blocks, records)
    }

    /// Dispatch and both tool loops honor task cancellation and the on-disk Stop flag.
    nonisolated static func dispatchCancelSignalled(_ cancelFlagPath: URL?) -> Bool {
        if Task.isCancelled { return true }
        if ChatCancelFlag.isRaised(cancelFlagPath) { return true }
        return false
    }

    /// Present folded `app` calls by their action identity.
    nonisolated static func spokenName(_ prepared: PreparedToolCall) -> String {
        guard prepared.internalName == "app", case .string(let action)? = prepared.dispatchInput["action"] else {
            return prepared.internalName
        }
        return "app " + action
    }

    nonisolated static func cancelledToolResult(_ name: String) -> JSONValue {
        let message = "tool '\(name)' was not run: the turn was stopped."
        return .object([
            "status": .string("cancelled"),
            "execution": .string("not_run"),
            "error": .string(message),
            "reason": .string("cancelled_before_start"),
            "effects": .string("none"),
            "remedy": Repair.terminal(instruction: "Stop cancelled this call before it started. Leave it stopped unless the person requests new work."),
        ])
    }

    /// A stopped caller receives the effect its owner could confirm at interruption.
    nonisolated static func interruptedToolResult(_ name: String, turn: Turn, committedID: String? = nil,
        abandonedCall: PreparedToolCall? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "status": .string("cancelled"), "execution": .string("attempted"),
            "reason": .string("interrupted_after_start"),
        ]
        if let abandonedCall {
            fields["invocationID"] = .string(abandonedCall.invocationID)
            fields["callID"] = .string(abandonedCall.pairedId)
        }
        if let committedID {
            fields["effects"] = .string("occurred")
            fields["id"] = .string(committedID)
            fields["detail"] = .string("\(name) committed.")
            return .object(fields)
        }
        let message = "tool '\(name)' was stopped: the turn was stopped after "
            + "the call had already started, so whether it took effect is unknown. "
            + "Check before repeating it."
        fields["error"] = .string(message)
        fields["effects"] = .string("unknown")
        fields["remedy"] = Repair.reconcile(
            instruction: abandonedCall == nil
                ? "Read this turn's dispatch receipts, then inspect the affected state for any unconfirmed effect before repeating the action."
                : "Read the saved result for this invocation if it has arrived, then inspect the affected state before repeating the action.",
            nextCall: abandonedCall == nil ? dispatchReceiptCall(turn: turn) : settledDispatchRead(turn: turn))
        return .object(fields)
    }

    /// The current turn's recorded outcomes, without asserting an unrecorded effect.
    nonisolated static func dispatchReceiptCall(turn: Turn) -> JSONValue {
        var args: [String: JSONValue] = ["kind": .string("tool.dispatch"), "view": .string("receipts")]
        args["turn_id"] = .string(turn.id)
        return .object(["tool": .string("app"), "input": .object([
            "action": .string("trace.recent"), "args": .object(args)])])
    }

    nonisolated private static func settledDispatchRead(turn: Turn) -> JSONValue {
        var args: [String: JSONValue] = [
            "kind": .string(TurnTraceEvent.dispatchSettledKind), "turn_id": .string(turn.id),
            "fields": .array(["invocationID", "callID", "result_recovery", "result_retention_failed"].map(JSONValue.string)),
        ]
        args["session_id"] = ChatToolSessionInjection.currentSession(turn: turn).map(JSONValue.string)
        return .object(["tool": .string("app"), "input": .object([
            "action": .string("trace.recent"), "args": .object(args)])])
    }

    /// Resident and helper calls share offered-descriptor admission before canonical dispatch or policy gates.
    nonisolated static func modelCallRefusal(
        name: String, input: [String: JSONValue], undeclaredKeys: [String] = [],
        providerTools: ProviderToolNameMap
    ) -> JSONValue? {
        if !undeclaredKeys.isEmpty { return undeclaredFieldsResult(name, keys: undeclaredKeys) }
        guard providerTools.providerName(forInternalName: name) != nil else {
            return notOfferedToolResult(name, input: input)
        }
        return nil
    }

    /// Return a declared-but-unoffered call as a dispatch error with its `app` translation or discovery step.
    nonisolated static func notOfferedToolResult(_ name: String, input: [String: JSONValue] = [:]) -> JSONValue {
        let call = ToolNameAliases.appCall(name, input: input)
        return .object([
            "status": .string("refused"),
            "reason": .string("tool_not_offered"),
            "error": .string("tool '\(name)' is not offered in this conversation, so it was not run. "
                + ToolNameAliases.foldedToolHint(name, input: input)),
            "not_offered": .bool(true),
            "effects": .string("none"),
            "remedy": .object([
                "kind": .string(call == nil ? "none" : "correct_route"),
                "instruction": .string(call == nil
                    ? "Nothing ran, and app has no call by that name; don't retry it. Tell the person why if the work needs it."
                    : "Nothing ran. Make next_call instead."),
                "next_call": call.map { .object(["tool": .string("app"), "input": .object($0)]) } ?? .null,
            ]),
        ])
    }

    /// A text-lane block carrying fields its tool does not take is not a call
    /// it can run (`TextMarkerCodec.calls`); it ran nothing.
    nonisolated static func undeclaredFieldsResult(_ name: String, keys: [String]) -> JSONValue {
        // On app, fields beside an action are that action's arguments in the wrong place: the words say where they go.
        let app = name == "app"
        return .object([
            "error": .string("\(name) takes no \(keys.joined(separator: ", ")), so this block was not run. "
                + (app ? "An action's own arguments go inside args: put them there and send it again."
                       : "To call \(name), use only its own parameters.")),
            "status": .string("skipped"),
            "reason": .string("undeclared_call_fields"),
            "effects": .string("none"),
            "remedy": .object(["kind": .string("correct_arguments"),
                "instruction": .string(app ? "Move \(keys.joined(separator: ", ")) into args and call again."
                                           : "Find the action's accepted parameters, then remove the undeclared fields."),
                "next_call": app ? .null : .object(["tool": .string("app"), "input": .object(["find": .string(name)])])]),
        ])
    }

    /// Ordered dispatch outcomes; the caller owns result-block and transcript formatting.
    struct DispatchedSlot: Sendable {
        let prepared: PreparedToolCall
        let result: JSONValue
        let isError: Bool
        let images: [LLMContentBlock]
    }

    nonisolated static func arrivalSkipped(_ name: String, arrival: ChatTurnSteering.WaitingArrival) -> JSONValue {
        .object([
            "status": .string("skipped"), "execution": .string("not_run"), "effects": .string("none"),
            "reason": .string("person_arrival"),
            "detail": .string("\(name) did not start because a \(arrival.subject) is waiting. Read it before deciding on another call."),
        ])
    }

    nonisolated private static func ownerWithdrawalSkipped(_ name: String) -> JSONValue {
        .object([
            "status": .string("skipped"), "execution": .string("not_run"), "effects": .string("none"),
            "reason": .string("owner_withdrawal"),
            "detail": .string("\(name) did not start. The person withdrew unstarted work for this turn. Finish the reply without proposing more calls."),
        ])
    }

    /// Preserve original slot order and the held turn through bounded dispatch groups.
    /// Slot failures never cancel siblings; turn cancellation cancels all children.
    /// Check Stop and arrivals before publishing a start; skipped slots retain only their outcome and wire pairing.
    nonisolated static func runIterationDispatchGroups(
        prepared: [PreparedToolCall],
        sessionId: String?,
        surface: String,
        tools: any ToolDispatchClient,
        cancelFlagPath: URL? = nil,
        onToolUse: @Sendable (PreparedToolCall) async -> Void,
        onOutcome: @Sendable (PreparedToolCall, JSONValue, Bool) async -> Void,
        turn: Turn,
    work: ChatTurnWork) async -> [DispatchedSlot] {
        // A folded `app` action is judged as the tool it runs: its parallel
        // class, its pixels and whether it is a send are that tool's.
        let ran = prepared.map { $0.ranCall.tool }
        let changesParts = prepared.contains {
            (try? PermissionLaw.toolClass($0.ranCall.tool, input: $0.ranCall.input, turn: turn)) != .read
        }
        let baseSafe = prepared.map {
            let certifiedByPart = $0.internalName == "app" || ToolNameAliases.canonical($0.ranCall.tool) == "mac_reminders_list_due_today"
            return (!certifiedByPart || !changesParts)
                && ($0.internalName != "app" || ParallelToolDispatch.singleAppAction($0.dispatchInput) != nil)
                && !Self.isConnectorRead($0.ranCall.tool)
                && ParallelToolDispatch.isParallelSafe(internalToolName: $0.ranCall.tool, input: $0.ranCall.input, turn: turn)
        }
        let groups = ParallelToolDispatch.plan(
            parallelSafe: baseSafe,
            forceSerial: StandingBotContinuity.isHelperTurn(turn: turn)
        )

        var slots: [DispatchedSlot] = []
        slots.reserveCapacity(prepared.count)
        // Only declared pixel-capable tools receive sinks; every sink shares the round budget, including concurrent dispatches.
        // Screen sinks attach pixels only for thin AX or an explicit pixel request.
        let imageIndices = Set(prepared.indices.filter {
            LocalToolImage.pixelCapableTools.contains(ToolNameAliases.canonical(ran[$0]))
        })
        let imageRound = LocalToolImage.Round()
        for group in groups {
            switch group {
            case .sequential(let idx):
                let p = prepared[idx]
                let withdrawn = if surface == "chat", let sessionId {
                    await ChatTurnSteering.shared.withdrawsUnstarted(in: sessionId, turn: turn)
                } else { false }
                if Self.dispatchCancelSignalled(cancelFlagPath) {
                    let cancelled = Self.cancelledToolResult(Self.spokenName(p))
                    await onOutcome(p, cancelled, false)
                    slots.append(DispatchedSlot(
                        prepared: p, result: cancelled, isError: true, images: []
                    ))
                    continue
                }
                let arrival = sessionId.flatMap(ChatTurnSteering.waitingArrival)
                if arrival != nil || withdrawn {
                    let skipped = arrival.map { Self.arrivalSkipped(Self.spokenName(p), arrival: $0) }
                        ?? Self.ownerWithdrawalSkipped(Self.spokenName(p))
                    await onOutcome(p, skipped, false)
                    slots.append(DispatchedSlot(prepared: p, result: skipped, isError: false, images: []))
                    continue
                }
                await onToolUse(p)
                if let connector = Self.connectorID(ran[idx]), slots.contains(where: {
                    guard let need = InlineInteractionNeed.interaction(in: $0.result) else { return false }
                    return need.kind == .connector && need.target == connector
                }) {
                    let result = ChatToolOutcome.normalizedFailure(.object([
                        "status": .string("skipped"),
                        "outcome": .string("unmet"), "effects": .string("none"),
                        "detail": .string("\(connector) is not connected. This action did not run."),
                        "fix": .string("The owner can sign in to \(connector) by requesting a setup card in chat or opening Connectors in Advanced view."),
                    ]), tool: ran[idx])
                    await onOutcome(p, result, true)
                    slots.append(DispatchedSlot(prepared: p,
                                                result: result, isError: true, images: []))
                    continue
                }
                let imageSink = imageIndices.contains(idx) ? LocalToolImage.Sink(round: imageRound) : nil
                let (dispatched, result, isError) = await Self.runResidentDispatch(
                    prepared: p, surface: surface, tools: tools, imageSink: imageSink,
                    cancelFlagPath: cancelFlagPath, turn: turn, work: work)
                await onOutcome(dispatched, result, true)
                slots.append(DispatchedSlot(
                    prepared: dispatched, result: result, isError: isError,
                    images: imageSink?.finish(success: !isError && !Task.isCancelled) ?? []
                ))

            case .concurrent(let indices):
                var outcomes: [Int: (prepared: PreparedToolCall, result: JSONValue, isError: Bool,
                                     images: [LLMContentBlock], publishedStart: Bool)] = [:]
                await withTaskGroup(
                    of: (Int, PreparedToolCall, JSONValue, Bool, [LLMContentBlock]).self
                ) { taskGroup in
                    var iterator = indices.makeIterator()
                    func addNext(turn: Turn) async -> Bool {
                        while let idx = iterator.next() {
                            let p = prepared[idx]
                            let withdrawn = if surface == "chat", let sessionId {
                                await ChatTurnSteering.shared.withdrawsUnstarted(in: sessionId, turn: turn)
                            } else { false }
                            // Stop reached this slot before it started: record the
                            // cancelled outcome and keep draining, so no further
                            // dispatch is ever handed to `tools`.
                            if Self.dispatchCancelSignalled(cancelFlagPath) {
                                outcomes[idx] = (p, Self.cancelledToolResult(Self.spokenName(p)), true, [], false)
                                continue
                            }
                            let arrival = sessionId.flatMap(ChatTurnSteering.waitingArrival)
                            if arrival != nil || withdrawn {
                                let skipped = arrival.map { Self.arrivalSkipped(Self.spokenName(p), arrival: $0) }
                                    ?? Self.ownerWithdrawalSkipped(Self.spokenName(p))
                                outcomes[idx] = (p, skipped, false, [], false)
                                continue
                            }
                            // Starts belong only to admitted slots, in their original order, including refills.
                            await onToolUse(p)
                            taskGroup.addTask {
                                let imageSink = imageIndices.contains(idx) ? LocalToolImage.Sink(round: imageRound) : nil
                                let (dispatched, result, isError) = await Self.runResidentDispatch(
                                    prepared: p, surface: surface, tools: tools, imageSink: imageSink,
                                    cancelFlagPath: cancelFlagPath, turn: turn, work: work)
                                return (idx, dispatched, result, isError, imageSink?.finish(success: !isError && !Task.isCancelled) ?? [])
                            }
                            return true
                        }
                        return false
                    }
                    var started = 0
                    while started < ParallelToolDispatch.maxConcurrentPerIteration, await addNext(turn: turn) {
                        started += 1
                    }
                    while let (idx, dispatched, result, isError, images) = await taskGroup.next() {
                        outcomes[idx] = (dispatched, result, isError, images, true)
                        _ = await addNext(turn: turn)
                    }
                }
                // Provider pairing uses IDs and stable original order, regardless of completion order.
                for idx in indices {
                    let outcome = outcomes[idx] ?? (
                        prepared: prepared[idx],
                        result: JSONValue.object([
                            "status": .string("unknown"),
                            "reason": .string("dispatch_result_missing"),
                            "effects": .string("unknown"),
                            "error": .string("parallel dispatch produced no result"),
                            "remedy": Repair.reconcile(
                                instruction: """
                                    Read this turn's dispatch receipts and inspect the affected state; a missing result does not prove the call \
                                    did not run.
                                    """,
                                nextCall: Self.dispatchReceiptCall(turn: turn)),
                        ]),
                        isError: true, images: [LLMContentBlock](), publishedStart: true
                    )
                    let p = outcome.prepared
                    await onOutcome(p, outcome.result, outcome.publishedStart)
                    slots.append(DispatchedSlot(
                        prepared: p,
                        result: outcome.result, isError: outcome.isError, images: outcome.images
                    ))
                }
            }
        }
        return slots
    }

    nonisolated static func makeSlotOutputs(
        prepared: PreparedToolCall,
        result: JSONValue,
        isError: Bool,
        priorDispatches: [TurnEngineResult.ToolDispatchRecord],
        dataRoot: URL?,
        appDoor: Bool,
        tools: any ToolDispatchClient, surface: String, cancelFlagPath: URL?, turn: Turn, work: ChatTurnWork
    ) async -> (record: TurnEngineResult.ToolDispatchRecord, block: LLMContentBlock) {
        var result = result, isError = isError
        if turn.doorPreview == nil, turn.partID == nil, turn.act == nil, work.invocation.appDoor == nil, prepared.dispatchInput["preview"] != .bool(true) {
            (result, isError) = (try? await followDeterminedRead(result, isError: isError, asked: prepared.internalName, input: prepared.dispatchInput,
                turn: turn, priorDispatches: priorDispatches, cancelFlagPath: cancelFlagPath) { input, act in
                try await TurnTraceContext.$automaticOrigin.withValue("body") {
                    try await AppDoorReentry.call("app", input: input, surface: surface, turn: turn.with(\.act, act ?? turn.act),
                        invocation: work.invocation, tools: tools)
                }
            }) ?? (result, isError)
        }
        // Translate next calls to `app` only when the current request offers it.
        let translated = appDoor ? ToolNameAliases.appCallPointers(result) : result
        var reply = ToolResult(repeatedReceipt(translated, name: prepared.internalName, input: prepared.dispatchInput,
            priorDispatches: priorDispatches, appDoor: appDoor))
        let resultStr: String
        do {
            resultStr = try {
            // Persist the complete card above; the model only needs the skip.
            if let card = InlineInteractionNeed.interaction(in: reply.payload),
               !InlineInteractionNeed.blocksTurn(card),
               case .object(let object) = reply.payload,
               object["repeat"] == nil,
               case .string(let detail)? = object["detail"] {
                return detail
            }
            if case .string(let s) = reply.payload { return s }
            return try reply.payload.serialize(pretty: false)
            }()
        } catch {
            let failure = ToolFailureError("""
                \(prepared.internalName) returned a receipt that cannot be encoded: \(error.localizedDescription). Inspect its effect before \
                repeating it and repair its result producer.
                """,
                effects: reply.effects ?? .unknown, owner: prepared.ranCall.tool, code: "tool_result_encoding_failed", recovery: .reconcile)
            reply = ToolResult(repeatedReceipt(ChatToolOutcome.failure(error: failure, tool: prepared.internalName),
                name: prepared.internalName, input: prepared.dispatchInput, priorDispatches: priorDispatches, appDoor: appDoor))
            // The failure envelope contains only checked strings and the owner's effect evidence.
            if case .int(let count)? = reply.payload.objectValue?["repeat"],
               let note = reply.payload.objectValue?["repeat_note"]?.stringValue {
                resultStr = failure.message + "\nrepeat: \(count)\n" + note
            } else { resultStr = failure.message }
        }
        traceRepeatedReceipt(reply.payload, original: translated, tool: prepared.internalName, turn: turn)
        let record = TurnEngineResult.ToolDispatchRecord(id: prepared.pairedId, name: prepared.internalName,
            input: prepared.dispatchInput, ranCall: prepared.ranCall, result: reply.payload)
        let providerResultStr = await ProviderToolResultPage.project(
            toolName: prepared.ranCall.tool,
            content: resultStr,
            dataRoot: dataRoot,
            turn: turn,
            originalResultClass: reply.outcome,
            appDoor: appDoor, batchActions: prepared.dispatchInput["actions"]?.arrayValue
        )
        let block = LLMContentBlock.toolResult(
            toolUseId: prepared.pairedId, content: providerResultStr.content,
            isError: isError || reply.carriesFailureEvidence || providerResultStr.failed
        )
        return (record, block)
    }

    nonisolated(nonsending) package static func followDeterminedRead(_ result: JSONValue, isError: Bool, asked tool: String, input asked: [String: JSONValue], turn: Turn,
        priorDispatches: [TurnEngineResult.ToolDispatchRecord] = [], cancelFlagPath: URL? = nil,
        run: ([String: JSONValue], String?) async throws -> JSONValue) async throws -> (JSONValue, Bool) {
        var seen = Set<String>()
        if tool == "app", let exact = try? JSONValue.object(asked).serialize(pretty: false) { seen.insert(exact) }
        nonisolated(nonsending) func follow(_ result: JSONValue, isError: Bool, askedRead: Bool, called: JSONValue) async throws -> (JSONValue, Bool) {
            guard !dispatchCancelSignalled(cancelFlagPath), case .object(var fields) = result,
                  fields["has_more"] != .bool(true),
                  let next = fields["remedy"]?.objectValue?["next_call"]?.objectValue,
                  next["tool"] == .string("app"), let input = next["input"]?.objectValue, input["preview"] != .bool(true),
                  (try? AppToolExecutor.doorReadOnly(input, turn: turn)) == true,
                  let exact = try? JSONValue.object(input).serialize(pretty: false), seen.insert(exact).inserted else { return (result, isError) }
            let read: JSONValue
            if let earlier = (priorDispatches + (turn.execution?.toolRecords ?? [])).last(where: {
                $0.name == "app" && $0.input.filter { !$0.key.hasPrefix("__") } == input.filter { !$0.key.hasPrefix("__") }
            }) {
                var pointer = earlier.result.objectValue?.filter { ["status", "state", "reason", "effects", "dispatch_receipt_id", "dispatch_receipt_source"].contains($0.key) } ?? [:]
                pointer["status"] = .string(ToolResult(earlier.result).outcome == .unknown
                    ? pointer["status"]?.stringValue ?? "outcome_unknown" : ToolResult(earlier.result).outcome.receipt.status)
                pointer["repeat"] = .int(1)
                pointer["repeat_note"] = .string("This read already ran in this turn; use its earlier result "
                    + (pointer["dispatch_receipt_id"]?.stringValue ?? earlier.id ?? "for the same app input") + ".")
                read = .object(pointer)
            } else {
                do { read = try await run(input, fields["dispatch_receipt_id"]?.stringValue) }
                catch let error as CancellationError { throw error }
                catch { read = ChatToolOutcome.failure(error: error, tool: "app") }
                turn.execution?.keepTools([.init(name: "app", input: input, ranCall: ("app", input), result: read)])
            }
            let followed = try await follow(read,
                isError: !ChatToolOutcome.outputLooksSuccessful(read) && !ChatToolOutcome.isWaitingOnPerson(read), askedRead: true, called: .object(input))
            guard askedRead, fields["status"] == .string("refused"), fields["effects"] == .string("none") else {
                var remedy = fields["remedy"]?.objectValue ?? [:]
                remedy["next_call"] = .null
                remedy["instruction"] = .string([remedy["instruction"]?.stringValue, "The body already made that call; its result is next_result."]
                    .compactMap { $0 }.joined(separator: " "))
                fields["remedy"] = .object(remedy)
                if fields["next_call"] != nil { fields["next_call"] = .null }
                fields["next_result"] = followed.0
                return (.object(fields), isError)
            }
            var resolved = followed.0.objectValue ?? ["content": followed.0]
            resolved["argument_notes"] = .array([.object(["reason": fields["reason"] ?? .null, "called": called, "ran_as": .object(input)])]
                + (resolved["argument_notes"]?.arrayValue ?? []))
            resolved["resolved"] = input["action"] ?? .object(input)
            return (.object(resolved), followed.1)
        }
        return try await follow(result, isError: isError, askedRead: tool == "app" ? (try? AppToolExecutor.doorReadOnly(asked, turn: turn)) == true
            : (try? PermissionLaw.toolClass(tool, input: asked, turn: turn)) == .read,
            called: tool == "app" ? .object(asked) : .object(["tool": .string(tool), "input": .object(asked)]))
    }

    /// Resident and standing-bot returns read their turn's existing results through this one annotation owner.
    nonisolated static func repeatedReceipt(_ result: JSONValue, name: String, input: [String: JSONValue],
        priorDispatches: [TurnEngineResult.ToolDispatchRecord], appDoor: Bool) -> JSONValue {
        let answer = receiptAnswer(result)
        let repeats = priorDispatches.filter {
            $0.name == name && $0.input == input
                && receiptAnswer(appDoor ? ToolNameAliases.appCallPointers($0.result) : $0.result) == answer
        }.count
        guard repeats > 0 else { return result }
        var fields = result.objectValue ?? ["result": result, "repeat_wrapped_value": .bool(true),
            "status": .string(ToolResult(result).outcome.receipt.status)]
        fields["repeat"] = .int(Int64(repeats))
        fields["repeat_note"] = .string("Same call, same answer as your last \(repeats); nothing has changed.")
        return .object(fields)
    }

    nonisolated static func traceRepeatedReceipt(_ receipt: JSONValue, original: JSONValue, tool: String, turn: Turn) {
        guard let count = receipt.objectValue?["repeat"], receipt != original else { return }
        TurnTraceBus.fireFromContext(kind: "tool.receipt.repeat", payload: .object([
            "tool": .string(ChatSecretRedactor.redactText(tool)), "repeat": count]), turn: turn)
    }

    nonisolated private static func receiptAnswer(_ result: JSONValue) -> JSONValue {
        guard case .object(var fields) = result else { return result }
        if fields["repeat_wrapped_value"] == .bool(true), let value = fields["result"] { return receiptAnswer(value) }
        if fields["dispatch_receipt_source"] == .string("detail") {
            fields["dispatch_receipt_id"] = nil
            fields["dispatch_receipt_source"] = nil
        }
        if fields["ability_run"]?.objectValue != nil { fields["ability_run"] = nil }
        if fields["action"] != nil, case .object(var returned)? = fields["result"], returned["ability_run"]?.objectValue != nil {
            returned["ability_run"] = nil
            if returned["dispatch_receipt_source"] == .string("detail") {
                returned["dispatch_receipt_id"] = nil; returned["dispatch_receipt_source"] = nil
            }
            fields["result"] = .object(returned)
        }
        if case .int(let count)? = fields["repeat"],
           fields["repeat_note"] == .string("Same call, same answer as your last \(count); nothing has changed.") {
            fields["repeat"] = nil
            fields["repeat_note"] = nil
        }
        return .object(fields)
    }

    nonisolated static func runSingleDispatch<Value: Sendable>(
        prepared: PreparedToolCall, watchName: String, surface: String, tools: any ToolDispatchClient,
        imageSink: LocalToolImage.Sink?, turn: Turn, work: ChatTurnWork,
        executing: @escaping @Sendable (Turn, @escaping @Sendable () async throws -> JSONValue) async throws -> Value
    ) async throws -> Value {
        var notice: (@Sendable (String) async -> Void)?
        if let show = turn.notices { notice = { await show("call.stalled", $0) } }
        return try await CallBound.run(name: watchName, declared: CallBound.declaredSeconds(input: prepared.ranCall.input),
            deadlines: work.deadlines, enclosing: turn.enclosingCall, notice: notice) { deadlines, watch in
            let callTurn = turn.with(\.enclosingCall, watch).with(\.invocationID, prepared.invocationID)
            let invocation = work.with(\.deadlines, deadlines).with(\.imageSink, imageSink).invocation
            return try await executing(callTurn) {
                try await tools.dispatch(tool: prepared.requestedName, input: prepared.dispatchInput,
                    surface: surface, turn: callTurn, invocation: invocation)
            }
        }
    }

    nonisolated private static func runResidentDispatch(
        prepared: PreparedToolCall,
        surface: String,
        tools: any ToolDispatchClient,
        imageSink: LocalToolImage.Sink? = nil,
        cancelFlagPath: URL? = nil,
        turn: Turn,
        work: ChatTurnWork
    ) async -> (PreparedToolCall, JSONValue, Bool) {
        if Self.dispatchCancelSignalled(cancelFlagPath) {
            return (prepared, Self.cancelledToolResult(Self.spokenName(prepared)), true)
        }
        let outcomes = ContinuationOnce<Result<(PreparedToolCall, JSONValue, Bool), Error>>()
        let body = TurnBodyLifetime<(PreparedToolCall, JSONValue, Bool)>()
        let committedID = Mutex<String?>(nil)
        let stopped: @Sendable () -> (PreparedToolCall, JSONValue, Bool) = {
            (prepared, Self.interruptedToolResult(Self.spokenName(prepared), turn: turn,
                committedID: committedID.withLock { $0 }, abandonedCall: prepared), true)
        }
        let dispatchTool = ToolNameAliases.ranTool(prepared.internalName, input: prepared.dispatchInput)
        var invocation = work.toolInvocation
        // A folded call can report for its own tool. A child action cannot report its ID as the enclosing call's.
        invocation.reportCommittedID = { tool, id in
            if tool == dispatchTool { committedID.withLock { $0 = id } }
        }
        let dispatchWork = work.with(\.toolInvocation, invocation)
        // This subscription belongs to the actual body, not its response.
        // A Stop after timeout must still reach the original work.
        let watcher = cancelFlagPath.map { flag in
            FileChangeWatcher(paths: [flag]) { _ in
                if ChatCancelFlag.isRaised(flag) {
                    body.cancel()
                    outcomes.resume(.success(stopped()))
                }
            }
        }
        // An ended call (found dead, or past its own declared time) ends as Stop does: the body is
        // cancelled and keeps its tool and journal until they settle, even after this waiter returns.
        let dispatch = Task { () -> Bool in
            do {
                let actual = try await Self.runSingleDispatch(prepared: prepared, watchName: Self.spokenName(prepared),
                    surface: surface, tools: tools, imageSink: imageSink, turn: turn, work: dispatchWork) { callTurn, dispatch in
                    do {
                        return try await body.run {
                            defer { watcher?.cancel() }
                            return await Self.runSettlingDispatch(prepared: prepared, cancelFlagPath: cancelFlagPath,
                                turn: callTurn, journal: dispatchWork.journal, dispatch: dispatch,
                                committedID: { committedID.withLock { $0 } })
                        }
                    } catch {
                        watcher?.cancel()
                        throw error
                    }
                }
                return outcomes.resume(.success(actual))
            } catch {
                guard var receipt = CallBound.ended(error, name: Self.spokenName(prepared), nextCall: Self.settledDispatchRead(turn: turn)) else {
                    outcomes.resume(.failure(error))
                    return false
                }
                // Found dead or past its own declared time: ended as Stop ends it, the body keeping its own settlement.
                body.cancel()
                if case .object(var fields) = receipt {
                    fields["invocationID"] = .string(prepared.invocationID)
                    fields["callID"] = .string(prepared.pairedId)
                    receipt = .object(fields)
                }
                outcomes.resume(.success((prepared, receipt, true)))
                return false
            }
        }
        let settlementID = UUID()
        Self.dispatchSettlements.withLock { pending in
            pending[settlementID] = (Self.spokenName(prepared), Task {
                let delivered = await dispatch.value
                let finished = await body.finish()
                watcher?.cancel()
                if !delivered, case .success(let actual)? = finished {
                    await TurnSettle.recordDispatch(actual.0, result: actual.1, surface: surface, turn: turn)
                }
                Self.dispatchSettlements.withLock { $0[settlementID] = nil }
            })
        }
        if Self.dispatchCancelSignalled(cancelFlagPath) {
            body.cancel()
            outcomes.resume(.success(stopped())) { dispatch.cancel() }
        }
        let result = await withTaskCancellationHandler {
            await outcomes.wait()
        } onCancel: {
            body.cancel()
            outcomes.resume(.success(stopped())) { dispatch.cancel() }
        }
        switch result {
        case .success(let actual): return actual
        case .failure(let error) where error is CancellationError:
            return stopped()
        case .failure(let error):
            var result = ChatToolOutcome.failure(error: error, tool: prepared.internalName)
            if case .object(var fields) = result {
                fields["invocationID"] = .string(prepared.invocationID)
                fields["callID"] = .string(prepared.pairedId)
                result = .object(fields)
            }
            return (prepared, result, true)
        }
    }

    /// Only the actual body closes its checkpoint. A caller timeout never
    /// supplies a fabricated terminal receipt to this owner.
    nonisolated private static func runSettlingDispatch(
        prepared: PreparedToolCall,
        cancelFlagPath: URL?, turn: Turn, journal: DeskContinuationTurn?,
        dispatch: @Sendable () async throws -> JSONValue, committedID: @Sendable () -> String?
    ) async -> (PreparedToolCall, JSONValue, Bool) {
        var prepared = prepared
        prepared.ranCall = ToolNameAliases.ranCall(prepared.internalName, input: prepared.dispatchInput)
        var step: DeskContinuation.Step
        do { step = try Self.checkpointStep(prepared, turn: turn) }
        catch {
            return (prepared, ChatToolOutcome.failure(error: ToolFailureError(
                """
                    The action's input cannot be encoded for its continuation: \(error.localizedDescription). Correct its producing call before \
                    execution.
                    """, effects: .none,
                owner: prepared.ranCall.tool, code: "tool_input_encoding_failed", recovery: .repair), tool: prepared.internalName), true)
        }
        do {
            step = try await journal?.begin(step, peerSources: turn.peerSteering?.checkpointSources ?? []) ?? step
        } catch {
            return (prepared, .object(["status": .string("failed"), "effects": .string("none"),
                "not_run_status": .string("continuation_refused"), "reason": .string("continuation_begin_failed"),
                "stage": .string("begin"), "proposed_step_id": .string(step.id),
                "detail": .string("The continuation journal could not admit this call: \(error.localizedDescription). The action did not start."),
                "remedy": Repair.reconcile(
                    instruction: "Read the Desk continuation and its journal error before proposing more work; this call has no effects to repeat.",
                    nextCall: .object(["tool": .string("app"), "input": .object(["page": .string("desk")])]))]), true)
        }
        var outcome = await runCheckpointedDispatchBody(prepared: prepared, cancelFlagPath: cancelFlagPath,
            turn: turn, dispatch: dispatch)
        // A nested cancellation can return before the committed action finishes its lookup.
        let dispatched = ToolResult(outcome.0)
        if dispatched.outcome == .cancelled, dispatched.effects == .unknown, let id = committedID() {
            outcome = (Self.interruptedToolResult(Self.spokenName(prepared), turn: turn, committedID: id), true)
        }
        guard let journal else { return (prepared, outcome.0, outcome.1) }
        let reply = ToolResult(outcome.0)
        let object: [String: JSONValue]
        if case .object(let fields) = outcome.0 { object = fields } else { object = [:] }
        let owner: String?
        let ran = prepared.ranCall.tool
        if ran == "bot_run_once", object["requestId"]?.stringValue != nil { owner = "helper" }
        else { owner = nil }
        // Settled on the receipt's own evidence, never on how the tool is spelled.
        let settled = ChatToolOutcome.neverRan(reply.payload) || reply.effects == ToolFailureError.Effects.none
            || (owner == nil && !ChatToolOutcome.isWaitingOnPerson(reply.payload, verdict: reply.outcome)
                && !DeskContinuation.receiptIsUnresolved(outcome.0)
                && ![.running, .timedOut, .effectUnconfirmed].contains(MacControlReceiptOutcome.projecting(envelope: outcome.0)))
        do {
            let json = try outcome.0.serialize(pretty: false)
            let savedResult = String(SwiftNativeChatOrchestrationClient.redactedPersistedToolResult(tool: ran, json: json, turn: turn).prefix(512))
            let savedStep = step, ownerID = object["id"]?.stringValue, requestID = object["requestId"]?.stringValue
            let peerSources = turn.peerSteering?.checkpointSources ?? []
            let saved = await settle { () -> Result<Void, Error> in
                do {
                    try await journal.settle(savedStep, result: savedResult, settled: settled,
                        owner: owner, ownerID: ownerID, requestID: requestID, peerSources: peerSources)
                    return .success(())
                } catch { return .failure(error) }
            }
            try saved.get()
        } catch {
            return (prepared, .object(["status": .string("failed"),
                "effects": object["effects"] ?? .string(ChatToolOutcome.neverRan(outcome.0) ? "none" : "unknown"),
                "reason": .string("continuation_settlement_failed"), "stage": .string("settlement"),
                "step_id": .string(step.id), "receipt": outcome.0,
                "detail": .string("""
                    The action returned, but its continuation journal could not record settlement: \(error.localizedDescription). The returned \
                    receipt remains evidence of its effects.
                    """),
                "remedy": Repair.reconcile(instruction: """
                    Use the retained receipt and inspect the affected state before repeating the action; read the Desk continuation to resolve its \
                    journal error.
                    """,
                    nextCall: .object(["tool": .string("app"), "input": .object(["page": .string("desk")])]))]), true)
        }
        return (prepared, outcome.0, outcome.1)
    }

    /// Checkpoints retain bounded redacted summaries and verifier references; whole-file writes use path and digest, never content.
    /// Digest the exact effect so a re-proposal identifies the same step.
    nonisolated private static func checkpointStep(_ prepared: PreparedToolCall, turn: Turn) throws -> DeskContinuation.Step {
        let json = try JSONValue.object(prepared.dispatchInput).serialize(pretty: false)
        let input = String(SwiftNativeChatOrchestrationClient.redactedPersistedToolInput(
            tool: prepared.internalName, json: json, turn: turn).prefix(512))
        let ran = prepared.ranCall.tool
        let ranInput = prepared.ranCall.input
        var reference: [String: JSONValue]?
        if ran == "write_file", ranInput["append"] != .bool(true),
           case .string(let path)? = ranInput["path"],
           case .string(let content)? = ranInput["content"] {
            reference = ["path": .string(path), "bytes": .int(Int64(content.utf8.count)),
                         "sha256": .string(SHA256Hex.of(Data(content.utf8)))]
        }
        let exact = try JSONValue.object(ranInput).serialize(pretty: false)
        return DeskContinuation.Step(id: UUID().uuidString, tool: ran, input: input, reference: reference,
            effect: SHA256Hex.of(Data((ran + "\n" + exact).utf8)))
    }

    nonisolated static func runCheckpointedDispatchBody(
        prepared: PreparedToolCall, cancelFlagPath: URL?, turn: Turn,
        dispatch: @Sendable () async throws -> JSONValue
    ) async -> (JSONValue, Bool) {
        if Self.dispatchCancelSignalled(cancelFlagPath) {
            return (Self.cancelledToolResult(Self.spokenName(prepared)), true)
        }
        do {
            let result = try await dispatch()
            // Use the shared outcome classification for nonthrowing failure envelopes as well as thrown errors.
            // A raised need is waiting, not failure, so both boundaries must keep its provider error bit clear.
            let reply = ToolResult(result)
            if InlineInteractionNeed.isWaiting(result) { return (result, false) }
            if ChatToolOutcome.isToolHandBack(result) { return (result, false) }
            return (ChatToolOutcome.normalizedFailure(reply.payload, tool: prepared.internalName),
                !ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome))
        } catch is CancellationError {
            // Stop interrupts an already-dispatched call; effects may exist, so this is neither failure nor "was not run".
            return (Self.interruptedToolResult(Self.spokenName(prepared), turn: turn), true)
        } catch {
            return (ChatToolOutcome.failure(error: error, tool: prepared.internalName), true)
        }
    }

    private nonisolated static func isConnectorRead(_ name: String) -> Bool {
        connectorID(name) != nil
    }

    private nonisolated static func connectorID(_ name: String) -> String? {
        name.hasPrefix("mail_") ? "mail" : nil
    }
}
