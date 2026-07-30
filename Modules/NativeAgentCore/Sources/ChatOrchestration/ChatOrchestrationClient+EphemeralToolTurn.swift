import Foundation
import NativeAgentCore
import TrustCenter

extension SwiftNativeChatOrchestrationClient {
    /// Executes a one-shot tool-capable turn without creating chat session state.
    /// The caller owns the tool scope; mission synthesis supplies its restricted
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
        verifiedSessionId: String? = nil,
        surface: String
    ) async throws -> ChatResponse {
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
            serviceTier: baseContext.serviceTier,
            toolsAvailable: baseContext.toolsAvailable,
            systemPrompt: baseContext.systemPrompt,
            userMessage: baseContext.userMessage,
            toolSchemas: baseContext.toolSchemas,
            systemSegments: baseContext.systemSegments,
            imageBlocks: baseContext.imageBlocks,
            fluidContextTurn: baseContext.fluidContextTurn
        )
        // Ephemeral/mission turns are still turns of the same resident mind.
        // Freeze and commit the existing cognitive projection once, then feed
        // that exact capsule/posture through the ordinary runtime-context seam.
        // The synthetic identity is request-scoped and creates no chat session
        // or transcript owner.
        let projectionSessionId = "ephemeral:\(surface):\(runId)"
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
                verifiedSessionId: verifiedSessionId
            )
            gated = ChatToolDispatchTracer(inner: autonomyGated, dataRoot: dataRoot)
        } else {
            gated = makeTracedGatedDispatcher(
                fileAccess: fileAccess,
                verifiedSessionId: verifiedSessionId
            )
        }
        let result = try await LLMCallContext.$turnActiveTools.withValue(requestTools) {
            try await engine.executeTurnWithToolLoop(
                surface: surface,
                userMessage: message,
                sessionId: nil,
                runId: runId,
                maxIterations: toolLoopMaxIterations(for: surface),
                llm: llm,
                tools: gated,
                preBuiltContext: projectedContext
            )
        }
        // R-F1: commit the projection only after the provider accepted the turn
        // (a throw above skips this, leaving the suppress window unconsumed).
        await commitDeliveredCognitiveTurnProjection(
            pendingProjectionCommit,
            surface: surface,
            userMessage: message,
            sessionId: projectionSessionId
        )
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
