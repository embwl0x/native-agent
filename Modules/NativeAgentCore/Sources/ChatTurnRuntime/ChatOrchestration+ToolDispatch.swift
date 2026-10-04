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

extension SwiftNativeTurnEngine {
    // MARK: - Per-iteration dispatch (shared by both loops; U1 step 6)

    /// One provider call, fully resolved for dispatch. Built up-front so
    /// task-group children capture only Sendable value types (plus the
    /// Sendable `tools` / `progress` references) — never the conversation
    /// array or any actor state.
    struct PreparedToolCall: Sendable {
        let pairedId: String
        /// The spelling the model called, handed to the chain as-is so its
        /// canonicalizer can carry it to the policy gates (GatedToolNameContext).
        let requestedName: String
        /// Its canonical name (ToolNameAliases): the one name the pill, the
        /// receipt, the records and every per-tool rule below read.
        let internalName: String
        let dispatchInput: [String: JSONValue]
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
                guard !ToolCallParser.isIgnorableToolName(call.name) else { return nil }
                let requestedName = providerTools.internalName(forProviderName: call.name)
                let internalName = CanonicalToolNameDispatcher.canonical(requestedName)
                let prepared = PreparedToolCall(
                    pairedId: i < pairedIds.count ? pairedIds[i] : call.id,
                    requestedName: requestedName,
                    internalName: internalName,
                    dispatchInput: Self.inputWithSessionIfNeeded(
                        toolName: internalName,
                        input: call.input,
                        sessionId: sessionId
                    )
                )
                // A folded, merged or retired tool is app's now: called by
                // name where this request never declared it, it runs nothing
                // (`notOfferedToolResult`). The door's own re-entry (home runs
                // as `workspace`) never passes here, so it still runs.
                let folded = ToolNameAliases.isAppDoorName(internalName)
                    && providerTools.providerName(forInternalName: internalName) == nil
                return (prepared, call.undeclaredKeys.isEmpty && !folded, call.input, call.undeclaredKeys)
            }
        let prepared = planned.filter(\.offered).map(\.call)
        let slots = await Self.runIterationDispatchGroups(
            prepared: prepared,
            modelId: modelId,
            surface: surface,
            personaID: personaID,
            fluidContextTurn: fluidContextTurn,
            tools: tools,
            progress: progress,
            cancelFlagPath: cancelFlagPath,
            // Mixed or not is decided on everything the model called in this
            // step, before unoffered calls are dropped.
            stepToolNames: planned.map { ToolNameAliases.ranTool($0.call.internalName, input: $0.call.dispatchInput) },
            onToolUse: { p in
                await progress?(.toolUse(name: p.internalName, input: .object(p.dispatchInput)))
            },
            onOutcome: { p, result, _ in
                await progress?(.toolResult(name: p.internalName, output: result))
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
            if entry.offered {
                guard let slot = slotIterator.next() else { continue }
                images.append(contentsOf: slot.images)
                out = await Self.makeSlotOutputs(
                    prepared: slot.prepared,
                    result: slot.result,
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
            }
            records.append(out.record)
            blocks.append(out.block)
        }
        // Keep all paired results first; pixels belong to the same user
        // continuation, not the persisted/tool-result text representation.
        blocks.append(contentsOf: images)
        return (blocks, records)
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
            "reason": .string(message),
        ])
    }

    /// User, 2026-09-06: what a tool call that HAD ALREADY STARTED when the Stop
    /// landed reports. It is still not a failure — a Stop is not a tool that
    /// tried and broke — but it is not the "was not run" receipt either: the
    /// dispatch reached the tool, so whatever it wrote before it unwound stands.
    /// `effects_unknown` is what retry safety reads; the failure counters keep
    /// ignoring it on the `status: cancelled` bit.
    nonisolated static func interruptedToolResult(_ name: String) -> JSONValue {
        let message = "tool '\(name)' was interrupted: the turn was stopped after "
            + "the call had already started, so whether it took effect is unknown. "
            + "Check before repeating it."
        return .object([
            "status": .string("cancelled"),
            "cancelled": .bool(true),
            "effects_unknown": .bool(true),
            "error": .string(message),
            "reason": .string(message),
        ])
    }

    /// 2026-09-25 (turn ed54a985): one reply held `act` click, `screen`, then
    /// three messages to Claude saying "done, my click returned ok". The
    /// click had failed; every message was written before any result existed
    /// and went out anyway. A call that speaks to someone outside the turn is
    /// therefore not run when the same reply also calls anything else: the
    /// others run, it comes back unsent, and the model sends again once it has
    /// read their results. A reply of only such calls runs as written.
    nonisolated static let outboundMessageTools: Set<String> = [
        "agent_message", "claude_message", "codex_message", "omp_message",
        "invoke_codex",
        "messages_send", "mail_send", "mail_reply", "agentmail_send",
        "slack_post_message", "mobile_notify", "phone_request", "mac_notify", "chat_reply",
    ]

    /// What a held send returns, or nil when the step (every call the model
    /// made in it, offered or not) is not mixed. An explicit error with
    /// `held_for_results` retaining the fact that no send was attempted.
    nonisolated static func heldOutboundResult(stepToolNames: [String]) -> JSONValue? {
        // A clock read can't change what a message reports, so it never holds
        // a send (A2A walk 09-25: 5 of 11 sends were held behind time_now).
        let housekeeping: Set<String> = ["time_now"]
        let others = stepToolNames.filter { !outboundMessageTools.contains($0) && !housekeeping.contains($0) }
        guard !others.isEmpty, others.count < stepToolNames.count else { return nil }
        var seen = Set<String>()
        let names = others.filter { seen.insert($0).inserted }.joined(separator: ", ")
        return .object([
            "status": .string("held"),
            "error": .string("held: run this send in its own step"),
            "held_for_results": .bool(true),
            "sent": .bool(false),
            "detail": .string("Not sent: written in the same step as \(names), before their results existed. "
                + "Read those results, then run this send in its own step with no other tool calls."),
        ])
    }

    /// The refusal a declared-but-not-offered `tool_use` gets back. Shaped
    /// exactly like a dispatch error so the loop, the no-progress guard and
    /// the transcript treat it as one. Her one tool is `app`: the answer is
    /// her call translated to it (a folded tool's action, workspace's home
    /// item, the catalog's find), else app's home.
    nonisolated static func notOfferedToolResult(_ name: String, input: [String: JSONValue] = [:]) -> JSONValue {
        .object([
            "error": .string("tool '\(name)' is not offered in this conversation, so it was not run. "
                + ToolNameAliases.foldedToolHint(name, input: input)),
            "not_offered": .bool(true),
            "effects": .string("none"),
        ])
    }

    /// A text-lane block carrying fields its tool does not take is a result
    /// she wrote, not a call (`TextMarkerCodec.calls`); it ran nothing.
    nonisolated static func undeclaredFieldsResult(_ name: String, keys: [String]) -> JSONValue {
        .object([
            "error": .string("\(name) takes no \(keys.joined(separator: ", ")), so this block was not run. "
                + "Results come only from tools; never write one. To call \(name), use only its own parameters."),
            "status": .string("skipped"),
            "effects": .string("none"),
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
        stepToolNames: [String]? = nil,
        onToolUse: @Sendable (PreparedToolCall) async -> Void,
        onOutcome: @Sendable (PreparedToolCall, JSONValue, Bool) async -> Void
    ) async -> [DispatchedSlot] {
        // A folded `app` action is judged as the tool it runs: its parallel
        // class, its pixels and whether it is a send are that tool's.
        let ran = prepared.map { ToolNameAliases.ranTool($0.internalName, input: $0.dispatchInput) }
        let baseSafe = ran.map {
            !Self.isConnectorRead($0) && ParallelToolDispatch.isParallelSafe(internalToolName: $0)
        }
        let fleetOverrides = ParallelToolDispatch.fleetParallelOverrides(
            names: ran,
            inputs: prepared.map { ToolNameAliases.ranInput($0.internalName, input: $0.dispatchInput) }
        )
        let groups = ParallelToolDispatch.plan(
            parallelSafe: zip(baseSafe, fleetOverrides).map { $1 ?? $0 },
            forceSerial: surface == "bot" || ParallelToolDispatch.effectiveForceSerial
        )

        var slots: [DispatchedSlot] = []
        slots.reserveCapacity(prepared.count)
        // Only the named pixel-capable tools can mint pixels — the file reader,
        // the tools that MAKE an image, and the agent's own page screenshot.
        // Bound each iteration to eight such calls, including parallel
        // dispatches — the same eight `boundConversation` keeps (was four: a
        // fifth read_file in one batch came back without pixels, 2026-09-23).
        // Every `screen` gets a sink (her-screen Phase 6): it attaches pixels
        // only for a thin-AX window or on pixels:true, and never otherwise.
        let imageIndices = Set(prepared.indices.filter {
            imagesEnabled && LocalToolImage.pixelCapableTools.contains(ran[$0])
        }.prefix(8))
        let heldResult = Self.heldOutboundResult(stepToolNames: stepToolNames ?? ran)
        let held = heldResult == nil ? [] : Set(prepared.indices.filter {
            outboundMessageTools.contains(ran[$0])
        })

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
                if held.contains(idx), let heldResult {
                    await onOutcome(p, heldResult, true)
                    slots.append(DispatchedSlot(
                        index: idx, prepared: p, result: heldResult, isError: true, images: []
                    ))
                    continue
                }
                if let connector = Self.connectorID(ran[idx]), slots.contains(where: {
                    guard let need = InlineInteractionNeed.interaction(in: $0.result) else { return false }
                    return need.kind == .connector && need.target == connector
                }) {
                    let result: JSONValue = .object([
                        "status": .string("skipped"),
                        "detail": .string("skipped: \(connector) isn't connected — card filed")
                    ])
                    await onOutcome(p, result, false)
                    slots.append(DispatchedSlot(index: idx, prepared: p,
                                                result: result, isError: false, images: []))
                    continue
                }
                let imageSink = imageIndices.contains(idx) ? LocalToolImage.Sink() : nil
                let (result, isError) = await Self.runSingleDispatch(
                    prepared: p, modelId: modelId, surface: surface,
                    personaID: personaID,
                    fluidContextTurn: fluidContextTurn,
                    tools: tools, progress: progress, imageSink: imageSink,
                    cancelFlagPath: cancelFlagPath
                )
                await onOutcome(p, result, isError)
                slots.append(DispatchedSlot(
                    index: idx, prepared: p, result: result, isError: isError,
                    images: imageSink?.finish(success: !isError && !Task.isCancelled) ?? []
                ))

            case .concurrent(let indices):
                // .toolUse for the whole group up-front, in index order —
                // keeps the progress stream deterministic while children
                // complete in arbitrary order.
                for idx in indices {
                    await onToolUse(prepared[idx])
                }
                var outcomes: [Int: (result: JSONValue, isError: Bool, images: [LLMContentBlock])] = [:]
                // Window of maxConcurrentPerIteration: refill on completion.
                await withTaskGroup(
                    of: (Int, JSONValue, Bool, [LLMContentBlock]).self
                ) { taskGroup in
                    var iterator = indices.makeIterator()
                    func addNext() -> Bool {
                        while let idx = iterator.next() {
                            let p = prepared[idx]
                            // Stop reached this slot before it started: record the
                            // cancelled outcome and keep draining, so no further
                            // dispatch is ever handed to `tools`.
                            if Self.dispatchCancelSignalled(cancelFlagPath) {
                                outcomes[idx] = (Self.cancelledToolResult(Self.spokenName(p)), true, [])
                                continue
                            }
                            if held.contains(idx), let heldResult {
                                outcomes[idx] = (heldResult, true, [])
                                continue
                            }
                            taskGroup.addTask {
                                let imageSink = imageIndices.contains(idx) ? LocalToolImage.Sink() : nil
                                let (result, isError) = await Self.runSingleDispatch(
                                    prepared: p, modelId: modelId, surface: surface,
                                    personaID: personaID,
                                    fluidContextTurn: fluidContextTurn,
                                    tools: tools, progress: progress, imageSink: imageSink,
                                    cancelFlagPath: cancelFlagPath
                                )
                                return (idx, result, isError, imageSink?.finish(success: !isError && !Task.isCancelled) ?? [])
                            }
                            return true
                        }
                        return false
                    }
                    var started = 0
                    while started < ParallelToolDispatch.maxConcurrentPerIteration, addNext() {
                        started += 1
                    }
                    while let (idx, result, isError, images) = await taskGroup.next() {
                        outcomes[idx] = (result, isError, images)
                        _ = addNext()
                    }
                }
                // Reassemble in ORIGINAL index order regardless of
                // completion order — the provider pairs tool_result blocks
                // to tool_use blocks by id AND expects consistent ordering.
                for idx in indices {
                    let outcome = outcomes[idx] ?? (
                        result: JSONValue.object([
                            "error": .string("parallel dispatch produced no result"),
                        ]),
                        isError: true, images: [LLMContentBlock]()
                    )
                    let p = prepared[idx]
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
            toolName: ToolNameAliases.ranTool(prepared.internalName, input: prepared.dispatchInput),
            content: redactedResultStr,
            sessionId: sessionId,
            turnId: TurnTraceContext.turnId,
            originalResultClass: ChatToolOutcome.exactResultClass(result),
            query: {
                let input = ToolNameAliases.ranInput(prepared.internalName, input: prepared.dispatchInput)
                if case .string(let query)? = input["query"] { return query }
                return nil
            }(),
            appDoor: appDoor
        )
        let block = LLMContentBlock.toolResult(
            toolUseId: prepared.pairedId, content: providerResultStr, isError: isError
        )
        return (record, block)
    }

    /// The single-dispatch core shared by the serial slot and every
    /// task-group child. Mirrors the original serial body: bind the notice bus
    /// to this turn's progress stream + the live turn model/surface (TaskLocals
    /// — propagate down the dispatch task tree), dispatch, and convert ANY
    /// thrown error into the slot's error-object result (the loop continues;
    /// the model sees the error as feedback).
    ///
    /// Trust loop #3: every dispatch is raced against a
    /// hard deadline (ToolDispatchDeadline) — a wedged tool throws
    /// ToolDispatchTimedOut, which the catch below turns into the same
    /// error-object result as any other tool failure, so a hung turn fails
    /// cleanly instead of freezing forever. Stop remains active even when the
    /// deadline is disabled. The dispatch task is added INSIDE the TaskLocal
    /// withValue scopes so it still inherits the runtime ctx + notice bus.
    nonisolated static func projectedToolDispatchError(_ error: Error) -> String {
        ChatToolOutcome.errorMessage(error)
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
    ) async -> (JSONValue, Bool) {
        let journal = DeskContinuationScope.current
        let step = Self.checkpointStep(prepared)
        do {
            try await journal?.begin(step, peerSources: PeerDataTaint.current?.checkpointSources ?? [])
        } catch {
            return (.object(["status": .string("failed"), "effects": .string("none"),
                "not_run_status": .string("continuation_refused"), "reason": .string(error.localizedDescription)]), true)
        }
        let outcome = await runCheckpointedDispatchBody(prepared: prepared, modelId: modelId, surface: surface,
            personaID: personaID, fluidContextTurn: fluidContextTurn, tools: tools, progress: progress,
            imageSink: imageSink, cancelFlagPath: cancelFlagPath)
        guard let journal else { return outcome }
        let object: [String: JSONValue]
        if case .object(let fields) = outcome.0 { object = fields } else { object = [:] }
        func text(_ key: String) -> String? {
            if case .string(let value)? = object[key] { return value }
            return nil
        }
        let owner: String?
        let ran = ToolNameAliases.ranTool(prepared.internalName, input: prepared.dispatchInput)
        if ran == "bot_run_once", text("requestId") != nil { owner = "helper" }
        else if ran == "workshop_submit", text("id") != nil,
                ["queued", "running", "pending"].contains(text("status") ?? "") { owner = "workshop" }
        else { owner = nil }
        let settled = step.readOnly || ChatToolOutcome.neverRan(outcome.0) || object["effects"] == .string("none")
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
            return (.object(["status": .string("failed"), "effects": .string("unknown"),
                "reason": .string(error.localizedDescription), "receipt": outcome.0]), true)
        }
        return outcome
    }

    /// The checkpoint keeps the same redacted argument summary the transcript
    /// keeps, bounded, plus only the reference a domain verifier needs: a
    /// whole-file write is checked by path and content digest, never content.
    nonisolated private static func checkpointStep(_ prepared: PreparedToolCall) -> DeskContinuation.Step {
        let json = (try? JSONValue.object(prepared.dispatchInput).serialize(pretty: false)) ?? ""
        let input = String(SwiftNativeChatOrchestrationClient.redactedPersistedToolInput(
            tool: prepared.internalName, json: json).prefix(512))
        // app files.write is write_file: its verifier checks the file it wrote.
        let ran = ToolNameAliases.ranTool(prepared.internalName, input: prepared.dispatchInput)
        let ranInput = ToolNameAliases.ranInput(prepared.internalName, input: prepared.dispatchInput)
        var reference: [String: JSONValue]?
        if ran == "write_file", ranInput["append"] != .bool(true),
           case .string(let path)? = ranInput["path"],
           case .string(let content)? = ranInput["content"] {
            reference = ["path": .string(path), "bytes": .int(Int64(content.utf8.count)),
                         "sha256": .string(SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined())]
        }
        var step = DeskContinuation.Step(id: UUID().uuidString, tool: ran, input: input, reference: reference)
        step.readOnly = ParallelToolDispatch.isParallelSafe(internalToolName: ran)
        return step
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
            toolName: ToolNameAliases.ranTool(prepared.internalName, input: prepared.dispatchInput),
            input: ToolNameAliases.ranInput(prepared.internalName, input: prepared.dispatchInput),
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
            // envelope (including MCP `isError:true`, wrapped or raw). Keep
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
            let message = Self.projectedToolDispatchError(error)
            // A connector that says, in TYPED form, "there is no credential
            // yet" is not a failed call — it is a call that never started
            // because nobody has connected the account. That is a need, and
            // it becomes a card at the point of use instead of a sentence
            // telling the person to go find Connectors.
            //
            // Only `ConnectorCredentialsMissing` reaches here: an HTTP
            // rejection, a rate limit, a malformed argument, or a corrupt
            // store all return nil from that protocol and keep the failure
            // envelope below, exactly as before.
            if let connector = error.missingConnectorID {
                let need = InlineInteractionRegistry.connector(
                    connector,
                    why: message,
                    dataRoot: PersistenceCore.defaultDataRoot()
                )
                // isError is FALSE on purpose: nothing broke. The turn
                // suspends on the card; the model is not told a tool failed.
                return (InlineInteractionNeed.envelope(need), false)
            }
            return (ChatToolOutcome.failure(error: error, tool: prepared.internalName), true)
        }
    }

    private nonisolated static func isConnectorRead(_ name: String) -> Bool {
        connectorID(name) != nil
    }

    private nonisolated static func connectorID(_ name: String) -> String? {
        for (prefix, id) in [("notion_", "notion"), ("gmail_", "gmail"),
                             ("google_calendar_", "gcal"), ("mail_", "mail"),
                             ("github_", "github"), ("slack_", "slack"), ("x_", "x")] {
            if name.hasPrefix(prefix) { return id }
        }
        return nil
    }

    private nonisolated static func inputWithSessionIfNeeded(
        toolName: String,
        input: [String: JSONValue],
        sessionId: String?
    ) -> [String: JSONValue] {
        ChatToolSessionInjection.apply(toolName: toolName, input: input, sessionId: sessionId)
    }
}
