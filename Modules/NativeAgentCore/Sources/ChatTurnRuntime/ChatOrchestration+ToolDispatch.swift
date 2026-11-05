import ApprovalInbox
import ChatToolParsing
import CryptoKit
import Foundation
import NativeAgentShared
import Desk
import MacControl
import Dispatcher
import NativeAgentCore
import PersistenceCore
import ToolRegistry
import TurnTrace
import Transcripts
import ProviderRouting
import Context
// Blueprint: | `ChatOrchestration+ToolDispatch.swift` | Offered-call admission; deadlines end only the wait |

extension SwiftNativeTurnEngine {
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
    /// Emit starts in index order, dispatch concurrently within the cap, then emit records and results in index order.
    /// Slot errors remain local; turn cancellation cancels all children.
    func dispatchIterationCalls(
        providerCalls: [ParsedToolCall],
        pairedIds: [String],
        providerTools: ProviderToolNameMap,
        priorDispatches: [TurnEngineResult.ToolDispatchRecord],
        modelId: String,
        surface: String,
        sessionId: String?,
        personaID: String? = nil,
        fluidContextTurn: ContextPreparedTurn? = nil,
        tools: any ToolDispatchClient,
        progress: ToolProgress?,
        cancelFlagPath: URL? = nil,
        /// The marker protocol returns results as text, so a text result's
        /// lines are kept from posing as another result block or a tool call.
        neutralizingTextResults: Bool = false,
        turn: Turn, work: ChatTurnWork
    ) async -> (blocks: [LLMContentBlock], records: [TurnEngineResult.ToolDispatchRecord]) {
        let planned: [(call: PreparedToolCall, offered: Bool, input: [String: JSONValue], undeclared: [String])] = providerCalls
            .enumerated().compactMap { i, call in
                guard !ToolCallParser.isIgnorableToolName(call.name) else { return nil }
                let requestedName = providerTools.internalName(forProviderName: call.name)
                let internalName = CanonicalToolNameDispatcher.canonical(requestedName)
                let input = Self.inputWithSessionIfNeeded(toolName: internalName, input: call.input, sessionId: sessionId)
                let prepared = PreparedToolCall(
                    pairedId: i < pairedIds.count ? pairedIds[i] : call.id,
                    requestedName: requestedName,
                    internalName: internalName,
                    dispatchInput: input,
                    ranCall: ToolNameAliases.ranCall(internalName, input: input)
                )
                // Every model call requires an offered descriptor. Internal app re-entry
                // has its own checked gate and never passes through this provider layer.
                let refusal = Self.modelCallRefusal(name: internalName, input: call.input,
                    undeclaredKeys: call.undeclaredKeys, providerTools: providerTools)
                return (prepared, refusal == nil, call.input, call.undeclaredKeys)
            }
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
        let prepared = planned.filter { $0.offered && claimed[$0.call.pairedId] == nil }.map(\.call)
        let slots = await Self.runIterationDispatchGroups(
            prepared: prepared,
            modelId: modelId,
            surface: surface,
            personaID: personaID,
            fluidContextTurn: fluidContextTurn,
            tools: tools,
            progress: progress,
            cancelFlagPath: cancelFlagPath,
            onToolUse: { p in
                await progress?(.toolUse(name: p.internalName, input: .object(p.dispatchInput)),
                    invocationID: p.invocationID)
            },
            onOutcome: { p, result in
                let reply = ToolResult(result)
                let receipt = ToolReceipt(turn: turn.with(\.invocationID, p.invocationID),
                    checkpoint: work.checkpoint, invocationID: p.invocationID,
                    toolName: p.internalName, input: ChatSecretRedactor.redactValue(.object(p.dispatchInput)),
                    ranCall: p.ranCall, output: ChatSecretRedactor.redactValue(result),
                    ok: ChatToolOutcome.outputLooksSuccessful(reply.payload, verdict: reply.outcome), cognitiveOutput: reply.payload)
                await progress?(.toolResult(name: p.internalName, output: result), receipt: receipt,
                    invocationID: p.invocationID)
            },
            turn: turn, work: work)

        // Reassemble every call's one result in original order to preserve wire pairing, including refused slots.
        var slotIterator = slots.makeIterator()
        // Only a request that offers app hears next calls as app calls; a
        // membrane's own catalog (studio wander) calls tools by name.
        let appDoor = providerTools.providerName(forInternalName: "app") != nil
        var blocks: [LLMContentBlock] = []
        var records: [TurnEngineResult.ToolDispatchRecord] = []
        var images: [LLMContentBlock] = []
        blocks.reserveCapacity(planned.count)
        records.reserveCapacity(planned.count)
        for entry in planned {
            let out: (record: TurnEngineResult.ToolDispatchRecord, block: LLMContentBlock)
            if entry.offered, let receipt = claimed[entry.call.pairedId] {
                let reply = ToolResult(receipt)
                out = await Self.makeSlotOutputs(prepared: entry.call, result: reply.payload,
                    isError: reply.carriesFailureEvidence,
                    sessionId: sessionId, neutralizingText: neutralizingTextResults, appDoor: appDoor,turn: turn)
            } else if entry.offered {
                guard let slot = slotIterator.next() else { continue }
                images.append(contentsOf: slot.images)
                out = await Self.makeSlotOutputs(
                    prepared: slot.prepared,
                    result: slot.result,
                    isError: slot.isError,
                    sessionId: sessionId,
                    neutralizingText: neutralizingTextResults,
                    appDoor: appDoor,
                turn: turn)
            } else {
                out = await Self.makeSlotOutputs(
                    prepared: entry.call,
                    result: entry.undeclared.isEmpty
                        ? Self.notOfferedToolResult(entry.call.internalName, input: entry.input)
                        : Self.undeclaredFieldsResult(entry.call.internalName, keys: entry.undeclared),
                    isError: true,
                    sessionId: sessionId,
                    appDoor: appDoor,
                turn: turn)
                ChatToolDispatchTracer.traceUndispatched(turn: turn, tool: entry.call.internalName, input: entry.call.dispatchInput,
                                                         surface: surface, result: out.record.result)
            }
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

    /// A started call retains uncertain effects after Stop; inspect before repeating it.
    nonisolated static func interruptedToolResult(_ name: String, turn: Turn) -> JSONValue {
        let message = "tool '\(name)' was stopped: the turn was stopped after "
            + "the call had already started, so whether it took effect is unknown. "
            + "Check before repeating it."
        return .object([
            "status": .string("cancelled"),
            "execution": .string("attempted"),
            "error": .string(message),
            "reason": .string("interrupted_after_start"),
            "effects": .string("unknown"),
            "remedy": Repair.reconcile(
                instruction: "Read this turn's dispatch receipts, then inspect the affected state for any unconfirmed effect before repeating the action.",
                nextCall: dispatchReceiptCall(turn: turn)),
        ])
    }

    /// The current turn's recorded outcomes, without asserting an unrecorded effect.
    nonisolated static func dispatchReceiptCall(turn: Turn) -> JSONValue {
        var args: [String: JSONValue] = ["kind": .string("tool.dispatch"), "view": .string("receipts")]
        args["turn_id"] = .string(turn.id)
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
        .object([
            "error": .string("\(name) takes no \(keys.joined(separator: ", ")), so this block was not run. "
                + "To call \(name), use only its own parameters."),
            "status": .string("skipped"),
            "reason": .string("undeclared_call_fields"),
            "effects": .string("none"),
            "remedy": .object(["kind": .string("correct_arguments"),
                "instruction": .string("Find the action's accepted parameters, then remove the undeclared fields."),
                "next_call": .object(["tool": .string("app"), "input": .object(["find": .string(name)])])]),
        ])
    }

    /// Ordered dispatch outcomes; the caller owns result-block and transcript formatting.
    struct DispatchedSlot: Sendable {
        let prepared: PreparedToolCall
        let result: JSONValue
        let isError: Bool
        let images: [LLMContentBlock]
    }

    /// Preserve original slot order and the held turn through bounded dispatch groups.
    /// Slot failures never cancel siblings; turn cancellation cancels all children.
    /// Check task and on-disk Stop before each dispatch; skipped slots still retain event/result pairing.
    nonisolated static func runIterationDispatchGroups(
        prepared: [PreparedToolCall],
        modelId: String,
        surface: String,
        personaID: String? = nil,
        fluidContextTurn: ContextPreparedTurn? = nil,
        tools: any ToolDispatchClient,
        progress: ToolProgress?,
        cancelFlagPath: URL? = nil,
        onToolUse: @Sendable (PreparedToolCall) async -> Void,
        onOutcome: @Sendable (PreparedToolCall, JSONValue) async -> Void,
        turn: Turn,
    work: ChatTurnWork) async -> [DispatchedSlot] {
        // A folded `app` action is judged as the tool it runs: its parallel
        // class, its pixels and whether it is a send are that tool's.
        let ran = prepared.map { $0.ranCall.tool }
        let baseSafe = prepared.map {
            !Self.isConnectorRead($0.ranCall.tool) && ParallelToolDispatch.isParallelSafe(internalToolName: $0.ranCall.tool, input: $0.ranCall.input,
                turn: turn)
        }
        let groups = ParallelToolDispatch.plan(
            parallelSafe: baseSafe,
            forceSerial: StandingBotContinuity.isHelperTurn(turn: turn) || ParallelToolDispatch.effectiveForceSerial
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
                await onToolUse(p)
                if Self.dispatchCancelSignalled(cancelFlagPath) {
                    let cancelled = Self.cancelledToolResult(Self.spokenName(p))
                    await onOutcome(p, cancelled)
                    slots.append(DispatchedSlot(
                        prepared: p, result: cancelled, isError: true, images: []
                    ))
                    continue
                }
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
                    await onOutcome(p, result)
                    slots.append(DispatchedSlot(prepared: p,
                                                result: result, isError: true, images: []))
                    continue
                }
                let imageSink = imageIndices.contains(idx) ? LocalToolImage.Sink(round: imageRound) : nil
                let (dispatched, result, isError) = await Self.runSingleDispatch(
                    prepared: p, modelId: modelId, surface: surface,
                    personaID: personaID,
                    fluidContextTurn: fluidContextTurn,
                    tools: tools, progress: progress, imageSink: imageSink,
                    cancelFlagPath: cancelFlagPath,
                 turn: turn,work: work)
                await onOutcome(dispatched, result)
                slots.append(DispatchedSlot(
                    prepared: dispatched, result: result, isError: isError,
                    images: imageSink?.finish(success: !isError && !Task.isCancelled) ?? []
                ))

            case .concurrent(let indices):
                // Emit starts in index order so progress stays deterministic despite arbitrary completion order.
                for idx in indices {
                    await onToolUse(prepared[idx])
                }
                var outcomes: [Int: (prepared: PreparedToolCall, result: JSONValue, isError: Bool, images: [LLMContentBlock])] = [:]
                await withTaskGroup(
                    of: (Int, PreparedToolCall, JSONValue, Bool, [LLMContentBlock]).self
                ) { taskGroup in
                    var iterator = indices.makeIterator()
                    func addNext(turn: Turn) -> Bool {
                        while let idx = iterator.next() {
                            let p = prepared[idx]
                            // Stop reached this slot before it started: record the
                            // cancelled outcome and keep draining, so no further
                            // dispatch is ever handed to `tools`.
                            if Self.dispatchCancelSignalled(cancelFlagPath) {
                                outcomes[idx] = (p, Self.cancelledToolResult(Self.spokenName(p)), true, [])
                                continue
                            }
                            taskGroup.addTask {
                                let imageSink = imageIndices.contains(idx) ? LocalToolImage.Sink(round: imageRound) : nil
                                let (dispatched, result, isError) = await Self.runSingleDispatch(
                                    prepared: p, modelId: modelId, surface: surface,
                                    personaID: personaID,
                                    fluidContextTurn: fluidContextTurn,
                                    tools: tools, progress: progress, imageSink: imageSink,
                                    cancelFlagPath: cancelFlagPath,
                                 turn: turn,work: work)
                                return (idx, dispatched, result, isError, imageSink?.finish(success: !isError && !Task.isCancelled) ?? [])
                            }
                            return true
                        }
                        return false
                    }
                    var started = 0
                    while started < ParallelToolDispatch.maxConcurrentPerIteration, addNext(turn: turn) {
                        started += 1
                    }
                    while let (idx, dispatched, result, isError, images) = await taskGroup.next() {
                        outcomes[idx] = (dispatched, result, isError, images)
                        _ = addNext(turn: turn)
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
                        isError: true, images: [LLMContentBlock]()
                    )
                    let p = outcome.prepared
                    await onOutcome(p, outcome.result)
                    slots.append(DispatchedSlot(
                        prepared: p,
                        result: outcome.result, isError: outcome.isError, images: outcome.images
                    ))
                }
            }
        }
        return slots
    }

    /// Pure slot finalization redacts tool results before provider delivery without mutable cross-task captures.
    nonisolated static func makeSlotOutputs(
        prepared: PreparedToolCall,
        result: JSONValue,
        isError: Bool,
        sessionId: String? = nil,
        neutralizingText: Bool = false,
        appDoor: Bool,
    turn: Turn) async -> (record: TurnEngineResult.ToolDispatchRecord, block: LLMContentBlock) {
        // Translate next calls to `app` only when the current request offers it.
        var reply = ToolResult(appDoor ? ToolNameAliases.appCallPointers(result) : result)
        let resultStr: String
        do {
            resultStr = try {
            // Persist the complete card above; the model only needs the skip.
            if let card = InlineInteractionNeed.interaction(in: reply.payload),
               !InlineInteractionNeed.blocksTurn(card),
               case .object(let object) = reply.payload,
               case .string(let detail)? = object["detail"] {
                return neutralizingText ? UntrustedText.neutralized(detail) : detail
            }
            if case .string(let s) = reply.payload { return neutralizingText ? UntrustedText.neutralized(s) : s }
            return try reply.payload.serialize(pretty: false)
            }()
        } catch {
            let failure = ToolFailureError("""
                \(prepared.internalName) returned a receipt that cannot be encoded: \(error.localizedDescription). Inspect its effect before \
                repeating it and repair its result producer.
                """,
                effects: reply.effects ?? .unknown, owner: prepared.ranCall.tool, code: "tool_result_encoding_failed", recovery: .reconcile)
            reply = ToolResult(ChatToolOutcome.failure(error: failure, tool: prepared.internalName))
            // The failure envelope contains only checked strings and the owner's effect evidence.
            resultStr = failure.message
        }
        let record = TurnEngineResult.ToolDispatchRecord(id: prepared.pairedId, name: prepared.internalName,
            input: prepared.dispatchInput, ranCall: prepared.ranCall, result: reply.payload)
        let redactedResultStr = ChatSecretRedactor.redactText(resultStr)
        let providerResultStr = await ProviderToolResultPage.project(
            toolName: prepared.ranCall.tool,
            content: redactedResultStr,
            sessionId: sessionId,
            turnId: turn.id,
            originalResultClass: reply.outcome,
            appDoor: appDoor
        )
        let block = LLMContentBlock.toolResult(
            toolUseId: prepared.pairedId, content: providerResultStr, isError: isError || reply.carriesFailureEvidence
        )
        return (record, block)
    }

    nonisolated static func runSingleDispatch(
        prepared: PreparedToolCall,
        modelId: String,
        surface: String,
        personaID: String? = nil,
        fluidContextTurn: ContextPreparedTurn? = nil,
        tools: any ToolDispatchClient,
        progress: ToolProgress?,
        imageSink: LocalToolImage.Sink? = nil,
        cancelFlagPath: URL? = nil,
        turn: Turn,
    work: ChatTurnWork) async -> (PreparedToolCall, JSONValue, Bool) {
        if Self.dispatchCancelSignalled(cancelFlagPath) {
            return (prepared, Self.cancelledToolResult(Self.spokenName(prepared)), true)
        }
        let nanos = ToolDispatchDeadline.timeoutNanos(toolName: prepared.ranCall.tool,
            input: prepared.ranCall.input, surface: surface)
        let seconds = Double(nanos) / 1_000_000_000
        let outcomes = ContinuationOnce<Result<(PreparedToolCall, JSONValue, Bool), Error>>()
        let body = TurnBodyLifetime<(PreparedToolCall, JSONValue, Bool)>()
        // This subscription belongs to the actual body, not its response.
        // A Stop after timeout must still reach the original work.
        let watcher = cancelFlagPath.map { flag in
            FileChangeWatcher(paths: [flag]) { _ in
                if ChatCancelFlag.isRaised(flag) {
                    body.cancel()
                    outcomes.resume(.failure(CancellationError()))
                }
            }
        }
        // The deadline owns only the response. Its child retains the actual
        // tool and journal until they settle, even after this waiter returns.
        let dispatch = Task {
            let operation: @Sendable (OperationDeadlines) async throws -> (PreparedToolCall, JSONValue, Bool) = { deadlines in
                do {
                    return try await body.run {
                        defer { watcher?.cancel() }
                        let actual = await Self.runSettlingDispatch(prepared: prepared, modelId: modelId, surface: surface,
                            personaID: personaID, fluidContextTurn: fluidContextTurn, tools: tools, progress: progress,
                            imageSink: imageSink, cancelFlagPath: cancelFlagPath, turn: turn, work: work.with(\.deadlines, deadlines))
                        TurnTraceBus.fireFromContext(kind: "tool.dispatch.settled", surface: surface, payload: .object([
                            "invocationID": .string(prepared.invocationID), "callID": .string(prepared.pairedId),
                            "tool": .string(actual.0.ranCall.tool),
                            "receipt": ChatSecretRedactor.redactValue(actual.1),
                        ]), turn: turn)
                        return actual
                    }
                } catch {
                    watcher?.cancel()
                    throw error
                }
            }
            do {
                let actual: (PreparedToolCall, JSONValue, Bool)
                if nanos > 0 {
                    actual = try await TurnDeadline.withThrowingDeadline(seconds: seconds, cancelWorkOnExpiry: false, deadlines: work.deadlines, operation)
                } else { actual = try await operation(work.deadlines) }
                outcomes.resume(.success(actual))
            } catch is TurnDeadline.DeadlineExceeded {
                outcomes.resume(.failure(ToolDispatchDeadline.timeoutError(tool: Self.spokenName(prepared), seconds: seconds)))
            } catch { outcomes.resume(.failure(error)) }
        }
        if Self.dispatchCancelSignalled(cancelFlagPath) {
            body.cancel()
            outcomes.resume(.failure(CancellationError())) { dispatch.cancel() }
        }
        let result = await withTaskCancellationHandler {
            await outcomes.wait()
        } onCancel: {
            body.cancel()
            outcomes.resume(.failure(CancellationError())) { dispatch.cancel() }
        }
        switch result {
        case .success(let actual): return actual
        case .failure(let error) where error is CancellationError:
            return (prepared, Self.interruptedToolResult(Self.spokenName(prepared), turn: turn), true)
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
        modelId: String,
        surface: String,
        personaID: String? = nil,
        fluidContextTurn: ContextPreparedTurn? = nil,
        tools: any ToolDispatchClient,
        progress: ToolProgress?,
        imageSink: LocalToolImage.Sink? = nil,
        cancelFlagPath: URL? = nil,
        turn: Turn, work: ChatTurnWork
    ) async -> (PreparedToolCall, JSONValue, Bool) {
        var prepared = prepared
        prepared.ranCall = ToolNameAliases.ranCall(prepared.internalName, input: prepared.dispatchInput)
        let journal = work.journal
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
        let outcome = await runCheckpointedDispatchBody(prepared: prepared, modelId: modelId, surface: surface,
            personaID: personaID, fluidContextTurn: fluidContextTurn, tools: tools, progress: progress,
            imageSink: imageSink, cancelFlagPath: cancelFlagPath, turn: turn, work: work)
        guard let journal else { return (prepared, outcome.0, outcome.1) }
        let reply = ToolResult(outcome.0)
        let object: [String: JSONValue]
        if case .object(let fields) = outcome.0 { object = fields } else { object = [:] }
        func text(_ key: String) -> String? {
            if case .string(let value)? = object[key] { return value }
            return nil
        }
        let owner: String?
        let ran = prepared.ranCall.tool
        if ran == "bot_run_once", text("requestId") != nil { owner = "helper" }
        else { owner = nil }
        // Settled on the receipt's own evidence, never on how the tool is spelled.
        let settled = ChatToolOutcome.neverRan(reply.payload) || reply.effects == ToolFailureError.Effects.none
            || (owner == nil && !ChatToolOutcome.isWaitingOnPerson(reply.payload, verdict: reply.outcome)
                && !DeskContinuation.receiptIsUnresolved(outcome.0)
                && ![.running, .timedOut, .effectUnconfirmed].contains(MacControlReceiptOutcome.projecting(envelope: outcome.0)))
        do {
            let json = try outcome.0.serialize(pretty: false)
            let savedResult = String(SwiftNativeChatOrchestrationClient.redactedPersistedToolResult(tool: ran, json: json, turn: turn).prefix(512))
            let savedStep = step, ownerID = text("id"), requestID = text("requestId")
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
                         "sha256": .string(SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined())]
        }
        let exact = try JSONValue.object(ranInput).serialize(pretty: false)
        return DeskContinuation.Step(id: UUID().uuidString, tool: ran, input: input, reference: reference,
            effect: SHA256.hash(data: Data((ran + "\n" + exact).utf8)).map { String(format: "%02x", $0) }.joined())
    }

    nonisolated static func runCheckpointedDispatchBody(
        prepared: PreparedToolCall, modelId: String, surface: String, personaID: String? = nil,
        fluidContextTurn: ContextPreparedTurn? = nil, tools: any ToolDispatchClient,
        progress: ToolProgress?, imageSink: LocalToolImage.Sink? = nil,
        cancelFlagPath: URL? = nil,
        turn: Turn, work: ChatTurnWork
    ) async -> (JSONValue, Bool) {
        if Self.dispatchCancelSignalled(cancelFlagPath) {
            return (Self.cancelledToolResult(Self.spokenName(prepared)), true)
        }
        do {
            let result = try await holding(work.with(\.imageSink, imageSink)) { work in
            try await holding(work.with(\.preparedContext, fluidContextTurn)) { work in
            try await holding(turn.with(\.runtime, .init(
                    model: modelId,
                    surface: surface,
                    personaID: personaID,
                    providerID: turn.admission?.provider
                ))) { turn in
                try await holding(turn.with(\.notices, { kind, text in
                    await progress?(.notice(kind: kind, text: text))
                })) { turn in
                    try Task.checkCancellation()
                    if Self.dispatchCancelSignalled(cancelFlagPath) { throw CancellationError() }
                    return try await tools.dispatch(tool: prepared.requestedName,
                        input: prepared.dispatchInput, surface: surface, turn: turn, invocation: work.invocation)
                }
            }
            }
            }
            // Use the shared outcome classification for nonthrowing failure envelopes as well as thrown errors.
            // A raised need is waiting, not failure, so both boundaries must keep its provider error bit clear.
            let reply = ToolResult(result)
            if InlineInteractionNeed.isWaiting(result) { return (result, false) }
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

    private nonisolated static func inputWithSessionIfNeeded(
        toolName: String,
        input: [String: JSONValue],
        sessionId: String?
    ) -> [String: JSONValue] {
        ChatToolSessionInjection.apply(toolName: toolName, input: input, sessionId: sessionId)
    }
}
