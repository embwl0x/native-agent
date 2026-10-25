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
// Blueprint: | `ChatOrchestrationClient+EphemeralToolTurn.swift` | `SwiftNativeChatOrchestrationClient`: `runEphemeralToolTurn`, `runPartToolTurn`; prepared part messages enter the same canonical loop and admitted routing with caller limits, restricted tools and taint, without persona/recall assembly, parent checkpoints or after-turn mind work; explicit part-thought surfaces admit their saved route without the parent's ProviderTurnChoice, omitted surfaces inherit; PartToolThinkingContext marks only that internal thought |

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
            var produced = ""
            do {
            let result = try await PartToolThinkingContext.$active.withValue(true) {
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
            } } } } } } } } }
            produced = result.reply
            guard result.completionState == .completed else {
                throw EphemeralToolTurnIncomplete(output: result.reply, reason: "The part thought did not complete.")
            }
            try Task.checkCancellation()
            let answer = produced
            await settle {
                await Self.recordAnswer(id: Experience.answer(run: thought), heardID: thought,
                    evidence: nil, state: .completed, dataRoot: root) {
                    Experience(id: Experience.answer(run: thought), kind: .answer, cause: [thought], face: Self.face(answer, []))
                }
            }
            return result.reply
            } catch {
                let answer = produced
                let state: TurnEngineResult.TerminalState = Task.isCancelled || error is CancellationError ? .stopped : .failed
                await settle {
                    await Self.recordAnswer(id: Experience.answer(run: thought), heardID: thought,
                        evidence: nil, state: state, dataRoot: root) {
                        Experience(id: Experience.answer(run: thought), kind: .answer, cause: [thought], face: Self.face(answer, []))
                    }
                }
                throw error
            }
        }
        if requestedSurface == nil, LLMCallContext.admittedModel != nil { return try await run() }
        // An explicit surface owns its saved route; a parent's per-turn pick
        // applies only when this thought did not select a surface of its own.
        let route = try await ProviderTurnChoice.$current.withValue(requestedSurface == nil ? ProviderTurnChoice.current : nil) {
            try await engine.checkedRouteAdmission(for: surface)
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
        // P2-3: fold before anything derives from it (projection session id,
        // autonomy resolution, the provider-facing surface).
        let surface = WorkshopSurfaceVocabulary.foldLegacySpelling(surface)
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty {
            throw ChatOrchestrationError.emptyMessage
        }

        let runId = UUID().uuidString
        // 2026-09-06: the Trust ▸ Multimodal gates apply on every lane that can
        // carry an attachment, not just the chat ones — otherwise "Allow vision
        // API calls" off is defeated by an execution turn.
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
            let (contextWithCognition, pendingProjectionCommit) = await Self.contextByAppendingCognitiveCapsule(
                to: context,
                surface: surface,
                userMessage: message,
                runId: runId,
                sessionId: projectionSessionId,
                fileAccess: fileAccess,
                projection: cognitiveProjection
            )
            return (contextWithCognition ?? context, pendingProjectionCommit)
        }
        // A caller that supplies any part of its route has that whole route
        // admitted once, before anything sizes against it (context, packet
        // budget, runtime line, cognitive capsule): every supplied part kept,
        // the rest the surface's pick. A caller that supplies none runs on the
        // route it was called under, as it always has.
        var route: TurnRouteAdmission?
        if !modelOverride.isEmpty || !effortOverride.isEmpty || !providerOverride.isEmpty || serviceTierOverride != nil {
            let surfaceRoute = try await engine.checkedRouteAdmission(for: surface, suppliedModel: modelOverride)
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
        // 2026-09-18: restricted non-chat surfaces keep their narrower trust
        // source and no first-conversation exemption (Sol P0-1); default
        // ephemeral callers retain the ordinary chat chain's exemption.
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
        ExperienceStore.record(dataRoot, runId) { store in
            try await store.begin(heard)
            try await store.append([.evidence(.init(source: "runtime", id: ExperienceStore.processID))], to: runId)
        }
        var answered = false
        defer {
            if !answered {
                ExperienceStore.record(dataRoot, runId) { store in
                    try await store.append([.letGo(key: "answer", reason: .failed)], to: runId)
                }
            }
        }
        let result: TurnEngineResult
        do {
            // Images and pending tool state belong to this worker's context,
            // never the parent turn or another worker that inherited it.
            result = try await ChatTurnExecution.$current.withValue(ChatTurnExecution()) {
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
                    providerAdmission: providerAdmission,
                    fileAccess: fileAccess
                )
            }
            }
            }
            }
            }
            }
        } catch TurnEngineError.streamCancelled {
            // No one watched this turn stream and it has no transcript to keep
            // a partial in, so a stop is a plain cancellation to its caller.
            throw CancellationError()
        } catch TurnEngineError.streamInterrupted(_, let underlying) {
            // Likewise: the caller gets the provider failure itself.
            throw underlying
        }
        // R-F1: commit the projection only after the provider accepted the turn
        // (a throw above skips this, leaving the suppress window unconsumed).
        await commitDeliveredCognitiveTurnProjection(
            pendingProjectionCommit,
            surface: surface,
            userMessage: message,
            sessionId: projectionSessionId,
            turnId: runId
        )
        if requireCompleted, result.completionState != .completed {
            throw EphemeralToolTurnIncomplete(
                output: result.reply,
                reason: "worker tool turn ended without a completed final reply; retained output is partial and attempted effects remain unverified"
            )
        }
        // The worker lane has no transcript row to settle, so its own promotion
        // starts here and runs on its own; the answer never waits for it. By
        // ticket, so a concurrent chat turn's pending capture is never adopted.
        await engine.startDeferredMemoryPromotion(ticket: result.memoryPromotionTicket)
        result.afterReply?.start()
        let generatedAttachments = ChatGeneratedImageArtifacts.attachments(
            from: result.toolDispatches,
            dataRoot: dataRoot
        )
        // Its answer goes back to its caller; it has no transcript row to stand on.
        await Self.recordAnswer(id: Experience.answer(run: runId), heardID: runId, evidence: nil,
                          state: result.resolvedTerminalReason(dataRoot: dataRoot).state, dataRoot: dataRoot) { [reply = result.reply] in
            Experience(id: Experience.answer(run: runId), kind: .answer, cause: [runId], face: Self.face(reply, generatedAttachments))
        }
        answered = true
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
}
