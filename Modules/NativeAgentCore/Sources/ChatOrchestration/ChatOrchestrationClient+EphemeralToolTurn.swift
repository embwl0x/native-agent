import Foundation
import NativeAgentCore
import PersistenceCore
import TrustCenter

/// An engine-owned incomplete terminal, not a provider/transport failure.
/// Preserve the existing reply for the caller's ordinary retained-output cap.
public struct EphemeralToolTurnIncomplete: Error, Sendable {
    public let output: String
    public let reason: String
}

extension SwiftNativeChatOrchestrationClient {
    /// Executes a one-shot tool-capable turn without creating chat session state.
    /// The caller owns the tool scope; execution synthesis supplies its restricted
    /// read-only dispatcher. All configured schemas are request-scoped through
    /// `turnActiveTools`, so no `ActiveToolsStore` row or transcript is needed.
    public func runEphemeralToolTurn(
        message: String,
        model: String = "",
        reasoningEffort: String = "",
        fileAccess: String = "read_only",
        attachments: [MultimodalAttachment] = [],
        persona: String? = nil,
        autonomyResolver: (any AutonomyResolver)? = nil,
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
        let attachmentInput = Self.turnAttachmentInput(
            message: message, attachments: attachments, dataRoot: dataRoot)
        let imageBlocks = attachmentInput.imageBlocks
        let baseContext = try await engine.buildTurnContext(
            surface: surface,
            userMessage: attachmentInput.userMessage,
            personaOverride: persona,
            imageBlocks: imageBlocks,
            sessionID: nil
        )
        let modelOverride = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effortOverride = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = TurnContext(
            surface: baseContext.surface,
            personaID: baseContext.personaID,
            personaDocs: baseContext.personaDocs,
            recalled: baseContext.recalled,
            modelId: modelOverride.isEmpty ? baseContext.modelId : modelOverride,
            reasoningEffort: effortOverride.isEmpty ? baseContext.reasoningEffort : effortOverride,
            providerId: providerID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? providerID
                : baseContext.providerId,
            // nil preserves existing callers. A captured standard tier is
            // passed explicitly as "default", never nil/fresh-surface fallback.
            serviceTier: serviceTierOverride ?? baseContext.serviceTier,
            toolsAvailable: baseContext.toolsAvailable,
            systemPrompt: baseContext.systemPrompt,
            userMessage: baseContext.userMessage,
            toolSchemas: baseContext.toolSchemas,
            systemSegments: baseContext.systemSegments,
            imageBlocks: baseContext.imageBlocks,
            fluidContextTurn: baseContext.fluidContextTurn
        )
        // 2026-09-22: the Claude subscription refuses a native tools[] array, so
        // this structured loop failed every background turn bound to it.
        if Self.providerNeedsTextToolLane(context.providerId ?? LLMCallContext.providerId) {
            return try await runEphemeralTextLaneTurn(
                message: message, context: context, requestedModel: modelOverride,
                fileAccess: fileAccess, attachments: attachments, persona: persona,
                autonomyResolver: autonomyResolver, verifiedSessionId: verifiedSessionId,
                requireCompleted: requireCompleted, surface: surface,
                providerAdmission: providerAdmission)
        }
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
        let cognitiveProjection = await prepareCognitiveTurnProjection(
            surface: surface,
            userMessage: message,
            sessionId: projectionSessionId
        )
        let (contextWithCognition, pendingProjectionCommit) = await contextByAppendingCognitiveCapsule(
            to: context,
            surface: surface,
            userMessage: message,
            runId: runId,
            sessionId: projectionSessionId,
            fileAccess: fileAccess,
            projection: cognitiveProjection
        )
        let projectedContext = contextWithCognition ?? context
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
            trust: autonomyResolver ?? trust,
            verifiedSessionId: toolSessionId,
            tracePeerTurn: true,
            allowsFirstConversationExemption: autonomyResolver == nil
        )
        // Temporary workers still own a real execution identity. Bind their
        // own run rather than leaving traces unknown or inheriting the parent
        // turn's ID; this creates no chat session or additional trace store.
        let result = try await PeerDataTaint.withScope {
        try await TurnTraceContext.$bus.withValue(turnTraceBus) {
        try await TurnTraceContext.$turnId.withValue(runId) {
        try await LLMCallContext.$turnActiveTools.withValue(requestTools) {
            try await engine.executeTurnWithToolLoop(
                surface: surface,
                userMessage: message,
                sessionId: nil,
                toolSessionId: toolSessionId,
                runId: runId,
                maxIterations: toolLoopMaxIterations(for: surface),
                llm: llm,
                tools: gated,
                preBuiltContext: projectedContext,
                providerAdmission: providerAdmission
            )
        }
        }
        }
        }
        // R-F1: commit the projection only after the provider accepted the turn
        // (a throw above skips this, leaving the suppress window unconsumed).
        await commitDeliveredCognitiveTurnProjection(
            pendingProjectionCommit,
            surface: surface,
            userMessage: message,
            sessionId: projectionSessionId
        )
        if requireCompleted, result.completionState != .completed {
            throw EphemeralToolTurnIncomplete(
                output: result.reply,
                reason: "worker tool turn ended without a completed final reply; retained output is partial and attempted effects remain unverified"
            )
        }
        // The worker lane has no transcript row to settle, so this is where its
        // own promotion both starts and finishes (Astra audit 2, finding 4,
        // 2026-09-11). By ticket, so a concurrent chat turn's pending capture is
        // never adopted here (Astra comb 3 review, finding 1, 2026-09-12).
        await engine.awaitDeferredMemoryPromotion(ticket: result.memoryPromotionTicket)
        let generatedAttachments = ChatGeneratedImageArtifacts.attachments(
            from: result.toolDispatches,
            dataRoot: dataRoot
        )
        return ChatResponse(
            runId: runId,
            model: result.modelUsed,
            requestedModel: modelOverride.isEmpty ? nil : modelOverride,
            reasoningEffort: projectedContext.reasoningEffort,
            output: result.reply,
            sessionId: nil,
            personaFingerprint: Self.personaFingerprint(dataRoot: dataRoot),
            contextFingerprint: Self.contextFingerprint(recalledIds: result.recalledIds),
            attachments: generatedAttachments.isEmpty ? nil : generatedAttachments,
            providerCallCount: result.providerCallCount
        )
    }

    /// The text tool lane on a throwaway session nothing is written to. The
    /// admission check runs once up front: this lane has no per-call hook.
    private func runEphemeralTextLaneTurn(
        message: String,
        context: TurnContext,
        requestedModel: String,
        fileAccess: String,
        attachments: [MultimodalAttachment],
        persona: String?,
        autonomyResolver: (any AutonomyResolver)?,
        verifiedSessionId: String?,
        requireCompleted: Bool,
        surface: String,
        providerAdmission: (@Sendable () async throws -> Void)?
    ) async throws -> ChatResponse {
        try await providerAdmission?()
        let lane = EphemeralTextLane(
            sessionId: UUID().uuidString,
            autonomyResolver: autonomyResolver,
            verifiedSessionId: verifiedSessionId
        )
        defer {
            // The per-session tool contract is what the lane still writes: its
            // state .json, the .json.lock and the .declaration sidecar.
            let dir = dataRoot
                .appendingPathComponent("chat", isDirectory: true)
                .appendingPathComponent("active_tools", isDirectory: true)
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            where name.hasPrefix(lane.sessionId + ".") {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        let execution = try await EphemeralTextLane.$current.withValue(lane) {
        try await ChatTurnExecution.$current.withValue(nil) {
        try await LLMCallContext.$admittedModel.withValue(context.modelId) {
        try await LLMCallContext.$providerId.withValue(context.providerId ?? LLMCallContext.providerId) {
        try await LLMCallContext.$reasoningEffort.withValue(context.reasoningEffort) {
        try await LLMCallContext.$serviceTier.withValue(context.serviceTier) {
            try await executeTextStreamingCompatibilityChat(
                message: message,
                sessionId: lane.sessionId,
                model: context.modelId,
                reasoningEffort: context.reasoningEffort,
                fileAccess: fileAccess,
                attachments: attachments,
                persona: persona,
                surface: surface,
                suppressUserAppend: false,
                progress: nil
            )
        }
        }
        }
        }
        }
        }
        if requireCompleted, execution.turn.completionState != .completed {
            throw EphemeralToolTurnIncomplete(
                output: execution.response.output,
                reason: "worker tool turn ended without a completed final reply; retained output is partial and attempted effects remain unverified"
            )
        }
        await engine.awaitDeferredMemoryPromotion(ticket: execution.turn.memoryPromotionTicket)
        var response = execution.response
        response.sessionId = nil
        response.requestedModel = requestedModel.isEmpty ? nil : requestedModel
        return response
    }
}

/// An ephemeral turn riding the text tool lane. Keyed by its throwaway session
/// so a nested chat turn inside it still persists and gates normally.
struct EphemeralTextLane: Sendable {
    @TaskLocal static var current: EphemeralTextLane?
    let sessionId: String
    let autonomyResolver: (any AutonomyResolver)?
    let verifiedSessionId: String?

    static func owns(_ sessionId: String) -> Bool { current?.sessionId == sessionId }
}
