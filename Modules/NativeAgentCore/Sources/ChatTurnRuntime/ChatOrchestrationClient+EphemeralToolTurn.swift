import Experiences
import Foundation
import NativeAgentCore
import PersistenceCore
import TurnTrace
import TrustCenter
import AuthoredCapabilities
import Desk
import ChatSessionWork
import ProviderRouting
// Blueprint: | `ChatOrchestrationClient+EphemeralToolTurn.swift` | `SwiftNativeChatOrchestrationClient`; `runEphemeralToolTurn`; `runPartToolTurn` |

/// An internal thought owns no reply or after-turn mind work. It uses the
/// canonical loop and inherits its caller's gates, taint and remaining limits.

public typealias EphemeralToolTurnIncomplete = ChatTurnContracts.EphemeralToolTurnIncomplete

extension SwiftNativeChatOrchestrationClient {
    /// Prepared part input uses the canonical loop with its restricted dispatcher; it owns no extra persona, recall or provider assembly.
    public func runPartToolTurn(messages: [LLMMessage], surface requestedSurface: String? = nil, turn: Turn, work: ChatTurnWork,
        call: LLMCall) async throws -> String {
        let surface = requestedSurface ?? call.surface
        guard !surface.isEmpty else {
            throw ChatOrchestrationError.underlying("A part thought needs an existing admitted routing surface.")
        }
        if let requestedSurface, !MODEL_SURFACES.contains(canonicalRoutingSurface(requestedSurface)) {
            throw ChatOrchestrationError.underlying("A part thought can select only an existing routing surface.")
        }
        guard let last = messages.last, last.role == .user else {
            throw ChatOrchestrationError.underlying("A thought that can call app ends its messages with a user prompt.")
        }
        @Sendable func text(_ message: LLMMessage) -> String {
            message.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
        }
        var reach = TurnReach()
        let system = messages.prefix { $0.role == .system }
        reach.guidance = system.map(text).joined(separator: "\n\n")
        let history = messages.dropFirst(system.count).dropLast()
        let names = try await tools.listAvailableTools(turn: turn, surface: surface)
        let schemas = try await tools.listAvailableToolSchemas(named: Set(names), turn: turn, surface: surface)
        let run: @Sendable (Turn) async throws -> String = { [self, reach] turn in
            guard let model = turn.admission?.model, let client = turn.client else {
                throw ChatOrchestrationError.underlying("The part thought has no admitted model.")
            }
            let context = TurnContext(surface: surface, personaDocs: [:], personaFingerprint: "", recalled: [],
                modelId: model, reasoningEffort: turn.admission?.reasoningEffort ?? "",
                providerId: turn.admission?.provider, serviceTier: turn.admission?.serviceTier,
                toolsAvailable: names, userMessage: text(last), toolSchemas: schemas,
                historyMessages: Array(history), turnReach: reach)
            // Nested thoughts need their own turn identity so provider recovery and contract evidence cannot overwrite parent records.
            let thought = UUID().uuidString
            let root = dataRoot
            let cause = turn.id
            let heard = Experience(id: thought, kind: .heard, cause: [cause],
                face: Self.face(text(last), []), addressedTo: ["her"], owes: ["answer": .init(to: "caller")])
            let began = ExperienceStore.record(root, thought) { try await $0.begin(heard) }
            await began.value
            let turn = turn.derived(id: thought, run: thought)
            let observation = ToolLoopTraceObservation()
            var produced: TurnEngineResult?
            do {
            let result = try await holding(turn.with(\.observation, observation)) { turn in
            try await holding(work.with(\.thinking, true)) { work in
            try await TurnTraceContext.$turnId.withValue(thought) {
            try await holding(call.with(\.session, thought)) { call in
            try await holding(work.with(\.prefixTelemetry, .unmeasuredRequestShape)) { work in
            try await holding(turn.with(\.offeredTools, Set(names))) { turn in
            try await holding(turn.with(\.replyChoices, nil)) { turn in
            try await holding(work.with(\.journal, nil)) { work in
            try await holding(work.with(\.checkpoint, nil)) { work in
            try await holding(turn.with(\.execution, ChatTurnExecution())) { turn in
                try await engine.executeTurnWithStreamingToolLoop(surface: surface, userMessage: text(last),
                    toolSessionId: turn.verifiedSessionID, llm: client,
                    tools: ExpansionDispatcher(inner: tools, dataRoot: root, session: turn.verifiedSessionID, work: work),
                    preBuiltContext: context, fileAccess: turn.fileAccess ?? "auto", turn: turn, work: work, call: call)
            } } } } } } } } } }
            produced = result
            guard result.completionState == .completed else {
                throw EphemeralToolTurnIncomplete(output: result.reply, reason: "The part thought did not complete.")
            }
            try Task.checkCancellation()
            _ = try await Self.settleEphemeralAnswer(runID: thought, output: result.reply,
                dispatches: result.toolDispatches, state: .completed, dataRoot: root)
            return result.reply
            } catch {
                let failure = Self.ephemeralFailure(error, produced: produced, observation: observation)
                // The thought's own failure is the answer; a settlement that also fails is reported beside it, never in its place.
                do {
                    _ = try await Self.settleEphemeralAnswer(runID: thought, output: failure.output,
                        dispatches: produced?.toolDispatches ?? observation.toolDispatches,
                        state: failure.state, dataRoot: root)
                } catch let settlement {
                    nativeLog("Part thought %@ settlement failed after its own failure: %@", thought, settlement.localizedDescription)
                }
                throw failure.error
            }
        }
        if requestedSurface == nil, turn.admission?.model != nil { return try await run(turn) }
        // An explicit surface owns its saved route; a parent's per-turn pick
        // applies only when this thought did not select a surface of its own.
        let route = try await engine.router.checkedRoutingSnapshot().routeAdmission(for: surface,
            choice: requestedSurface == nil ? turn.providerChoice : nil)
        return try await withModelContext(route, surface: surface, turn: turn, run)
    }

    /// Request-scoped tool schemas and the caller's restricted dispatcher let this turn run without owning a chat transcript.
    public func runEphemeralToolTurn(
        message: String,
        model: String = "",
        reasoningEffort: String = "",
        fileAccess: String = "read_only",
        attachments: [MultimodalAttachment] = [],
        persona: String? = nil,
        providerID: String? = nil,
        serviceTierOverride: String? = nil,
        verifiedSessionId: String? = nil,
        requireCompleted: Bool = false,
        surface: String,
        providerAdmission: (@Sendable () async throws -> Void)? = nil,
        purpose: String = "other",
        turn: Turn, work: ChatTurnWork
    ) async throws -> ChatResponse {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty {
            throw ChatOrchestrationError.emptyMessage
        }

        let runId = Turn.mintID()
        let parentID = turn.id
        let thoughtTurn = turn.derived(id: runId, run: runId).with(\.session, nil)
        // Trust's multimodal gates apply to every surface that carries attachments.
        let attachmentInput = try Self.turnAttachmentInput(
            message: message, attachments: attachments, dataRoot: dataRoot)
        let imageBlocks = attachmentInput.imageBlocks
        let modelOverride = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effortOverride = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerOverride = providerID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Freeze and commit one cognitive projection for the turn; request-scoped identity creates no session or transcript owner.
        let projectionSessionId = "ephemeral:\(surface):\(runId)"
        // Native tools require verified request identity even without a session row; it expires with the request and widens no authority.
        let toolSessionId = verifiedSessionId ?? projectionSessionId
        let prepare = { [self] (turn: Turn) async throws in
            let context = try await engine.buildTurnContext(
                surface: surface,
                userMessage: attachmentInput.userMessage,
                personaOverride: persona,
                imageBlocks: imageBlocks,
                sessionID: verifiedSessionId,
             turn: turn, work: work)
            let cognitiveProjection = try await prepareCognitiveTurnProjection(
                surface: surface,
                userMessage: message,
                sessionId: projectionSessionId,
                runId: runId,
             turn: turn)
            let contextWithCognition = await Self.contextByAppendingCognitiveCapsule(
                to: context,
                projection: cognitiveProjection?.projection
            )
            return (turn, contextWithCognition, cognitiveProjection)
        }
        // Admit any explicitly supplied route before sizing context; preserve every supplied field and resolve the rest from its surface.
        // An unadmitted thought obtains its route here; preparation never chooses a model.
        var route: TurnRouteAdmission?
        if !modelOverride.isEmpty || !effortOverride.isEmpty || !providerOverride.isEmpty || serviceTierOverride != nil {
            let surfaceRoute = try await engine.router.checkedRouteAdmission(for: surface, suppliedModel: modelOverride)
            route = TurnRouteAdmission(
                routingSurface: surfaceRoute.routingSurface,
                modelId: modelOverride.isEmpty ? surfaceRoute.modelId : modelOverride,
                reasoningEffort: effortOverride.isEmpty ? surfaceRoute.reasoningEffort : effortOverride,
                providerId: providerOverride.isEmpty ? surfaceRoute.providerId : providerOverride,
                serviceTier: serviceTierOverride ?? surfaceRoute.serviceTier
            )
        } else if thoughtTurn.admission == nil {
            route = try await engine.router.checkedRoutingSnapshot().routeAdmission(
                for: surface, choice: thoughtTurn.providerChoice)
        }
        let (turn, projectedContext, pendingProjectionCommit) = if let route {
            try await withModelContext(route, surface: surface, turn: thoughtTurn) { turn in try await prepare(turn) }
        } else {
            try await prepare(thoughtTurn)
        }
        let call = LLMCall(turn: turn, surface: surface, purpose: purpose, session: runId)
        let requestTools = Set(projectedContext.toolSchemas.map(\.name))
        // Every surface uses ordinary Trust; successful chat writes settle exact-session progression.
        let gated = makeGatedToolDispatchClient(
            tools: tools,
            fileAccess: fileAccess,
            approvalFiler: approvalFiler,
            approvalTimeoutSeconds: approvalTimeoutSeconds,
            dataRoot: dataRoot,
            verifiedSessionId: toolSessionId,
            tracePeerTurn: true,
            work: work
        )
        // Bind each worker's own run ID so its traces cannot be unknown or overwrite the parent turn.
        // Its answer belongs to its caller, without creating a conversation or trace store.
        let heard = Experience(id: runId, kind: .heard, cause: [parentID],
                               face: Self.face(message, []), addressedTo: ["her"],
                               owes: ["answer": .init(to: "caller")])
        let began = ExperienceStore.record(dataRoot, runId) { store in
            try await store.begin(heard)
            try await store.append([.evidence(.init(source: "runtime", id: ExperienceStore.processID))], to: runId)
        }
        await began.value
        let observation = ToolLoopTraceObservation()
        let result: TurnEngineResult
        do {
            // Images and pending tool state belong to this worker's context,
            // never the parent turn or another worker that inherited it.
            result = try await holding(turn.with(\.observation, observation)) { turn in
            try await holding(turn.with(\.execution, ChatTurnExecution())) { turn in
            try await holding(turn.with(\.peerSteering, turn.peerSteering ?? PeerDataTaint())) { turn in
            try await TurnTraceContext.$bus.withValue(turnTraceBus) {
            try await TurnTraceContext.$turnId.withValue(runId) {
            // A worker answers its caller, never the parent's reply: nothing it attaches goes there.
            try await holding(turn.with(\.replyChoices, nil)) { turn in
            try await holding(turn.with(\.offeredTools, requestTools)) { turn in
                try await engine.executeTurnWithStreamingToolLoop(
                    surface: surface,
                    userMessage: message,
                    sessionId: nil,
                    toolSessionId: toolSessionId,
                    runId: runId,
                    llm: llm,
                    tools: gated,
                    preBuiltContext: projectedContext,
                    onDelivery: { await self.commitDeliveredCognitiveTurnProjection(pendingProjectionCommit, turn: turn) },
                    providerAdmission: providerAdmission,
                    fileAccess: fileAccess,
                 turn: turn, work: work, call: call)
            }
            }
            }
            }
            }
            }
            }
        } catch {
            let failure = Self.ephemeralFailure(error, produced: nil, observation: observation)
            try await Self.settleEphemeralAnswer(runID: runId, output: failure.output,
                dispatches: observation.toolDispatches, state: failure.state, dataRoot: dataRoot)
            throw failure.error
        }
        let state = Task.isCancelled ? TurnEngineResult.TerminalState.stopped
            : result.resolvedTerminalReason(dataRoot: dataRoot).state
        let generatedAttachments = try await Self.settleEphemeralAnswer(runID: runId, output: result.reply,
            dispatches: result.toolDispatches, state: state, dataRoot: dataRoot)
        if state == .stopped {
            throw TurnEngineError.streamCancelled(partial: result.reply, underlying: CancellationError())
        }
        if requireCompleted, result.completionState != .completed {
            throw EphemeralToolTurnIncomplete(
                output: result.reply,
                reason: "worker turn ended without a completed final reply; retained output is partial and attempted effects remain unverified"
            )
        }
        await result.afterReply?.start()
        let response = ChatResponse(
            runId: runId,
            model: result.modelUsed,
            requestedModel: modelOverride.isEmpty ? nil : modelOverride,
            reasoningEffort: projectedContext.reasoningEffort,
            output: result.reply,
            sessionId: nil,
            personaFingerprint: projectedContext.personaFingerprint,
            contextFingerprint: Self.contextFingerprint(recalledIds: result.recalledIds),
            attachments: generatedAttachments.isEmpty ? nil : generatedAttachments,
            providerCallCount: result.providerCallCount,
            terminalState: result.resolvedTerminalReason(dataRoot: dataRoot).state
        )
        if result.cognitiveContextDelivered, response.terminalState == .completed, !response.isSilentCompletion {
            await settle { [self] in await self.commitRepliedCognitiveTurnProjection(pendingProjectionCommit) }
        }
        return response
    }

    /// Keep the canonical partial-output error carriers instead of translating
    /// them into errors that have no place for the produced answer.
    private static func ephemeralFailure(_ error: any Error, produced: TurnEngineResult?,
        observation: ToolLoopTraceObservation
    ) -> (output: String, state: TurnEngineResult.TerminalState, error: any Error) {
        let partial: String
        let underlying: any Error
        let stopped: Bool
        switch error {
        case TurnEngineError.streamCancelled(let text, let cause):
            partial = text; underlying = cause; stopped = true
        case TurnEngineError.streamInterrupted(let text, let cause):
            partial = text; underlying = cause; stopped = Task.isCancelled
        default:
            partial = (error as? EphemeralToolTurnIncomplete)?.output ?? observation.partialReply
            underlying = error; stopped = Task.isCancelled || error is CancellationError
        }
        let output = produced?.reply ?? partial
        let retained: any Error
        if stopped { retained = TurnEngineError.streamCancelled(partial: output, underlying: underlying) }
        else if let incomplete = error as? EphemeralToolTurnIncomplete { retained = incomplete }
        else { retained = TurnEngineError.streamInterrupted(partial: output, underlying: underlying) }
        return (output, stopped ? .stopped : .failed, retained)
    }

    @discardableResult
    private static func settleEphemeralAnswer(runID: String, output: String,
        dispatches: [TurnEngineResult.ToolDispatchRecord], state: TurnEngineResult.TerminalState, dataRoot: URL
    ) async throws -> [MultimodalAttachment] {
        let attachments = ChatGeneratedImageArtifacts.attachments(from: dispatches, dataRoot: dataRoot)
        let answer = ChatResponse(runId: runID, model: "", output: output, attachments: attachments, terminalState: state)
        await settle {
            await recordAnswer(runID: runID, heardID: runID, evidence: nil, state: state,
                dataRoot: dataRoot, words: output, attachments: attachments, silence: answer.isSilentCompletion ? runID : nil)
        }
        if answer.isSilentCompletion,
           try silentTurn(dataRoot: dataRoot, sessionId: nil, runId: runID, turnId: runID) == nil {
            throw ChatOrchestrationError.underlying("The turn's chosen silence could not be saved; repair its experience record.")
        }
        return attachments
    }

}
