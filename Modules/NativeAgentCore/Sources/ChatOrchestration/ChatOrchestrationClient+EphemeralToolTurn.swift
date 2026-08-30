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
        surface: String
    ) async throws -> ChatResponse {
        // P2-3: fold before anything derives from it (projection session id,
        // autonomy resolution, the provider-facing surface).
        let surface = WorkshopSurfaceVocabulary.foldLegacySpelling(surface)
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && attachments.isEmpty {
            throw ChatOrchestrationError.emptyMessage
        }

        let runId = UUID().uuidString
        let imageBlocks = Self.imageBlocksFromAttachments(attachments)
        let baseContext = try await engine.buildTurnContext(
            surface: surface,
            userMessage: message,
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
        let gated: any ToolDispatchClient
        if let autonomyResolver {
            // Restricted non-chat surfaces may supply a narrower resolver while
            // retaining the exact ordinary chain: SecurityCenter, file-access
            // gate, autonomy gate, and outer trace. The regular chat helper and
            // every default ephemeral caller remain untouched.
            let gate = AutonomyGate(trust: autonomyResolver, approvalFiler: approvalFiler)
            let fileAccessGated = FileAccessGatedDispatcher(inner: tools, fileAccess: fileAccess)
            let autonomyGated = AutonomyGatedDispatcher(
                inner: fileAccessGated,
                gate: gate,
                approvalFiler: approvalFiler,
                securityCenter: SwiftNativeSecurityCenter(dataRoot: dataRoot),
                hasFiler: approvalFiler != nil,
                approvalTimeoutSeconds: approvalTimeoutSeconds,
                verifiedSessionId: toolSessionId,
                // W2/W3-FIX-R2 1 — same inbox-backed injection approval check
                // as the ordinary chat chain; a narrower resolver must not mean
                // a weaker approval root.
                injectionApprovalVerifier: ApprovalInboxInjectionApprovalVerifier(dataRoot: dataRoot)
            )
            gated = ChatToolDispatchTracer(inner: autonomyGated, dataRoot: dataRoot)
        } else {
            gated = makeTracedGatedDispatcher(
                fileAccess: fileAccess,
                verifiedSessionId: toolSessionId
            )
        }
        // Temporary workers still own a real execution identity. Bind their
        // own run rather than leaving traces unknown or inheriting the parent
        // turn's ID; this creates no chat session or additional trace store.
        let result = try await TurnTraceContext.$bus.withValue(turnTraceBus) {
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
                preBuiltContext: projectedContext
            )
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
}
