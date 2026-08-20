import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import MemoryV2
import MCPDispatcher
import ProviderRouting
import TrustCenter
import KnowledgeGraph
import XConnector
import Dispatcher
import MacControl
import SwarmRuns
import MacIntegration
import CognitiveSubstrate

/// Per-ITERATION sink for provider-native tool_use blocks. Deliberately
/// constructed fresh inside each tool-loop iteration rather than once per turn:
/// a turn-scoped collector would have to be drained correctly on every one of
/// the loop's early-return paths (cancel, provider error, empty-reply recovery,
/// protocol violation), and a missed drain would leak iteration N's calls into
/// iteration N+1 as phantom dispatches. Fresh-per-iteration makes that class of
/// bug unrepresentable.
actor NativeToolCallCollector {
    private var calls: [LLMStreamToolCall] = []
    func append(_ call: LLMStreamToolCall) { calls.append(call) }
    /// Wire order preserved — P0 shape C requires ALL blocks to dispatch in
    /// the order the model emitted them.
    func drain() -> [LLMStreamToolCall] { calls }
}

extension SwiftNativeChatOrchestrationClient {
    /// Does THIS turn ride the provider-native tools lane?
    ///
    /// Resolution order mirrors the existing async text-compat gate: an already
    /// admitted provider id wins (it is the one the router actually bound),
    /// then the requested model's implied provider, then the surface's active
    /// provider. Every branch funnels through the single NativeToolCapability
    /// predicate, so "only kimi-code" is enforced in exactly one place and the
    /// Claude OAuth adapters can never be reached by this lane.
    func usesNativeToolLane(model: String, surface: String) async -> Bool {
        if let admitted = LLMCallContext.providerId {
            return NativeToolCapability.providerSupportsNativeTools(admitted)
        }
        if NativeToolCapability.modelImpliesNativeToolProvider(model) { return true }
        let active = try? await engine.checkedActiveProviderID(for: surface)
        return NativeToolCapability.providerSupportsNativeTools(active ?? nil)
    }

    /// Append user-role text to the native conversation WITHOUT creating two
    /// consecutive user turns: if the conversation already ends with a user
    /// message, the text rides as an extra block on that message.
    nonisolated static func appendNativeUserText(
        _ text: String,
        to conversation: inout [LLMMessage]
    ) {
        if let last = conversation.last, last.role == .user {
            conversation[conversation.count - 1] = LLMMessage(
                role: .user,
                content: last.content + [.text(text)]
            )
        } else {
            conversation.append(.user(text))
        }
    }

    func executeTextStreamingCompatibilityChat(
        message: String,
        sessionId: String?,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        progress: ChatOrchestrationProgressHandler?
    ) async throws -> StructuredChatExecution {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty {
            throw ChatOrchestrationError.emptyMessage
        }
        guard let streamingLLM else {
            throw ChatOrchestrationError.underlying("no streaming LLM client wired")
        }
        let resolvedSession = try Self.resolveSessionId(sessionId)
        // Suppressed-append turns adopt the enqueue-time runId (see
        // ChatPersistenceContext.pinnedTurnRunID) — same rule as the
        // structured path, so both routes exclude the pre-appended row.
        let runId = (suppressUserAppend ? ChatPersistenceContext.pinnedTurnRunID : nil)
            ?? UUID().uuidString

        // Turn Inspector W1: bind the per-turn trace id ONCE around the whole
        // tool loop (runTextStreamingCompatibility calls streamTurn once per
        // iteration; streamTurn inherits this id rather than minting a fresh
        // one each iteration, so all iterations of this turn share one story).
        // MEMORY-SAFETY (2026-07-04): bind the task-local INSIDE the Task with
        // the async withValue overload, never a sync withValue wrapping the
        // Task creation — see the matching note in StreamFacade.chatStream. The
        // old `withValue(turnId) { Task { … } }` shape freed task-local storage
        // on the parent while the child still referenced it → the
        // swift_task_dealloc_specific crash on first chat (G4-5).
        let turnId = TurnTraceContext.turnId ?? TurnTraceContext.mintTurnId()
        let producerControl = ChatStreamProducerControl()
        let stream = AsyncThrowingStream<TurnStreamEvent, Error> { continuation in
            let task = Task { [self] in
                defer { producerControl.resolve() }
                await TurnTraceContext.$bus.withValue(turnTraceBus) {
                await TurnTraceContext.$turnId.withValue(turnId) {
                    await runTextStreamingCompatibility(
                        message: message,
                        sessionId: resolvedSession,
                        runId: runId,
                        model: model,
                        reasoningEffort: reasoningEffort,
                        fileAccess: fileAccess,
                        attachments: attachments,
                        persona: persona,
                        surface: surface,
                        suppressUserAppend: suppressUserAppend,
                        streamingLLM: streamingLLM,
                        emitTextDeltas: false,
                        continuation: continuation
                    )
                }
                }
            }
            producerControl.install(task)
            continuation.onTermination = { termination in
                if case .cancelled = termination { producerControl.cancel() }
            }
        }

        var finalResult: TurnEngineResult?
        var lastError: String?
        var iterationError: Error?
        do {
            for try await event in stream {
                await observeCognitiveProgressEvent(
                    sessionId: resolvedSession,
                    runId: runId,
                    surface: surface,
                    event: event,
                    toolResultAlreadyPersisted: true
                )
                await progress?(event)
                switch event {
                case .final(let result):
                    finalResult = result
                case .error(let message):
                    lastError = message
                case .delta, .toolUse, .toolResult, .notice:
                    // .notice already forwarded via progress?(event) above.
                    break
                }
            }
        } catch {
            iterationError = error
            producerControl.cancel()
        }

        // The producer owns partial/cancellation persistence and may publish a
        // terminal event before that write settles. Joining is intentionally
        // cancellation-insensitive so regenerate cannot drain a replacement
        // turn ahead of the old producer's canonical receipt.
        if Task.isCancelled { producerControl.cancel() }
        await producerControl.wait()

        if Task.isCancelled || iterationError is CancellationError
            || Self.isCancellationStreamError(lastError) {
            throw CancellationError()
        }
        if let iterationError {
            let message = (iterationError as? LocalizedError)?.errorDescription
                ?? String(describing: iterationError)
            throw ChatOrchestrationError.underlying(message)
        }

        guard let finalResult else {
            throw ChatOrchestrationError.underlying(
                lastError ?? "anthropic text compatibility stream ended without final reply"
            )
        }

        let generatedAttachments = ChatGeneratedImageArtifacts.attachments(
            from: finalResult.toolDispatches,
            dataRoot: dataRoot
        )
        let response = ChatResponse(
            runId: runId,
            model: finalResult.modelUsed,
            requestedModel: model.isEmpty ? nil : model,
            reasoningEffort: finalResult.terminalObservation?.reasoningEffort
                ?? (reasoningEffort.isEmpty ? nil : reasoningEffort),
            output: finalResult.reply,
            sessionId: resolvedSession,
            personaFingerprint: Self.personaFingerprint(dataRoot: dataRoot),
            contextFingerprint: Self.contextFingerprint(recalledIds: finalResult.recalledIds),
            attachments: generatedAttachments.isEmpty ? nil : generatedAttachments,
            providerCallCount: finalResult.providerCallCount
        )
        return StructuredChatExecution(response: response, turn: finalResult)
    }

    private nonisolated static func isCancellationStreamError(_ error: String?) -> Bool {
        guard let normalized = error?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return normalized == "cancelled"
            || normalized == "canceled"
            || normalized == "cancellationerror()"
    }

    nonisolated static func shouldUseAnthropicTextStreamingCompatibility(
        model: String,
        surface: String
    ) -> Bool {
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isAnthropicTextCompatibilitySurface(normalizedSurface) else { return false }
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedModel.isEmpty else { return false }
        if normalizedModel.hasPrefix("anthropic/") { return true }
        if normalizedModel.hasPrefix("claude-") { return true }
        // Kimi Code subscription models speak the Anthropic wire protocol and
        // MUST ride this text-compat path: the API-key AnthropicAdapter never
        // sends native tools[], so text-compat's system-block tool contract is
        // what makes them tool-capable (gpt-5.5 review HIGH, 2026-07-18).
        if FirstPartyModelCatalog.kimiCodeModelIDSet.contains(normalizedModel) { return true }
        return normalizedModel.hasPrefix("opus")
            || normalizedModel.hasPrefix("sonnet")
            || normalizedModel.hasPrefix("haiku")
    }

    func shouldUseAnthropicTextStreamingCompatibility(
        model: String,
        surface: String
    ) async throws -> Bool {
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isAnthropicTextCompatibilitySurface(normalizedSurface) else { return false }
        if let admittedProvider = LLMCallContext.providerId {
            return Self.isAnthropicProviderId(admittedProvider)
        }
        if Self.shouldUseAnthropicTextStreamingCompatibility(model: model, surface: surface) {
            return true
        }
        guard let activeProvider = try await engine.checkedActiveProviderID(for: normalizedSurface) else {
            return false
        }
        return Self.isAnthropicProviderId(activeProvider)
    }

    private nonisolated static func isAnthropicTextCompatibilitySurface(_ surface: String) -> Bool {
        let compatibleSurfaces: Set<String> = [
            "chat", "telegram", "slack", "ios", "icloud", "iphone", "ipad", "mobile"
        ]
        return compatibleSurfaces.contains(surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private nonisolated static func isAnthropicProviderId(_ providerId: String) -> Bool {
        let normalized = providerId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        // kimi-code is an Anthropic-WIRE provider (Kimi Code subscription
        // endpoint) — its turns take the same text-compat contract.
        return normalized == "anthropic" || normalized.hasPrefix("anthropic_")
            || normalized == "kimi_code"
    }

    func runTextStreamingCompatibility(
        message: String,
        sessionId: String?,
        runId runIdOverride: String? = nil,
        model: String,
        reasoningEffort: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        surface: String,
        suppressUserAppend: Bool,
        streamingLLM: any StreamingLLMClient,
        emitTextDeltas: Bool,
        continuation: AsyncThrowingStream<TurnStreamEvent, Error>.Continuation
    ) async {
        let rawResolvedSession = sessionId ?? UUID().uuidString
        guard let resolvedSession = NativeAgentChatSessionID.normalizedPathComponent(rawResolvedSession) else {
            continuation.yield(.error("invalid chat session id"))
            continuation.finish()
            return
        }
        let recoveryScope = ProviderToolResultRecoveryStore.Scope(
            sessionId: resolvedSession,
            turnId: TurnTraceContext.turnId
        )
        defer {
            if let recoveryScope {
                Task { await ProviderToolResultRecoveryStore.shared.remove(scope: recoveryScope) }
            }
        }
        let runId = runIdOverride ?? UUID().uuidString
        let outputMilestoneGate = TurnLifecycleFirstOutputGate()
        TurnLifecycleTelemetry.emit(
            .turnAccepted,
            surface: surface,
            sessionId: resolvedSession,
            observedBy: "text_compat.entry"
        )
        let cancelFlagPath = dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(resolvedSession, isDirectory: true)
            .appendingPathComponent("cancelled.flag")
        // Clear only the marker inherited from a PRIOR turn, at the same
        // acceptance boundary as the structured provider lane. A Stop written
        // after acceptance must remain observable while persistence/context
        // work is in flight; clearing it later can erase a real remote Stop.
        try? FileManager.default.removeItem(at: cancelFlagPath)
        // Native vision: image attachments become per-turn DYNAMIC image blocks
        // on the CURRENT user message; the model sees the RAW message text (no
        // stringified suffix). Empty → byte-identical wire shape.
        let composed = message
        let imageBlocks = Self.imageBlocksFromAttachments(attachments)

        if !suppressUserAppend {
            do {
                try await appendMessage(
                    sessionId: resolvedSession,
                    role: "user",
                    content: message,
                    runId: runId,
                    attachments: attachments,
                    persona: persona,
                    source: surface
                )
            } catch is CancellationError {
                continuation.yield(.error("cancelled"))
                continuation.finish()
                return
            } catch {
                continuation.yield(.error("persist user turn failed: \(error)"))
                continuation.finish()
                return
            }
        }

        do {
            _ = try await compactSessionBeforeContextIfNeeded(
                sessionId: resolvedSession,
                model: model,
                surface: surface,
                runId: runId
            )
        } catch is CancellationError {
            continuation.yield(.error("cancelled"))
            continuation.finish()
            return
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if Self.shouldPersistFailureMessage(surface: surface) {
                try? await appendFailureMessageIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    errorMessage: "Autocompact failed before context assembly: \(message)",
                    persona: persona
                )
            }
            continuation.yield(.error("autocompact failed before context assembly: \(message)"))
            continuation.finish()
            return
        }

        let gated = makeTracedGatedDispatcher(
            fileAccess: fileAccess, verifiedSessionId: resolvedSession
        )
        async let residentPreparationTask = prepareResidentTurnInputs(
            message: message,
            surface: surface,
            sessionId: resolvedSession,
            fileAccess: fileAccess
        )
        async let preloadActiveToolsTask = activeToolsStore.load(sessionId: resolvedSession)
        async let preloadAvailableNamesTask: Set<String> = {
            Set(((try? await tools.listAvailableToolSchemas()) ?? []).map(\.name))
        }()

        // U1 step 7 fix (2026-06-10 review): this Anthropic text-compat path
        // was the one first-model-call site WITHOUT predictive preload — and
        // claude models stream through here, so it's the PRIMARY production
        // path. The preload is request-scoped: streamTurn and dispatch read it
        // through LLMCallContext.turnActiveTools so first-call schemas and the
        // lazy gate agree without growing the persisted ActiveToolsStore.
        // availableToolNames mirrors the context builder's catalog source:
        // tools.listAvailableToolSchemas() under fullMacToolAccess() policy
        // flags (ChatOrchestration+TurnEngine.swift buildTurnContext; the
        // factory hands engine + client the same dispatcher instance).
        let residentPreparation = await residentPreparationTask
        let turnPlan = residentPreparation.turnPlan
        let preloadActiveTools = await preloadActiveToolsTask.activeTools
        let preloadAvailableNames = await preloadAvailableNamesTask
        let preloadPrediction = turnPlan?.preloadPrediction
            ?? ToolPreloadHeuristics.predict(userMessage: message)
        let turnActiveTools = await ToolPreloadHeuristics.preloadIfConfident(
            prediction: preloadPrediction,
            sessionId: resolvedSession,
            activeTools: preloadActiveTools,
            availableToolNames: preloadAvailableNames,
            surface: surface,
            dataRoot: dataRoot
        )
        // Route focus now lives in TurnPlan's dynamic system segment, shared
        // by structured and text-compatible providers. Keeping it there makes
        // the cue identical across Mac, Telegram, Slack, and bridge surfaces,
        // and avoids a second, request-appended set of behavioral fences.
        let routedComposed = composed

        var accumulated = ""
        var pendingDelta = ""
        var dispatches: [TurnEngineResult.ToolDispatchRecord] = []
        var finalResult: TurnEngineResult?
        // Packet provenance (gpt-5.5 LOW, 2026-07-11): a protocol violation
        // clears finalResult, but the memories the turn USED don't un-happen —
        // retain the last seen recalledIds so the exhaustion fallback still
        // stamps them on the persisted assistant turn.
        var lastRecalledIds: [String] = []
        var sawFinal = false
        let maxToolIterations = toolLoopMaxIterations(for: surface)
        var currentUserMessage = routedComposed
        var announceNudgeCount = 0
        // K3 empty-reply recovery (2026-07-20 live: two turns died on
        // "HTTP 200 with no answer text (stop_reason=end_turn; content:
        // thinking×1)" — the model did the whole move inside its thinking
        // block and emitted zero text, deterministically enough that
        // identical whole-turn replays failed identically). In-loop feedback
        // is the fix, same plumbing as the protocol-violation and announce
        // nudges; bounded so a provider that only ever thinks can't loop.
        var emptyReplyNudgeCount = 0
        // 2026-07-21 audit fix: bound the protocol-violation bounce. Announce
        // and empty-reply nudges were capped (< 2) but a deterministically
        // malformed model could violate EVERY iteration — and since violation
        // iterations dispatch zero tools, the no-progress guard never fires —
        // burning the ENTIRE iteration budget (up to 180 provider calls on
        // telegram). Same philosophy: the third violation is accepted as
        // final (the post-loop exhausted path yields its terminalReply).
        var violationNudgeCount = 0
        var didCancel = false
        var exhaustedToolLoop = false
        var lastProtocolViolation: ToolCallProtocolViolation?
        var noProgressGuard = ToolLoopNoProgressGuard()
        var loopRecoveryReply: String?
        // C-H1 (2026-07-18): this text-compat loop is the PRIMARY Anthropic/Claude
        // chat path but never counted provider calls — streamTurn yields a
        // TurnEngineResult with providerCallCount:nil (one provider completion per
        // call), so ChatDrive/eval aggregations undercounted the main surface. The
        // loop OWNS the count (one streamTurn per iteration); stamp it onto every
        // result site this function emits, same pattern as the structured loops
        // (ChatOrchestration+ToolLoop.swift:1548 B3).
        var providerCallCount = 0

        let effectiveModel = LLMCallContext.admittedModel ?? model
        // The user's selected effort is the provider contract. The retired
        // adaptive-effort experiment no longer runs a pre-provider decision
        // or records a production intervention on ordinary chat.
        let effectiveReasoningEffort = LLMCallContext.reasoningEffort ?? reasoningEffort
        if let turnPlan {
            await TurnPlanTraceRecorder.append(
                turnPlan,
                runId: runId,
                surface: surface,
                dataRoot: dataRoot,
                turnTraceBus: turnTraceBus
            )
        }
        let cognitiveRuntimeContext = await textCompatibilityCognitiveRuntimeContext(
            surface: surface,
            userMessage: message,
            runId: runId,
            sessionId: resolvedSession,
            fileAccess: fileAccess,
            projection: residentPreparation.cognitiveProjection
        )
        // R-F1: held until the provider accepts the turn; nil when nothing was
        // actually appended to provider input.
        let pendingProjectionCommit: CognitiveTurnProjection? =
            cognitiveRuntimeContext == nil ? nil : residentPreparation.cognitiveProjection

        // U1 item 9 (F1 lane (b), text-compat): the grown single user
        // message re-paid its full mass to the provider EVERY tool-loop
        // iteration (F1 live measure: 12-18k input tokens/iteration; only
        // Anthropic's flaky server-side heuristic ever recovered any). New
        // default shape: an APPEND-ONLY [LLMMessage] conversation —
        // [user(composed)] + per iteration [assistant(raw reply incl.
        // markers), user(tool results)] — streamed over the adapter's real
        // messages SSE with a trailing message breakpoint, so iteration N+1
        // deterministically cache-READS everything through iteration N.
        // Eligibility is fail-closed to the legacy grown-prompt wire shape
        // (see isAppendOnlyMessagesEligible); NATIVE_AGENT_GROWN_PROMPT_
        // COMPAT=1 is the same one rollback lever item 8 shipped — it
        // restores the old grown-prompt shape here AND the old breakpoint
        // layout in the adapter.
        //
        // Known model-visible deltas vs the grown shape (QA-gate pinned
        // equivalent on fixtures, TextCompatAppendOnlyQATests): the model
        // now sees its own prior in-turn replies as assistant messages
        // (Claude-Code incremental framing), and memory recall is keyed on
        // the ORIGINAL user message every iteration instead of the
        // tool-result-polluted grown prompt (which also keeps the system
        // prompt byte-stable across iterations — the cache precondition).
        // turn-context-iteration-cache (2026-08-13): the append-only marker
        // lane now builds the turn context ONCE (iteration 1) and REUSES it
        // for every later iteration — catalog, clock line, and ContextFlow
        // packet all pin for the turn, native-structured-loop parity. The
        // per-iteration rebuild survives ONLY on the legacy grown-prompt
        // shape (its transcript rides ctx.userMessage) and the kimi native
        // lane (its provider tools array is its only call channel). Mid-turn
        // tool_load stays usable everywhere via schemas_added in its result
        // + the store-reading dispatch gate.
        // NATIVE TOOL LANE (kimi-code only). Resolved ONCE per turn — the
        // provider cannot change mid-turn, and re-resolving per iteration would
        // add a routing-snapshot read to every provider call.
        let nativeLane = await usesNativeToolLane(model: effectiveModel, surface: surface)
        var appendOnlyEligible = Self.isAppendOnlyMessagesEligible(
            streamingLLM: streamingLLM,
            dataRoot: dataRoot
        )
        // The native lane REQUIRES the structured messages transport: tool_use
        // and tool_result are content BLOCKS, and there is no way to express
        // them in the legacy grown-prompt string. The standard eligibility
        // check gates on Anthropic OAuth credentials (the only provider with a
        // real messages SSE implementation on the text-compat lane), which
        // kimi-code does not have and does not need — it rides the adapter's
        // non-streaming messages path. So a messages-capable client is the
        // whole requirement here.
        if nativeLane, streamingLLM is any MessagesStreamingLLMClient {
            appendOnlyEligible = true
        }
        // Fail closed and LOUD rather than silently degrading: without the
        // messages transport the native lane would ship a tools array whose
        // results could never be returned, so the model would call the same
        // tool forever. Drop back to the proven text-compat marker protocol.
        let ridesNativeTools = nativeLane && appendOnlyEligible
        // Image blocks ride the FIRST user message of the append-only
        // conversation (per-turn DYNAMIC). Later iterations append assistant +
        // tool-result user messages WITHOUT images — base64 is never re-sent.
        var conversation: [LLMMessage] = imageBlocks.isEmpty
            ? [.user(routedComposed)]
            : [.userWithImages(routedComposed, images: imageBlocks)]
        var emittedProviderFirstDelta = false
        // Sibling of the catalog pin: the clock line renders into the dynamic
        // system segment, and a turn crossing a minute boundary re-rendered
        // it mid-turn — byte-diff-proven cache bust. The turn is one moment:
        // freeze its instant here and pass it to every iteration's build.
        let turnClockNow = Date()
        // Third pin (see streamTurn.preBuiltContext): iteration 1's fully
        // built context is captured and reused for every later iteration, so
        // ContextFlow prepares ONCE per turn and the packet bytes cannot
        // reshuffle mid-turn as her attention moves with tool results.
        // Kimi native lane exempt (its per-iteration tools-array refresh is
        // load-bearing). Box is @unchecked Sendable: written once inside
        // iteration 1's stream (before its first yield), read only after
        // that stream completes — sequential access by construction.
        final class TurnContextBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: TurnContext?
            func set(_ ctx: TurnContext) { lock.lock(); if value == nil { value = ctx }; lock.unlock() }
            func get() -> TurnContext? { lock.lock(); defer { lock.unlock() }; return value }
        }
        let turnContextBox = TurnContextBox()
        // Reuse ONLY on the append-only messages transport: the legacy
        // grown-prompt shape carries the growing transcript INSIDE
        // ctx.userMessage, so it structurally requires a fresh build per
        // iteration (QA2/QA3/QA6 pin that carrier byte-for-byte). Kimi
        // native lane exempt for its tools-array refresh.
        let reuseTurnContext = !ridesNativeTools && appendOnlyEligible
        let onTurnContextBuilt: (@Sendable (TurnContext) -> Void)? =
            reuseTurnContext ? { @Sendable ctx in turnContextBox.set(ctx) } : nil

        toolLoop: for iteration in 0..<maxToolIterations {
            providerCallCount += 1
            var iterAccumulated = ""
            var iterFinal: TurnEngineResult?
            var emptyReplyRecovery = false
            // Fresh per iteration — see NativeToolCallCollector's note.
            let nativeCollector = ridesNativeTools ? NativeToolCallCollector() : nil
            var nativeSink: (@Sendable (LLMStreamToolCall) async -> Void)?
            if let nativeCollector {
                nativeSink = { @Sendable call in await nativeCollector.append(call) }
            }
            let reusedTurnContext = reuseTurnContext ? turnContextBox.get() : nil
            // MEMORY-SAFETY (2026-07-04): pass turnActiveTools EXPLICITLY so
            // streamTurn binds it inside its own child Task. The old sync
            // `LLMCallContext.$turnActiveTools.withValue { engine.streamTurn(…) }`
            // wrap popped the task-local on THIS task while streamTurn's spawned
            // Task still referenced it → task-allocator LIFO violation ("freed
            // pointer was not the last allocation"), the deterministic release
            // crash on first chat (reproduced headlessly via chat-drive).
            // turn-context-iteration-cache (2026-08-13): pin the advertised
            // tool catalog to the turn-start set for the whole turn. Without
            // this, a mid-turn tool_load grew the catalog inside the STABLE
            // cache-breakpointed system segment on the next iteration's
            // rebuild — byte-diff-proven prefix kill (369k cache-creation
            // tokens on live turn 47ee5b6d). Dispatch still honors the store
            // per call and tool_load returns schemas_added, so a just-loaded
            // tool is usable THIS turn. The kimi native lane keeps the fresh
            // store read: its provider tools array is the only channel its
            // model can call a tool through, so next-iteration refresh is
            // load-bearing there (and its providers don't use Anthropic
            // prefix caching).
            let stream = engine.streamTurn(
                surface: surface,
                userMessage: appendOnlyEligible ? routedComposed : currentUserMessage,
                sessionId: resolvedSession,
                streamingLLM: streamingLLM,
                historyLimit: historyLimit,
                historyReader: history,
                personaOverride: persona,
                modelOverride: effectiveModel,
                reasoningEffortOverride: effectiveReasoningEffort,
                excludeHistoryRunId: runId,
                cancelFlagPath: cancelFlagPath,
                textToolCompatibility: true,
                conversation: appendOnlyEligible ? conversation : nil,
                turnPlan: turnPlan,
                runtimeContext: cognitiveRuntimeContext,
                providerIDOverride: nil,
                turnActiveTools: turnActiveTools,
                pinnedActiveTools: ridesNativeTools ? nil : turnActiveTools,
                clockNowOverride: turnClockNow,
                preBuiltContext: reusedTurnContext,
                onContextBuilt: onTurnContextBuilt,
                imageBlocks: imageBlocks,
                nativeTools: ridesNativeTools,
                nativeToolCallSink: nativeSink,
                // Relevance consumers see the RAW message; the tool-routing
                // hint (and any loop nudges grown onto currentUserMessage)
                // stay wire-only. Without this, the hint's tool names are
                // selection-query vocabulary on every text-compat turn.
                queryUserMessage: message
            )
            do {
                for try await event in stream {
                    if Task.isCancelled {
                        didCancel = true
                        break
                    }
                    switch event {
                    case .delta(let s):
                        if !s.isEmpty, !emittedProviderFirstDelta {
                            emittedProviderFirstDelta = true
                            TurnLifecycleTelemetry.emit(
                                .providerFirstDelta,
                                surface: surface,
                                sessionId: resolvedSession,
                                observedBy: "text_compat.stream"
                            )
                        }
                        iterAccumulated += s
                        if emitTextDeltas {
                            pendingDelta += s
                            let enqueued = Self.flushCompatibilityDeltaBuffer(
                                &pendingDelta,
                                force: false,
                                continuation: continuation
                            )
                            if enqueued, await outputMilestoneGate.claim() {
                                TurnLifecycleTelemetry.emit(
                                    .surfaceOutputEnqueued,
                                    surface: surface,
                                    sessionId: resolvedSession,
                                    observedBy: "text_compat.continuation"
                                )
                            }
                        }
                    case .toolUse, .toolResult, .notice:
                        continuation.yield(event)
                    case .final(let r):
                        iterFinal = r
                        finalResult = r
                        if !r.recalledIds.isEmpty { lastRecalledIds = r.recalledIds }
                    case .error(let m):
                        if m == "cancelled" {
                            didCancel = true
                            continuation.yield(.error(m))
                            break   // breaks the switch; the producer finishes
                                    // after .error so the loop ends and the
                                    // didCancel block (~2171) persists cancelled:true
                        }
                        // "no answer text" is the adapter's own grammar for a
                        // thinking-only empty 200/stream (emptyTextResponseError
                        // / the stream message_stop guard, both test-pinned).
                        // Recoverable in-loop: swallow the event (no .error
                        // reaches the surface), then nudge-continue below —
                        // an identical whole-turn replay is proven useless
                        // against this shape (13:08Z live, retried same-fail).
                        if m.contains("no answer text"),
                           iterAccumulated.isEmpty,
                           emptyReplyNudgeCount < 2 {
                            emptyReplyRecovery = true
                            break
                        }
                        // Provider failures arriving as ENGINE-YIELDED .error
                        // events bypassed the thrown-stream catch's post-tool-
                        // effect wrap below, so a surface retry ladder saw a
                        // bare retryable string and replayed already-run tools
                        // (gpt-5.5 BLOCKING, 2026-07-20 — the 13:08Z live error
                        // carried no marker despite 3 dispatches). Stamp the
                        // same cross-module marker contract here.
                        let m = dispatches.isEmpty
                            ? m
                            : "provider failure after \(dispatches.count) tool "
                              + "dispatch(es) [\(ProviderErrorAfterToolEffects.markerPhrase)]: \(m)"
                        // Real provider error mid-turn: TERMINAL. A plain `break`
                        // only exits the switch (Swift semantics), so the loop
                        // would fall through to ToolCallParser.parse (~2182) —
                        // dispatching a tool AFTER the turn already failed, and
                        // the no-marker path would persist the partial mislabeled
                        // as cancelled:true (~2311). Surface the error and persist
                        // the partial as a NON-cancel truncation. CRITICAL: stream
                        // + persist only the VISIBLE prose BEFORE any tool marker —
                        // a marker that was mid-emission when the stream failed must
                        // never render or persist as raw text (audit #1; the #6
                        // force-flush would otherwise leak it — gpt-5.5 review
                        // 2026-06-14).
                        if emitTextDeltas {
                            if let r = ToolCallParser.earliestPotentialProtocolMarker(in: pendingDelta) {
                                let safe = String(pendingDelta[..<r.lowerBound])
                                if !safe.isEmpty { continuation.yield(.delta(safe)) }
                            } else {
                                // force-flush: the compat buffer holds back a
                                // <=16-char tail, so a short reply like "Hello"
                                // would be lost on this early return otherwise.
                                let enqueued = Self.flushCompatibilityDeltaBuffer(
                                    &pendingDelta,
                                    force: true,
                                    continuation: continuation
                                )
                                if enqueued, await outputMilestoneGate.claim() {
                                    TurnLifecycleTelemetry.emit(
                                        .surfaceOutputEnqueued,
                                        surface: surface,
                                        sessionId: resolvedSession,
                                        observedBy: "text_compat.continuation"
                                    )
                                }
                            }
                            pendingDelta.removeAll(keepingCapacity: true)
                        }
                        continuation.yield(.error(m))
                        var partialVisible: String = {
                            let full = accumulated + iterAccumulated
                            if let r = ToolCallParser.earliestPotentialProtocolMarker(in: full) {
                                return String(full[..<r.lowerBound])
                            }
                            return full
                        }()
                        // Transcript honesty, ENGINE-YIELDED error path (live
                        // 2026-07-20 16:19Z: a native-lane 400 died here with
                        // no stub, no trace — the turn just vanished; only the
                        // bridge event ring held the reason). Same stub the
                        // thrown-catch path persists.
                        if partialVisible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            partialVisible = "(reply failed before any text: \(String(m.prefix(240))))"
                        }
                        TurnTraceBus.fireFromContext(
                            kind: "turn.failed",
                            surface: surface,
                            payload: .object([
                                "reason": .string(String(m.prefix(200))),
                                "iteration": .int(Int64(iteration)),
                                "dispatchCount": .int(Int64(dispatches.count)),
                            ])
                        )
                        await persistPartialIfNeeded(
                            sessionId: resolvedSession,
                            runId: runId,
                            text: partialVisible,
                            cancelled: false,
                            source: surface,
                            outcomeInterventionAssignment: nil,
                            onNotice: { kind, text in continuation.yield(.notice(kind: kind, text: text)) }
                        )
                        continuation.finish()
                        return
                    }
                }
            } catch is CancellationError {
                didCancel = true
                continuation.yield(.error("cancelled"))
            } catch {
                // Marker-wrap post-tool-effect failures so the surface retry
                // ladder (Telegram) sees "whole-turn retry unsafe" in the event
                // text and does not replay a turn whose tools already ran.
                let surfaced = ProviderErrorAfterToolEffects.wrapping(error, dispatchCount: dispatches.count)
                TurnTraceBus.fireFromContext(
                    kind: "turn.failed",
                    surface: surface,
                    payload: .object([
                        "reason": .string(String(String(describing: surfaced).prefix(200))),
                        "iteration": .int(Int64(iteration)),
                        "dispatchCount": .int(Int64(dispatches.count)),
                    ])
                )
                continuation.yield(.error("stream error: \(surfaced)"))
                // accumulated only absorbs an iteration's text after it
                // completes call-free; the text the user just watched render
                // is still in iterAccumulated. Persist both, or a mid-stream
                // provider error silently loses the whole partial reply.
                var partialVisible: String = {
                    let full = accumulated + iterAccumulated
                    if let r = ToolCallParser.earliestPotentialProtocolMarker(in: full) {
                        return String(full[..<r.lowerBound])
                    }
                    return full
                }()
                // Transcript honesty (2026-07-19 Kimi 403 incident): a turn
                // that dies BEFORE any text leaves a hole in the session —
                // the next turn's history shows User's message with no reply
                // and the model has no idea the failure happened. Persist a
                // short honest stub so the conversation itself carries the
                // failure, on every surface.
                if partialVisible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let reason = (surfaced as? LocalizedError)?.errorDescription
                        ?? String(describing: surfaced)
                    partialVisible = "(reply failed before any text: \(String(reason.prefix(240))))"
                }
                await persistPartialIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    text: partialVisible,
                    cancelled: false,
                    source: surface,
                    outcomeInterventionAssignment: nil,
                    onNotice: { kind, text in continuation.yield(.notice(kind: kind, text: text)) }
                )
                continuation.finish()
                return
            }
            if didCancel {
                let partialVisible: String = {
                    let full = accumulated + iterAccumulated
                    if let r = ToolCallParser.earliestPotentialProtocolMarker(in: full) {
                        return String(full[..<r.lowerBound])
                    }
                    return full
                }()
                await persistPartialIfNeeded(
                    sessionId: resolvedSession,
                    runId: runId,
                    text: partialVisible,
                    cancelled: true,
                    source: surface,
                    outcomeInterventionAssignment: nil,
                    onNotice: { kind, text in continuation.yield(.notice(kind: kind, text: text)) }
                )
                continuation.finish()
                return
            }

            if emptyReplyRecovery {
                emptyReplyNudgeCount += 1
                finalResult = nil
                sawFinal = false
                pendingDelta.removeAll(keepingCapacity: true)
                // Lane-aware: telling a native-tools model to emit marker text
                // would instruct it to produce output this lane no longer
                // parses — the nudge would actively cause the next failure.
                // The TEXT-lane string is BYTE-IDENTICAL to the pre-native-lane
                // wording (gpt-5.5 blocking, 2026-07-20: a lane-generic rewrite
                // silently changed provider-visible text for every non-kimi
                // provider on the recovery path).
                let feedback = ridesNativeTools
                    ? "Your previous response contained only internal "
                        + "reasoning and NO output — nothing reached the user or "
                        + "the tool runtime, so whatever you decided never happened. "
                        + "Respond again NOW: either make the tool call(s) for the "
                        + "action you chose, or deliver your complete answer as "
                        + "plain prose. The response must never be empty."
                    : "Your previous response contained only internal "
                        + "reasoning and NO text output — nothing reached the user or "
                        + "the tool runtime, so whatever you decided never happened. "
                        + "Respond again NOW with actual text: either emit the "
                        + "<tool_use name=\"tool_name\">{\"arg\": \"value\"}</tool_use> "
                        + "marker(s) for the action you chose, or deliver your complete "
                        + "answer as plain prose. The text channel must never be empty."
                if ridesNativeTools {
                    // MERGE, don't append. An empty reply produces NO assistant
                    // message, so a fresh user message here would follow the
                    // previous iteration's tool_result user message — two
                    // consecutive user turns. The Anthropic wire expects
                    // alternating roles, and this lane is the one that actually
                    // ships structured turns, so fold the nudge into the
                    // trailing user message instead of risking a 400 on the
                    // recovery path (which is exactly when we can least afford
                    // another failure).
                    Self.appendNativeUserText(feedback, to: &conversation)
                } else if appendOnlyEligible {
                    conversation.append(.user(feedback))
                } else {
                    currentUserMessage += "\n\n" + feedback
                }
                continue toolLoop
            }
            // NATIVE LANE: the structured tool calls the provider actually
            // emitted this iteration, in wire order. Empty on the text lane.
            let nativeCalls = await nativeCollector?.drain() ?? []
            if ridesNativeTools {
                // The marker protocol is NOT this lane's contract, so a reply
                // that merely LOOKS like a formatted marker is ordinary prose
                // here — running the violation detector would bounce valid
                // answers (e.g. the model explaining tool syntax to the user).
                lastProtocolViolation = nil
            } else if let violation = ToolCallParser.formattedToolCallViolation(in: iterAccumulated) {
                lastProtocolViolation = violation
                violationNudgeCount += 1
                if violationNudgeCount > 2 {
                    exhaustedToolLoop = true
                    break toolLoop
                }
                finalResult = nil
                sawFinal = false
                pendingDelta.removeAll(keepingCapacity: true)
                if iteration == maxToolIterations - 1 {
                    exhaustedToolLoop = true
                }
                if appendOnlyEligible {
                    conversation.append(.assistantText(iterAccumulated))
                    conversation.append(.user(violation.modelFeedback))
                } else {
                    currentUserMessage += "\n\n" + ToolCallParser.feedbackIncludingRejectedOutput(
                        iterAccumulated,
                        violation: violation
                    )
                }
                continue toolLoop
            }
            if !ridesNativeTools { lastProtocolViolation = nil }
            // ONE `calls` list feeds ONE dispatch block for both lanes. Native
            // tool_use blocks are mapped into the same ParsedToolCall shape the
            // marker parser produces, so dispatch keeps the identical gating,
            // dispatch records, transcript rows and tool.dispatch traces — only
            // the way the call was DECLARED on the wire differs.
            let calls: [ParsedToolCall] = ridesNativeTools
                ? nativeCalls.map { call in
                    var input: [String: JSONValue] = [:]
                    if let parsed = try? JSONValue.parse(call.inputJSON),
                       case .object(let obj) = parsed {
                        input = obj
                    }
                    return ParsedToolCall(id: call.id, name: call.name, input: input)
                }
                : ToolCallParser.parse(iterAccumulated)
            if calls.isEmpty {
                // Completion-contract guard (2026-07-19; round 2 after the
                // live incident showed round 1 was too narrow): a final reply
                // that is in-progress-shaped ("reading the README now") is not
                // a valid stopping point in an agent runtime with NO background
                // execution — whether or not tools already ran this turn (the
                // real miss: two dispatches, then narration, then stop). Bounce
                // through the violation-feedback plumbing, at most TWICE per
                // turn; a third promise is accepted as final so a model that
                // refuses to act can never loop. Worst case = 2 extra provider
                // calls on a turn that was already broken for the user.
                // R7 rides the same bounce: `**Tool: desk_read**` as the whole
                // reply is an attempted call that never left the text channel.
                if announceNudgeCount < 2, !preloadAvailableNames.isEmpty,
                   ToolCallParser.looksLikeUnfulfilledActionPromise(iterAccumulated)
                    || ToolCallParser.looksLikeNarratedToolInvocation(
                        iterAccumulated,
                        knownToolNames: preloadAvailableNames.union(turnActiveTools)
                    ) {
                    announceNudgeCount += 1
                    finalResult = nil
                    sawFinal = false
                    pendingDelta.removeAll(keepingCapacity: true)
                    let readySource = turnActiveTools.isEmpty ? preloadAvailableNames : turnActiveTools
                    let readyTools = readySource.sorted().prefix(8).joined(separator: ", ")
                    // Same lane-awareness as the empty-reply nudge: the
                    // announce detector still applies to FINAL prose on the
                    // native lane, but the remedy it prescribes must match the
                    // lane's actual calling convention.
                    let nextStepInstruction = ridesNativeTools
                        ? "make the next tool call"
                        : "emit the next <tool_use name=\"tool_name\">{\"arg\": \"value\"}"
                            + "</tool_use> marker(s)"
                    let feedback: String
                    if announceNudgeCount == 1 {
                        feedback = "NativeAgent completion contract: your reply describes work "
                            + "as in progress but this runtime has NO background execution — "
                            + "work you narrate without a tool call never happens, and the "
                            + "user is left waiting. Continue NOW in this same turn: "
                            + "\(nextStepInstruction), or deliver your complete final answer. "
                            + "Tools ready: \(readyTools)."
                    } else if ridesNativeTools {
                        feedback = "SECOND bounce — you again narrated instead of acting. This "
                            + "is your last continuation: either make the tool call for the "
                            + "next step right now, or give the user your "
                            + "complete final answer (including any concrete blocker). Do not "
                            + "describe future work."
                    } else {
                        // BYTE-IDENTICAL to the pre-native-lane wording for
                        // every text-lane provider (gpt-5.5 blocking #2).
                        feedback = "SECOND bounce — you again narrated instead of acting. This "
                            + "is your last continuation: either emit the exact tool_use "
                            + "marker for the next step right now, or give the user your "
                            + "complete final answer (including any concrete blocker). Do not "
                            + "describe future work."
                    }
                    if appendOnlyEligible {
                        conversation.append(.assistantText(iterAccumulated))
                        conversation.append(.user(feedback))
                    } else {
                        currentUserMessage += "\n\n" + feedback
                    }
                    continue toolLoop
                }
                // Marker stripping is a TEXT-lane concern. On the native lane
                // the model's prose is just prose — rewriting it because it
                // happens to contain marker-shaped text would corrupt a
                // legitimate answer (e.g. one that quotes tool syntax).
                let ignoredOnly = ridesNativeTools
                    ? false
                    : ToolCallParser.containsOnlyIgnorableCalls(iterAccumulated)
                let visibleIteration = ignoredOnly
                    ? ToolCallParser.stripToolUseMarkers(iterAccumulated)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    : iterAccumulated
                sawFinal = iterFinal != nil
                accumulated += visibleIteration
                if emitTextDeltas {
                    if ignoredOnly {
                        pendingDelta = ToolCallParser.stripToolUseMarkers(pendingDelta)
                    }
                    let enqueued = Self.flushCompatibilityDeltaBuffer(
                        &pendingDelta,
                        force: true,
                        continuation: continuation
                    )
                    if enqueued, await outputMilestoneGate.claim() {
                        TurnLifecycleTelemetry.emit(
                            .surfaceOutputEnqueued,
                            surface: surface,
                            sessionId: resolvedSession,
                            observedBy: "text_compat.continuation"
                        )
                    }
                }
                if let r = iterFinal {
                    let finalWithDispatches = Self.turnResult(
                        r,
                        replacingToolDispatchesWith: dispatches,
                        rawLLMResponse: accumulated.isEmpty ? r.rawLLMResponse : accumulated,
                        providerCallCount: providerCallCount,
                        replyOverride: ignoredOnly ? visibleIteration : nil
                    )
                    finalResult = finalWithDispatches
                    continuation.yield(.final(finalWithDispatches))
                }
                break toolLoop
            }
            pendingDelta.removeAll(keepingCapacity: true)

            if iteration == maxToolIterations - 1 {
                exhaustedToolLoop = true
            }

            // U1 item 9: the model's raw reply (prose + markers, exactly as
            // emitted) becomes the appended assistant message; this
            // iteration's tool results accumulate into ONE user message
            // appended after the dispatch loop. The per-call result text is
            // the SAME literal the grown shape appends — only the carrier
            // changes (new message vs string growth).
            //
            // SERIAL DISPATCH — INTENTIONAL (gpt-5.5 review 2026-06-11):
            // this inline call-by-call loop deliberately preserves the
            // legacy compat path's serial semantics — zero behavior change
            // vs the pre-item-9 production loop. Unifying it onto
            // ChatOrchestration+ToolLoop's dispatchIterationCalls (which
            // would introduce PARALLEL dispatch here, the step-6 semantics)
            // is a named follow-up, NOT part of item 9. See the matching
            // Decisions entry in docs/build_plans/u1-performance-core.md
            // (2026-06-11).
            var iterationToolResults = ""
            // NATIVE LANE: the append-only conversation carries real content
            // blocks instead of prose. The assistant message replays the
            // model's own tool_use blocks (its ORIGINAL argument bytes, not our
            // session-injected dispatch input — the transcript must say what
            // the model said), and the following user message carries one
            // tool_result per call, paired by tool_use_id (P0 shape B).
            var nativeToolUseBlocks: [LLMContentBlock] = []
            var nativeToolResultBlocks: [LLMContentBlock] = []
            let iterationDispatchStart = dispatches.count

            for (index, call) in calls.enumerated() {
                let dispatchInput = Self.inputWithSessionIfNeeded(
                    toolName: call.name,
                    input: call.input,
                    sessionId: resolvedSession
                )
                let inputObj: JSONValue = .object(dispatchInput)
                let redactedInput = ChatSecretRedactor.redactValue(inputObj)
                continuation.yield(.toolUse(name: call.name, input: redactedInput))
                // Use the same deadline/runtime/notice dispatch core as the
                // structured loops. This closes the former Claude text-compat
                // carve where an interactive tool could still hang forever.
                let prepared = SwiftNativeTurnEngine.PreparedToolCall(
                    pairedId: call.id,
                    internalName: call.name,
                    dispatchInput: dispatchInput
                )
                let (result, isError) = await LLMCallContext.$turnActiveTools.withValue(turnActiveTools) {
                    await SwiftNativeTurnEngine.runSingleDispatch(
                        prepared: prepared,
                        modelId: model,
                        surface: surface,
                        tools: gated,
                        progress: { event in
                            if case .notice(let kind, let text) = event {
                                continuation.yield(.notice(kind: kind, text: text))
                            }
                        }
                    )
                }
                let ok = !isError
                dispatches.append(TurnEngineResult.ToolDispatchRecord(
                    id: call.id,
                    name: call.name,
                    input: dispatchInput,
                    result: result
                ))
                let redactedResult = ChatSecretRedactor.redactValue(result)
                continuation.yield(.toolResult(name: call.name, output: redactedResult))
                let inputJSON = (try? redactedInput.serialize(pretty: false)) ?? "{}"
                let resultJSON = (try? redactedResult.serialize(pretty: false)) ?? "null"
                let providerResultJSON = await ProviderToolResultProjection.project(
                    toolName: call.name,
                    content: resultJSON,
                    sessionId: resolvedSession,
                    turnId: TurnTraceContext.turnId
                )
                do {
                    try await appendToolMessage(
                        sessionId: resolvedSession,
                        runId: runId,
                        toolName: call.name,
                        inputJSON: inputJSON,
                        resultSummary: resultJSON,
                        ok: ok,
                        cognitiveResult: ChatToolOutcome.cognitiveResult(
                            tool: call.name,
                            output: redactedResult
                        ),
                        source: surface
                    )
                } catch {
                    // M2 completion (gpt-5.5 review HIGH, 2026-07-09): the sweep
                    // fixed the structured path and missed this text-compat twin —
                    // the same dropped-receipt silent loss, same fail-loud remedy.
                    await Self.reportTranscriptWriteFailure(
                        label: "appendToolMessage(\(call.name)) [text-compat]",
                        path: self.dataRoot,
                        error: error,
                        userText: "Couldn't save the receipt for tool '\(call.name)' - it won't appear in the saved transcript.",
                        onNotice: nil
                    )
                }
                let toolResultBlock = """

                NativeAgent tool result for \(call.name):
                \(providerResultJSON)
                Use this verified result. If more action is needed, emit another exact <tool_use name="...">{...}</tool_use> marker; otherwise answer the user directly.
                """
                if ridesNativeTools {
                    if index < nativeCalls.count {
                        let native = nativeCalls[index]
                        // Replayed tool_use blocks go back over the wire next
                        // iteration, and the collector holds INTERNAL names
                        // (the sink reverse-maps before dispatch). Re-sanitize
                        // for the wire — Kimi validates name characters in
                        // blocks exactly like the tools array (the live 400).
                        // Static transform, not the per-iteration map: a
                        // collision-suffixed alias would differ, but the
                        // provider validates CHARACTERS, not catalog
                        // membership, and history may legitimately reference
                        // unloaded tools.
                        nativeToolUseBlocks.append(.toolUse(
                            id: native.id,
                            name: ProviderToolNameMap.providerName(for: native.name),
                            inputJSON: native.inputJSON
                        ))
                    }
                    nativeToolResultBlocks.append(.toolResult(
                        toolUseId: call.id,
                        content: providerResultJSON,
                        isError: !ok
                    ))
                } else if appendOnlyEligible {
                    iterationToolResults += toolResultBlock
                } else {
                    currentUserMessage += toolResultBlock
                }
            }

            var stopForNoProgress = false
            let iterationRecords = Array(dispatches[iterationDispatchStart...])
            switch noProgressGuard.observe(iterationRecords) {
            case .none:
                break
            case .warn(let feedback):
                continuation.yield(.notice(kind: "tool_loop_recovery", text: feedback))
                // 2026-07-21 audit fix: model-directed WARN guidance must
                // reach the MODEL, not just the user (see the structured
                // loop's matching fix) — ride it on the SAME user message as
                // the tool results, like the stop branch's recovery block.
                let warnBlock = "\n\nNativeAgent recovery guidance:\n\(feedback)"
                if ridesNativeTools {
                    nativeToolResultBlocks.append(.text(warnBlock))
                } else if appendOnlyEligible { iterationToolResults += warnBlock }
                else { currentUserMessage += warnBlock }
            case .stop(let feedback):
                let block = "\n\nNativeAgent recovery guidance:\n\(feedback)"
                if ridesNativeTools {
                    // Rides as a trailing text block on the SAME user message
                    // as the tool_results — Anthropic allows mixed blocks, and
                    // a separate message would break tool_result adjacency.
                    nativeToolResultBlocks.append(.text(block))
                } else if appendOnlyEligible { iterationToolResults += block }
                else { currentUserMessage += block }
                loopRecoveryReply = feedback
                exhaustedToolLoop = true
                stopForNoProgress = true
            }

            if ridesNativeTools {
                // Assistant turn = its prose (if any) THEN its tool_use blocks.
                // A tool-only response legitimately has no text at all (P0
                // contract note 1) — the adapter's encoder drops empty text
                // blocks, so we can append unconditionally.
                var assistantBlocks: [LLMContentBlock] = []
                if !iterAccumulated.isEmpty { assistantBlocks.append(.text(iterAccumulated)) }
                assistantBlocks.append(contentsOf: nativeToolUseBlocks)
                conversation.append(LLMMessage(role: .assistant, content: assistantBlocks))
                conversation.append(LLMMessage(role: .user, content: nativeToolResultBlocks))
            } else if appendOnlyEligible {
                conversation.append(.assistantText(iterAccumulated))
                conversation.append(.user(iterationToolResults))
            }
            if stopForNoProgress { break toolLoop }
        }

        if exhaustedToolLoop && !sawFinal {
            let fallback = loopRecoveryReply ?? lastProtocolViolation?.terminalReply
                ?? ToolLoopExhaustion.fallbackReply(
                    iterationLimit: maxToolIterations,
                    dispatchCount: dispatches.count
                )
            let fallbackResult = TurnEngineResult(
                reply: fallback,
                modelUsed: finalResult?.modelUsed ?? effectiveModel,
                recalledIds: finalResult?.recalledIds ?? lastRecalledIds,
                toolDispatches: dispatches,
                elapsedMs: finalResult?.elapsedMs ?? 0,
                rawLLMResponse: finalResult?.rawLLMResponse ?? accumulated,
                providerCallCount: providerCallCount,
                terminalObservation: finalResult?.terminalObservation
            )
            finalResult = fallbackResult
            continuation.yield(.final(fallbackResult))
        }

        if !sawFinal && !exhaustedToolLoop && (Task.isCancelled || finalResult == nil) {
            await persistPartialIfNeeded(
                sessionId: resolvedSession,
                runId: runId,
                text: accumulated,
                cancelled: true,
                source: surface,
                outcomeInterventionAssignment: nil,
                onNotice: { kind, text in continuation.yield(.notice(kind: kind, text: text)) }
            )
            continuation.finish()
            return
        }

        // R-F1: every failure path above (mid-stream provider error, thrown
        // stream error, cancel, no-final bailout) returned early — reaching
        // here means the provider accepted the turn (a final reply, or an
        // exhausted tool loop whose provider calls all carried the capsule).
        // Commit the projection exactly once, now.
        await commitDeliveredCognitiveTurnProjection(
            pendingProjectionCommit,
            surface: surface,
            userMessage: message,
            sessionId: resolvedSession
        )

        let replyText = finalResult?.reply ?? accumulated
        if !replyText.isEmpty {
            do {
                let generatedAttachments = ChatGeneratedImageArtifacts.attachments(
                    from: finalResult?.toolDispatches ?? [],
                    dataRoot: dataRoot
                )
                try await appendMessage(
                    sessionId: resolvedSession,
                    role: "assistant",
                    content: replyText,
                    runId: runId,
                    attachments: generatedAttachments,
                    persona: persona,
                    source: surface,
                    recalledMemoryIds: finalResult?.recalledIds ?? [],
                    canonicalAssistantCompletion: true,
                    outcomeResult: finalResult,
                    outcomeContext: nil,
                    outcomeTurnID: TurnTraceContext.turnId ?? runId,
                    outcomeInterventionAssignment: nil
                )
                if let finalResult {
                    emitMetacognitiveTerminalTrace(
                        turnId: TurnTraceContext.turnId ?? runId,
                        sessionId: resolvedSession,
                        surface: surface,
                        context: nil,
                        result: finalResult
                    )
                }
            } catch {
                continuation.yield(.error("persist assistant turn failed: \(error)"))
            }
            if let promoter {
                await promoter.observeTurn(
                    userMessage: message,
                    assistantMessage: replyText,
                    sessionId: resolvedSession
                )
            }
        }
        continuation.finish()
    }

    /// U1 item 9: pick the append-only messages transport ONLY when the
    /// whole chain can serve it without losing live deltas; anything else
    /// fail-closes to the legacy grown-prompt shape (today's exact wire).
    ///   1. Rollback lever: NATIVE_AGENT_GROWN_PROMPT_COMPAT=1 (the same
    ///      item-8 lever) restores the grown-prompt wire shape on this path.
    ///   2. Capability: the injected streaming client must stream messages
    ///      (MessagesStreamingLLMClient — production SwiftNativeLLMClient
    ///      conforms; prompt-only mocks don't).
    ///   3. Credentials: the Anthropic OAUTH adapter is the only one with a
    ///      real messages SSE implementation. Without its auth file the
    ///      append-only-messages path has no streaming backend — strict
    ///      routing (9358710c) no longer silently falls through to the api-key
    ///      adapter, so this preflight gates the path off instead. Preflight
    ///      the same dataRoot path the compat gate already reads
    ///      providers/active.json from.
    private nonisolated static func isAppendOnlyMessagesEligible(
        streamingLLM: any StreamingLLMClient,
        dataRoot: URL
    ) -> Bool {
        guard !AnthropicOAuthDirectAdapter.GrownPromptCompat.effective else { return false }
        guard streamingLLM is any MessagesStreamingLLMClient else { return false }
        let authFile = dataRoot
            .appendingPathComponent("providers", isDirectory: true)
            .appendingPathComponent("anthropic_oauth_direct.json")
        return AnthropicOAuthDirectAdapter.hasUsableOAuthCredentials(at: authFile)
    }

    @discardableResult
    private nonisolated static func flushCompatibilityDeltaBuffer(
        _ pending: inout String,
        force: Bool,
        continuation: AsyncThrowingStream<TurnStreamEvent, Error>.Continuation
    ) -> Bool {
        guard !pending.isEmpty else { return false }
        // Final flush: stream EVERYTHING that remains. A real tool marker is
        // discarded via pendingDelta.removeAll() on the tool-call path BEFORE any
        // force flush runs, so when we reach here the iteration finished
        // tool-free and any "<tool"-looking text is prose that must be shown.
        // (Previously this short-circuited on "<tool" even when force==true, so a
        // reply merely MENTIONING "<tool" never streamed — frozen bubble then an
        // instant dump via .final. audit #6, 2026-06-14.)
        if force {
            continuation.yield(.delta(pending))
            pending = ""
            return true
        }
        // Non-force: stream prose up to the earliest point that could begin a
        // tool marker or Markdown pseudo-call, holding that candidate until the
        // iteration end disambiguates it (real marker -> parsed, malformed block
        // -> bounced, ordinary prose -> shown by the force pass). Keep a <=16-char
        // cross-chunk tail so a candidate forming at the boundary is not split.
        let holdFrom: String.Index
        if let r = ToolCallParser.earliestPotentialProtocolMarker(in: pending) {
            holdFrom = r.lowerBound
        } else {
            let tail = min(16, pending.count)
            holdFrom = pending.index(pending.endIndex, offsetBy: -tail)
        }
        guard holdFrom > pending.startIndex else { return false }
        let flush = String(pending[..<holdFrom])
        pending = String(pending[holdFrom...])
        if !flush.isEmpty {
            continuation.yield(.delta(flush))
            return true
        }
        return false
    }

    private nonisolated static func turnResult(
        _ result: TurnEngineResult,
        replacingToolDispatchesWith dispatches: [TurnEngineResult.ToolDispatchRecord],
        rawLLMResponse: String,
        providerCallCount: Int,
        replyOverride: String? = nil
    ) -> TurnEngineResult {
        TurnEngineResult(
            reply: replyOverride ?? result.reply,
            modelUsed: result.modelUsed,
            recalledIds: result.recalledIds,
            toolDispatches: dispatches,
            elapsedMs: result.elapsedMs,
            rawLLMResponse: rawLLMResponse,
            providerCallCount: providerCallCount,
            terminalObservation: result.terminalObservation
        )
    }

    private func textCompatibilityCognitiveRuntimeContext(
        surface: String,
        userMessage: String,
        runId: String,
        sessionId: String,
        fileAccess: String,
        projection: CognitiveTurnProjection?
    ) async -> String? {
        // Same one-line handling seam as the structured path (StructuredChat) —
        // this text-compat path is the PRIMARY one for Anthropic models, and the
        // guidance moved out of the capsule kernel, so it must ride both seams.
        guard let runtimeContext = Self.cognitiveRuntimeContext(
            runId: runId,
            sessionId: sessionId,
            surface: surface,
            fileAccess: fileAccess,
            capsule: projection?.capsule,
            posture: projection?.posture
        ) else { return nil }
        // R-F1 (2026-07-17): no commit here anymore — assembly must not consume
        // the Body-line suppress window before the provider accepts the turn.
        // The compat producer commits once, after its failure paths have all
        // returned early (same contract as the structured executors).
        return runtimeContext
    }
}
