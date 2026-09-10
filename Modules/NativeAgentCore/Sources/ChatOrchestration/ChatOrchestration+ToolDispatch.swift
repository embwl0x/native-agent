import Foundation
import Dispatcher
import NativeAgentCore
import PersistenceCore
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
        let internalName: String
        let dispatchInput: [String: JSONValue]
    }

    /// Execute ONE iteration's batch of tool calls and return the
    /// tool_result blocks + dispatch records in ORIGINAL INDEX ORDER.
    ///
    /// This is the single implementation behind both the non-streaming and
    /// streaming loops, so the serial/parallel split cannot drift between
    /// them. The planning + concurrency window itself lives one level down in
    /// `runIterationDispatchGroups`, which the Claude text-compat loop also
    /// calls (A1, 2026-08-28) with its own slot finalization.
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
    ///
    /// `offeredToolNames` is the OFFERED/authorized set for this turn on the
    /// mid-conversation tool-change lane. The provider `tools` array there
    /// DECLARES the whole session catalog — most of it `defer_loading: true` —
    /// so the name map, which exists to translate wire aliases, is a superset
    /// of what the model is allowed to call. A `tool_use` naming a declared but
    /// NOT-offered tool is refused here and answered with an error
    /// `tool_result`: it never reaches a dispatch, never touches
    /// SwiftToolDispatcher's gates, and stays paired on the wire. nil (every
    /// other lane) means "no narrowing", i.e. today's behavior exactly.
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
        offeredToolNames: Set<String>? = nil,
        cancelFlagPath: URL? = nil
    ) async -> (blocks: [LLMContentBlock], records: [TurnEngineResult.ToolDispatchRecord]) {
        let planned: [(call: PreparedToolCall, offered: Bool)] = providerCalls
            .enumerated().compactMap { i, call in
                guard !ToolCallParser.isIgnorableToolName(call.name) else { return nil }
                let internalName = providerTools.internalName(forProviderName: call.name)
                let prepared = PreparedToolCall(
                    pairedId: i < pairedIds.count ? pairedIds[i] : call.id,
                    internalName: internalName,
                    dispatchInput: Self.inputWithSessionIfNeeded(
                        toolName: internalName,
                        input: call.input,
                        sessionId: sessionId
                    )
                )
                return (prepared, offeredToolNames?.contains(internalName) ?? true)
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
                    sessionId: sessionId
                )
            } else {
                out = await Self.makeSlotOutputs(
                    prepared: entry.call,
                    result: Self.notOfferedToolResult(entry.call.internalName),
                    isError: true,
                    sessionId: sessionId
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
        if let flag = cancelFlagPath,
           FileManager.default.fileExists(atPath: flag.path) { return true }
        return false
    }

    /// User, 2026-09-06: what a tool call that never ran because the turn was
    /// stopped reports. Shaped like the other slot outcomes so the wire pairing
    /// stays valid (every `tool_use` still gets its `tool_result`), but it says
    /// CANCELLED, not failed — the model must not read a Stop as a tool that
    /// tried and broke.
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

    /// The refusal a declared-but-not-offered `tool_use` gets back. Shaped
    /// exactly like a dispatch error so the loop, the no-progress guard and
    /// the transcript treat it as one — the model reads it as feedback and can
    /// `tool_load` the tool for real.
    nonisolated static func notOfferedToolResult(_ name: String) -> JSONValue {
        .object([
            "error": .string(
                "tool '\(name)' is declared but not currently offered in this "
                + "conversation, so it was not run. Call tool_load([\"\(name)\"]) "
                + "first, then call it."
            ),
            "not_offered": .bool(true),
        ])
    }

    /// One slot's dispatch outcome, carried back to the caller in ORIGINAL
    /// INDEX ORDER. Slot FINALIZATION (result-block shape, transcript rows)
    /// belongs to the caller: the structured loops and the Claude text-compat
    /// loop carry different result-block formats, but the safety veto, the
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
        let baseSafe = prepared.map {
            ParallelToolDispatch.isParallelSafe(internalToolName: $0.internalName)
        }
        let fleetOverrides = ParallelToolDispatch.fleetParallelOverrides(
            names: prepared.map(\.internalName),
            inputs: prepared.map(\.dispatchInput)
        )
        let groups = ParallelToolDispatch.plan(
            parallelSafe: zip(baseSafe, fleetOverrides).map { $1 ?? $0 },
            forceSerial: surface == "bot" || ParallelToolDispatch.effectiveForceSerial
        )

        var slots: [DispatchedSlot] = []
        slots.reserveCapacity(prepared.count)
        // Only native image reads can mint pixels. Bound each iteration to
        // four image-capable reads, including parallel dispatches.
        let imageIndices = Set(prepared.indices.filter { imagesEnabled && prepared[$0].internalName == "read_file" }.prefix(4))

        for group in groups {
            switch group {
            case .sequential(let idx):
                let p = prepared[idx]
                await onToolUse(p)
                if Self.dispatchCancelSignalled(cancelFlagPath) {
                    let cancelled = Self.cancelledToolResult(p.internalName)
                    await onOutcome(p, cancelled, true)
                    slots.append(DispatchedSlot(
                        index: idx, prepared: p, result: cancelled, isError: true, images: []
                    ))
                    continue
                }
                let imageSink = imageIndices.contains(idx) ? LocalToolImage.Sink() : nil
                let (result, isError) = await Self.runSingleDispatch(
                    prepared: p, modelId: modelId, surface: surface,
                    personaID: personaID,
                    fluidContextTurn: fluidContextTurn,
                    tools: tools, progress: progress, imageSink: imageSink
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
                                outcomes[idx] = (Self.cancelledToolResult(p.internalName), true, [])
                                continue
                            }
                            taskGroup.addTask {
                                let imageSink = imageIndices.contains(idx) ? LocalToolImage.Sink() : nil
                                let (result, isError) = await Self.runSingleDispatch(
                                    prepared: p, modelId: modelId, surface: surface,
                                    personaID: personaID,
                                    fluidContextTurn: fluidContextTurn,
                                    tools: tools, progress: progress, imageSink: imageSink
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
        sessionId: String? = nil
    ) async -> (record: TurnEngineResult.ToolDispatchRecord, block: LLMContentBlock) {
        let record = TurnEngineResult.ToolDispatchRecord(
            id: prepared.pairedId,
            name: prepared.internalName,
            input: prepared.dispatchInput,
            result: result
        )
        let resultStr: String = {
            if case .string(let s) = result { return s }
            return (try? result.serialize(pretty: false)) ?? "null"
        }()
        let redactedResultStr = ChatSecretRedactor.redactText(resultStr)
        let providerResultStr = await ProviderToolResultProjection.project(
            toolName: prepared.internalName,
            content: redactedResultStr,
            sessionId: sessionId,
            turnId: TurnTraceContext.turnId
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
    /// cleanly instead of freezing forever. An explicit disabled deadline
    /// (deadlineNanos == 0) takes the original un-raced path unchanged. The
    /// deadline task is added INSIDE the TaskLocal withValue scopes so the
    /// dispatch child still inherits the runtime ctx + notice bus.
    nonisolated static func projectedToolDispatchError(_ error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        let redacted = ChatSecretRedactor.redactText(raw)
        let home = NSHomeDirectory().trimmingCharacters(in: .whitespacesAndNewlines)
        let pathSafe = home.isEmpty
            ? redacted
            : redacted.replacingOccurrences(of: home, with: "~")
        return String(pathSafe.prefix(2_000))
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
        imageSink: LocalToolImage.Sink? = nil
    ) async -> (JSONValue, Bool) {
        let deadlineNanos = ToolDispatchDeadline.timeoutNanos(
            toolName: prepared.internalName,
            input: prepared.dispatchInput,
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
                    guard deadlineNanos > 0 else {
                        return try await tools.dispatch(
                            tool: prepared.internalName,
                            input: prepared.dispatchInput,
                            surface: surface
                        )
                    }
                    // User, 2026-09-06: the deadline used to be a throwing task
                    // group, and leaving a group waits for its cancelled
                    // children — so a connector that ignores cancellation held
                    // the turn open past the very ceiling this exists to
                    // enforce. Same resume-once shape as the provider wall.
                    let seconds = Double(deadlineNanos) / 1_000_000_000
                    let raced = await IntraTurnContextCompaction.withDeadline(
                        seconds: seconds
                    ) { () -> SingleDispatchRace in
                        do {
                            return .value(try await tools.dispatch(
                                tool: prepared.internalName,
                                input: prepared.dispatchInput,
                                surface: surface
                            ))
                        } catch {
                            return .thrown(error)
                        }
                    }
                    switch raced {
                    case .value(let result):
                        return result
                    case .thrown(let error):
                        throw error
                    case nil:
                        // A Stop resolves the gate with the same nil the ceiling
                        // does; keep cancellation its own outcome.
                        if Task.isCancelled { throw CancellationError() }
                        throw ToolDispatchDeadline.ToolDispatchTimedOut(
                            tool: prepared.internalName,
                            seconds: seconds
                        )
                    }
                }
            }
            }
            }
            // A nonthrowing transport can still carry a canonical failure
            // envelope (including MCP `isError:true`, wrapped or raw). Keep
            // the provider tool-result bit, persisted progress, and traces on
            // the same shared classification.
            return (result, !ChatToolOutcome.outputLooksSuccessful(result))
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
            return (Self.interruptedToolResult(prepared.internalName), true)
        } catch {
            let message = Self.projectedToolDispatchError(error)
            return (.object([
                "status": .string("failed"),
                "error": .string(message),
                "reason": .string(message),
            ]), true)
        }
    }

    private nonisolated static func inputWithSessionIfNeeded(
        toolName: String,
        input: [String: JSONValue],
        sessionId: String?
    ) -> [String: JSONValue] {
        ChatToolSessionInjection.apply(toolName: toolName, input: input, sessionId: sessionId)
    }
}
