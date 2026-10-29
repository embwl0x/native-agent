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
// Blueprint: | `ChatOrchestrationClient+EphemeralToolTurn.swift` | `SwiftNativeChatOrchestrationClient`: `runEphemeralToolTurn`, `runPartToolTurn`; prepared part messages enter the same canonical loop and admitted routing with caller limits, restricted tools and taint, without persona/recall assembly, parent checkpoints or after-turn mind work; every exit joins answer/heard settlement with retained prose and dispatch artifacts; interrupted errors keep partial output and distinguish Stop; explicit part-thought surfaces admit their saved route without the parent's ProviderTurnChoice, omitted surfaces inherit; PartToolThinkingContext marks only that internal thought |

/// An internal thought owns no reply or after-turn mind work. It uses the
/// canonical loop and inherits its caller's gates, taint and remaining limits.
enum PartToolThinkingContext {
    @TaskLocal static var active = false
}

public typealias EphemeralToolTurnIncomplete = ChatTurnContracts.EphemeralToolTurnIncomplete

extension SwiftNativeChatOrchestrationClient {
    /// Prepared part input enters the existing tool-turn owner without persona,
    /// recall, cognition preparation or another provider route. The dispatcher
    /// supplied to this client is the part's own restricted host.
    public func runPartToolTurn(messages: [LLMMessage], surface requestedSurface: String? = nil) async throws -> String {
        guard let surface = requestedSurface ?? LLMCallContext.surface else {
            throw ChatOrchestrationError.underlying("A part thought needs an existing admitted routing surface.")
        }
        if let requestedSurface, !MODEL_SURFACES.contains(canonicalRoutingSurface(requestedSurface)) {
            throw ChatOrchestrationError.underlying("A part thought can select only an existing routing surface.")
        }
        guard let last = messages.last, last.role == .user else {
            throw ChatOrchestrationError.underlying("A tool-capable thought ends its messages with a user prompt.")
        }
        @Sendable func text(_ message: LLMMessage) -> String {
            message.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
        }
        var reach = TurnReach()
        let system = messages.prefix { $0.role == .system }
        reach.guidance = system.map(text).joined(separator: "\n\n")
        let history = messages.dropFirst(system.count).dropLast()
        let names = try await tools.listAvailableTools()
        let schemas = try await tools.listAvailableToolSchemas(named: Set(names))
        let run: @Sendable () async throws -> String = { [self, reach] in
            guard let model = LLMCallContext.admittedModel, let client = LLMCallContext.client else {
                throw ChatOrchestrationError.underlying("The part thought has no admitted model.")
            }
            let context = TurnContext(surface: surface, personaDocs: [:], personaFingerprint: "", recalled: [],
                modelId: model, reasoningEffort: LLMCallContext.reasoningEffort ?? "",
                providerId: LLMCallContext.providerId, serviceTier: LLMCallContext.serviceTier,
                toolsAvailable: names, userMessage: text(last), toolSchemas: schemas,
                historyMessages: Array(history), turnReach: reach)
            // The canonical loop owns transient provider recovery, context and
            // tool-contract evidence by turn id. A nested thought cannot borrow
            // its caller's identity and overwrite those owners' parent records.
            let thought = UUID().uuidString
            let root = dataRoot
            let cause = Experience.currentAct ?? TurnTraceContext.turnId
            let heard = Experience(id: thought, kind: .heard, cause: cause.map { [$0] } ?? [],
                face: Self.face(text(last), []), addressedTo: ["her"], owes: ["answer": .init(to: "caller")])
            let began = ExperienceStore.record(root, thought) { try await $0.begin(heard) }
            await began.value
            let observation = ToolLoopTraceObservation()
            var produced: TurnEngineResult?
            do {
            let result = try await ToolLoopTraceObservation.$current.withValue(observation) {
            try await PartToolThinkingContext.$active.withValue(true) {
            try await TurnTraceContext.$turnId.withValue(thought) {
            try await LLMCallContext.$sessionId.withValue(thought) {
            try await ConversationPrefixTelemetry.$sink.withValue(.unmeasuredRequestShape) {
            try await LLMCallContext.$turnActiveTools.withValue(Set(names)) {
            try await ReplyChoices.$current.withValue(nil) {
            try await DeskContinuationScope.$current.withValue(nil) {
            try await TurnCheckpointScope.$current.withValue(nil) {
            try await ChatTurnExecution.$current.withValue(ChatTurnExecution()) {
                try await engine.executeTurnWithStreamingToolLoop(surface: surface, userMessage: text(last),
                    toolSessionId: ChatToolSessionContext.verifiedSessionId, llm: client,
                    tools: tools, preBuiltContext: context, fileAccess: ChatToolSessionContext.fileAccess ?? "auto")
            } } } } } } } } } }
            produced = result
            guard result.completionState == .completed else {
                throw EphemeralToolTurnIncomplete(output: result.reply, reason: "The part thought did not complete.")
            }
            try Task.checkCancellation()
            await Self.settleEphemeralAnswer(runID: thought, output: result.reply,
                dispatches: result.toolDispatches, state: .completed, dataRoot: root)
            return result.reply
            } catch {
                let failure = Self.ephemeralFailure(error, produced: produced, observation: observation)
                await Self.settleEphemeralAnswer(runID: thought, output: failure.output,
                    dispatches: produced?.toolDispatches ?? observation.toolDispatches,
                    state: failure.state, dataRoot: root)
                throw failure.error
            }
        }
        if requestedSurface == nil, LLMCallContext.admittedModel != nil { return try await run() }
        // An explicit surface owns its saved route; a parent's per-turn pick
        // applies only when this thought did not select a surface of its own.
        let route = try await ProviderTurnChoice.$current.withValue(requestedSurface == nil ? ProviderTurnChoice.current : nil) {
            try await engine.router.checkedRouteAdmission(for: surface)
        }
        return try await withModelContext(route, surface: surface, run)
    }

    /// Executes a one-shot tool-capable turn without creating chat session state.
    /// The caller owns the tool scope; execution synthesis supplies its restricted
    /// read-only dispatcher. All configured schemas are request-scoped through
    /// `turnActiveTools`, so no transcript is needed.
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
        providerAdmission: (@Sendable () async throws -> Void)? = nil
    ) async throws -> ChatResponse {
        // Fold the surface before deriving identity, authority or provider routing.
        let surface = WorkshopSurfaceVocabulary.foldLegacySpelling(surface)
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty {
            throw ChatOrchestrationError.emptyMessage
        }

        let runId = UUID().uuidString
        // Trust's multimodal gates apply to every surface that carries attachments.
        let attachmentInput = try Self.turnAttachmentInput(
            message: message, attachments: attachments, dataRoot: dataRoot)
        let imageBlocks = attachmentInput.imageBlocks
        let modelOverride = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effortOverride = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerOverride = providerID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Ephemeral/execution turns are still turns of the same resident mind.
        // Freeze and commit the existing cognitive projection once, then feed
        // that exact capsule/posture through the ordinary runtime-context seam.
        // The synthetic identity is request-scoped and creates no chat session
        // or transcript owner.
        let projectionSessionId = "ephemeral:\(surface):\(runId)"
        // Lazy native tools still require a verified request identity even
        // though this path intentionally creates no chat-session row. The
        // synthetic identity expires with the request and grants no authority
        // beyond the resolver/membrane already supplied by the caller.
        let toolSessionId = verifiedSessionId ?? projectionSessionId
        let prepare = { [self] () async throws in
            let context = try await engine.buildTurnContext(
                surface: surface,
                userMessage: attachmentInput.userMessage,
                personaOverride: persona,
                imageBlocks: imageBlocks,
                sessionID: nil
            )
            let cognitiveProjection = await prepareCognitiveTurnProjection(
                surface: surface,
                userMessage: message,
                sessionId: projectionSessionId,
                runId: runId
            )
            let contextWithCognition = await Self.contextByAppendingCognitiveCapsule(
                to: context,
                projection: cognitiveProjection?.projection
            )
            return (contextWithCognition, cognitiveProjection)
        }
        // A caller that supplies any part of its route has that whole route
        // admitted once, before anything sizes against it (context, packet
        // budget, runtime line, cognitive capsule): every supplied part kept,
        // the rest the surface's pick. A caller that supplies none runs on the
        // route it was called under, as it always has.
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
        }
        let (projectedContext, pendingProjectionCommit) = if let route {
            try await withModelContext(route, surface: surface) { try await prepare() }
        } else {
            try await prepare()
        }
        let requestTools = Set(projectedContext.toolSchemas.map(\.name))
        // Restricted non-chat surfaces retain narrower trust without the first-conversation exemption; default callers keep it.
        let gated = makeGatedToolDispatchClient(
            tools: tools,
            fileAccess: fileAccess,
            approvalFiler: approvalFiler,
            approvalTimeoutSeconds: approvalTimeoutSeconds,
            dataRoot: dataRoot,
            verifiedSessionId: toolSessionId,
            tracePeerTurn: true,
            allowsFirstConversationExemption: true
        )
        // Temporary workers still own a real execution identity. Bind their
        // own run rather than leaving traces unknown or inheriting the parent
        // turn's ID; this creates no chat session or additional trace store.
        // The worker run is a turn of her mind hearing its brief, caused by the
        // turn that started it when one did; its answer returns to its caller.
        let heard = Experience(id: runId, kind: .heard, cause: TurnTraceContext.turnId.map { [$0] } ?? [],
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
            result = try await ToolLoopTraceObservation.$current.withValue(observation) {
            try await ChatTurnExecution.$current.withValue(ChatTurnExecution()) {
            try await PeerDataTaint.withScope {
            try await TurnTraceContext.$bus.withValue(turnTraceBus) {
            try await TurnTraceContext.$turnId.withValue(runId) {
            // A worker answers its caller, never the parent's reply: nothing it attaches goes there.
            try await ReplyChoices.$current.withValue(nil) {
            try await LLMCallContext.$turnActiveTools.withValue(requestTools) {
                try await engine.executeTurnWithStreamingToolLoop(
                    surface: surface,
                    userMessage: message,
                    sessionId: nil,
                    toolSessionId: toolSessionId,
                    runId: runId,
                    llm: llm,
                    tools: gated,
                    preBuiltContext: projectedContext,
                    onDelivery: { await self.commitDeliveredCognitiveTurnProjection(pendingProjectionCommit, turnId: runId) },
                    providerAdmission: providerAdmission,
                    fileAccess: fileAccess
                )
            }
            }
            }
            }
            }
            }
            }
        } catch {
            let failure = Self.ephemeralFailure(error, produced: nil, observation: observation)
            await Self.settleEphemeralAnswer(runID: runId, output: failure.output,
                dispatches: observation.toolDispatches, state: failure.state, dataRoot: dataRoot)
            throw failure.error
        }
        let state = Task.isCancelled ? TurnEngineResult.TerminalState.stopped
            : result.resolvedTerminalReason(dataRoot: dataRoot).state
        let generatedAttachments = await Self.settleEphemeralAnswer(runID: runId, output: result.reply,
            dispatches: result.toolDispatches, state: state, dataRoot: dataRoot)
        if state == .stopped {
            throw TurnEngineError.streamCancelled(partial: result.reply, underlying: CancellationError())
        }
        if requireCompleted, result.completionState != .completed {
            throw EphemeralToolTurnIncomplete(
                output: result.reply,
                reason: "worker tool turn ended without a completed final reply; retained output is partial and attempted effects remain unverified"
            )
        }
        await result.afterReply?.start()
        return ChatResponse(
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
    ) async -> [MultimodalAttachment] {
        let attachments = ChatGeneratedImageArtifacts.attachments(from: dispatches, dataRoot: dataRoot)
        await settle {
            await recordAnswer(runID: runID, heardID: runID, evidence: nil, state: state,
                dataRoot: dataRoot, words: output, attachments: attachments)
        }
        return attachments
    }

}
