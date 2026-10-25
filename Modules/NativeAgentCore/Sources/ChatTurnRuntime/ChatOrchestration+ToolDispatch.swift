import ApprovalInbox
import ChatToolParsing
import CryptoKit
import Foundation
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
// Blueprint: | `ChatOrchestration+ToolDispatch.swift` | Shared per-iteration tool dispatch and refusal of unoffered folded calls |

extension SwiftNativeTurnEngine {
    // MARK: - Per-iteration dispatch (shared by both loops; U1 step 6)

    /// One provider call, prepared for dispatch. Built up-front so
    /// task-group children capture only Sendable value types (plus the
    /// Sendable `tools` / `progress` references) — never the conversation
    /// array or any actor state.
    struct PreparedToolCall: Sendable {
        let pairedId: String
        /// The spelling the model called, handed to the chain as-is so its
        /// canonicalizer resolves the same tool she named.
        let requestedName: String
        /// Its canonical name (ToolNameAliases): the one name the pill, the
        /// receipt and the records below read.
        let internalName: String
        let dispatchInput: [String: JSONValue]
        /// Planning identity; refreshed when execution starts, then carried unchanged.
        var ranCall: (tool: String, input: [String: JSONValue])
    }

    /// Execute ONE iteration's batch of tool calls and return the
    /// tool_result blocks + dispatch records in ORIGINAL INDEX ORDER.
    ///
    /// This is the single implementation behind both the non-streaming and
    /// streaming loops, so the serial/parallel split cannot drift between
    /// them. The planning + concurrency window itself lives one level down in
    /// `runIterationDispatchGroups`.
    /// Semantics preserved from the serial code, per slot:
    ///   .toolUse progress → dispatch (notice bus + runtime ctx bound) →
    ///   record → .toolResult progress → redact → tool_result block.
    /// For a `.concurrent` group the .toolUse events for the whole group are
    /// emitted first (in index order), children dispatch concurrently
    /// (cap: ParallelToolDispatch.maxConcurrentPerIteration; notices stream
    /// live), then records/.toolResult events/blocks are emitted in index
    /// order after the group completes. Errors never escape a slot: a
    /// throwing tool yields that slot's {"error": ...} result exactly as the
    /// serial path would, and never cancels siblings. Turn cancellation
    /// cancels all in-flight children (structured task group).
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
        progress: ChatOrchestrationProgressHandler?,
        cancelFlagPath: URL? = nil,
        /// The marker protocol returns results as text, so a text result's
        /// lines are kept from posing as another result block or a tool call.
        neutralizingTextResults: Bool = false
    ) async -> (blocks: [LLMContentBlock], records: [TurnEngineResult.ToolDispatchRecord]) {
        let planned: [(call: PreparedToolCall, offered: Bool, input: [String: JSONValue], undeclared: [String])] = providerCalls
            .enumerated().compactMap { i, call in
                guard !ToolCallParser.isIgnorableToolName(call.name, recordShim: true) else { return nil }
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
                // A folded, merged or retired tool is app's now: called by
                // name where this request never declared it, it runs nothing
                // (`notOfferedToolResult`). The door's own re-entry (home runs
                // as `workspace`) never passes here, so it still runs.
                let folded = ToolNameAliases.isAppDoorName(internalName)
                    && providerTools.providerName(forInternalName: internalName) == nil
                return (prepared, call.undeclaredKeys.isEmpty && !folded, call.input, call.undeclaredKeys)
            }
        // One execution claim per effect: a call this turn put on an approval
        // card is that card's to run while it is undecided; after the decision
        // it answers one re-proposal with the card's receipt, and an identical
        // call after that is a fresh invocation through the gate.
        var answered: Set<String> = []
        let claimed: [String: JSONValue] = planned.reduce(into: [:]) { claims, entry in
            guard let receipt = cardClaim(on: entry.call, priorDispatches: priorDispatches) else { return }
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
                await progress?(.toolUse(name: p.internalName, input: .object(p.dispatchInput)))
            },
            onOutcome: { p, result, _ in
                await ToolReceipt.$dispatchedCall.withValue(p.ranCall) {
                    await progress?(.toolResult(name: p.internalName, output: result))
                }
            }
        )

        // Re-interleave in ORIGINAL INDEX ORDER: dispatched slots come back in
        // `prepared` order, refused calls are synthesized in place. Every
        // tool_use still gets exactly one tool_result, which is what keeps the
        // wire pairing valid.
        var slotIterator = slots.makeIterator()
        // Only a request that offers app hears next calls as app calls; a
        // membrane's own catalog (Workshop, studio wander) calls tools by name.
        let appDoor = providerTools.providerName(forInternalName: "app") != nil
        var blocks: [LLMContentBlock] = []
        var records: [TurnEngineResult.ToolDispatchRecord] = []
        var images: [LLMContentBlock] = []
        blocks.reserveCapacity(planned.count)
        records.reserveCapacity(planned.count)
        for entry in planned {
            let out: (record: TurnEngineResult.ToolDispatchRecord, block: LLMContentBlock)
            if entry.offered, let receipt = claimed[entry.call.pairedId] {
                out = await Self.makeSlotOutputs(prepared: entry.call, result: receipt, isError: false,
                    sessionId: sessionId, neutralizingText: neutralizingTextResults, appDoor: appDoor)
            } else if entry.offered {
                guard let slot = slotIterator.next() else { continue }
                images.append(contentsOf: slot.images)
                out = await Self.makeSlotOutputs(
                    prepared: slot.prepared,
                    result: Self.webReadRecovery(slot.result, prepared: slot.prepared, history: priorDispatches + records),
                    isError: slot.isError,
                    sessionId: sessionId,
                    neutralizingText: neutralizingTextResults,
                    appDoor: appDoor
                )
            } else {
                out = await Self.makeSlotOutputs(
                    prepared: entry.call,
                    result: entry.undeclared.isEmpty
                        ? Self.notOfferedToolResult(entry.call.internalName, input: entry.input)
                        : Self.undeclaredFieldsResult(entry.call.internalName, keys: entry.undeclared),
                    isError: true,
                    sessionId: sessionId,
                    appDoor: appDoor
                )
                ChatToolDispatchTracer.traceUndispatched(tool: entry.call.internalName, input: entry.call.dispatchInput,
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

    /// The receipt of the approval card that still holds this exact call (same
    /// tool, same arguments), or nil. The claim lives on the call's latest
    /// record: while that record waits on the card the claim holds; once the
    /// decided receipt has answered a re-proposal, that record no longer waits,
    /// so the claim is spent.
    func cardClaim(on call: PreparedToolCall, priorDispatches: [TurnEngineResult.ToolDispatchRecord]) -> JSONValue? {
        guard let held = priorDispatches.last(where: {
            $0.ranCall.tool == call.ranCall.tool && $0.ranCall.input == call.ranCall.input
        }), ChatToolOutcome.isWaitingApproval(held.result), case .string(let card)? = SessionHistoryPromptRenderer.receiptField("approvalId", in: held.result)
            ?? SessionHistoryPromptRenderer.receiptField("approval_id", in: held.result) else { return nil }
        let path = (remPinsDataRoot ?? defaultDataRoot()).appendingPathComponent("workflows/approvals/requests.json")
        let record: ApprovalRecord
        do {
            guard let found = try SwiftNativeApprovalInbox(root: remPinsDataRoot ?? defaultDataRoot())
                .recordsUnlocked().first(where: { $0.id == card }) else {
                return .object(["status": .string("unknown"), "effects": .string("unknown"), "card": .string(card),
                    "not_run_status": .string("claimed_by_card"), "reason": .string("claimed_card_missing"),
                    "detail": .string("The loaded approval queue has no card \(card) for this exact call. This proposal did not run again; the earlier outcome is unknown."),
                    "remedy": Repair.reconcile(instruction: "Read the prior dispatch receipts and inspect the affected state before proposing new work; a missing card does not prove the earlier action did not run.",
                        nextCall: Self.dispatchReceiptCall())])
            }
            record = found
        } catch {
            return .object(["status": .string("unknown"), "effects": .string("unknown"), "card": .string(card),
                "not_run_status": .string("claimed_by_card"),
                "reason": .string("claimed_card_unreadable"),
                "detail": .string("Card \(card) for this exact call could not be read: \(error.localizedDescription). This proposal did not run again; the earlier outcome is unknown."),
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
        return .object(["status": .string(record.executionIsStopped ? "stopped" : approved ? (record.executedAction == nil ? "unknown" : "ok") : "skipped"),
            "effects": .string(approved ? "unknown" : "none"), "card": .string(card),
            "decision": .string(record.decision ?? record.status), "receipt": record.executedAction ?? .null,
            "not_run_status": .string("claimed_by_card"),
            "reason": .string(record.executionIsStopped ? DataRootLife.stoppedReason : approved && record.executedAction == nil ? "card_outcome_unavailable" : "card_already_decided"),
            "detail": .string("This exact call was already decided on card \(card) (\(record.decision ?? record.status)); its receipt is the card's, and it was not run again."),
            "remedy": approved && record.executedAction == nil
                ? Repair.reconcile(instruction: "Read this card's execution record, then inspect the affected state before repeating an action whose outcome is missing.",
                    nextCall: .object(["tool": .string("app"), "input": .object([
                        "action": .string("files.read"), "args": .object(["path": .string(path.path)])])]))
                : Repair.terminal(instruction: "Use the retained card decision and receipt; this proposal did not run again.")])
    }

    /// User, 2026-09-06: Stop must stop the REST of the batch too. Both cancel
    /// signals the streaming/non-streaming ladders poll (the turn task's own
    /// cancellation and the on-disk Stop flag), in one place so the dispatch
    /// runner reads exactly what the loops read.
    nonisolated static func dispatchCancelSignalled(_ cancelFlagPath: URL?) -> Bool {
        if Task.isCancelled { return true }
        if ChatCancelFlag.isRaised(cancelFlagPath) { return true }
        return false
    }

    /// User, 2026-09-06: what a tool call that never ran because the turn was
    /// stopped reports. Shaped like the other slot outcomes so the wire pairing
    /// stays valid (every `tool_use` still gets its `tool_result`), but it says
    /// CANCELLED, not failed — the model must not read a Stop as a tool that
    /// tried and broke.
    /// The name a call is spoken of by in what she reads back: an `app`
    /// call by its action.
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
            "cancelled": .bool(true),
            "error": .string(message),
            "reason": .string("cancelled_before_start"),
            "effects": .string("none"),
            "remedy": Repair.terminal(instruction: "Stop cancelled this call before it started. Leave it stopped unless the person requests new work."),
        ])
    }

    /// User, 2026-09-06: what a tool call that HAD ALREADY STARTED when the Stop
    /// landed reports. It is still not a failure — a Stop is not a tool that
    /// tried and broke — but it is not the "was not run" receipt either: the
    /// dispatch reached the tool, so whatever it wrote before it unwound stands.
    /// `effects_unknown` is what retry safety reads; the failure counters keep
    /// ignoring it on the `status: cancelled` bit.
    nonisolated static func interruptedToolResult(_ name: String) -> JSONValue {
        let message = "tool '\(name)' was stopped: the turn was stopped after "
            + "the call had already started, so whether it took effect is unknown. "
            + "Check before repeating it."
        return .object([
            "status": .string("cancelled"),
            "cancelled": .bool(true),
            "effects_unknown": .bool(true),
            "error": .string(message),
            "reason": .string("interrupted_after_start"),
            "effects": .string("unknown"),
            "remedy": Repair.reconcile(instruction: "Read this turn's dispatch receipts, then inspect the affected state for any unconfirmed effect before repeating the action.",
                nextCall: dispatchReceiptCall()),
        ])
    }

    /// The current turn's recorded outcomes, without asserting an unrecorded effect.
    nonisolated static func dispatchReceiptCall() -> JSONValue {
        var args: [String: JSONValue] = ["kind": .string("tool.dispatch"), "view": .string("receipts")]
        if let turn = TurnTraceContext.turnId { args["turn_id"] = .string(turn) }
        return .object(["tool": .string("app"), "input": .object([
            "action": .string("trace.recent"), "args": .object(args)])])
    }

    /// The refusal a declared-but-not-offered `tool_use` gets back. Shaped
    /// exactly like a dispatch error so the loop and transcript treat it as one.
    /// Her one tool is `app`: the answer is
    /// her call translated to it (a folded tool's action, workspace's home
    /// item, the catalog's find), else app's home.
    nonisolated static func notOfferedToolResult(_ name: String, input: [String: JSONValue] = [:]) -> JSONValue {
        // The one next step: the same call through app, or none at all.
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

    /// One slot's dispatch outcome, carried back to the caller in ORIGINAL
    /// INDEX ORDER. Slot FINALIZATION (result-block shape, transcript rows)
    /// belongs to the caller: the native and text-marker codecs carry
    /// different result-block formats, but the safety veto, the
    /// grouping and the event ORDER contract must stay one implementation.
    struct DispatchedSlot: Sendable {
        let index: Int
        let prepared: PreparedToolCall
        let result: JSONValue
        let isError: Bool
        let images: [LLMContentBlock]
    }

    /// Plan and execute ONE iteration's tool calls under the fail-closed
    /// `ParallelToolDispatch` veto table, the fleet cwd overrides and the
    /// `effectiveForceSerial` escape hatch, returning every slot's outcome in
    /// original index order.
    ///
    /// EVENT CONTRACT (identical for every caller, which is the point of
    /// this being one function): for a `.concurrent` group `onToolUse` fires
    /// for the whole group up-front in index order, the children dispatch
    /// concurrently under the `maxConcurrentPerIteration` window with notices
    /// streaming live, then `onOutcome` fires in index order once the group
    /// has completed. A `.sequential` slot is onToolUse → dispatch →
    /// onOutcome. Errors never escape a slot and never cancel siblings; turn
    /// cancellation cancels all in-flight children (structured task group).
    ///
    /// STOP (User, 2026-09-06): both cancel signals are polled before EVERY
    /// dispatch — the in-flight children were already cancelled by the task
    /// group, but the batch used to keep starting the calls behind them, so a
    /// Stop still ran the remaining `write_file`s. A slot the Stop reaches is
    /// reported CANCELLED without ever touching `tools.dispatch`; it still
    /// emits its onToolUse/onOutcome pair and still produces a slot, because
    /// dropping it would leave a `tool_use` with no `tool_result` on the wire.
    ///
    /// Task-local bindings the caller installs around this call (the tool
    /// loop's `LLMCallContext.$turnActiveTools`, for one) propagate into the
    /// task-group children, so per-call re-binding is unnecessary.
    nonisolated static func runIterationDispatchGroups(
        prepared: [PreparedToolCall],
        modelId: String,
        surface: String,
        personaID: String? = nil,
        fluidContextTurn: ContextPreparedTurn? = nil,
        tools: any ToolDispatchClient,
        progress: ChatOrchestrationProgressHandler?,
        imagesEnabled: Bool = true,
        cancelFlagPath: URL? = nil,
        onToolUse: @Sendable (PreparedToolCall) async -> Void,
        onOutcome: @Sendable (PreparedToolCall, JSONValue, Bool) async -> Void
    ) async -> [DispatchedSlot] {
        // A folded `app` action is judged as the tool it runs: its parallel
        // class, its pixels and whether it is a send are that tool's.
        let ran = prepared.map { $0.ranCall.tool }
        let baseSafe = prepared.map {
            !Self.isConnectorRead($0.ranCall.tool) && ParallelToolDispatch.isParallelSafe(internalToolName: $0.ranCall.tool, input: $0.ranCall.input)
        }
        let fleetOverrides = ParallelToolDispatch.fleetParallelOverrides(
            names: ran,
            inputs: prepared.map { $0.ranCall.input }
        )
        let groups = ParallelToolDispatch.plan(
            parallelSafe: zip(baseSafe, fleetOverrides).map { $1 ?? $0 },
            forceSerial: StandingBotContinuity.isHelperTurn || ParallelToolDispatch.effectiveForceSerial
        )

        var slots: [DispatchedSlot] = []
        slots.reserveCapacity(prepared.count)
        // Only the named pixel-capable tools can mint pixels — the file reader,
        // the tools that MAKE an image, and the agent's own page screenshot.
        // Their sinks share one round budget (`LocalToolImage.Round`), parallel
        // dispatches included. Every `screen` gets a sink (her-screen Phase 6):
        // it attaches pixels only for a thin-AX window or on pixels:true.
        let imageIndices = Set(prepared.indices.filter {
            imagesEnabled && LocalToolImage.pixelCapableTools.contains(ran[$0])
        })
        let imageRound = LocalToolImage.Round()
        for group in groups {
            switch group {
            case .sequential(let idx):
                let p = prepared[idx]
                await onToolUse(p)
                if Self.dispatchCancelSignalled(cancelFlagPath) {
                    let cancelled = Self.cancelledToolResult(Self.spokenName(p))
                    await onOutcome(p, cancelled, true)
                    slots.append(DispatchedSlot(
                        index: idx, prepared: p, result: cancelled, isError: true, images: []
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
                    await onOutcome(p, result, true)
                    slots.append(DispatchedSlot(index: idx, prepared: p,
                                                result: result, isError: true, images: []))
                    continue
                }
                let imageSink = imageIndices.contains(idx) ? LocalToolImage.Sink(round: imageRound) : nil
                let (dispatched, result, isError) = await Self.runSingleDispatch(
                    prepared: p, modelId: modelId, surface: surface,
                    personaID: personaID,
                    fluidContextTurn: fluidContextTurn,
                    tools: tools, progress: progress, imageSink: imageSink,
                    cancelFlagPath: cancelFlagPath
                )
                await onOutcome(dispatched, result, isError)
                slots.append(DispatchedSlot(
                    index: idx, prepared: dispatched, result: result, isError: isError,
                    images: imageSink?.finish(success: !isError && !Task.isCancelled) ?? []
                ))

            case .concurrent(let indices):
                // .toolUse for the whole group up-front, in index order —
                // keeps the progress stream deterministic while children
                // complete in arbitrary order.
                for idx in indices {
                    await onToolUse(prepared[idx])
                }
                var outcomes: [Int: (prepared: PreparedToolCall, result: JSONValue, isError: Bool, images: [LLMContentBlock])] = [:]
                // Window of maxConcurrentPerIteration: refill on completion.
                await withTaskGroup(
                    of: (Int, PreparedToolCall, JSONValue, Bool, [LLMContentBlock]).self
                ) { taskGroup in
                    var iterator = indices.makeIterator()
                    func addNext() -> Bool {
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
                                    cancelFlagPath: cancelFlagPath
                                )
                                return (idx, dispatched, result, isError, imageSink?.finish(success: !isError && !Task.isCancelled) ?? [])
                            }
                            return true
                        }
                        return false
                    }
                    var started = 0
                    while started < ParallelToolDispatch.maxConcurrentPerIteration, addNext() {
                        started += 1
                    }
                    while let (idx, dispatched, result, isError, images) = await taskGroup.next() {
                        outcomes[idx] = (dispatched, result, isError, images)
                        _ = addNext()
                    }
                }
                // Reassemble in ORIGINAL index order regardless of
                // completion order — the provider pairs tool_result blocks
                // to tool_use blocks by id AND expects consistent ordering.
                for idx in indices {
                    let outcome = outcomes[idx] ?? (
                        prepared: prepared[idx],
                        result: JSONValue.object([
                            "status": .string("unknown"),
                            "reason": .string("dispatch_result_missing"),
                            "effects": .string("unknown"),
                            "error": .string("parallel dispatch produced no result"),
                            "remedy": Repair.reconcile(instruction: "Read this turn's dispatch receipts and inspect the affected state; a missing result does not prove the call did not run.",
                                nextCall: Self.dispatchReceiptCall()),
                        ]),
                        isError: true, images: [LLMContentBlock]()
                    )
                    let p = outcome.prepared
                    await onOutcome(p, outcome.result, outcome.isError)
                    slots.append(DispatchedSlot(
                        index: idx, prepared: p,
                        result: outcome.result, isError: outcome.isError, images: outcome.images
                    ))
                }
            }
        }
        return slots
    }

    nonisolated private static func webReadRecovery(
        _ result: JSONValue, prepared: PreparedToolCall, history: [TurnEngineResult.ToolDispatchRecord]
    ) -> JSONValue {
        guard prepared.ranCall.tool == "read_page",
              case .object(var failure) = result, failure["status"] == .string("failed"),
              [.int(402), .int(403)].contains(failure["http_status"] ?? .null),
              case .string(let url)? = failure["url"] else { return result }
        for call in history.reversed() where call.ranCall.tool == "web_search" {
            guard case .object(let envelope) = call.result, envelope["status"] == .string("ok"),
                  case .object(let search)? = envelope["result"], case .array(let rows)? = search["results"] else { continue }
            let urls = rows.compactMap { row -> String? in
                guard case .object(let fields) = row, case .string(let value)? = fields["url"] else { return nil }
                return value
            }
            guard let index = urls.firstIndex(of: url), let next = urls.dropFirst(index + 1).first(where: {
                guard let parsed = URL(string: $0) else { return false }
                return ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") && parsed.host != nil && $0 != url
            }) else { continue }
            let nextCall: JSONValue = .object(["tool": .string("app"), "input": .object([
                "action": .string("web.read"), "args": .object(["url": .string(next)])])])
            failure["next_call"] = nextCall
            failure["remedy"] = .object(["kind": .string("read_next_search_result"),
                "instruction": .string("This source refused the public read. Read the next search result URL with next_call."),
                "next_call": nextCall])
            return .object(failure)
        }
        return result
    }

    /// Slot finalization, pure: dispatch record + redacted tool_result
    /// block. (Redact before the provider sees it: persistence and progress
    /// events already redact this surface — this path was the one place raw
    /// secrets shipped out, audit 2026-06-09.) Static-pure rather than a
    /// mutable-capturing local function so Swift 6 region isolation doesn't
    /// flag the capture as a cross-task send.
    nonisolated static func makeSlotOutputs(
        prepared: PreparedToolCall,
        result: JSONValue,
        isError: Bool,
        sessionId: String? = nil,
        neutralizingText: Bool = false,
        appDoor: Bool
    ) async -> (record: TurnEngineResult.ToolDispatchRecord, block: LLMContentBlock) {
        // A next call named by a folded tool reaches her as its app call,
        // whichever tool's result names it (work_context's desk_read), when
        // this request offers app.
        let result = appDoor ? ToolNameAliases.appCallPointers(result) : result
        let record = TurnEngineResult.ToolDispatchRecord(
            id: prepared.pairedId,
            name: prepared.internalName,
            input: prepared.dispatchInput,
            ranCall: prepared.ranCall,
            result: result
        )
        let resultStr: String = {
            // Persist the complete card above; the model only needs the skip.
            if let card = InlineInteractionNeed.interaction(in: result),
               !InlineInteractionNeed.blocksTurn(card),
               case .object(let object) = result,
               case .string(let detail)? = object["detail"] {
                return neutralizingText ? UntrustedText.neutralized(detail) : detail
            }
            if case .string(let s) = result { return neutralizingText ? UntrustedText.neutralized(s) : s }
            return (try? result.serialize(pretty: false)) ?? "null"
        }()
        let redactedResultStr = ChatSecretRedactor.redactText(resultStr)
        let providerResultStr = await ProviderToolResultProjection.project(
            toolName: prepared.ranCall.tool,
            content: redactedResultStr,
            sessionId: sessionId,
            turnId: TurnTraceContext.turnId,
            originalResultClass: ChatToolOutcome.exactResultClass(result),
            appDoor: appDoor
        )
        let block = LLMContentBlock.toolResult(
            toolUseId: prepared.pairedId, content: providerResultStr, isError: isError
        )
        return (record, block)
    }

    /// One dispatch's outcome carried out of the deadline race, so a thrown
    /// error stays tellable apart from the ceiling winning (`nil`). `@unchecked`
    /// only because `any Error` is not `Sendable`; the value crosses one
    /// resume-once gate and is rethrown on the same lane.
    enum SingleDispatchRace: @unchecked Sendable {
        case value(JSONValue)
        case thrown(any Error)
    }

    nonisolated static func runSingleDispatch(
        prepared: PreparedToolCall,
        modelId: String,
        surface: String,
        personaID: String? = nil,
        fluidContextTurn: ContextPreparedTurn? = nil,
        tools: any ToolDispatchClient,
        progress: ChatOrchestrationProgressHandler?,
        imageSink: LocalToolImage.Sink? = nil,
        cancelFlagPath: URL? = nil
    ) async -> (PreparedToolCall, JSONValue, Bool) {
        var prepared = prepared
        prepared.ranCall = ToolNameAliases.ranCall(prepared.internalName, input: prepared.dispatchInput)
        let journal = DeskContinuationScope.current
        var step = Self.checkpointStep(prepared)
        do {
            step = try await journal?.begin(step, peerSources: PeerDataTaint.current?.checkpointSources ?? []) ?? step
        } catch {
            return (prepared, .object(["status": .string("failed"), "effects": .string("none"),
                "not_run_status": .string("continuation_refused"), "reason": .string("continuation_begin_failed"),
                "stage": .string("begin"), "proposed_step_id": .string(step.id),
                "detail": .string("The continuation journal could not admit this call: \(error.localizedDescription). The action did not start."),
                "remedy": Repair.reconcile(instruction: "Read the Desk continuation and its journal error before proposing more work; this call has no effects to repeat.",
                    nextCall: .object(["tool": .string("app"), "input": .object(["page": .string("desk")])]))]), true)
        }
        let outcome = await runCheckpointedDispatchBody(prepared: prepared, modelId: modelId, surface: surface,
            personaID: personaID, fluidContextTurn: fluidContextTurn, tools: tools, progress: progress,
            imageSink: imageSink, cancelFlagPath: cancelFlagPath)
        guard let journal else { return (prepared, outcome.0, outcome.1) }
        let object: [String: JSONValue]
        if case .object(let fields) = outcome.0 { object = fields } else { object = [:] }
        func text(_ key: String) -> String? {
            if case .string(let value)? = object[key] { return value }
            return nil
        }
        let owner: String?
        let ran = prepared.ranCall.tool
        if ran == "bot_run_once", text("requestId") != nil { owner = "helper" }
        else if ran == "workshop_submit", text("id") != nil,
                ["queued", "running", "pending"].contains(text("status") ?? "") { owner = "workshop" }
        else { owner = nil }
        // Settled on the receipt's own evidence, never on how the tool is spelled.
        let settled = ChatToolOutcome.neverRan(outcome.0) || object["effects"] == .string("none")
            || (owner == nil && !ChatToolOutcome.isWaitingOnPerson(outcome.0)
                && !DeskContinuation.receiptIsUnresolved(outcome.0)
                && ![.running, .timedOut, .effectUnconfirmed].contains(MacControlReceiptOutcome.projecting(envelope: outcome.0)))
        let json = (try? outcome.0.serialize(pretty: false)) ?? ""
        do {
            try await journal.settle(step,
                result: String(SwiftNativeChatOrchestrationClient.redactedPersistedToolResult(
                    tool: ran, json: json).prefix(512)),
                settled: settled, owner: owner, ownerID: text("id"), requestID: text("requestId"),
                peerSources: PeerDataTaint.current?.checkpointSources ?? [])
        } catch {
            return (prepared, .object(["status": .string("failed"),
                "effects": object["effects"] ?? .string(ChatToolOutcome.neverRan(outcome.0) ? "none" : "unknown"),
                "reason": .string("continuation_settlement_failed"), "stage": .string("settlement"),
                "step_id": .string(step.id), "receipt": outcome.0,
                "detail": .string("The action returned, but its continuation journal could not record settlement: \(error.localizedDescription). The returned receipt remains evidence of its effects."),
                "remedy": Repair.reconcile(instruction: "Use the retained receipt and inspect the affected state before repeating the action; read the Desk continuation to resolve its journal error.",
                    nextCall: .object(["tool": .string("app"), "input": .object(["page": .string("desk")])]))]), true)
        }
        return (prepared, outcome.0, outcome.1)
    }

    /// The checkpoint keeps the same redacted argument summary the transcript
    /// keeps, bounded, plus only the reference a domain verifier needs: a
    /// whole-file write is checked by path and content digest, never content.
    /// `effect` digests the exact call, so a re-proposed one is the same step.
    nonisolated private static func checkpointStep(_ prepared: PreparedToolCall) -> DeskContinuation.Step {
        let json = (try? JSONValue.object(prepared.dispatchInput).serialize(pretty: false)) ?? ""
        let input = String(SwiftNativeChatOrchestrationClient.redactedPersistedToolInput(
            tool: prepared.internalName, json: json).prefix(512))
        // app files.write is write_file: its verifier checks the file it wrote.
        let ran = prepared.ranCall.tool
        let ranInput = prepared.ranCall.input
        var reference: [String: JSONValue]?
        if ran == "write_file", ranInput["append"] != .bool(true),
           case .string(let path)? = ranInput["path"],
           case .string(let content)? = ranInput["content"] {
            reference = ["path": .string(path), "bytes": .int(Int64(content.utf8.count)),
                         "sha256": .string(SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined())]
        }
        let exact = (try? JSONValue.object(ranInput).serialize(pretty: false)) ?? json
        return DeskContinuation.Step(id: UUID().uuidString, tool: ran, input: input, reference: reference,
            effect: SHA256.hash(data: Data((ran + "\n" + exact).utf8)).map { String(format: "%02x", $0) }.joined())
    }

    nonisolated static func runCheckpointedDispatchBody(
        prepared: PreparedToolCall, modelId: String, surface: String, personaID: String? = nil,
        fluidContextTurn: ContextPreparedTurn? = nil, tools: any ToolDispatchClient,
        progress: ChatOrchestrationProgressHandler?, imageSink: LocalToolImage.Sink? = nil,
        cancelFlagPath: URL? = nil
    ) async -> (JSONValue, Bool) {
        if Self.dispatchCancelSignalled(cancelFlagPath) {
            return (Self.cancelledToolResult(Self.spokenName(prepared)), true)
        }
        // A folded app action waits as long as the tool it runs.
        let deadlineNanos = ToolDispatchDeadline.timeoutNanos(
            toolName: prepared.ranCall.tool,
            input: prepared.ranCall.input,
            surface: surface
        )
        do {
            let result = try await LocalToolImage.$sink.withValue(imageSink) {
            try await FluidContextToolScope.$current.withValue(fluidContextTurn) {
            try await ChatTurnRuntimeContext.$current.withValue(
                .init(
                    model: modelId,
                    surface: surface,
                    personaID: personaID,
                    providerID: LLMCallContext.providerId
                )
            ) {
                try await ToolNoticeBus.$emit.withValue({ kind, text in
                    await progress?(.notice(kind: kind, text: text))
                }) {
                    // User, 2026-09-06: the deadline used to be a throwing task
                    // group, and leaving a group waits for its cancelled
                    // children — so a connector that ignores cancellation held
                    // the turn open past the very ceiling this exists to
                    // enforce. Same resume-once shape as the provider wall.
                    let seconds = Double(deadlineNanos) / 1_000_000_000
                    // Keep the first terminal outcome, including Stop, even if
                    // the tool ignores cancellation and returns a late value.
                    let outcomes = AsyncStream<SingleDispatchRace>.makeStream(bufferingPolicy: .bufferingOldest(1))
                    let dispatch = Task {
                        let work: @Sendable () async -> SingleDispatchRace = {
                            do {
                                if Self.dispatchCancelSignalled(cancelFlagPath) { throw CancellationError() }
                                return .value(try await tools.dispatch(
                                    tool: prepared.requestedName,
                                    input: prepared.dispatchInput,
                                    surface: surface
                                ))
                            } catch {
                                return .thrown(error)
                            }
                        }
                        let result: SingleDispatchRace
                        if deadlineNanos > 0 {
                            let raced = await IntraTurnContextCompaction.withDeadline(seconds: seconds, work)
                            if let raced {
                                result = raced
                            } else if Task.isCancelled {
                                result = .thrown(CancellationError())
                            } else {
                                result = .thrown(ToolDispatchDeadline.ToolDispatchTimedOut(
                                    tool: Self.spokenName(prepared), seconds: seconds
                                ))
                            }
                        } else {
                            result = await work()
                        }
                        outcomes.continuation.yield(result)
                    }
                    let watcher = cancelFlagPath.map { flag in
                        FileChangeWatcher(paths: [URL(fileURLWithPath: flag.path)]) { _ in
                            if ChatCancelFlag.isRaised(flag) {
                                outcomes.continuation.yield(.thrown(CancellationError()))
                                dispatch.cancel()
                            }
                        }
                    }
                    defer {
                        watcher?.cancel()
                        dispatch.cancel()
                        outcomes.continuation.finish()
                    }
                    // Close the registration race using the run-tagged URL.
                    if Self.dispatchCancelSignalled(cancelFlagPath) {
                        outcomes.continuation.yield(.thrown(CancellationError()))
                        dispatch.cancel()
                    }
                    let raced = await withTaskCancellationHandler {
                        var iterator = outcomes.stream.makeAsyncIterator()
                        return await iterator.next()
                    } onCancel: {
                        outcomes.continuation.yield(.thrown(CancellationError()))
                        dispatch.cancel()
                    }
                    switch raced {
                    case .value(let result):
                        return result
                    case .thrown(let error):
                        throw error
                    case nil:
                        throw CancellationError()
                    }
                }
            }
            }
            }
            // A nonthrowing transport can still carry a canonical failure
            // envelope (including `isError:true`, wrapped or raw). Keep
            // the provider tool-result bit, persisted progress, and traces on
            // the same shared classification.
            // A raised need is not an error and must not reach the model as
            // `is_error: true` — nothing broke, the call is waiting on a
            // person. Without this a need returned by a NON-throwing boundary
            // (the shared cloud read, the Mac permission gate) would be
            // flagged an error while the identical need from a THROWING one
            // was not, and the two paths would disagree about the same fact.
            if InlineInteractionNeed.isWaiting(result) { return (result, false) }
            return (ChatToolOutcome.normalizedFailure(result, tool: prepared.internalName), !ChatToolOutcome.outputLooksSuccessful(result))
        } catch is CancellationError {
            // User, 2026-09-06: a Stop is not a tool failure. Reporting it as
            // one told the model the tool tried and broke, and left the
            // transcript claiming a failed write that never happened.
            //
            // User, 2026-09-06: but this catch is reached only AFTER the
            // dispatch was handed to `tools` — the never-started slots take
            // the pre-dispatch path in `runIterationDispatchGroups`. Using the
            // "was not run" receipt here told every counter the call had no
            // effects, so a `write_file` a Stop interrupted mid-write let a
            // surface ladder replay the whole turn and write it again.
            return (Self.interruptedToolResult(Self.spokenName(prepared)), true)
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
